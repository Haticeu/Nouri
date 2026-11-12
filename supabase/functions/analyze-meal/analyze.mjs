// Meal photo -> estimated foods, portions and nutrition, using Claude vision.
// Shared by the Supabase Edge Function (Deno) and the local dev server (Node):
// both pass in their own Anthropic client so this file has no imports.

export const MODEL = 'claude-opus-5-5';

const SYSTEM = `You are a nutrition assistant in a food-logging app that clients share with their dietitian.
You look at a photo of a meal and estimate, as accurately as you can, what is on it and its nutrition.
Clients rely on these numbers, and their dietitian reviews them, so be thorough and realistic.

Look carefully at the whole photo before answering:
- List EVERY distinct food and drink you can see, including small items, sides, garnishes, spreads, sauces and drinks
  (e.g. a sprinkle of parsley, a few olives, a pat of butter, a glass of tea). Small items still count.
- Count discrete pieces and estimate from them: "2 boiled eggs", "6 black olives", "3 slices of tomato".
- Estimate grams from visual cues: plate and cutlery size, how deep or piled the food is, and typical portion sizes.
- Use the cooking method you can see (fried, grilled, boiled, raw, baked); frying adds absorbed oil.
- Account for visible or very likely fat: oil on salads or vegetables, butter, cheese, dressings, sauces.
- If you can't identify something with certainty, do NOT leave it out: give your best guess of what it most likely is,
  estimate it anyway, and mark it "low" confidence. An approximate value is more useful than a missing item.
- Do not invent foods that are not visible.

For each item give: a plain, natural name; a human-readable portion; grams; and calories, protein, carbohydrate
and fat for THAT portion, based on standard food-composition values. Rate confidence: "high" when both the food
and the amount are clear, "medium" when one is uncertain, "low" when both are or when you are guessing.

Turkish and Mediterranean dishes are common: recognise them by their usual names (menemen, mercimek çorbası,
bulgur pilavı, kuru fasulye, karnıyarık, simit, ayran, beyaz peynir ...).

Write item names, portions and notes in the language you are asked to use.
If the photo shows no food or drink, return no items and set is_food to false.
Notes: one or two short, practical sentences on what you assumed (e.g. amount of oil) or what the user should check.`;

const LANGUAGES = { tr: 'Turkish', en: 'English', de: 'German', fr: 'French', es: 'Spanish', ar: 'Arabic' };

export const SCHEMA = {
  type: 'object',
  properties: {
    is_food: { type: 'boolean' },
    items: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          portion: { type: 'string', description: 'Human-readable portion, e.g. "1 bowl", "2 slices"' },
          grams: { type: 'number' },
          calories: { type: 'number' },
          protein_g: { type: 'number' },
          carbs_g: { type: 'number' },
          fat_g: { type: 'number' },
          confidence: { type: 'string', enum: ['low', 'medium', 'high'] },
        },
        required: ['name', 'portion', 'grams', 'calories', 'protein_g', 'carbs_g', 'fat_g', 'confidence'],
        additionalProperties: false,
      },
    },
    notes: { type: 'string' },
  },
  required: ['is_food', 'items', 'notes'],
  additionalProperties: false,
};

export class MealAnalysisError extends Error {
  constructor(message, status = 422) {
    super(message);
    this.status = status;
  }
}

/**
 * @param client   an Anthropic SDK client (`new Anthropic()`)
 * @param imageBase64  the photo, base64 without a data: prefix
 * @param mediaType    image/jpeg | image/png | image/webp | image/gif
 * @param mealSlot     optional hint: breakfast | lunch | dinner | snack
 * @param language     app language code (e.g. "tr"); names and notes come back in it
 */
export async function analyzeMeal(client, { imageBase64, mediaType, mealSlot, language }) {
  const lang = LANGUAGES[String(language ?? '').slice(0, 2).toLowerCase()] ?? 'English';
  const ask = [
    mealSlot ? `This photo was logged as ${mealSlot}.` : '',
    'Estimate everything on it.',
    `Write names, portions and notes in ${lang}.`,
  ].filter(Boolean).join(' ');

  const response = await client.beta.messages.create({
    model: MODEL,
    max_tokens: 16000,
    // On a safety decline, let the API retry on Anthropic's recommended fallback model.
    betas: ['server-side-fallback-2026-07-01'],
    fallbacks: 'default',
    system: SYSTEM,
    // Accuracy matters more than speed here, so think it through.
    output_config: { effort: 'high', format: { type: 'json_schema', schema: SCHEMA } },
    messages: [{
      role: 'user',
      content: [
        { type: 'image', source: { type: 'base64', media_type: mediaType, data: imageBase64 } },
        { type: 'text', text: ask },
      ],
    }],
  });

  if (response.stop_reason === 'refusal') {
    throw new MealAnalysisError('This photo could not be analysed. Please add the meal manually.');
  }
  if (response.stop_reason === 'max_tokens') {
    throw new MealAnalysisError('The analysis was cut off. Please try again.', 502);
  }
  const text = response.content.find((b) => b.type === 'text')?.text;
  if (!text) throw new MealAnalysisError('No analysis was returned. Please try again.', 502);

  const result = JSON.parse(text);
  const round = (n, d = 0) => Math.max(0, Math.round(Number(n) * 10 ** d) / 10 ** d);
  return {
    is_food: result.is_food,
    notes: result.notes,
    model: response.model,
    items: result.items.map((i) => ({
      ...i,
      grams: round(i.grams),
      calories: round(i.calories),
      protein_g: round(i.protein_g, 1),
      carbs_g: round(i.carbs_g, 1),
      fat_g: round(i.fat_g, 1),
    })),
  };
}

/**
 * Use your OWN model instead of Claude: set MEAL_ANALYZER_URL (and optionally
 * MEAL_ANALYZER_TOKEN). Nouri POSTs JSON
 *   { "image_base64": "...", "media_type": "image/jpeg", "meal": "lunch", "language": "tr" }
 * and expects back the same shape as SCHEMA above:
 *   { "is_food": true, "notes": "...", "items": [{ "name", "portion", "grams", "calories",
 *     "protein_g", "carbs_g", "fat_g", "confidence": "low"|"medium"|"high" }] }
 */
export async function analyzeWithEndpoint(url, token, { imageBase64, mediaType, mealSlot, language }) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify({ image_base64: imageBase64, media_type: mediaType, meal: mealSlot ?? null, language: language ?? null }),
    signal: AbortSignal.timeout(90_000),
  });
  if (!res.ok) throw new MealAnalysisError(`The meal analysis service answered ${res.status}.`, 502);
  const result = await res.json().catch(() => null);
  const valid = result && typeof result.is_food === 'boolean' && Array.isArray(result.items) &&
    result.items.every((i) => typeof i?.name === 'string' && ['grams', 'calories', 'protein_g', 'carbs_g', 'fat_g'].every((k) => Number.isFinite(Number(i[k]))));
  if (!valid) throw new MealAnalysisError('The meal analysis service returned an unexpected format.', 502);
  const round = (n, d = 0) => Math.max(0, Math.round(Number(n) * 10 ** d) / 10 ** d);
  return {
    is_food: result.is_food,
    notes: String(result.notes ?? ''),
    model: 'custom',
    items: result.items.map((i) => ({
      name: i.name,
      portion: String(i.portion ?? ''),
      confidence: ['low', 'medium', 'high'].includes(i.confidence) ? i.confidence : 'medium',
      grams: round(i.grams),
      calories: round(i.calories),
      protein_g: round(i.protein_g, 1),
      carbs_g: round(i.carbs_g, 1),
      fat_g: round(i.fat_g, 1),
    })),
  };
}

export const NOT_CONFIGURED =
  'Photo analysis is not connected yet. You can still add the meal yourself. (Admin: add ANTHROPIC_API_KEY or MEAL_ANALYZER_URL.)';
