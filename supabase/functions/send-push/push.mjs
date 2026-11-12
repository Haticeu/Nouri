// Deliver a row of public.notifications to the user's phones through
// Firebase Cloud Messaging (HTTP v1). Shared by the Edge Function (index.ts)
// and the tests. Uses only Web Crypto + fetch (works in Deno and Node).
//
// Secret: FCM_SERVICE_ACCOUNT = the JSON key of a Firebase service account
// (Firebase console -> Project settings -> Service accounts -> Generate key).
// It stays in Supabase secrets; the app never sees it.

const b64url = (bytes) => {
  const bin = typeof bytes === 'string' ? new TextEncoder().encode(bytes) : new Uint8Array(bytes);
  let s = '';
  for (const b of bin) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

/** Signed JWT asking Google for an FCM access token (RS256, 1 hour). */
export async function serviceAccountJwt(account, now = Math.floor(Date.now() / 1000)) {
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64url(JSON.stringify({
    iss: account.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  }));
  const pem = account.private_key.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${header}.${claims}`));
  return `${header}.${claims}.${b64url(sig)}`;
}

export async function accessToken(account, fetchImpl = fetch) {
  const res = await fetchImpl('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: await serviceAccountJwt(account),
    }),
  });
  if (!res.ok) throw new Error(`Google token request failed (${res.status})`);
  return (await res.json()).access_token;
}

/** The FCM message for one notification row and one device token. */
export function fcmMessage(notification, token) {
  const data = Object.fromEntries(Object.entries({ ...(notification.data ?? {}), type: notification.type, notification_id: notification.id })
    .map(([k, v]) => [k, typeof v === 'string' ? v : JSON.stringify(v)])); // FCM data values must be strings
  return {
    message: {
      token,
      notification: { title: notification.title, ...(notification.body ? { body: notification.body } : {}) },
      data,
      android: { priority: 'high', notification: { channel_id: 'nouri_updates' } },
    },
  };
}

/**
 * Send one notification to every token. Returns { sent, dead } where dead are
 * tokens FCM says no longer exist (the caller deletes them).
 */
export async function sendToTokens({ account, notification, tokens, fetchImpl = fetch }) {
  if (!tokens.length) return { sent: 0, dead: [] };
  const bearer = await accessToken(account, fetchImpl);
  let sent = 0;
  const dead = [];
  for (const token of tokens) {
    const res = await fetchImpl(`https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(fcmMessage(notification, token)),
    });
    if (res.ok) sent++;
    else if (res.status === 404 || res.status === 400) {
      const err = await res.json().catch(() => ({}));
      if (JSON.stringify(err).includes('UNREGISTERED') || JSON.stringify(err).includes('INVALID_ARGUMENT')) dead.push(token);
    }
  }
  return { sent, dead };
}
