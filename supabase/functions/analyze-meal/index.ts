// Supabase Edge Function: POST /functions/v1/analyze-meal
// Body: { photo_path: "<user id>/<file>.jpg", meal?: "breakfast" | "lunch" | "dinner" | "snack" }
//
// The photo must already be uploaded to the private `meal-photos` bucket. It is
// downloaded with the CALLER's token, so storage RLS decides access: users can
// only analyse their own photos.
//
// Deploy:  supabase functions deploy analyze-meal
// Secret:  supabase secrets set ANTHROPIC_API_KEY=sk-ant-...

import Anthropic from 'npm:@anthropic-ai/sdk';
import { createClient } from 'npm:@supabase/supabase-js@2';
import { analyzeMeal, analyzeWithEndpoint, MealAnalysisError, NOT_CONFIGURED } from './analyze.mjs';

// Your own model (MEAL_ANALYZER_URL) takes precedence over Claude (ANTHROPIC_API_KEY).
const customAnalyzer = Deno.env.get('MEAL_ANALYZER_URL');
const anthropic = !customAnalyzer && Deno.env.get('ANTHROPIC_API_KEY') ? new Anthropic() : null;
const MAX_BYTES = 5 * 1024 * 1024;
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  });
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return json({ error: 'Not signed in' }, 401);

  const { photo_path, meal, language } = await req.json().catch(() => ({}));
  if (typeof photo_path !== 'string' || !photo_path.startsWith(`${user.id}/`)) {
    return json({ error: 'photo_path must be one of your own meal photos' }, 400);
  }

  const { data: file, error } = await supabase.storage.from('meal-photos').download(photo_path);
  if (error || !file) return json({ error: 'Photo not found' }, 404);
  if (file.size > MAX_BYTES) return json({ error: 'Photo is too large (max 5 MB)' }, 413);
  const mediaType = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'].includes(file.type) ? file.type : 'image/jpeg';

  const bytes = new Uint8Array(await file.arrayBuffer());
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));

  if (!anthropic && !customAnalyzer) return json({ error: NOT_CONFIGURED, code: 'ai_not_configured' }, 503);
  try {
    const input = { imageBase64: btoa(binary), mediaType, mealSlot: meal, language };
    return json(customAnalyzer
      ? await analyzeWithEndpoint(customAnalyzer, Deno.env.get('MEAL_ANALYZER_TOKEN'), input)
      : await analyzeMeal(anthropic, input));
  } catch (e) {
    if (e instanceof MealAnalysisError) return json({ error: e.message }, e.status);
    if (e instanceof Anthropic.RateLimitError) return json({ error: 'Too many requests, try again shortly' }, 429);
    if (e instanceof Anthropic.APIError) {
      console.error('Anthropic API error', e.status, e.message);
      return json({ error: 'Analysis service unavailable' }, 502);
    }
    console.error(e);
    return json({ error: 'Analysis failed' }, 500);
  }
});
