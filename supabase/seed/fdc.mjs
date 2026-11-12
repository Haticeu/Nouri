// Read USDA FoodData Central CSV archives (SR Legacy, Foundation, FNDDS)
// straight from the downloaded zip files in .cache/. CC0 public-domain data:
// https://fdc.nal.usda.gov (please credit "USDA FoodData Central").
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const CACHE = fileURLToPath(new URL('./.cache/', import.meta.url));
export const DATASETS = {
  foundation: 'FoodData_Central_foundation_food_csv_2026-04-30',
  sr_legacy: 'FoodData_Central_sr_legacy_food_csv_2018-04',
  fndds: 'FoodData_Central_survey_food_csv_2024-10-31',
};
// FDC nutrient ids. Foundation foods often report energy only as Atwater (2047/2048);
// FNDDS files use the legacy nutrient numbers (208 energy, 203 protein, ...).
export const NUTRIENTS = {
  kcal: [1008, 2047, 2048, 208],
  protein: [1003, 203],
  fat: [1004, 204],
  carbs: [1005, 1050, 205],
  fiber: [1079, 291],
};

function extract(dataset) {
  const dir = join(CACHE, DATASETS[dataset]);
  if (!existsSync(join(dir, 'food.csv'))) {
    mkdirSync(CACHE, { recursive: true });
    const zip = join(CACHE, `${DATASETS[dataset]}.zip`);
    if (!existsSync(zip)) throw new Error(`Missing ${zip}. Download it from https://fdc.nal.usda.gov/download-datasets`);
    // tar (bsdtar) ships with Windows 10+ and macOS and reads zip files.
    execFileSync('tar', ['-xf', zip, '-C', CACHE]);
  }
  return dir;
}

/** Minimal CSV parser for FDC files (quoted fields, commas inside quotes). */
export function parseCsv(text) {
  const rows = [];
  let row = [], field = '', quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (ch === '"') quoted = false;
      else field += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ',') { row.push(field); field = ''; }
    else if (ch === '\n') { row.push(field.replace(/\r$/, '')); rows.push(row); row = []; field = ''; }
    else field += ch;
  }
  if (field || row.length) { row.push(field); rows.push(row); }
  const [header, ...data] = rows;
  return data.filter((r) => r.length > 1).map((r) => Object.fromEntries(header.map((h, i) => [h, r[i]])));
}

const loaded = new Map();
/** { foods: Map<fdcId, {fdc_id, dataset, description, n:{kcal,...}, portions:[...]}> } */
export function load(dataset) {
  if (loaded.has(dataset)) return loaded.get(dataset);
  const dir = extract(dataset);
  const read = (f) => parseCsv(readFileSync(join(dir, f), 'utf8'));
  const units = new Map(read('measure_unit.csv').map((u) => [u.id, u.name]));
  const foods = new Map();
  const wanted = new Set(['foundation_food', 'sr_legacy_food', 'survey_fndds_food']);
  for (const f of read('food.csv')) {
    if (!wanted.has(f.data_type)) continue;
    foods.set(f.fdc_id, { fdc_id: f.fdc_id, dataset, description: f.description, n: {}, portions: [] });
  }
  const idToKey = new Map();
  for (const [key, ids] of Object.entries(NUTRIENTS)) ids.forEach((id, rank) => idToKey.set(String(id), [key, rank]));
  for (const r of read('food_nutrient.csv')) {
    const k = idToKey.get(r.nutrient_id);
    const food = k && foods.get(r.fdc_id);
    if (!food || r.amount === '') continue;
    const [key, rank] = k;
    // Keep the most preferred id for each nutrient (e.g. 1008 over Atwater 2047).
    if (food.n[key] === undefined || rank < food.n[`${key}_rank`]) {
      food.n[key] = Number(r.amount);
      food.n[`${key}_rank`] = rank;
    }
  }
  for (const p of read('food_portion.csv')) {
    const food = foods.get(p.fdc_id);
    if (!food || !p.gram_weight) continue;
    food.portions.push({
      id: p.id,
      amount: Number(p.amount || 1),
      unit: units.get(p.measure_unit_id) ?? '',
      description: p.portion_description || '',
      modifier: p.modifier || '',
      grams: Number(p.gram_weight),
    });
  }
  const result = { foods };
  loaded.set(dataset, result);
  return result;
}

export function loadAll() {
  return Object.keys(DATASETS).map((d) => load(d));
}
