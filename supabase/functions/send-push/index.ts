// Edge Function: deliver new notifications as phone pushes (FCM).
//
// Wire it up once there is a Firebase project:
//   1. supabase secrets set FCM_SERVICE_ACCOUNT="$(cat service-account.json)" PUSH_WEBHOOK_SECRET=<random>
//   2. supabase functions deploy send-push --no-verify-jwt
//   3. Dashboard -> Database -> Webhooks: on INSERT into public.notifications,
//      POST to /functions/v1/send-push with header x-webhook-secret: <same random>.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { sendToTokens } from './push.mjs';

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  if (req.headers.get('x-webhook-secret') !== Deno.env.get('PUSH_WEBHOOK_SECRET')) {
    return new Response('Forbidden', { status: 403 });
  }
  const accountJson = Deno.env.get('FCM_SERVICE_ACCOUNT');
  if (!accountJson) return new Response('Push not configured', { status: 503 });

  const { record } = await req.json(); // Database Webhook payload: { type, table, record, ... }
  if (!record?.user_id) return new Response('No notification', { status: 400 });

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: rows } = await admin.from('device_tokens').select('token').eq('user_id', record.user_id);
  const result = await sendToTokens({
    account: JSON.parse(accountJson),
    notification: record,
    tokens: (rows ?? []).map((r: { token: string }) => r.token),
  });
  if (result.dead.length) await admin.from('device_tokens').delete().in('token', result.dead);
  if (result.sent) await admin.from('notifications').update({ pushed_at: new Date().toISOString() }).eq('id', record.id);
  return Response.json(result);
});
