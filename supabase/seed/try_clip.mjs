// Quick accuracy check: MobileCLIP-S0 zero-shot over the Nouri food catalog.
//   node try_clip.mjs [dtype]   (dtype: fp32 | q8; default fp32)
import { readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { AutoTokenizer, CLIPTextModelWithProjection, AutoProcessor, CLIPVisionModelWithProjection, RawImage, env } from '@huggingface/transformers';
import catalog from './catalog.mjs';

env.cacheDir = fileURLToPath(new URL('./.cache/hf/', import.meta.url));
// onnxruntime-node needs a newer VC++ runtime here; use the WebAssembly runtime from disk.
env.backends.onnx.wasm.wasmPaths = new URL('./node_modules/onnxruntime-web/dist/', import.meta.url).href;
env.backends.onnx.wasm.numThreads = 1;
const MODEL = 'Xenova/mobileclip_s0';
const dtype = process.argv[2] ?? 'fp32';

const prompts = (f) => {
  const names = [f.en, ...(f.aliases ?? []).filter((a) => /^[a-z ,'-]+$/i.test(a))].slice(0, 3);
  return [...names.map((n) => `a photo of ${n.replace(/\s*\(.*\)/, '')}, a type of food.`), `a photo of ${f.tr}, a Turkish dish.`];
};

const tokenizer = await AutoTokenizer.from_pretrained(MODEL);
const textModel = await CLIPTextModelWithProjection.from_pretrained(MODEL, { dtype, device: 'cpu' });
const processor = await AutoProcessor.from_pretrained(MODEL);
const visionModel = await CLIPVisionModelWithProjection.from_pretrained(MODEL, { dtype, device: 'cpu' });

const norm = (v) => { const n = Math.hypot(...v); return v.map((x) => x / n); };
const embedText = async (texts) => {
  const { text_embeds } = await textModel(tokenizer(texts, { padding: 'max_length', max_length: 77, truncation: true }));
  return text_embeds.tolist().map(norm);
};

const foods = [];
for (const f of catalog) {
  const e = await embedText(prompts(f));
  foods.push({ key: f.key, tr: f.tr, emb: norm(e[0].map((_, i) => e.reduce((s, v) => s + v[i], 0))) });
}

const dir = new URL('./.cache/testimg/', import.meta.url);
for (const file of readdirSync(dir)) {
  const image = await RawImage.read(fileURLToPath(new URL(file, dir)));
  const { image_embeds } = await visionModel(await processor(image));
  const img = norm(image_embeds.tolist()[0]);
  const scored = foods.map((f) => ({ f, s: f.emb.reduce((a, x, i) => a + x * img[i], 0) })).sort((a, b) => b.s - a.s);
  console.log(`${file.padEnd(18)} -> ${scored.slice(0, 4).map((x) => `${x.f.tr} ${(x.s * 100).toFixed(1)}`).join(' | ')}`);
}
