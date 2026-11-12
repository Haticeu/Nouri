// Supabase Edge Function: POST /functions/v1/estimate-meal
// Body: { text: "2 haşlanmış yumurta, 1 dilim ekmek", meal?: "breakfast", language?: "tr" }
//
// Rule-based (no AI): matches the description against public.foods and
// public.portion_units. All nutrition comes from those tables.
//
// Deploy: supabase functions deploy estimate-meal

import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { estimateFromText } from './estimate.mjs';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

// The food list changes rarely; keep it for a minute per function instance.
let cache: { at: number; foods: unknown[] } | null = null;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  });
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return json({ error: 'Not signed in' }, 401);

  const { text, language } = await req.json().catch(() => ({}));
  if (typeof text !== 'string' || !text.trim()) return json({ error: 'Describe what you ate.' }, 400);

  if (!cache || Date.now() - cache.at > 60_000) {
    // Generic foods only; packaged (barcode) products are found by scanning or search.
    const { data, error } = await supabase.from('foods')
      .select('*, portion_units(unit, size, grams_per_unit, source, sort)')
      .is('barcode', null);
    if (error) return json({ error: 'Could not load the food list' }, 500);
    cache = {
      at: Date.now(),
      foods: (data ?? []).map(({ portion_units, search_text: _, ...f }) => ({
        ...f,
        portions: [...portion_units]
          .sort((a, b) => a.sort - b.sort || a.grams_per_unit - b.grams_per_unit)
          .map((p) => ({ unit: p.unit, size: p.size, grams: p.grams_per_unit, source: p.source })),
      })),
    };
  }
  return json(estimateFromText(text.slice(0, 2000), language, cache.foods));
});
