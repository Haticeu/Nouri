// Tests for the push sender (no real Firebase: a throwaway RSA key and a fake fetch).
//   cd supabase/tests && node push_test.mjs
import assert from 'node:assert/strict';
import { generateKeyPairSync, createVerify } from 'node:crypto';
import { fcmMessage, sendToTokens, serviceAccountJwt } from '../functions/send-push/push.mjs';

let passed = 0;
async function test(name, fn) {
  try { await fn(); passed++; console.log(`  ok  ${name}`); }
  catch (e) { console.log(`  FAIL ${name}\n       ${e.message}`); process.exitCode = 1; }
}

const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const account = {
  client_email: 'push@test-project.iam.gserviceaccount.com',
  project_id: 'test-project',
  private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
};
const notification = { id: 'n1', user_id: 'u1', type: 'message', title: 'New message', body: 'Hello', data: { client_id: 'c1', n: 2 } };

await test('service-account JWT is a valid RS256 signature with the FCM scope', async () => {
  const jwt = await serviceAccountJwt(account, 1000);
  const [h, c, s] = jwt.split('.');
  const verify = createVerify('RSA-SHA256');
  verify.update(`${h}.${c}`);
  assert.ok(verify.verify(publicKey, Buffer.from(s, 'base64url')));
  const claims = JSON.parse(Buffer.from(c, 'base64url'));
  assert.equal(claims.scope, 'https://www.googleapis.com/auth/firebase.messaging');
  assert.equal(claims.exp - claims.iat, 3600);
});

await test('FCM message: title/body, string-only data, high priority', () => {
  const m = fcmMessage(notification, 'tok').message;
  assert.equal(m.token, 'tok');
  assert.deepEqual(m.notification, { title: 'New message', body: 'Hello' });
  assert.deepEqual(m.data, { client_id: 'c1', n: '2', type: 'message', notification_id: 'n1' });
  assert.equal(m.android.priority, 'high');
});

await test('sends to every token and reports dead ones', async () => {
  const calls = [];
  const fetchImpl = async (url, opts) => {
    calls.push(url);
    if (url.includes('oauth2')) return { ok: true, json: async () => ({ access_token: 'at' }) };
    const { message } = JSON.parse(opts.body);
    assert.equal(opts.headers.Authorization, 'Bearer at');
    return message.token === 'gone'
      ? { ok: false, status: 404, json: async () => ({ error: { details: [{ errorCode: 'UNREGISTERED' }] } }) }
      : { ok: true, status: 200, json: async () => ({}) };
  };
  const r = await sendToTokens({ account, notification, tokens: ['a', 'gone'], fetchImpl });
  assert.deepEqual(r, { sent: 1, dead: ['gone'] });
  assert.ok(calls[1].endsWith('/projects/test-project/messages:send'));
  assert.deepEqual(await sendToTokens({ account, notification, tokens: [], fetchImpl }), { sent: 0, dead: [] });
});

console.log(`\n${passed} passed${process.exitCode ? ', some FAILED' : ''}`);
