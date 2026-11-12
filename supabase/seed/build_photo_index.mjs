// Build the files the app uses to recognise food in photos, for free and on
// the device (no API, no internet needed once installed):
//
//   app/assets/ai/food_vision.onnx   MobileCLIP-S0 image encoder (Apple, via
//                                    Xenova/mobileclip_s0 on Hugging Face)
//   app/assets/ai/food_index.bin     one text embedding per food (Float32, N x 512)
//   app/assets/ai/food_index.json    { model, dim, keys: [seed_key, ...] }
//
// MobileCLIP compares a photo with text, so we "teach" it our foods by
// describing each one (catalog names + looks.mjs). The photo's embedding is
// compared with every food's; the closest foods are offered to the user, who
// confirms. Calories always come from the foods table, never from the model.
//
//   node build_photo_index.mjs                 build (default: full precision model)
//   node build_photo_index.mjs --dtype q8      smaller quantized model (11 MB)
//   node build_photo_index.mjs --test          also score the photos in .cache/testimg/
import { copyFileSync, mkdirSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { AutoTokenizer, CLIPTextModelWithProjection, AutoProcessor, CLIPVisionModelWithProjection, RawImage, env } from '@huggingface/transformers';
import catalog from './catalog.mjs';
import looks from './looks.mjs';

const MODEL = 'Xenova/mobileclip_s0';
const args = process.argv.slice(2);
const dtype = args.includes('--dtype') ? args[args.indexOf('--dtype') + 1] : 'fp32';
env.cacheDir = fileURLToPath(new URL('./.cache/hf/', import.meta.url));
// onnxruntime-node needs a newer VC++ runtime on some PCs; the WebAssembly runtime works everywhere.
env.backends.onnx.wasm.wasmPaths = new URL('./node_modules/onnxruntime-web/dist/', import.meta.url).href;
env.backends.onnx.wasm.numThreads = 1;

const norm = (v) => { const n = Math.hypot(...v); return v.map((x) => x / n); };
const mean = (vs) => norm(vs[0].map((_, i) => vs.reduce((s, v) => s + v[i], 0) / vs.length));

const prompts = (f) => {
  const english = [f.en, ...(f.aliases ?? []).filter((a) => /^[a-z ,'&-]+$/i.test(a))]
    .map((n) => n.replace(/\s*\(.*?\)/g, '').trim()).filter(Boolean);
  return [
    ...(looks[f.key] ? [`a photo of ${looks[f.key]}.`] : []),
    ...[...new Set(english)].slice(0, 3).map((n) => `a photo of ${n}, a type of food.`),
  ];
};

const tokenizer = await AutoTokenizer.from_pretrained(MODEL);
const textModel = await CLIPTextModelWithProjection.from_pretrained(MODEL, { dtype: 'fp32', device: 'cpu' });
const embedTexts = async (texts) => {
  // MobileCLIP's text model expects exactly 77 tokens.
  const { text_embeds } = await textModel(tokenizer(texts, { padding: 'max_length', max_length: 77, truncation: true }));
  return text_embeds.tolist().map(norm);
};

const foods = [];
for (const f of catalog) foods.push({ key: f.key, tr: f.tr, emb: mean(await embedTexts(prompts(f))) });
const dim = foods[0].emb.length;

const out = fileURLToPath(new URL('../../app/assets/ai/', import.meta.url));
mkdirSync(out, { recursive: true });
const bin = new Float32Array(foods.length * dim);
foods.forEach((f, i) => bin.set(f.emb, i * dim));
writeFileSync(out + 'food_index.bin', Buffer.from(bin.buffer));
writeFileSync(out + 'food_index.json', JSON.stringify({
  model: `${MODEL} (${dtype})`, dim, image_size: 256, keys: foods.map((f) => f.key),
}));
const onnxName = dtype === 'q8' ? 'vision_model_quantized.onnx' : 'vision_model.onnx';
const visionModel = await CLIPVisionModelWithProjection.from_pretrained(MODEL, { dtype, device: 'cpu' });
const cached = fileURLToPath(new URL(`./.cache/hf/${MODEL}/onnx/${onnxName}`, import.meta.url));
if (!existsSync(cached)) throw new Error(`model file not found at ${cached}`);
copyFileSync(cached, out + 'food_vision.onnx');
console.log(`Wrote ${foods.length} foods x ${dim} and the ${dtype} image model to app/assets/ai/`);

if (args.includes('--test')) {
  const processor = await AutoProcessor.from_pretrained(MODEL);
  const dir = new URL('./.cache/testimg/', import.meta.url);
  for (const file of readdirSync(dir)) {
    const { image_embeds } = await visionModel(await processor(await RawImage.read(fileURLToPath(new URL(file, dir)))));
    const img = norm(image_embeds.tolist()[0]);
    const scored = foods.map((f) => ({ f, s: f.emb.reduce((a, x, i) => a + x * img[i], 0) })).sort((a, b) => b.s - a.s);
    console.log(`${file.padEnd(18)} -> ${scored.slice(0, 4).map((x) => `${x.f.tr} ${(x.s * 100).toFixed(1)}`).join(' | ')}`);
  }
}
