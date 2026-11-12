// Tests for the meal-text estimator (no AI) and the barcode parser, against
// the real foods table built by the migrations.
//   cd supabase/tests && node estimate_test.mjs
import assert from 'node:assert/strict';
import { PGlite } from '@electric-sql/pglite';
import { pg_trgm } from '@electric-sql/pglite/contrib/pg_trgm';
import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { estimateFromText, foldTr, gramsFor } from '../functions/estimate-meal/estimate.mjs';
import { lookupBarcode, packageGrams, parseOffProduct } from '../functions/lookup-barcode/barcode.mjs';

// --- load the food database exactly as migrated -------------------------------------
const db = new PGlite({ extensions: { pg_trgm } });
await db.exec(`
  create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
  create schema auth; create table auth.users (id uuid primary key, email text, raw_user_meta_data jsonb default '{}');
  create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
  create schema storage; create table storage.buckets (id text primary key, name text, public boolean);
  create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
  create publication supabase_realtime; create schema extensions;`);
const dir = fileURLToPath(new URL('../migrations/', import.meta.url));
for (const f of readdirSync(dir).filter((x) => x.endsWith('.sql')).sort()) await db.exec(readFileSync(dir + f, 'utf8'));
const foods = (await db.query(`select private.food_json(id) as f from public.foods where barcode is null`)).rows.map((r) => r.f);
const food = (key) => foods.find((f) => f.seed_key === key);

let passed = 0;
async function test(name, fn) {
  try { await fn(); passed++; console.log(`  ok  ${name}`); }
  catch (e) { console.log(`  FAIL ${name}\n       ${e.message}`); process.exitCode = 1; }
}
const est = (text, lang = 'tr') => estimateFromText(text, lang, foods);
const item = (r, key) => r.items.find((i) => i.food.seed_key === key);
const unitGrams = (key, unit, size = null) => gramsFor(food(key), unit, size, 1);

await test('folding matches SQL private.fold_tr', async () => {
  for (const s of ['Işık İNCİR çorbası', 'ŞEKER', 'Günaydın']) {
    const { rows: [{ v }] } = await db.query(`select private.fold_tr($1) v`, [s]);
    assert.equal(foldTr(s), v);
  }
});

await test('Turkish breakfast: counts, sizes and slices use USDA portions', () => {
  const r = est('2 büyük haşlanmış yumurta, 1 dilim tam buğday ekmeği, 5 siyah zeytin');
  assert.equal(item(r, 'egg_boiled').grams, 2 * unitGrams('egg_boiled', 'adet', 'büyük'));
  assert.equal(item(r, 'egg_boiled').unit, 'adet');
  assert.equal(item(r, 'bread_whole_wheat').grams, unitGrams('bread_whole_wheat', 'dilim'));
  assert.equal(item(r, 'olives_black').grams, 5 * unitGrams('olives_black', 'adet'));
  for (const i of r.items) assert.equal(i.confidence, 'high', i.name);
});

await test('nutrition is per-100 g values × grams, nothing else', () => {
  const r = est('150 gr tavuk göğsü', 'tr');
  const i = item(r, 'chicken_breast');
  assert.equal(i.grams, 150);
  assert.equal(i.calories, Math.round(Number(food('chicken_breast').kcal_per_100g) * 1.5));
  assert.equal(i.protein_g, Math.round(Number(food('chicken_breast').protein_per_100g) * 15) / 10);
});

await test('measures: su bardağı, çay bardağı, yemek kaşığı, grams, litres', () => {
  assert.equal(item(est('1 su bardağı süt'), 'milk_whole').grams, unitGrams('milk_whole', 'su bardağı'));
  assert.equal(item(est('2 çay bardağı çay'), 'tea').grams, 2 * unitGrams('tea', 'çay bardağı'));
  assert.equal(item(est('1 yemek kaşığı bal'), 'honey').grams, unitGrams('honey', 'yemek kaşığı'));
  assert.equal(item(est('1,5 litre su'), 'water').grams, Math.round(1500 * unitGrams('water', 'ml') * 10) / 10);
  assert.equal(item(est('yarım su bardağı pirinç'), 'rice_white').grams, Math.round(unitGrams('rice_white', 'su bardağı') * 5) / 10);
});

await test('measure words are not foods ("su bardağı" is not water, "çay kaşığı" not tea)', () => {
  assert.deepEqual(est('1 su bardağı ayran').items.map((i) => i.food.seed_key), ['ayran']);
  assert.deepEqual(est('1 çay kaşığı şeker').items.map((i) => i.food.seed_key), ['sugar']);
});

await test('a measure the food does not have is asked, not guessed', () => {
  const r = est('1 kase mercimek çorbası');
  const i = item(r, 'lentil_soup');
  assert.equal(i.grams, null);
  assert.equal(i.calories, null);
  assert.match(i.question, /ne kadar/);
  assert.match(r.notes, /tamamla/);
});

await test('no amount: USDA typical portion, said in the notes', () => {
  const r = est('mercimek çorbası');
  assert.equal(item(r, 'lentil_soup').unit, 'porsiyon');
  assert.equal(item(r, 'lentil_soup').grams, unitGrams('lentil_soup', 'porsiyon'));
  assert.match(r.notes, /standart porsiyon/);
});

await test('todo foods are recognised but have no values', () => {
  const i = item(est('2 adet simit'), 'simit');
  assert.equal(i.calories, null);
  assert.match(i.question, /diyetisyen/);
});

await test('"2 şekerli çay" is tea with two sugar cubes', () => {
  const r = est('2 şekerli çay');
  assert.equal(r.items.filter((i) => i.food.seed_key === 'tea').length, 1);
  assert.equal(item(r, 'tea').unit, 'çay bardağı', 'tea comes in a tea glass');
  assert.equal(item(r, 'sugar').grams, 2 * unitGrams('sugar', 'adet'));
  assert.equal(item(est('2 portakal suyu'), 'orange_juice').grams, 2 * unitGrams('orange_juice', 'su bardağı'));
});

await test('"-lı" extras are added and asked for; endings and softened stems match', () => {
  const r = est('sahanda 2 yumurta tereyağlı');
  assert.equal(item(r, 'egg_fried').amount, 2);
  assert.equal(item(est('Sahanda 2 yumurta TEREYAĞLI'), 'egg_fried').text, 'Sahanda 2 yumurta TEREYAĞLI', 'shown as written');
  assert.equal(item(r, 'butter').grams, null, 'how much butter is asked');
  assert.ok(item(est('ekmeği yarım yedim'), 'bread_white'), 'ekmeği -> ekmek');
  assert.equal(item(est('zeytinyağlı salata'), 'olives_green'), undefined, '"zeytinyağlı" is not olives');
  assert.deepEqual(est('sucuk').items.map((i) => i.food.seed_key), ['sucuk'], '"sucuk" is not water');
});

await test('English descriptions', () => {
  const r = est('2 large boiled eggs, 1 slice of white bread, coffee with milk', 'en');
  assert.equal(item(r, 'egg_boiled').grams, 2 * unitGrams('egg_boiled', 'adet', 'büyük'));
  assert.equal(item(r, 'bread_white').grams, unitGrams('bread_white', 'dilim'));
  assert.ok(item(r, 'coffee') && item(r, 'milk_whole'));
  assert.equal(item(r, 'egg_boiled').name, 'Boiled egg');
  assert.equal(item(est('eggs on toast', 'en'), 'egg_boiled').amount, 1, '"on" is not ten');
});

await test('unrecognised text is reported, not guessed', () => {
  const r = est('bilinmeyen bir şey yedim');
  assert.equal(r.items.length, 0);
  assert.equal(r.is_food, false);
  assert.match(r.notes, /Tanınamadı/);
});

// --- barcode -------------------------------------------------------------------------
const offProduct = {
  status: 1,
  product: {
    code: '8690000000001', product_name_tr: 'Süzme Peynir', brands: 'Örnek Süt, Örnek', quantity: '500 g',
    serving_quantity: 30, nutriments: { 'energy-kcal_100g': 250, proteins_100g: 17, carbohydrates_100g: 2, fat_100g: 19.5, fiber_100g: 0 },
  },
};

await test('barcode: label values only; incomplete products are not stored', () => {
  const r = parseOffProduct(offProduct, '8690000000001');
  assert.equal(r.ok, true);
  assert.equal(r.food.kcal_per_100g, 250);
  assert.equal(r.food.brand, 'Örnek Süt');
  assert.equal(r.food.source, 'open_food_facts');
  assert.deepEqual(r.portions, [
    { unit: 'paket', grams: 500, note: 'Open Food Facts package quantity (500 g)' },
    { unit: 'porsiyon', grams: 30, note: 'Open Food Facts serving size (500 g)' },
  ]);
  // A 52 g chocolate bar with a 30 g "serving": one package is 52 g.
  assert.equal(packageGrams('52 g'), 52);
  assert.equal(packageGrams('52g'), 52);
  assert.equal(packageGrams('0,5 kg'), 500);
  assert.equal(packageGrams('33 cl'), 330);
  assert.equal(packageGrams('6 x 30 g'), null);
  assert.equal(packageGrams(''), null);
  const kj = parseOffProduct({ status: 1, product: { product_name: 'X', nutriments: { energy_100g: 1046, proteins_100g: 1, carbohydrates_100g: 1, fat_100g: 1 } } }, '12345678');
  assert.equal(kj.food.kcal_per_100g, 250, 'kJ converted');
  const missing = parseOffProduct({ status: 1, product: { product_name: 'Y', nutriments: { 'energy-kcal_100g': 100 } } }, '12345678');
  assert.deepEqual(missing, { ok: false, reason: 'incomplete', name: 'Y' });
  assert.equal(parseOffProduct({ status: 0 }, '1').reason, 'not_found');
});

await test('barcode: cache first, then Open Food Facts with a User-Agent, then cached', async () => {
  const store = new Map();
  let calls = 0;
  const deps = {
    userAgent: 'Nouri-test/1 (test@example.com)',
    findCached: async (c) => store.get(c) ?? null,
    saveFood: async ({ food: f }) => { store.set(f.barcode, f); return f; },
    fetchImpl: async (url, opts) => {
      calls++;
      assert.match(url, /world\.openfoodfacts\.org\/api\/v2\/product\/8690000000001\.json/);
      assert.equal(opts.headers['User-Agent'], 'Nouri-test/1 (test@example.com)');
      return { ok: true, status: 200, json: async () => offProduct };
    },
  };
  const first = await lookupBarcode('8690000000001', deps);
  assert.equal(first.found, true);
  assert.equal(first.cached, false);
  assert.match(first.attribution, /Open Food Facts/);
  const second = await lookupBarcode('8690000000001', deps);
  assert.equal(second.cached, true);
  assert.equal(calls, 1);
  await assert.rejects(lookupBarcode('12ab', deps), /8 to 14 digits/);
  const none = await lookupBarcode('99999999', { ...deps, fetchImpl: async () => ({ ok: false, status: 404 }) });
  assert.deepEqual([none.found, none.reason], [false, 'not_found']);
});

console.log(`\n${passed} passed${process.exitCode ? ', some FAILED' : ''}`);
