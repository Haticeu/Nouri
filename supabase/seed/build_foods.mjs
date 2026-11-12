// Build the food seed migration from catalog.mjs + USDA FoodData Central.
//
//   node build_foods.mjs            -> writes ../migrations/20261024000100_food_seed.sql
//   node build_foods.mjs --report   -> also prints every food with its units
//
// Nutrition values and portion weights come only from the FDC files in
// .cache/ (see fdc.mjs). Household units are derived from USDA portions:
//   su bardağı   = USDA cup grams × 200 / 236.6   (Turkish water glass, 200 ml)
//   çay bardağı  = USDA cup grams × 100 / 236.6   (tea glass, 100 ml; drinks only)
//   ml           = USDA cup (or fl oz) grams per ml (drinks only)
//   yemek kaşığı = USDA tablespoon, çay kaşığı = USDA teaspoon
//   dilim        = USDA slice; adet = USDA piece / small / medium / large
//   porsiyon     = USDA FNDDS "Quantity not specified" (USDA's typical amount)
// kase, kepçe, tatlı kaşığı and avuç have no published source and are left
// for dietitians to add.
import { writeFileSync } from 'node:fs';
import { load } from './fdc.mjs';
import catalog from './catalog.mjs';

const CUP_ML = 236.588;
const FL_OZ_ML = 29.5735;
const LABEL = { sr_legacy: 'SR Legacy', foundation: 'Foundation', fndds: 'FNDDS' };

const byId = new Map();
for (const d of ['foundation', 'sr_legacy', 'fndds']) for (const [id, food] of load(d).foods) byId.set(id, food);

const describe = (p) => {
  const unit = p.unit === 'undetermined' ? '' : p.unit;
  const mod = /^\d+$/.test(p.modifier) ? '' : p.modifier;
  return [unit, mod, p.description].filter(Boolean).join(' ').toLowerCase().replace(/\s+/g, ' ').trim().replace(/^1 /, '');
};
const r1 = (n) => Math.round(n * 10) / 10;
const r2 = (n) => Math.round(n * 100) / 100;

const PIECE = /^(piece|roll|sandwich|egg|fruit|olive|pat\b|cube|serving 1 cube|bagel|croissant|muffin|pancake|waffle|taco|burrito|enchilada|tamale|empanada|quesadilla|hot dog|burger|hamburger|cheeseburger|doughnut|cookie|biscuit|nugget|wing|drumstick|patty|link|frank|sausage|bar\b|date|fig|clove|pepper|tomato|onion|carrot|kiwi|banana|apple|orange|peach|pear|plum|tangerine|apricot|pita|tortilla|naan|sushi|egg roll|pierogi|ravioli|dumpling)/;
const SIZE = { small: 'küçük', medium: 'orta', large: 'büyük' };

/** USDA portions -> [{unit, size, grams, note}] */
function deriveUnits(entry, portions) {
  const units = [];
  const add = (unit, size, grams, note) => {
    if (entry.skip?.includes(unit) || !(grams > 0)) return;
    if (units.some((u) => u.unit === unit && u.size === size)) return;
    units.push({ unit, size, grams: r1(grams), note });
  };
  const list = portions.map((p) => ({ ...p, text: describe(p), per1: p.grams / (p.amount || 1) }));

  // Cup -> su bardağı (and drinks: çay bardağı, ml). Plain "cup" beats "cup, chopped".
  const cups = list.filter((p) => /^cups?\b/.test(p.text) && !/crumb|cube/.test(p.text))
    .sort((a, b) => a.text.length - b.text.length);
  const flOz = list.find((p) => /^fl oz\b|^fluid ounce/.test(p.text));
  const cup = cups[0];
  if (cup) add('su bardağı', null, cup.per1 * 200 / CUP_ML, `USDA "${cup.text}" = ${r1(cup.per1)} g, scaled to 200 ml`);
  if (entry.liquid) {
    const perMl = cup ? cup.per1 / CUP_ML : flOz ? flOz.per1 / FL_OZ_ML : null;
    if (perMl) {
      const from = cup ? `USDA "${cup.text}" = ${r1(cup.per1)} g` : `USDA "${flOz.text}" = ${r1(flOz.per1)} g`;
      if (!cup) add('su bardağı', null, perMl * 200, `${from}, scaled to 200 ml`);
      add('çay bardağı', null, perMl * 100, `${from}, scaled to 100 ml`);
      units.push({ unit: 'ml', size: null, grams: Math.round(perMl * 1000) / 1000, note: `${from}, per ml` });
    }
  }
  const tbsp = list.find((p) => /^(tbsp|tablespoons?)\b/.test(p.text));
  if (tbsp) add('yemek kaşığı', null, tbsp.per1, `USDA "${tbsp.text}"`);
  const tsp = list.find((p) => /^(tsp|teaspoons?)\b/.test(p.text));
  if (tsp) add('çay kaşığı', null, tsp.per1, `USDA "${tsp.text}"`);

  // A wedge of melon or cheese is what Turkish calls a dilim.
  for (const p of list.filter((x) => /^(slices?|wedge)\b/.test(x.text) && !/very thin|crust not eaten/.test(x.text))) {
    const size = /large/.test(p.text) ? 'büyük' : /thin|small/.test(p.text) ? 'küçük' : null;
    add('dilim', size, p.per1, `USDA "${p.text}"`);
  }

  if (entry.pick) {
    const p = list.find((x) => entry.pick.test(x.text));
    if (p) add('adet', null, p.per1, `USDA "${p.text}"`);
  } else {
    const sized = list.filter((p) => /^(small|medium|large)\b/.test(p.text) ||
      /^(small|medium|large) (pita|tortilla|piece)/.test(p.text));
    for (const p of sized) {
      const size = SIZE[p.text.match(/^(small|medium|large)/)[1]];
      add('adet', size, p.per1, `USDA "${p.text}"`);
    }
    if (!sized.length) {
      const piece = list.find((p) => PIECE.test(p.text) && !/^pieces?, /.test(p.text));
      if (piece) add('adet', null, piece.per1, `USDA "${piece.text}"`);
    }
  }

  const nqs = list.find((p) => /quantity not specified/.test(p.text));
  if (nqs) add('porsiyon', null, nqs.per1, 'USDA FNDDS "Quantity not specified" (typical amount eaten)');
  return units;
}

const sql = (v) => v === null || v === undefined ? 'null'
  : typeof v === 'number' ? String(v)
  : typeof v === 'boolean' ? String(v)
  : Array.isArray(v) ? (v.length ? `array[${v.map(sql).join(', ')}]::text[]` : `'{}'::text[]`)
  : `'${String(v).replaceAll("'", "''")}'`;

const problems = [];
const foodRows = [];
const unitRows = [];
const report = [];
const seen = new Set();
for (const e of catalog) {
  if (seen.has(e.key)) problems.push(`duplicate key ${e.key}`);
  seen.add(e.key);
  if (!e.fdc) {
    foodRows.push([e.key, e.tr, e.en, e.aliases ?? [], e.category, !!e.liquid, null, null, null, null, null, 'todo', null,
      'No USDA equivalent. Needs values from a dietitian (e.g. from TürKomp or a recipe calculation).']);
    report.push(`TODO  ${e.key.padEnd(22)} ${e.tr}`);
    continue;
  }
  const food = byId.get(e.fdc);
  if (!food) { problems.push(`${e.key}: FDC ${e.fdc} not found`); continue; }
  const n = food.n;
  for (const k of ['kcal', 'protein', 'carbs', 'fat']) if (n[k] === undefined) problems.push(`${e.key}: FDC ${e.fdc} has no ${k}`);
  const portionSource = e.portionsFrom ? byId.get(String(e.portionsFrom)) : null;
  if (e.portionsFrom && !portionSource) problems.push(`${e.key}: portionsFrom ${e.portionsFrom} not found`);
  const units = deriveUnits(e, [...food.portions, ...(portionSource?.portions ?? [])]);
  const ref = `USDA FDC ${food.fdc_id} (${LABEL[food.dataset]}: "${food.description}")` +
    (portionSource ? `; portions from FDC ${portionSource.fdc_id} ("${portionSource.description}")` : '');
  const note = e.approx ? `Approximation: ${e.approx}. Needs dietitian review.`
    : food.dataset === 'fndds' ? 'USDA survey dish (typical US recipe).' : null;
  foodRows.push([e.key, e.tr, e.en, e.aliases ?? [], e.category, !!e.liquid,
    r1(n.kcal), r2(n.protein), r2(n.carbs), r2(n.fat), n.fiber === undefined ? null : r2(n.fiber), 'usda_fdc', ref, note]);
  units.forEach((u, i) => unitRows.push([e.key, u.unit, u.size, u.grams, 'usda_fdc', u.note, i]));
  report.push(`${food.dataset.padEnd(10)} ${e.key.padEnd(22)} ${String(r1(n.kcal)).padStart(5)} kcal  ${e.tr}  <- ${food.description}` +
    `\n${' '.repeat(34)}${units.map((u) => `${u.unit}${u.size ? ` (${u.size})` : ''}=${u.grams}`).join(', ') || '(gram only)'}`);
}

if (process.argv.includes('--report')) console.log(report.join('\n'));
if (problems.length) {
  console.error(`\n${problems.length} problem(s):\n  ${problems.join('\n  ')}`);
  process.exit(1);
}

const out = `-- Generated by supabase/seed/build_foods.mjs. Do not edit by hand: change
-- catalog.mjs and run \`node build_foods.mjs\` again.
--
-- Nutrition and portion weights: USDA FoodData Central (public domain, CC0),
-- https://fdc.nal.usda.gov. SR Legacy (2018-04), Foundation (2026-04-30),
-- FNDDS 2021-2023 (2024-10-31). Credit: "USDA FoodData Central".
-- Rows with source 'todo' have no values yet; dietitians fill and verify them.
-- All rows start unverified.

insert into public.foods (seed_key, name_tr, name_en, aliases, category, is_liquid,
  kcal_per_100g, protein_per_100g, carbs_per_100g, fat_per_100g, fiber_per_100g,
  source, source_ref, source_note)
values
${foodRows.map((r) => `  (${r.map((v, i) => (i === 11 ? `${sql(v)}::public.food_source` : sql(v))).join(', ')})`).join(',\n')}
on conflict (seed_key) do nothing;

insert into public.portion_units (food_id, unit, size, grams_per_unit, source, source_note, sort)
select f.id, v.unit, v.size, v.grams, v.source, v.note, v.sort
  from (values
${unitRows.map((r) => `    (${r.map(sql).join(', ')})`).join(',\n')}
  ) as v (seed_key, unit, size, grams, source, note, sort)
  join public.foods f on f.seed_key = v.seed_key
on conflict do nothing;
`;
const target = new URL('../migrations/20261024000100_food_seed.sql', import.meta.url);
writeFileSync(target, out);
const todoCount = foodRows.filter((r) => r[11] === 'todo').length;
console.log(`Wrote ${foodRows.length} foods (${foodRows.length - todoCount} from USDA, ${todoCount} todo) and ${unitRows.length} portion units.`);
