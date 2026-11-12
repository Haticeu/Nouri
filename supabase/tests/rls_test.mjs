// RLS / RPC tests for the dietitian-client migration.
// Runs the migration in PGlite (Postgres in WASM) with minimal stubs of
// Supabase's auth/storage schemas and default grants.
//
//   cd supabase/tests && npm install && node rls_test.mjs

import { PGlite } from '@electric-sql/pglite';
import { pg_trgm } from '@electric-sql/pglite/contrib/pg_trgm';
import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

// Every migration, in order (schema, then the food seed data).
const migrationsDir = fileURLToPath(new URL('../migrations/', import.meta.url));
const migrations = readdirSync(migrationsDir).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => [f, readFileSync(migrationsDir + f, 'utf8')]);

const SUPABASE_STUB = `
  create role anon nologin;
  create role authenticated nologin;
  create role service_role nologin bypassrls;
  grant usage on schema public to anon, authenticated, service_role;
  alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
  alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
  alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;

  create schema auth;
  grant usage on schema auth to anon, authenticated;
  create table auth.users (id uuid primary key, email text, raw_user_meta_data jsonb default '{}');
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

  create schema storage;
  grant usage on schema storage to authenticated;
  create table storage.buckets (id text primary key, name text, public boolean);
  create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
  alter table storage.objects enable row level security;
  grant all on storage.objects to authenticated;

  create publication supabase_realtime;
  create schema extensions;
  grant usage on schema extensions to anon, authenticated, service_role;
`;

const db = new PGlite({ extensions: { pg_trgm } });
await db.exec(SUPABASE_STUB);
for (const [name, sql] of migrations) {
  try { await db.exec(sql); }
  catch (e) { console.error(`migration ${name} failed: ${e.message}${e.where ? `
  ${e.where}` : ""}`); process.exit(1); }
}

const CONSENT = (await db.query(`select private.consent_version() v`)).rows[0].v;
const ids = {};
async function signUp(name, role, email = `${name}@x.test`) {
  const { rows } = await db.query(
    `insert into auth.users (id, email, raw_user_meta_data)
     values (gen_random_uuid(), $1, jsonb_build_object('role', $2::text, 'full_name', $3::text)) returning id`,
    [email, role, name],
  );
  ids[name] = rows[0].id;
}

// Run queries as a signed-in user (RLS applies).
async function as(user, sql, params = []) {
  await db.exec(`set role authenticated`);
  await db.query(`select set_config('request.jwt.claim.sub', $1, false)`, [ids[user]]);
  try {
    return (await db.query(sql, params)).rows;
  } finally {
    await db.exec(`reset role; select set_config('request.jwt.claim.sub', '', false)`);
  }
}
async function fails(user, sql, params, pattern) {
  await assert.rejects(as(user, sql, params), pattern);
}

let passed = 0;
async function test(name, fn) {
  try { await fn(); passed++; console.log(`  ok  ${name}`); }
  catch (e) { console.log(`  FAIL ${name}\n       ${e.message}`); process.exitCode = 1; }
}

for (const [n, r] of [['d1', 'dietitian'], ['d2', 'dietitian'], ['c1', 'client'], ['c2', 'client'], ['c3', 'client'], ['c4', 'client']]) {
  await signUp(n, r);
}

// --- Setup: D1 invites C1 -------------------------------------------------
const [{ code }] = await as('d1', `insert into invites (dietitian_id) values ($1) returning code`, [ids.d1]);

await test('signup creates profile + dietitian workspace', async () => {
  const { rows } = await db.query(`select count(*)::int n from dietitian_profiles`);
  assert.equal(rows[0].n, 2);
});

await test('client sees invite preview for consent screen', async () => {
  const r = await as('c1', `select * from get_invite_preview($1)`, [code]);
  assert.equal(r.length, 1);
  assert.equal(r[0].full_name, 'd1');
  assert.ok(r[0].shared_data.length > 0);
});

await test('accept requires consent', () =>
  fails('c1', `select accept_invite($1, '')`, [code], /consent is required/));

await test('outdated consent text is rejected', () =>
  fails('c1', `select accept_invite($1, '2020-01-01')`, [code], /consent text has changed/));

await test('consent preview explains what happens after leaving; unverified flagged', async () => {
  const [p] = await as('c1', `select * from get_invite_preview($1)`, [code]);
  assert.equal(p.verified, false);
  assert.equal(p.consent_version, CONSENT);
  assert.ok(p.after_leaving.some((x) => x.includes('private notes')));
});

await test('dietitian cannot accept an invite', () =>
  fails('d2', `select accept_invite($1, '${CONSENT}')`, [code], /only client accounts/));

await test('client accepts invite', async () => {
  await as('c1', `select accept_invite($1, '${CONSENT}')`, [code]);
  const r = await as('c1', `select status from client_links`);
  assert.deepEqual(r, [{ status: 'active' }]);
});

await test('used invite cannot be reused', () =>
  fails('c2', `select accept_invite($1, '${CONSENT}')`, [code], /invalid or has expired/));

await test('dietitian cannot reopen an accepted invite', async () => {
  const r = await as('d1', `update invites set status = 'pending' returning id`);
  assert.equal(r.length, 0);
});

// --- Client data --------------------------------------------------------------
const today = new Date().toISOString().slice(0, 10);
for (const c of ['c1', 'c2']) {
  for (const daysAgo of [0, 1, 2, 4]) {
    await as(c, `insert into food_entries (client_id, logged_on, meal, name, calories)
                 values ($1, current_date - $2::int, 'lunch', 'Salad', 450)`, [ids[c], daysAgo]);
  }
  await as(c, `insert into weight_entries (client_id, measured_on, weight_kg) values
               ($1, current_date - 10, 82), ($1, current_date, 80.5)`, [ids[c]]);
}

await test('client sees only own food log', async () => {
  const r = await as('c1', `select distinct client_id from food_entries`);
  assert.deepEqual(r.map((x) => x.client_id), [ids.c1]);
});

await test('client cannot write rows for another client', () =>
  fails('c1', `insert into food_entries (client_id, logged_on, meal, name) values ($1, current_date, 'snack', 'x')`,
    [ids.c2], /row-level security/));

await test('linked dietitian reads client log; unlinked client hidden', async () => {
  const r = await as('d1', `select client_id, count(*)::int n from food_entries group by 1`);
  assert.deepEqual(r, [{ client_id: ids.c1, n: 4 }]);
});

await test('other dietitian sees nothing', async () => {
  assert.equal((await as('d2', `select * from food_entries`)).length, 0);
  assert.equal((await as('d2', `select * from profiles where id = $1`, [ids.c1])).length, 0);
});

await test('dietitian cannot edit client food log', async () => {
  const r = await as('d1', `update food_entries set calories = 1 returning id`);
  assert.equal(r.length, 0);
});

await test('client sees dietitian profile; dietitian sees client profile', async () => {
  assert.equal((await as('c1', `select * from profiles where id = $1`, [ids.d1])).length, 1);
  assert.equal((await as('d1', `select * from profiles where id = $1`, [ids.c1])).length, 1);
  assert.equal((await as('c1', `select * from profiles where id = $1`, [ids.c2])).length, 0);
});

await test('role cannot be self-changed', () =>
  fails('c1', `update profiles set role = 'dietitian' where id = $1`, [ids.c1], /permission denied/));

// --- Targets + audit log -----------------------------------------------------
await test('dietitian sets targets; client sees change history', async () => {
  await as('d1', `insert into nutrition_targets (client_id, calories, protein_g) values ($1, 1800, 100)`, [ids.c1]);
  await as('d1', `update nutrition_targets set protein_g = 110 where client_id = $1`, [ids.c1]);
  const r = await as('c1', `select summary from audit_log order by id`);
  assert.deepEqual(r.map((x) => x.summary), [
    'Your dietitian set your calorie target to 1800 kcal',
    'Your dietitian set your protein target to 100 g',
    'Your dietitian updated your protein target to 110 g',
  ]);
});

await test('linked client cannot override dietitian targets', async () => {
  const r = await as('c1', `update nutrition_targets set calories = 3000 returning client_id`);
  assert.equal(r.length, 0);
});

await test('unlinked client manages own targets, without audit entries', async () => {
  await as('c4', `insert into nutrition_targets (client_id, calories) values ($1, 2000)`, [ids.c4]);
  assert.equal((await as('c4', `select * from audit_log`)).length, 0);
});

await test('audit log is not writable by users', () =>
  fails('d1', `insert into audit_log (dietitian_id, client_id, entity, action, summary) values ($1, $2, 'x', 'x', 'fake')`,
    [ids.d1, ids.c1], /row-level security/));

// --- Notes, comments, recommendations, appointments ---------------------------
await test('private notes visible only to the authoring dietitian', async () => {
  await as('d1', `insert into private_notes (dietitian_id, client_id, body) values ($1, $2, 'secret')`, [ids.d1, ids.c1]);
  assert.equal((await as('d1', `select * from private_notes`)).length, 1);
  assert.equal((await as('c1', `select * from private_notes`)).length, 0);
  assert.equal((await as('d2', `select * from private_notes`)).length, 0);
});

await test('dietitian cannot write notes for a client not linked to them', () =>
  fails('d1', `insert into recommendations (dietitian_id, client_id, body) values ($1, $2, 'x')`,
    [ids.d1, ids.c2], /row-level security/));

await test('recommendation + meal comment + appointment visible to client', async () => {
  await as('d1', `insert into recommendations (dietitian_id, client_id, body) values ($1, $2, 'More fibre')`, [ids.d1, ids.c1]);
  const [{ id: entry }] = await as('c1', `select id from food_entries limit 1`);
  await as('d1', `insert into comments (dietitian_id, client_id, food_entry_id, body) values ($1, $2, $3, 'Nice')`, [ids.d1, ids.c1, entry]);
  await as('d1', `insert into appointments (dietitian_id, client_id, starts_at) values ($1, $2, now() + interval '3 days')`, [ids.d1, ids.c1]);
  assert.equal((await as('c1', `select * from recommendations`)).length, 1);
  assert.equal((await as('c1', `select * from comments`)).length, 1);
  assert.equal((await as('c1', `select * from appointments`)).length, 1);
});

await test('comment cannot reference another client\'s meal', async () => {
  const [{ id: c2entry }] = await db.query(`select id from food_entries where client_id = $1 limit 1`, [ids.c2]).then((r) => r.rows);
  await fails('d1', `insert into comments (dietitian_id, client_id, food_entry_id, body) values ($1, $2, $3, 'x')`,
    [ids.d1, ids.c1, c2entry], /does not belong/);
});

// --- Meal plans -----------------------------------------------------------------
await test('template assignment copies plan; one audit entry', async () => {
  const [{ id: tpl }] = await as('d1', `insert into meal_plans (dietitian_id, name) values ($1, 'Cut') returning id`, [ids.d1]);
  await as('d1', `insert into meal_plan_items (plan_id, day_index, meal, title) values ($1, 0, 'breakfast', 'Oats'), ($1, 0, 'lunch', 'Bowl')`, [tpl]);
  assert.equal((await as('c1', `select * from meal_plans where id = $1`, [tpl])).length, 0, 'template hidden from client');
  const before = (await as('c1', `select count(*)::int n from audit_log`))[0].n;
  await as('d1', `select assign_meal_plan($1, $2)`, [tpl, ids.c1]);
  const plans = await as('c1', `select p.name, count(i.*)::int items from meal_plans p join meal_plan_items i on i.plan_id = p.id group by 1`);
  assert.deepEqual(plans, [{ name: 'Cut', items: 2 }]);
  const after = await as('c1', `select summary from audit_log order by id offset $1`, [before]);
  assert.deepEqual(after.map((x) => x.summary), ['Your dietitian assigned you the meal plan "Cut"']);
});

// --- Messaging --------------------------------------------------------------------
await test('messaging between linked pair, read receipts only', async () => {
  await as('c1', `insert into messages (dietitian_id, client_id, sender_id, body) values ($1, $2, $2, 'Hi!')`, [ids.d1, ids.c1]);
  const [m] = await as('d1', `select id from messages where read_at is null`);
  assert.ok(m);
  await fails('d1', `update messages set body = 'edited' where id = $1`, [m.id], /permission denied/);
  await as('d1', `update messages set read_at = now() where id = $1`, [m.id]);
  await fails('c2', `insert into messages (dietitian_id, client_id, sender_id, body) values ($1, $2, $2, 'spam')`,
    [ids.d1, ids.c2], /row-level security/);
});

// --- Overview dashboard ---------------------------------------------------------
await test('client overview row', async () => {
  await as('c1', `insert into messages (dietitian_id, client_id, sender_id, body) values ($1, $2, $2, 'Another')`, [ids.d1, ids.c1]);
  const r = await as('d1', `select * from dietitian_client_overview()`);
  assert.equal(r.length, 1);
  assert.equal(r[0].client_id, ids.c1);
  assert.equal(Number(r[0].today_calories), 450);
  assert.equal(r[0].target_calories, 1800);
  assert.equal(r[0].weight_trend, 'down');
  assert.equal(r[0].logging_streak, 3);   // today, -1, -2 (gap at -3)
  assert.equal(r[0].unread_messages, 1);
});

await test('premium unlocked while linked', async () => {
  assert.equal((await as('c1', `select has_premium() p`))[0].p, true);
  assert.equal((await as('c2', `select has_premium() p`))[0].p, false);
});

// --- Storage ----------------------------------------------------------------------
await test('meal photo storage scoped to client folder', async () => {
  await as('c1', `insert into storage.objects (bucket_id, name) values ('meal-photos', $1)`, [`${ids.c1}/a.jpg`]);
  await fails('c1', `insert into storage.objects (bucket_id, name) values ('meal-photos', $1)`, [`${ids.c2}/a.jpg`], /row-level security/);
  await fails('c1', `insert into storage.objects (bucket_id, name) values ('meal-photos', 'garbage/a.jpg')`, [], /row-level security/);
  assert.equal((await as('d1', `select * from storage.objects`)).length, 1);
  assert.equal((await as('d2', `select * from storage.objects`)).length, 0);
});

// --- Leaving ------------------------------------------------------------------------
await test('leaving revokes all dietitian access immediately', async () => {
  await as('c1', `select leave_dietitian()`);
  for (const t of ['food_entries', 'weight_entries', 'messages', 'target_change_requests', 'audit_log', 'recommendations', 'nutrition_targets', 'storage.objects']) {
    assert.equal((await as('d1', `select * from ${t}`)).length, 0, t);
  }
  assert.equal((await as('d1', `select * from dietitian_client_overview()`)).length, 0);
  await fails('d1', `insert into comments (dietitian_id, client_id, log_date, body) values ($1, $2, current_date, 'x')`,
    [ids.d1, ids.c1], /row-level security/);
});

await test('dietitian keeps own private notes and authored plans (read-only) after leaving', async () => {
  assert.equal((await as('d1', `select * from private_notes where client_id = $1`, [ids.c1])).length, 1);
  await fails('d1', `insert into private_notes (dietitian_id, client_id, body) values ($1, $2, 'new')`,
    [ids.d1, ids.c1], /row-level security/);
  await as('d1', `update private_notes set body = 'edited after leaving' where client_id = $1`, [ids.c1]);
  await fails('d1', `update private_notes set client_id = $1`, [ids.c2], /permission denied/);
  const plans = await as('d1', `select p.id, count(i.*)::int n from meal_plans p join meal_plan_items i on i.plan_id = p.id where p.client_id = $1 group by 1`, [ids.c1]);
  assert.equal(plans.length, 1);
  assert.equal(plans[0].n, 2);
  assert.equal((await as('d1', `update meal_plans set name = 'x' where client_id = $1 returning id`, [ids.c1])).length, 0);
  const [link] = await as('d1', `select client_display_name, status from client_links where client_id = $1`, [ids.c1]);
  assert.deepEqual(link, { client_display_name: 'c1', status: 'ended' });
  assert.equal((await as('d1', `select * from profiles where id = $1`, [ids.c1])).length, 0);
});

await test('client data logged after leaving is never visible', async () => {
  await as('c1', `insert into food_entries (client_id, logged_on, meal, name) values ($1, current_date, 'dinner', 'After')`, [ids.c1]);
  assert.equal((await as('d1', `select * from food_entries where name = 'After'`)).length, 0);
});

await test('client keeps their shared history after leaving', async () => {
  assert.ok((await as('c1', `select * from audit_log`)).length > 0);
  assert.equal((await as('c1', `select * from recommendations`)).length, 1);
  assert.equal((await as('c1', `select * from messages`)).length, 2);
  assert.equal((await as('c1', `select has_premium() p`))[0].p, false);
});

// --- Limits & invite restrictions --------------------------------------------------
await test('subscription tier no longer limits clients (the app is free)', async () => {
  await db.query(`insert into dietitian_subscriptions (dietitian_id, max_active_clients) values ($1, 1)`, [ids.d2]);
  const codes = await as('d2', `insert into invites (dietitian_id) values ($1), ($1) returning code`, [ids.d2]);
  await as('c2', `select accept_invite($1, '${CONSENT}')`, [codes[0].code]);
  await as('c3', `select accept_invite($1, '${CONSENT}')`, [codes[1].code]);
  assert.equal((await as('d2', `select * from my_workspace_status()`))[0].active_clients, 2);
});

await test('one dietitian at a time', async () => {
  const [{ code: c }] = await as('d1', `insert into invites (dietitian_id) values ($1) returning code`, [ids.d1]);
  await fails('c2', `select accept_invite($1, '${CONSENT}')`, [c], /leave your current dietitian/);
});

await test('invite codes are case-insensitive', async () => {
  const [{ code: c }] = await as('d1', `insert into invites (dietitian_id) values ($1) returning code`, [ids.d1]);
  await as('c4', `select accept_invite($1, '${CONSENT}')`, [` ${c.toLowerCase()} `]);
});

// --- Target change requests & notifications ------------------------------------
await test('client requests a target change; dietitian is notified and answers', async () => {
  await as('c4', `insert into target_change_requests (client_id, dietitian_id, message, requested_calories) values ($1, $2, 'Too hungry', 1900)`, [ids.c4, ids.d1]);
  const [n] = await as('d1', `select type, body from notifications where type = 'target_request'`);
  assert.deepEqual(n, { type: 'target_request', body: 'Too hungry' });
  assert.equal((await as('c4', `update target_change_requests set status = 'resolved' returning id`)).length, 0);
  await as('d1', `update target_change_requests set status = 'resolved', response = 'Raised to 1900'`);
  const [r] = await as('c4', `select status, resolved_at is not null as done from target_change_requests`);
  assert.deepEqual(r, { status: 'resolved', done: true });
  assert.equal((await as('c4', `select * from notifications where type = 'target_request'`)).length, 1);
});

await test('client cannot send a request to a dietitian they are not linked to', () =>
  fails('c3', `insert into target_change_requests (client_id, dietitian_id, message) values ($1, $2, 'x')`,
    [ids.c3, ids.d1], /row-level security/));

await test('dietitian changes and messages create notifications', async () => {
  await as('d1', `insert into nutrition_targets (client_id, calories) values ($1, 1700)
                  on conflict (client_id) do update set calories = 1700`, [ids.c4]);
  const n = await as('c4', `select body from notifications where type = 'change'`);
  assert.ok(n.some((x) => x.body === 'Your dietitian updated your calorie target to 1700 kcal'), JSON.stringify(n));
  await as('c4', `insert into messages (dietitian_id, client_id, sender_id, body) values ($1, $2, $2, 'Thanks')`, [ids.d1, ids.c4]);
  assert.ok((await as('d1', `select * from notifications where type = 'message' and body = 'Thanks'`)).length === 1);
  assert.equal((await as('c4', `select * from notifications where type = 'message'`)).length, 0, 'sender not notified');
  assert.equal((await as('c2', `select * from notifications`)).length, 0, 'others see nothing');
  await fails('c4', `update notifications set body = 'x'`, [], /permission denied/);
});

// --- Verification ------------------------------------------------------------------
await test('unverified dietitian limited to 3 active clients', async () => {
  const [s] = await as('d1', `select * from my_workspace_status()`);
  assert.equal(s.verification_status, 'unsubmitted');
  assert.equal(s.client_limit, 3);
  await signUp('c5', 'client'); await signUp('c6', 'client'); await signUp('c7', 'client');
  const codes = await as('d1', `insert into invites (dietitian_id) values ($1), ($1), ($1) returning code`, [ids.d1]);
  await as('c5', `select accept_invite($1, '${CONSENT}')`, [codes[0].code]);   // c4, c5 active
  await as('c6', `select accept_invite($1, '${CONSENT}')`, [codes[1].code]);   // 3 active
  await fails('c7', `select accept_invite($1, '${CONSENT}')`, [codes[2].code], /client limit/);
});

await test('credential upload, admin review lifts the limit', async () => {
  await signUp('admin', 'client');
  await db.query(`insert into admins (user_id) values ($1)`, [ids.admin]);
  await fails('d1', `select submit_verification($1)`, [`${ids.d2}/x.pdf`], /own credentials folder/);
  await fails('c1', `insert into storage.objects (bucket_id, name) values ('credentials', $1)`, [`${ids.c1}/x.pdf`], /row-level security/);
  await as('d1', `insert into storage.objects (bucket_id, name) values ('credentials', $1)`, [`${ids.d1}/diploma.pdf`]);
  const [{ submit_verification: sub }] = await as('d1', `select submit_verification($1)`, [`${ids.d1}/diploma.pdf`]);
  assert.equal((await as('d1', `select * from my_workspace_status()`))[0].verification_status, 'pending');

  await fails('d1', `select * from admin_pending_verifications()`, [], /admins only/);
  await fails('d1', `select admin_review_verification($1, true)`, [sub], /admins only/);
  assert.equal((await as('d2', `select * from storage.objects where bucket_id = 'credentials'`)).length, 0);
  assert.equal((await as('admin', `select * from storage.objects where bucket_id = 'credentials'`)).length, 1);
  assert.equal((await as('admin', `select * from notifications where type = 'verification'`)).length, 1);
  const q = await as('admin', `select * from admin_pending_verifications()`);
  assert.deepEqual(q.map((x) => x.full_name), ['d1']);

  await fails('admin', `select admin_review_verification($1, false)`, [sub], /reason is required/);
  await as('admin', `select admin_review_verification($1, true)`, [sub]);
  const [s] = await as('d1', `select * from my_workspace_status()`);
  assert.equal(s.verification_status, 'approved');
  assert.equal(s.client_limit, null, 'verified dietitians have no client limit');
  const [{ code: c }] = await as('d1', `select code from invites where status = 'pending' limit 1`);
  await as('c7', `select accept_invite($1, '${CONSENT}')`, [c]);
  assert.equal((await as('c7', `select verified from get_invite_preview($1)`, [c])).length, 0, 'used code no longer previews');
});

await test('dietitian cannot self-verify', () =>
  fails('d2', `update dietitian_profiles set verification_status = 'approved' where user_id = $1`, [ids.d2], /permission denied/));

await test('helpers are not in the API schema', async () => {
  await fails('c1', `select has_active_link($1, $2)`, [ids.d1, ids.c1], /does not exist/);
});

await test('anon can call nothing', async () => {
  await db.exec(`set role anon`);
  try { await assert.rejects(db.query(`select get_invite_preview('X')`), /permission denied/); }
  finally { await db.exec(`reset role`); }
});

// --- Profile, reminders, broadcasts, avatars ---------------------------------------
await test('profile details editable by owner only; linked dietitian can read them', async () => {
  await as('c4', `update profiles set birth_date = '1990-05-01', height_cm = 168, sex = 'female' where id = $1`, [ids.c4]);
  const [p] = await as('d1', `select height_cm, sex from profiles where id = $1`, [ids.c4]);
  assert.equal(Number(p.height_cm), 168);
  assert.equal((await as('c2', `update profiles set height_cm = 1 where id = $1 returning id`, [ids.c4])).length, 0);
});

await test('reminder settings created with defaults, private to the user', async () => {
  const [r] = await as('c4', `select enabled, breakfast, lunch, dinner from reminder_settings`);
  assert.deepEqual(r, { enabled: true, breakfast: '08:30:00', lunch: '12:30:00', dinner: '19:30:00' });
  await as('c4', `update reminder_settings set lunch = '13:15' where user_id = $1`, [ids.c4]);
  assert.equal((await as('c4', `select lunch from reminder_settings`))[0].lunch, '13:15:00');
  assert.equal((await as('d1', `select * from reminder_settings where user_id = $1`, [ids.c4])).length, 0);
  await fails('c4', `update reminder_settings set user_id = $1`, [ids.c2], /permission denied/);
});

await test('broadcast reaches current clients only, with a notification', async () => {
  await as('d1', `insert into broadcasts (dietitian_id, category, title, body) values ($1, 'tip', 'Drink water', 'Aim for 8 glasses.')`, [ids.d1]);
  assert.equal((await as('c4', `select * from broadcasts`)).length, 1, 'active client sees it');
  assert.equal((await as('c1', `select * from broadcasts`)).length, 0, 'former client does not');
  assert.equal((await as('c2', `select * from broadcasts`)).length, 0, "another dietitian's client does not");
  const n = await as('c4', `select title, body from notifications where type = 'broadcast'`);
  assert.deepEqual(n, [{ title: 'Tip from d1', body: 'Drink water' }]);
  assert.equal((await as('c1', `select * from notifications where type = 'broadcast'`)).length, 0);
  await fails('c4', `insert into broadcasts (dietitian_id, title, body) values ($1, 'x', 'y')`, [ids.d1], /row-level security/);
  assert.equal((await as('d2', `delete from broadcasts returning id`)).length, 0, 'other dietitian cannot delete');
});

await test('avatars: write own folder only', async () => {
  await as('c4', `insert into storage.objects (bucket_id, name) values ('avatars', $1)`, [`${ids.c4}/a.jpg`]);
  await fails('c4', `insert into storage.objects (bucket_id, name) values ('avatars', $1)`, [`${ids.c2}/a.jpg`], /row-level security/);
});

// --- Food database -----------------------------------------------------------------
// d1 is a verified dietitian from here on; d2 is not.
const foodId = async (key) => (await db.query(`select id from foods where seed_key = $1`, [key])).rows[0].id;

await test('food seed: USDA rows have values and a source, todo rows have none', async () => {
  const [s] = await as('c1', `select * from food_stats()`);
  assert.ok(s.total >= 300, `only ${s.total} foods`);
  assert.ok(s.todo >= 50);
  assert.equal(s.verified, 0, 'everything starts unverified');
  const bad = await as('c1', `select name_tr from foods where source <> 'todo' and (kcal_per_100g is null or source_ref not like 'USDA FDC %')`);
  assert.deepEqual(bad, []);
  const [t] = await as('c1', `select kcal_per_100g, verified from foods where seed_key = 'menemen'`);
  assert.deepEqual(t, { kcal_per_100g: null, verified: false });
  const [u] = await as('c1', `select count(*)::int n from portion_units where unit = 'su bardağı'`);
  assert.ok(u.n > 100);
});

await test('a food cannot have values without a source, or a todo row values', async () => {
  await assert.rejects(db.query(`insert into foods (name_tr, name_en, source, kcal_per_100g, protein_per_100g, carbs_per_100g, fat_per_100g)
                                 values ('x', 'x', 'todo', 1, 1, 1, 1)`), /foods_values_match_source/);
  await assert.rejects(db.query(`insert into foods (name_tr, name_en, source) values ('x', 'x', 'usda_fdc')`), /foods_values_match_source/);
});

await test('search: Turkish without special letters, typos, English names', async () => {
  const top = async (q) => (await as('c1', `select x ->> 'name_tr' as n from search_foods($1) x`, [q])).map((r) => r.n);
  assert.equal((await top('mercimek corbasi'))[0], 'Mercimek çorbası');
  assert.equal((await top('mercmek çorbası'))[0], 'Mercimek çorbası');
  assert.equal((await top('lentil soup'))[0], 'Mercimek çorbası');
  assert.ok((await top('yumurta')).slice(0, 3).includes('Haşlanmış yumurta'));
  assert.ok((await top('IZGARA KÖFTE')).includes('Izgara köfte'), 'todo rows are found too');
  const [x] = await as('c1', `select x from search_foods('beyaz peynir') x`);
  assert.ok(x.x.portions.some((p) => p.unit === 'dilim'), JSON.stringify(x.x.portions));
  assert.deepEqual(await top('a'), [], 'too short');
});

await test('nobody writes foods directly; only verified dietitians curate', async () => {
  const id = await foodId('tea');
  await fails('c1', `update foods set kcal_per_100g = 0 where id = $1`, [id], /permission denied/);
  await fails('d1', `insert into portion_units (food_id, unit, grams_per_unit, source) values ($1, 'kase', 300, 'dietitian')`, [id], /permission denied/);
  await fails('c1', `select verify_food($1)`, [id], /only verified dietitians/);
  await fails('d2', `select verify_food($1)`, [id], /only verified dietitians/);
  await fails('d2', `select update_food($1, '{"kcal_per_100g": 5}'::jsonb)`, [id], /only verified dietitians/);
});

await test('verified dietitian verifies a USDA food; history is kept', async () => {
  const id = await foodId('lentil_soup');
  const [{ verify_food: f }] = await as('d1', `select verify_food($1)`, [id]);
  assert.equal(f.verified, true);
  assert.equal(f.verified_by, ids.d1);
  assert.equal(f.source, 'usda_fdc', 'verifying keeps the source');
  const [{ search_foods: hit }] = await as('c4', `select search_foods('mercimek çorbası')`);
  assert.equal(hit.verified, true);
  assert.equal((await as('d1', `select action from food_revisions where food_id = $1`, [id]))[0].action, 'verify');
  assert.equal((await as('c1', `select * from food_revisions`)).length, 0, 'clients do not see curation history');
});

await test('todo food: cannot verify until values are entered; then it is the dietitian\'s', async () => {
  const id = await foodId('ayran');
  await fails('d1', `select verify_food($1)`, [id], /add the nutrition values/);
  const data = JSON.stringify({ kcal_per_100g: 38, protein_per_100g: 1.7, carbs_per_100g: 2.6, fat_per_100g: 2.3,
    source_note: 'TürKomp (test)', portions: [{ unit: 'su bardağı', grams: 200 }, { unit: 'kase', grams: 250 }] });
  const [{ update_food: f }] = await as('d1', `select update_food($1, $2::jsonb, true)`, [id, data]);
  assert.equal(f.source, 'dietitian');
  assert.equal(f.verified, true);
  assert.match(f.source_ref, /^Dietitian d1/);
  assert.deepEqual(f.portions.map((p) => [p.unit, Number(p.grams), p.source]).sort(),
    [['kase', 250, 'dietitian'], ['su bardağı', 200, 'dietitian']]);
});

await test('editing values un-verifies unless re-verified; unchanged portions keep their source', async () => {
  const id = await foodId('milk_whole');
  const [{ get_food: before }] = await as('c1', `select get_food($1)`, [id]);
  const portions = before.portions.map((p) => ({ unit: p.unit, size: p.size, grams: p.grams }));
  await as('d1', `select verify_food($1)`, [id]);
  const [{ update_food: f }] = await as('d1', `select update_food($1, $2::jsonb)`,
    [id, JSON.stringify({ fat_per_100g: 3.3, portions: [...portions, { unit: 'kase', grams: 240 }] })]);
  assert.equal(f.verified, false);
  assert.equal(f.source, 'dietitian');
  assert.match(f.source_ref, /was USDA FDC 171265/);
  assert.equal(f.portions.find((p) => p.unit === 'su bardağı').source, 'usda_fdc');
  assert.equal(f.portions.find((p) => p.unit === 'kase').source, 'dietitian');
  assert.equal((await as('d1', `select count(*)::int n from food_revisions where food_id = $1`, [id]))[0].n, 2);
});

await test('verified dietitian adds a new food', async () => {
  const [{ create_food: f }] = await as('d1', `select create_food($1::jsonb)`, [JSON.stringify({
    name_tr: 'Test keki', kcal_per_100g: 300, protein_per_100g: 5, carbs_per_100g: 50, fat_per_100g: 9,
    aliases: ['deneme'], portions: [{ unit: 'dilim', grams: 60 }] })]);
  assert.equal(f.name_en, 'Test keki');
  assert.equal(f.source, 'dietitian');
  assert.equal(f.verified, false);
  assert.equal((await as('c1', `select x ->> 'name_tr' n from search_foods('deneme') x`))[0].n, 'Test keki');
  await fails('d2', `select create_food('{"name_tr": "x", "kcal_per_100g": 1, "protein_per_100g": 1, "carbs_per_100g": 1, "fat_per_100g": 1}'::jsonb)`, [], /only verified dietitians/);
});

await test('food entries record the food, portion and how they were logged', async () => {
  const id = await foodId('egg_boiled');
  await as('c4', `insert into food_entries (client_id, logged_on, meal, name, calories, food_id, portion_unit, portion_amount, grams, source)
                  values ($1, current_date, 'breakfast', 'Haşlanmış yumurta', 136, $2, 'adet', 2, 88, 'manual')`, [ids.c4, id]);
  const [e] = await as('d1', `select food_id, portion_unit, source from food_entries where client_id = $1 and food_id is not null`, [ids.c4]);
  assert.deepEqual(e, { food_id: id, portion_unit: 'adet', source: 'manual' });
  await fails('c4', `insert into food_entries (client_id, logged_on, meal, name, source) values ($1, current_date, 'lunch', 'x', 'telepathy')`,
    [ids.c4], /food_entries_source_check/);
});

// --- Onboarding answers ------------------------------------------------------------
await test('onboarding answers: own profile only; linked dietitian reads them; consent lists them', async () => {
  await signUp('c8', 'client');
  const [fresh] = await as('c8', `select onboarded_at from profiles where id = $1`, [ids.c8]);
  assert.equal(fresh.onboarded_at, null, 'new accounts get the questions');
  await as('c8', `update profiles set goal = 'lose', goal_pace = 'slow', activity_level = 'light',
                  diet_preferences = '{vegetarian}', allergies = '{nuts}', health_flags = '{diabetes}',
                  challenges = '{sweets}', meals_per_day = 3, onboarded_at = now() where id = $1`, [ids.c8]);
  assert.equal((await as('c2', `update profiles set allergies = '{x}' where id = $1 returning id`, [ids.c8])).length, 0);
  await fails('c8', `update profiles set goal = 'fly' where id = $1`, [ids.c8], /profiles_goal_check/);
  // c4 is d1's client: d1 sees c4's answers, d2 does not.
  await as('c4', `update profiles set allergies = '{milk}' where id = $1`, [ids.c4]);
  assert.deepEqual((await as('d1', `select allergies from profiles where id = $1`, [ids.c4]))[0].allergies, ['milk']);
  assert.equal((await as('d2', `select allergies from profiles where id = $1`, [ids.c4])).length, 0);
  const [{ code: c }] = await as('d1', `insert into invites (dietitian_id) values ($1) returning code`, [ids.d1]);
  const [p] = await as('c8', `select * from get_invite_preview($1)`, [c]);
  assert.ok(p.shared_data[0].includes('health notes'));
  assert.equal(p.consent_version, '2026-10-25');
});

// --- Find a dietitian: directory, requests, ratings ----------------------------------
{
  for (const [n, r] of [['d3', 'dietitian'], ['d4', 'dietitian'], ['c9', 'client'], ['c10', 'client'], ['c11', 'client']]) await signUp(n, r);
  // d3 verified (as an admin would), d4 not.
  await db.query(`update dietitian_profiles set verification_status = 'approved', city = 'İzmir', specialties = '{Diyabet}' where user_id = $1`, [ids.d3]);

  await test('directory lists only verified, listed dietitians; search folds Turkish letters', async () => {
    const names = (await as('c9', `select full_name from list_dietitians()`)).map((r) => r.full_name);
    assert.ok(names.includes('d3'));
    assert.ok(!names.includes('d4'), 'unverified dietitians are not listed');
    assert.equal((await as('c9', `select * from list_dietitians('izmir')`)).length, 1);
    assert.equal((await as('c9', `select * from list_dietitians('DİYABET')`))[0].full_name, 'd3');
    await as('d3', `update dietitian_profiles set listed = false where user_id = $1`, [ids.d3]);
    assert.equal((await as('c9', `select * from list_dietitians('izmir')`)).length, 0);
    await as('d3', `update dietitian_profiles set listed = true where user_id = $1`, [ids.d3]);
  });

  await test('dietitian cannot change their own verification or the request table directly', async () => {
    await fails('d4', `update dietitian_profiles set verification_status = 'approved' where user_id = $1`, [ids.d4], /permission denied/);
    await fails('c9', `insert into connection_requests (client_id, dietitian_id, consent_version) values ($1, $2, 'x')`, [ids.c9, ids.d3], /permission denied/);
    await fails('c9', `insert into dietitian_ratings (link_id, dietitian_id, client_id, stars) select id, dietitian_id, client_id, 5 from client_links limit 1`, [], /permission denied/);
  });

  await test('request needs current consent; unverified dietitian cannot be requested', async () => {
    await fails('c9', `select request_dietitian($1, 'hi', '2020-01-01')`, [ids.d3], /consent text has changed/);
    await fails('c9', `select request_dietitian($1, 'hi', $2)`, [ids.d4, CONSENT], /not accepting requests/);
    await fails('d1', `select request_dietitian($1, 'hi', $2)`, [ids.d3, CONSENT], /only client accounts/);
  });

  let req;
  await test('client sends one request; dietitian sees only name and message', async () => {
    [{ request_dietitian: req }] = await as('c9', `select request_dietitian($1, 'Diyabetim var', $2)`, [ids.d3, CONSENT]);
    await fails('c9', `select request_dietitian($1, 'again', $2)`, [ids.d1, CONSENT], /already have a pending request/);
    const [r] = await as('d3', `select * from my_connection_requests()`);
    assert.equal(r.client_name, 'c9');
    assert.equal(r.message, 'Diyabetim var');
    assert.equal((await as('d3', `select * from profiles where id = $1`, [ids.c9])).length, 0, 'no profile access before accepting');
    assert.equal((await as('d4', `select * from connection_requests`)).length, 0, 'other dietitians see nothing');
    assert.equal((await as('d3', `select count(*)::int n from notifications where type = 'link_request'`))[0].n, 1);
    assert.equal((await as('c9', `select my_request from list_dietitians() where dietitian_id = $1`, [ids.d3]))[0].my_request, 'pending');
  });

  await test('only the addressed dietitian can answer', () =>
    fails('d1', `select respond_to_request($1, true)`, [req], /request not found/));

  await test('accepting creates the link with the consent from the request', async () => {
    await as('d3', `select respond_to_request($1, true)`, [req]);
    const [l] = await as('c9', `select dietitian_id, status, consent_version from client_links where client_id = $1`, [ids.c9]);
    assert.deepEqual(l, { dietitian_id: ids.d3, status: 'active', consent_version: CONSENT });
    assert.equal((await as('d3', `select full_name from profiles where id = $1`, [ids.c9]))[0].full_name, 'c9');
    await fails('d3', `select respond_to_request($1, true)`, [req], /already answered/);
  });

  await test('requests are allowed when full (demand), accepting is not', async () => {
    await as('d3', `update dietitian_profiles set capacity = 1 where user_id = $1`, [ids.d3]);
    assert.equal((await as('c10', `select is_full from list_dietitians() where dietitian_id = $1`, [ids.d3]))[0].is_full, true);
    const [{ request_dietitian: r2 }] = await as('c10', `select request_dietitian($1, null, $2)`, [ids.d3, CONSENT]);
    await fails('d3', `select respond_to_request($1, true)`, [r2], /client list is full/);
    await as('d3', `select respond_to_request($1, false, 'Kontenjanım dolu')`, [r2]);
    const [q] = await as('c10', `select status, decline_reason from connection_requests`);
    assert.deepEqual(q, { status: 'declined', decline_reason: 'Kontenjanım dolu' });
    await fails('c10', `select request_dietitian($1, null, $2)`, [ids.d3, CONSENT], /declined your request recently/);
    await as('d3', `update dietitian_profiles set capacity = null where user_id = $1`, [ids.d3]);
  });

  await test('client can cancel a pending request', async () => {
    await as('c11', `select request_dietitian($1, null, $2)`, [ids.d3, CONSENT]);
    await as('c11', `select cancel_dietitian_request()`);
    assert.equal((await as('c11', `select status from connection_requests`))[0].status, 'cancelled');
    assert.equal((await as('d3', `select * from my_connection_requests()`)).length, 0);
  });

  await test('switching: accepting a client who has a dietitian ends the old link', async () => {
    // c9 (with d3) asks d1 (verified earlier in these tests).
    const [{ request_dietitian: r3 }] = await as('c9', `select request_dietitian($1, null, $2)`, [ids.d1, CONSENT]);
    assert.equal((await as('d1', `select has_dietitian from my_connection_requests()`))[0].has_dietitian, true);
    await as('d1', `select respond_to_request($1, true)`, [r3]);
    const links = await as('c9', `select dietitian_id, status from client_links order by started_at`);
    assert.deepEqual(links.map((l) => l.status), ['ended', 'active']);
    assert.equal((await as('d3', `select * from profiles where id = $1`, [ids.c9])).length, 0, 'old dietitian lost access');
    const former = await as('d3', `select * from dietitian_former_clients()`);
    assert.equal(former[0].client_name, 'c9');
    assert.equal((await as('d1', `select * from dietitian_former_clients()`)).some((f) => f.client_id === ids.c9), false);
  });

  await test('ratings: only after 14 days with the dietitian; anonymous to others', async () => {
    await fails('c9', `select rate_dietitian($1, 5)`, [ids.d1], /after working with them for 14 days/);
    await fails('c11', `select rate_dietitian($1, 5)`, [ids.d3], /after working with them for 14 days/);
    await db.query(`update client_links set started_at = started_at - interval '20 days' where client_id = $1 and dietitian_id = $2`, [ids.c9, ids.d3]);
    await fails('c9', `select rate_dietitian($1, 6)`, [ids.d3], /1 to 5 stars/);
    await as('c9', `select rate_dietitian($1, 4, 'Çok yardımcı oldu')`, [ids.d3]);
    await as('c9', `select rate_dietitian($1, 5, 'Çok yardımcı oldu')`, [ids.d3]); // updates, no duplicate
    const [d] = await as('c10', `select rating_avg, rating_count from list_dietitians() where dietitian_id = $1`, [ids.d3]);
    assert.deepEqual([Number(d.rating_avg), d.rating_count], [5, 1]);
    const rev = await as('c10', `select * from dietitian_reviews($1)`, [ids.d3]);
    assert.deepEqual(Object.keys(rev[0]).sort(), ['comment', 'created_at', 'stars'], 'no reviewer identity');
    assert.equal((await as('d3', `select * from dietitian_ratings`)).length, 0, 'dietitian cannot see who rated');
    assert.equal((await as('c9', `select my_stars from my_rateable_dietitians()`))[0].my_stars, 5);
  });

  await test('package size: any user fixes it from the label, values untouched, history kept', async () => {
    const { rows: [{ id: bar }] } = await db.query(`insert into foods (name_tr, name_en, barcode, kcal_per_100g, protein_per_100g, carbs_per_100g, fat_per_100g, source, source_ref)
      values ('Albeni Maxi', 'Albeni Maxi', '8690504000000', 500, 6, 60, 26, 'open_food_facts', 'OFF test') returning id`);
    await db.query(`insert into portion_units (food_id, unit, grams_per_unit, source) values ($1, 'porsiyon', 30, 'open_food_facts')`, [bar]);
    const [{ set_package_size: f }] = await as('c10', `select set_package_size($1, 52)`, [bar]);
    const paket = f.portions.find((p) => p.unit === 'paket');
    assert.equal(Number(paket.grams), 52);
    assert.equal(Number(f.kcal_per_100g), 500, 'nutrition values unchanged');
    await as('c11', `select set_package_size($1, 52.5)`, [bar]);
    assert.equal((await db.query(`select count(*)::int n from portion_units where food_id = $1 and unit = 'paket'`, [bar])).rows[0].n, 1);
    assert.equal((await db.query(`select count(*)::int n from food_revisions where food_id = $1 and action = 'package_size'`, [bar])).rows[0].n, 2);
    await fails('c10', `select set_package_size($1, 0)`, [bar], /between 1 and 5000/);
    const { rows: [{ id: rice }] } = await db.query(`select id from foods where barcode is null and source <> 'todo' limit 1`);
    await fails('c10', `select set_package_size($1, 50)`, [rice], /only be set for packaged/);
    await fails('c10', `insert into portion_units (food_id, unit, grams_per_unit, source) values ($1, 'paket', 1, 'user_label')`, [bar], /permission denied/);
  });

  await test('unverified dietitian: own capacity cannot lift the 3-client cap', async () => {
    await as('d4', `update dietitian_profiles set capacity = 50 where user_id = $1`, [ids.d4]);
    assert.equal((await as('d4', `select client_limit from my_workspace_status()`))[0].client_limit, 3);
    await as('d4', `update dietitian_profiles set capacity = 2 where user_id = $1`, [ids.d4]);
    assert.equal((await as('d4', `select client_limit from my_workspace_status()`))[0].client_limit, 2);
  });
}

console.log(`\n${passed} passed${process.exitCode ? ', some FAILED' : ''}`);
