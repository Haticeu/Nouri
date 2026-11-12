// Edge Function: barcode -> food (Open Food Facts, cached in public.foods).
//
//   POST /functions/v1/lookup-barcode   { "barcode": "8690504000014" }
//
// Secrets: OFF_USER_AGENT, e.g. "Nouri/0.1 (you@example.com)"; Open Food Facts
// asks every app to identify itself. SUPABASE_URL / SUPABASE_ANON_KEY /
// SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.
//
//   supabase functions deploy lookup-barcode
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { BarcodeError, lookupBarcode } from './barcode.mjs';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return reply(405, { error: 'Method not allowed' });

  // Reads run as the caller (RLS); only the cache insert uses the service role.
  const user = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  });
  const { data: auth } = await user.auth.getUser();
  if (!auth?.user) return reply(401, { error: 'Not signed in' });
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  const getFood = async (id: string) => {
    const { data, error } = await user.rpc('get_food', { p_food: id });
    if (error) throw error;
    return data;
  };

  try {
    const { barcode } = await req.json().catch(() => ({}));
    const result = await lookupBarcode(barcode, {
      userAgent: Deno.env.get('OFF_USER_AGENT') ?? undefined,
      findCached: async (code: string) => {
        const { data } = await user.from('foods').select('id').eq('barcode', code).maybeSingle();
        return data ? await getFood(data.id) : null;
      },
      saveFood: async ({ food, portions }: { food: Record<string, unknown>; portions: { unit: string; grams: number; note: string }[] }) => {
        // Another lookup may have cached it a moment ago: keep the first row.
        const { error } = await admin.from('foods').upsert(food, { onConflict: 'barcode', ignoreDuplicates: true });
        if (error) throw error;
        const { data: row } = await admin.from('foods').select('id').eq('barcode', food.barcode).single();
        if (portions.length) {
          // A duplicate (from a concurrent lookup) is rejected by the unique index; that's fine.
          await admin.from('portion_units').insert(
            portions.map((p, i) => ({ food_id: row!.id, unit: p.unit, grams_per_unit: p.grams, source: 'open_food_facts', source_note: p.note, sort: i })),
          );
        }
        return await getFood(row!.id);
      },
    });
    return reply(200, result);
  } catch (e) {
    if (e instanceof BarcodeError) return reply(e.status, { error: e.message });
    console.error(e);
    return reply(500, { error: 'Barcode lookup failed' });
  }
});
