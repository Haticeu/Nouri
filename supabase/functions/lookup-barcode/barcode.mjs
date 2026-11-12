// Barcode -> food, via Open Food Facts, cached in public.foods.
//
// Shared by the Edge Function (index.ts) and the local dev server, so both
// behave the same. No AI: the values are the ones printed on the label, as
// entered in Open Food Facts.
//
// Open Food Facts data is under the Open Database License (ODbL): show
// "Open Food Facts" as the source wherever a product's values are shown, and
// keep the cached rows open (share-alike). https://world.openfoodfacts.org
// Their API asks every app to send a User-Agent "AppName/Version (contact)".

export const ATTRIBUTION = 'Open Food Facts (ODbL)';
const FIELDS = [
  'code', 'product_name', 'product_name_tr', 'product_name_en', 'brands', 'quantity',
  'serving_quantity', 'serving_quantity_unit', 'nutriments', 'categories_tags', 'nutrition_data_per',
].join(',');

export class BarcodeError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

export const isBarcode = (s) => /^[0-9]{8,14}$/.test(String(s ?? ''));

const num = (v) => {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(String(v).replace(',', '.'));
  return Number.isFinite(n) ? n : null;
};
const r = (n, d) => (n === null ? null : Math.round(n * 10 ** d) / 10 ** d);

/**
 * Grams (or ml) in one package from OFF's free-text quantity, or null when it
 * isn't a single plain amount (multipacks like "6 x 30 g" are skipped: the
 * package there isn't what one person eats).
 */
export function packageGrams(quantity) {
  const m = String(quantity ?? '').trim().toLowerCase().match(/^(\d+(?:[.,]\d+)?)\s*(g|gr|gram|kg|ml|cl|l)\.?$/);
  if (!m) return null;
  const v = Number(m[1].replace(',', '.')) * ({ kg: 1000, l: 1000, cl: 10 }[m[2]] ?? 1);
  return v > 0 && v <= 5000 ? Math.round(v * 10) / 10 : null;
}

/**
 * Open Food Facts product JSON -> { ok: true, food, portions } or
 * { ok: false, reason: 'not_found' | 'incomplete', name }.
 * Uses only what the label says; a product missing any of energy, protein,
 * carbs or fat is not stored (we never fill in a value).
 */
export function parseOffProduct(json, barcode) {
  if (!json || json.status !== 1 || !json.product) return { ok: false, reason: 'not_found' };
  const p = json.product;
  const n = p.nutriments ?? {};
  const name = [p.product_name_tr, p.product_name, p.product_name_en].map((s) => s?.trim()).find(Boolean) ?? null;
  // kcal if given; otherwise convert the kJ figure (OFF's energy_100g is in kJ; 1 kcal = 4.184 kJ).
  let kcal = num(n['energy-kcal_100g']);
  if (kcal === null) {
    const kj = num(n['energy-kj_100g']) ?? num(n.energy_100g);
    if (kj !== null) kcal = kj / 4.184;
  }
  const values = {
    kcal_per_100g: r(kcal, 1),
    protein_per_100g: r(num(n.proteins_100g), 2),
    carbs_per_100g: r(num(n.carbohydrates_100g), 2),
    fat_per_100g: r(num(n.fat_100g), 2),
    fiber_per_100g: r(num(n.fiber_100g), 2),
  };
  const required = ['kcal_per_100g', 'protein_per_100g', 'carbs_per_100g', 'fat_per_100g'];
  const inRange = (k, v) => v === null || (v >= 0 && v <= (k === 'kcal_per_100g' ? 900 : 100));
  if (!name || required.some((k) => values[k] === null) || !Object.entries(values).every(([k, v]) => inRange(k, v))) {
    return { ok: false, reason: 'incomplete', name };
  }

  const liquid = /\b\d+([.,]\d+)?\s*(ml|cl|l)\b/i.test(p.quantity ?? '') ||
    (p.categories_tags ?? []).includes('en:beverages');
  const brand = p.brands?.split(',')[0]?.trim() || null;
  const englishName = p.product_name_en?.trim() || name;
  const portions = [];
  // Whole package from the label quantity ("52 g", "52g", "0,5 kg", "330 ml").
  const pack = packageGrams(p.quantity);
  if (pack) portions.push({ unit: 'paket', grams: pack, note: `Open Food Facts package quantity (${p.quantity})` });
  const serving = num(p.serving_quantity);
  const servingUnit = String(p.serving_quantity_unit ?? 'g').toLowerCase();
  if (serving && serving > 0 && serving <= 5000 && servingUnit === 'g') {
    portions.push({ unit: 'porsiyon', grams: r(serving, 1), note: `Open Food Facts serving size (${p.quantity ?? 'label'})` });
  }
  return {
    ok: true,
    food: {
      name_tr: name,
      name_en: englishName,
      brand,
      barcode,
      is_liquid: liquid,
      ...values,
      source: 'open_food_facts',
      source_ref: `Open Food Facts ${barcode} (https://world.openfoodfacts.org/product/${barcode})`,
      source_note: `Label values per 100 ${liquid ? 'ml' : 'g'} as entered in Open Food Facts (ODbL). Not checked by a dietitian.`,
    },
    portions,
  };
}

/**
 * Look a barcode up: our cache first, then Open Food Facts (and cache it).
 *   findCached(barcode) -> food json | null
 *   saveFood({ food, portions }) -> food json
 * Returns { found, cached, food?, reason?, name?, attribution }.
 */
export async function lookupBarcode(barcode, { findCached, saveFood, fetchImpl = fetch, userAgent }) {
  const code = String(barcode ?? '').trim();
  if (!isBarcode(code)) throw new BarcodeError(400, 'A barcode is 8 to 14 digits.');
  const cached = await findCached(code);
  if (cached) return { found: true, cached: true, food: cached, attribution: cached.source === 'open_food_facts' ? ATTRIBUTION : null };

  let res;
  try {
    res = await fetchImpl(`https://world.openfoodfacts.org/api/v2/product/${code}.json?fields=${FIELDS}`, {
      headers: { 'User-Agent': userAgent || 'Nouri/0.1 (nutrition app)', Accept: 'application/json' },
      signal: AbortSignal.timeout(10_000),
    });
  } catch {
    throw new BarcodeError(502, 'Could not reach Open Food Facts. Check your connection and try again.');
  }
  if (res.status === 404) return { found: false, cached: false, reason: 'not_found', attribution: ATTRIBUTION };
  if (res.status === 429) throw new BarcodeError(429, 'Too many barcode lookups, try again in a minute.');
  if (!res.ok) throw new BarcodeError(502, `Open Food Facts answered ${res.status}. Try again later.`);

  const parsed = parseOffProduct(await res.json(), code);
  if (!parsed.ok) return { found: false, cached: false, reason: parsed.reason, name: parsed.name ?? null, attribution: ATTRIBUTION };
  const food = await saveFood(parsed);
  return { found: true, cached: false, food, attribution: ATTRIBUTION };
}
