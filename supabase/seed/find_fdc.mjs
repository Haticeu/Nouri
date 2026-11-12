// Helper for curating catalog.mjs: show the closest FDC foods for each query.
//   node find_fdc.mjs "egg whole boiled" "lentil soup" ...
import { load, DATASETS } from './fdc.mjs';

const queries = process.argv.slice(2);
const all = Object.keys(DATASETS).flatMap((d) => [...load(d).foods.values()]);
for (const q of queries) {
  const words = q.toLowerCase().split(/\s+/).filter(Boolean);
  const scored = all
    .map((f) => {
      const d = f.description.toLowerCase();
      if (!words.every((w) => d.includes(w))) return null;
      return { f, score: d.length };
    })
    .filter(Boolean)
    .sort((a, b) => a.score - b.score)
    .slice(0, 6);
  console.log(`\n# ${q}`);
  for (const { f } of scored) {
    console.log(`  [${f.dataset}] ${f.fdc_id} | ${f.description} | ${f.n.kcal ?? '?'} kcal P${f.n.protein ?? '?'} C${f.n.carbs ?? '?'} F${f.n.fat ?? '?'}`);
  }
  if (!scored.length) console.log('  (no match)');
}
