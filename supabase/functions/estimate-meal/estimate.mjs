// Turn what the user wrote ("2 haşlanmış yumurta, 1 dilim tam buğday ekmeği,
// 1 su bardağı ayran") into foods from the foods table plus amounts.
// Rule-based, no AI. Nutrition is never computed from anything but the
// food's per-100 g values and a portion weight from portion_units.
//
//   estimateFromText(text, language, foods) -> {
//     is_food, notes, source: 'database',
//     items: [{ food, food_id, name, text, unit, size, amount, grams, confidence, question,
//               calories, protein_g, carbs_g, fat_g }]
//   }
// `foods` is the list from private.food_json (with `portions`). An item whose
// amount can't be worked out has grams = null and a `question` for the user;
// an item whose food has no values yet (a todo row) has null nutrition.
//
// The future AI meal parser returns the same shape (food names + portion unit
// + amount, matched against the same foods), so the app's confirmation card
// works for both.

export const w = (alts) => new RegExp(`(?<!\\p{L})(?:${alts})(?!\\p{L})`, 'u');

/** Same folding as private.fold_tr in SQL: lower case, Turkish letters to ASCII. */
export function foldTr(s) {
  return String(s ?? '')
    .replace(/[İIı]/g, 'i')
    .toLowerCase()
    .replace(/[çğöşüâîû]/g, (c) => ({ ç: 'c', ğ: 'g', ö: 'o', ş: 's', ü: 'u', â: 'a', î: 'i', û: 'u' })[c]);
}

const isTr = (language) => String(language ?? '').toLowerCase().startsWith('tr');

// Words for household measures -> portion_units.unit ('gram' and 'ml' are direct).
const UNITS = [
  { re: w('kg|kilo|kilogram'), unit: 'gram', factor: 1000 },
  { re: w('g|gr|gram|grams|gramlik'), unit: 'gram', factor: 1 },
  { re: w('lt|litre|liter|l'), unit: 'ml', factor: 1000 },
  { re: w('ml|mililitre|milliliters?'), unit: 'ml', factor: 1 },
  { re: w('su bardagi|su bardak'), unit: 'su bardağı' },
  { re: w('cay bardagi|cay bardak|tea glass(es)?'), unit: 'çay bardağı' },
  { re: w('bardak|glass|glasses|cup|cups|mug'), unit: 'su bardağı' },
  { re: w('yemek kasigi|tbsp|tablespoons?|y\\.k\\.'), unit: 'yemek kaşığı' },
  { re: w('tatli kasigi|dessert spoons?'), unit: 'tatlı kaşığı' },
  { re: w('cay kasigi|tsp|teaspoons?|c\\.k\\.'), unit: 'çay kaşığı' },
  { re: w('kasik|spoons?'), unit: 'yemek kaşığı' },
  { re: w('avuc|handfuls?'), unit: 'avuç' },
  { re: w('kase|bowls?'), unit: 'kase' },
  { re: w('kepce|ladles?'), unit: 'kepçe' },
  { re: w('porsiyon|portions?|servings?|tabak|plates?'), unit: 'porsiyon' },
  { re: w('dilim|slices?|wedges?'), unit: 'dilim' },
  { re: w('adet|tane|pieces?|pcs'), unit: 'adet' },
];
const SIZES = [
  { re: w('kucuk|ufak|minik|small'), size: 'küçük' },
  { re: w('orta|medium'), size: 'orta' },
  { re: w('buyuk|iri|large|big'), size: 'büyük' },
];
const NUMBER_WORDS = {
  yarim: 0.5, half: 0.5, ceyrek: 0.25, quarter: 0.25,
  bir: 1, one: 1, a: 1, an: 1, iki: 2, two: 2, uc: 3, three: 3, dort: 4, four: 4, bes: 5, five: 5,
  alti: 6, six: 6, yedi: 7, seven: 7, sekiz: 8, eight: 8, dokuz: 9, nine: 9, on: 10, ten: 10,
};
// What may follow a food name inside a word: Turkish case/possessive endings
// ("yumurtayı", "çorbası") and English plurals, folded like the text.
const SUFFIXES = new Set([
  '', 's', 'es',
  'u', 'i', 'a', 'e', 'yu', 'yi', 'ya', 'ye', 'su', 'si', 'nu', 'ni',
  'da', 'de', 'ta', 'te', 'dan', 'den', 'tan', 'ten', 'la', 'le', 'yla', 'yle',
  'lar', 'ler', 'lari', 'leri', 'in', 'un', 'nin', 'nun', 'ini', 'unu', 'im', 'um', 'cik', 'ck',
]);
const WITH = /^(lu|li)$/; // "-lı": sucuklu yumurta = eggs with sucuk

/** Names a food can be called by, folded: "Pide ekmeği / lavaş (x)" -> ["pide ekmegi", "lavas"]. */
function namesOf(food) {
  const out = new Set();
  for (const n of [food.name_tr, food.name_en, ...(food.aliases ?? [])]) {
    const base = foldTr(n).replace(/\([^)]*\)/g, ' ');
    for (const part of base.split('/')) {
      const s = part.replace(/\s+/g, ' ').trim();
      if (s.length < 2) continue;
      out.add(s);
      // Turkish softening before a vowel ending: ekmek -> ekmeği, kebap -> kebabı, simit -> simidi.
      const soft = { k: 'g', p: 'b', t: 'd' }[s.at(-1)];
      if (soft && s.length >= 4) out.add(s.slice(0, -1) + soft);
    }
  }
  return [...out];
}

/** Index foods once: [{ food, names }] (longest names first). */
export function indexFoods(foods) {
  return foods.map((food) => ({ food, names: namesOf(food).sort((a, b) => b.length - a.length) }));
}

/** Split folded text on a separator regex, keeping the original spelling of each part. */
function splitBoth(orig, folded, re) {
  const out = [];
  let last = 0;
  for (const m of folded.matchAll(new RegExp(re.source, 'gu'))) {
    out.push({ o: orig.slice(last, m.index), f: folded.slice(last, m.index) });
    last = m.index + m[0].length;
  }
  out.push({ o: orig.slice(last), f: folded.slice(last) });
  return out;
}

/** Parts of the description: { text (folded, for matching), original, side ("with ...") }. */
function segments(text) {
  const folded = foldTr(text);
  // Folding keeps positions for Turkish text; if not, show the folded text.
  const orig = folded.length === text.length ? text : folded;
  const out = [];
  // Commas split items, except inside a number ("1,5 litre").
  for (const part of splitBoth(orig, folded, /[;\n]+|(?<!\d),|,(?!\d)|\s\+\s|\s(?:ve|and|ayrica|plus)\s/)) {
    const pieces = splitBoth(part.o, part.f, /\s(?:ile|with|yaninda|ustune|uzerine|on top)\s/);
    pieces.forEach((p, i) => { if (p.f.trim()) out.push({ text: p.f.trim(), original: p.o.trim(), side: i > 0 }); });
  }
  return out;
}

/** Every place `name` occurs as a whole word (plus an allowed ending) in seg. */
function occurrences(seg, name) {
  const out = [];
  let from = 0;
  for (;;) {
    const i = seg.indexOf(name, from);
    if (i < 0) return out;
    from = i + 1;
    if (i > 0 && /\p{L}/u.test(seg[i - 1])) continue; // must start a word
    const rest = seg.slice(i + name.length).match(/^\p{L}*/u)[0];
    if (!SUFFIXES.has(rest) && !WITH.test(rest)) continue;
    out.push({ start: i, end: i + name.length + rest.length, extra: WITH.test(rest) });
  }
}

/**
 * Foods named in one segment, longest name first. "X-lı" words are extras.
 * A multi-word name also matches with its words apart or reordered
 * ("sahanda 2 yumurta" = sahanda yumurta, "yumurta haşlanmış").
 */
function findFoods(seg, index) {
  const hits = [];
  for (const entry of index) {
    for (const name of entry.names) {
      for (const o of occurrences(seg, name)) hits.push({ entry, name, ...o });
      const words = name.split(' ');
      if (words.length < 2) continue;
      const found = words.map((word) => occurrences(seg, word).find((o) => !o.extra));
      if (found.every(Boolean)) {
        const start = Math.min(...found.map((o) => o.start));
        const end = Math.max(...found.map((o) => o.end));
        if (end - start <= name.length + 16) hits.push({ entry, name, start, end, extra: false, spread: true });
      }
    }
  }
  // Longest first; drop overlaps and repeats. Prefer foods that have values.
  hits.sort((a, b) => b.name.length - a.name.length ||
    (a.entry.food.source === 'todo') - (b.entry.food.source === 'todo'));
  const chosen = [];
  for (const h of hits) {
    if (chosen.some((c) => c.entry === h.entry || (h.start < c.end && c.start < h.end))) continue;
    chosen.push(h);
  }
  const main = chosen.find((h) => !h.extra) ?? chosen[0];
  if (!main) return null;
  return {
    main,
    // Other foods in the same words ("eggs on toast"): own items, default amounts.
    others: chosen.filter((h) => h !== main && !h.extra),
    extras: chosen.filter((h) => h !== main && h.extra),
  };
}

function parseCount(seg) {
  let m = seg.match(/(?:^|\s)(\d+(?:[.,]\d+)?)(?:\s*\/\s*(\d+))?(?=\s|$|\p{L})/u);
  if (m) {
    const v = m[2] ? Number(m[1].replace(',', '.')) / Number(m[2]) : Number(m[1].replace(',', '.'));
    if (v > 0) return { value: v, explicit: true };
  }
  const words = seg.split(/\s+/);
  for (let i = 0; i < words.length; i++) {
    const word = words[i];
    if (!(word in NUMBER_WORDS)) continue;
    // short English words only at the start ("a slice"), never "on top"
    if (i > 0 && ['a', 'an', 'on', 'one'].includes(word)) continue;
    const v = NUMBER_WORDS[word] + (words[i + 1] === 'bucuk' ? 0.5 : 0);
    return { value: v, explicit: true };
  }
  return { value: 1, explicit: false };
}

const round = (n, d = 0) => Math.round(n * 10 ** d) / 10 ** d;
const label = (food, tr) => (tr ? food.name_tr : food.name_en);

/** Grams for `amount` of `unit` (size optional), or null if the food has no such measure. */
export function gramsFor(food, unit, size, amount) {
  if (unit === 'gram') return amount;
  const options = (food.portions ?? []).filter((p) => p.unit === unit);
  if (!options.length) return null;
  const p = options.find((o) => (o.size ?? null) === (size ?? null)) ??
    options.find((o) => o.size === 'orta') ?? options.find((o) => o.size === null) ?? options[0];
  return amount * Number(p.grams);
}

/** Nutrition for `grams` of a food, from its per-100 g values (null for todo rows). */
export function nutritionFor(food, grams) {
  if (grams === null || food.kcal_per_100g === null || food.kcal_per_100g === undefined) {
    return { calories: null, protein_g: null, carbs_g: null, fat_g: null };
  }
  const x = grams / 100;
  return {
    calories: round(Number(food.kcal_per_100g) * x),
    protein_g: round(Number(food.protein_per_100g) * x, 1),
    carbs_g: round(Number(food.carbs_per_100g) * x, 1),
    fat_g: round(Number(food.fat_per_100g) * x, 1),
  };
}

function makeItem(food, original, tr, { unit, size, amount, explicit, defaulted, side }) {
  let grams = null;
  let confidence = 'low';
  let question = null;
  let chosenUnit = unit;
  if (unit) {
    grams = gramsFor(food, unit, size, amount);
    if (grams !== null) confidence = explicit ? 'high' : 'medium';
  } else {
    // No measure named: pieces when counted, else USDA's typical portion.
    // Drinks come by the glass: tea in a tea glass, anything else in a water glass.
    const glass = food.is_liquid ? [/(^|\s)(cay|tea)\b/.test(foldTr(food.name_tr + ' ' + food.name_en)) ? 'çay bardağı' : 'su bardağı'] : [];
    for (const u of explicit ? ['adet', 'dilim', ...glass, 'porsiyon'] : [...glass, 'porsiyon', 'adet', 'dilim']) {
      const g = gramsFor(food, u, size, amount);
      if (g !== null) { grams = g; chosenUnit = u; confidence = explicit ? 'high' : 'medium'; break; }
    }
  }
  if (grams === null) {
    question = tr ? `${label(food, tr)}: ne kadar? Gram olarak gir ya da bir ölçü seç.`
      : `${label(food, tr)}: how much? Enter grams or pick a measure.`;
    chosenUnit = (food.portions ?? [])[0]?.unit ?? 'gram';
  }
  if (food.source === 'todo') {
    question = tr ? `${label(food, tr)} için besin değerleri henüz girilmedi (diyetisyen onayı bekliyor).`
      : `No nutrition values for ${label(food, tr)} yet (waiting for a dietitian).`;
    confidence = 'low';
  }
  return {
    food,
    food_id: food.id,
    name: label(food, tr),
    text: original.length > 60 ? `${original.slice(0, 57)}…` : original,
    unit: chosenUnit,
    size: size ?? null,
    amount: round(amount, 2),
    grams: grams === null ? null : round(grams, 1),
    confidence: defaulted && confidence === 'high' ? 'medium' : confidence,
    question,
    side: !!side,
    ...nutritionFor(food, grams),
  };
}

export function estimateFromText(text, language, foods) {
  const tr = isTr(language);
  const index = indexFoods(foods);
  const sugar = index.find((e) => e.food.seed_key === 'sugar')?.food;
  const items = [];
  const unknown = [];
  const assumed = [];

  for (const { text: seg, original, side } of segments(String(text ?? '').slice(0, 2000))) {
    // "2 şekerli çay" = tea with 2 sugars: that number counts sugar, not tea.
    const SUGAR = /(\d+|bir|iki|uc|one|two|three)\s*(?:kup\s*)?(?:seker\p{L}*|sugars?)/u;
    const sugarMatch = seg.match(SUGAR);
    const rest = seg.replace(SUGAR, ' ').trim();
    const measure = UNITS.find((u) => u.re.test(rest));
    // Measure words are not foods: "su bardağı" is not water, "çay kaşığı" not tea.
    const hit = findFoods(measure ? rest.replace(measure.re, ' ') : rest, index);
    if (!hit) {
      if (/\p{L}{3,}/u.test(seg)) unknown.push(seg);
      continue;
    }
    const count = parseCount(rest);
    const size = SIZES.find((s) => s.re.test(rest))?.size ?? null;
    const food = hit.main.entry.food;

    const item = makeItem(food, original, tr, {
      unit: measure?.unit ?? null,
      size,
      amount: count.value * (measure?.factor ?? 1),
      explicit: count.explicit || !!measure,
      defaulted: !count.explicit && !measure,
      side,
    });
    if (!count.explicit && !measure && item.grams !== null) assumed.push(item.name);
    items.push(item);
    for (const o of hit.others) {
      const other = makeItem(o.entry.food, original, tr, { unit: null, size: null, amount: 1, explicit: false, defaulted: true, side: true });
      if (other.grams !== null) assumed.push(other.name);
      items.push(other);
    }

    // Extras named with "-lı" ("sucuklu yumurta", "tereyağlı"): ask how much.
    for (const x of hit.extras) {
      items.push(makeItem(x.entry.food, original, tr, { unit: null, size: null, amount: 1, explicit: false, defaulted: true, side: true }));
      const extra = items[items.length - 1];
      // An "-lı" extra is a part of the dish, not a typical portion of its own.
      Object.assign(extra, { grams: null, calories: null, protein_g: null, carbs_g: null, fat_g: null, confidence: 'low',
        question: extra.question ?? (tr ? `${extra.name}: ne kadar?` : `${extra.name}: how much?`) });
    }
    // Sugar counted in a drink ("2 şekerli çay", "tea with 1 sugar"): sugar cubes.
    if (sugar && sugarMatch && food.seed_key !== 'sugar') {
      const n = Number(sugarMatch[1]) || NUMBER_WORDS[sugarMatch[1]] || 1;
      items.push(makeItem(sugar, original, tr, { unit: 'adet', size: null, amount: n, explicit: true, defaulted: false, side: true }));
    }
  }

  const notes = [];
  if (unknown.length) {
    notes.push(tr
      ? `Tanınamadı: ${unknown.join(', ')}. Besin arayarak ekleyebilirsin.`
      : `Not recognised: ${unknown.join(', ')}. You can add these by searching for the food.`);
  }
  if (assumed.length) {
    notes.push(tr
      ? `Miktar yazılmadığı için standart porsiyon kullanıldı: ${assumed.join(', ')}.`
      : `No amount given, so a standard portion was used for: ${assumed.join(', ')}.`);
  }
  if (items.some((i) => i.grams === null || i.calories === null)) {
    notes.push(tr ? 'Bazı kalemler için miktar ya da değer eksik; kaydetmeden önce tamamla.'
      : 'Some items need an amount or have no values yet; complete them before logging.');
  }
  return { is_food: items.length > 0, notes: notes.join(' '), source: 'database', items };
}
