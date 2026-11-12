// Download a few freely licensed food photos from Wikimedia Commons for
// checking photo recognition (into .cache/testimg/, not committed).
//   node fetch_test_images.mjs
import { mkdirSync, writeFileSync, existsSync } from 'node:fs';

const dir = new URL('./.cache/testimg/', import.meta.url);
mkdirSync(dir, { recursive: true });
const UA = 'Nouri-dev/0.1 (food recognition test; local only)';
const queries = {
  lahmacun: 'lahmacun', menemen: 'menemen', simit: 'simit', lentil_soup: 'mercimek çorbası', baklava: 'baklava',
  manti: 'mantı yogurt', pilaf: 'pirinç pilavı', kofte: 'ızgara köfte', doner: 'döner kebap', sarma: 'yaprak sarma',
  kuru_fasulye: 'kuru fasulye yemeği', karniyarik: 'karnıyarık', breakfast: 'Turkish breakfast', boiled_egg: 'boiled egg',
  banana: 'banana fruit', pizza: 'pizza margherita', ayran: 'ayran', cacik: 'cacık', borek: 'su böreği', kunefe: 'künefe',
};
for (const [key, q] of Object.entries(queries)) {
  if (existsSync(new URL(`${key}.jpg`, dir))) continue;
  const api = `https://commons.wikimedia.org/w/api.php?action=query&format=json&generator=search&gsrnamespace=6&gsrlimit=5` +
    `&gsrsearch=${encodeURIComponent(`${q} filetype:bitmap`)}&prop=imageinfo&iiprop=url|mime&iiurlwidth=640`;
  const res = await fetch(api, { headers: { 'User-Agent': UA } });
  const pages = Object.values((await res.json()).query?.pages ?? {}).sort((a, b) => a.index - b.index);
  const hit = pages.find((p) => p.imageinfo?.[0]?.mime === 'image/jpeg');
  if (!hit) { console.log(`${key}: no jpeg found`); continue; }
  const img = await fetch(hit.imageinfo[0].thumburl, { headers: { 'User-Agent': UA } });
  writeFileSync(new URL(`${key}.jpg`, dir), Buffer.from(await img.arrayBuffer()));
  console.log(`${key}: ${hit.title}`);
}
