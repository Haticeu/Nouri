// Local stand-in for Supabase, for development and demos without a cloud project.
//
// Runs the REAL migration (tables, RLS policies, triggers, RPCs) in PGlite
// (Postgres compiled to WASM) and speaks enough of Supabase's HTTP/WebSocket
// protocols for supabase_flutter: Auth (email/password), PostgREST, Storage
// (upload + signed URLs) and Realtime postgres_changes.
//
// Every request runs as the signed-in user (role `authenticated`, auth.uid()
// from the token), so RLS is enforced exactly as in production.
//
//   cd devserver && npm install && npm start      -> http://localhost:54321
//   Data persists in devserver/.pgdata; delete that folder to reset + reseed.

import { PGlite } from '@electric-sql/pglite';
import { pg_trgm } from '@electric-sql/pglite/contrib/pg_trgm';
import http from 'node:http';
import crypto from 'node:crypto';
import { existsSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import Anthropic from '@anthropic-ai/sdk';
import { seed } from './seed.mjs';
import { analyzeMeal, analyzeWithEndpoint, MealAnalysisError, NOT_CONFIGURED } from '../supabase/functions/analyze-meal/analyze.mjs';
import { estimateFromText } from '../supabase/functions/estimate-meal/estimate.mjs';
import { BarcodeError, lookupBarcode } from '../supabase/functions/lookup-barcode/barcode.mjs';

// Optional local secrets (e.g. ANTHROPIC_API_KEY=...) in devserver/.env; never committed.
const envFile = fileURLToPath(new URL('./.env', import.meta.url));
if (existsSync(envFile)) process.loadEnvFile(envFile);

const PORT = Number(process.env.PORT ?? 54321);
const JWT_SECRET = 'nouri-local-dev-secret-not-for-production';
const here = (p) => fileURLToPath(new URL(p, import.meta.url));

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------
// PGlite's data folder must only ever be opened by ONE process, or it gets
// corrupted. Refuse to start if another copy of this server is already running.
const portTaken = await new Promise((resolve) => {
  const probe = http.get({ host: '127.0.0.1', port: PORT, path: '/', timeout: 1500 }, (r) => { r.resume(); resolve(true); });
  probe.on('error', () => resolve(false));
  probe.on('timeout', () => { probe.destroy(); resolve(true); });
});
if (portTaken) {
  console.error(`Port ${PORT} is already in use: the Nouri local server (or something else) is already running.`);
  console.error('Close the other terminal running `npm run dev`, or stop that process, then try again.');
  process.exit(1);
}

// NOURI_DATA_DIR lets a second, throwaway server run on a copy of the data.
const dataDir = process.env.NOURI_DATA_DIR || here('./.pgdata');
const fresh = !existsSync(dataDir);
const db = new PGlite(dataDir, { extensions: { pg_trgm } });

// Close the database cleanly on Ctrl+C so its files are never left half-written.
for (const signal of ['SIGINT', 'SIGTERM', 'SIGBREAK']) {
  process.on(signal, async () => {
    try { await chain; await db.close(); } finally { process.exit(0); }
  });
}

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
  create table auth.users (
    id uuid primary key, email text unique, raw_user_meta_data jsonb default '{}',
    encrypted_password text, created_at timestamptz default now()
  );
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

  create schema storage;
  grant usage on schema storage to authenticated;
  create table storage.buckets (id text primary key, name text, public boolean);
  create table storage.objects (
    id uuid primary key default gen_random_uuid(), bucket_id text, name text,
    owner uuid default auth.uid(), created_at timestamptz default now(), unique (bucket_id, name)
  );
  alter table storage.objects enable row level security;
  grant select, insert, update, delete on storage.objects to authenticated;

  create publication supabase_realtime;

  -- dev-only internals
  create schema dev;
  create table dev.files (bucket text, name text, mime text, content bytea, primary key (bucket, name));
  create table dev.refresh_tokens (token text primary key, user_id uuid not null);
  create table dev.changes (id bigserial primary key, tbl text, op text, rec jsonb, old jsonb);
  create function dev.capture() returns trigger language plpgsql security definer as $$
  begin
    insert into dev.changes (tbl, op, rec, old) values (
      tg_table_name, tg_op,
      case when tg_op <> 'DELETE' then to_jsonb(new) end,
      case when tg_op <> 'INSERT' then to_jsonb(old) end);
    return null;
  end $$;
`;

if (fresh) {
  console.log('Creating database (first run)…');
  await db.exec(SUPABASE_STUB);
}

// Dev-only tables and stub pieces added after the first release of this
// server; created on every start so existing databases get them too.
await db.exec(`
  create schema if not exists extensions;
  grant usage on schema extensions to anon, authenticated, service_role;
  create table if not exists dev.recovery_codes (
    email text primary key, code text not null, expires_at timestamptz not null);
  create table if not exists dev.mail (
    id bigserial primary key, recipient text not null, subject text not null,
    body text not null, created_at timestamptz not null default now());
  create table if not exists dev.migrations (name text primary key, applied_at timestamptz not null default now());
`);
await runMigrations();

/**
 * Apply supabase/migrations/*.sql that this database hasn't run yet, in name
 * order, each in its own transaction. Existing data is kept.
 */
async function runMigrations() {
  const dir = here('../supabase/migrations/');
  const files = readdirSync(dir).filter((f) => f.endsWith('.sql')).sort();
  // Databases created before migrations were tracked already ran the first one.
  const tracked = (await db.query(`select count(*)::int as n from dev.migrations`)).rows[0].n > 0;
  const hasSchema = (await db.query(`select to_regclass('public.profiles') is not null as ok`)).rows[0].ok;
  if (!tracked && hasSchema) await db.query(`insert into dev.migrations (name) values ($1)`, [files[0]]);
  const done = new Set((await db.query(`select name from dev.migrations`)).rows.map((r) => r.name));
  for (const f of files.filter((x) => !done.has(x))) {
    console.log(`Applying migration ${f}…`);
    await db.exec('begin');
    try {
      await db.exec(readFileSync(dir + f, 'utf8'));
      await db.query(`insert into dev.migrations (name) values ($1)`, [f]);
      await db.exec('commit');
    } catch (e) {
      await db.exec('rollback');
      console.error(`Migration ${f} failed, nothing from it was applied: ${e.message}`);
      process.exit(1);
    }
  }
  // Feed realtime from every table in the supabase_realtime publication.
  const { rows } = await db.query(`
    select t.tablename from pg_publication_tables t
     where t.pubname = 'supabase_realtime' and not exists (
       select 1 from pg_trigger g where g.tgname = 'zz_dev_realtime'
          and g.tgrelid = format('public.%I', t.tablename)::regclass)`);
  for (const { tablename } of rows) {
    await db.exec(`create trigger zz_dev_realtime after insert or update or delete on public.${tablename}
                   for each row execute function dev.capture()`);
  }
}

// One connection, so serialize everything.
let chain = Promise.resolve();
function serial(fn) {
  const p = chain.then(fn, fn);
  chain = p.catch(() => {});
  return p;
}

/** Run fn inside a transaction as the given user (null = anon, 'service' = superuser). */
function asUser(uid, fn) {
  return serial(async () => {
    await db.exec('begin');
    try {
      if (uid === 'service') {
        // superuser, bypasses RLS
      } else if (uid) {
        await db.exec('set local role authenticated');
        await db.query(`select set_config('request.jwt.claim.sub', $1, true)`, [uid]);
      } else {
        await db.exec('set local role anon');
      }
      const result = await fn();
      await db.exec('commit');
      return result;
    } catch (e) {
      await db.exec('rollback');
      throw e;
    }
  });
}

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------
const b64url = (b) => Buffer.from(b).toString('base64url');
const hmac = (s) => crypto.createHmac('sha256', JWT_SECRET).update(s).digest('base64url');

function signJwt(payload) {
  const head = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64url(JSON.stringify(payload));
  return `${head}.${body}.${hmac(`${head}.${body}`)}`;
}
function verifyJwt(token) {
  const [h, b, s] = String(token ?? '').split('.');
  if (!s || hmac(`${h}.${b}`) !== s) return null;
  const p = JSON.parse(Buffer.from(b, 'base64url').toString());
  return p.exp * 1000 > Date.now() ? p : null;
}
function userIdFrom(req) {
  const auth = req.headers.authorization ?? '';
  return verifyJwt(auth.replace(/^Bearer\s+/i, ''))?.sub ?? null;
}

const hashPassword = (pw, salt = crypto.randomBytes(8).toString('hex')) =>
  `${salt}:${crypto.scryptSync(pw, salt, 32).toString('hex')}`;
const checkPassword = (pw, stored) => !!stored && hashPassword(pw, stored.split(':')[0]) === stored;

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------
function cors(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PATCH,PUT,DELETE,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', req.headers['access-control-request-headers'] ?? '*');
  res.setHeader('Access-Control-Expose-Headers', 'Content-Range, Content-Type');
}
function send(res, status, body, type = 'application/json') {
  if (body === undefined || body === null) {
    res.writeHead(status);
    return res.end();
  }
  res.writeHead(status, { 'Content-Type': type });
  res.end(type === 'application/json' ? JSON.stringify(body) : body);
}
async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return Buffer.concat(chunks);
}
const json = (buf) => (buf.length ? JSON.parse(buf.toString('utf8')) : {});

function pgError(e) {
  const status = { '42501': 403, '23505': 409, '23503': 409, '42P01': 404, '42883': 404, PGRST116: 406 }[e.code] ?? 400;
  return [status, { code: e.code ?? 'PGRST000', message: e.message, details: e.detail ?? null, hint: e.hint ?? null }];
}

// ---------------------------------------------------------------------------
// Auth (/auth/v1)
// ---------------------------------------------------------------------------
function userJson(u) {
  const ts = new Date(u.created_at ?? Date.now()).toISOString();
  return {
    id: u.id, aud: 'authenticated', role: 'authenticated', email: u.email, phone: '',
    email_confirmed_at: ts, confirmed_at: ts, last_sign_in_at: new Date().toISOString(),
    app_metadata: { provider: 'email', providers: ['email'] },
    user_metadata: u.raw_user_meta_data ?? {}, identities: [], created_at: ts, updated_at: ts, is_anonymous: false,
  };
}
async function sessionFor(u) {
  const now = Math.floor(Date.now() / 1000);
  const refresh = crypto.randomBytes(24).toString('base64url');
  await asUser('service', () => db.query(`insert into dev.refresh_tokens values ($1, $2)`, [refresh, u.id]));
  return {
    access_token: signJwt({ sub: u.id, email: u.email, role: 'authenticated', aud: 'authenticated', iat: now, exp: now + 3600 }),
    token_type: 'bearer', expires_in: 3600, expires_at: now + 3600, refresh_token: refresh, user: userJson(u),
  };
}
const authError = (res, status, code, msg) => send(res, status, { code: status, error_code: code, msg, error: code, error_description: msg });
const findUser = (where, v) => asUser('service', async () => (await db.query(`select * from auth.users where ${where} = $1`, [v])).rows[0]);

async function handleAuth(req, res, url) {
  const route = url.pathname.replace('/auth/v1', '');
  if (req.method === 'POST' && route === '/signup') {
    const { email, password, data } = json(await readBody(req));
    if (!email || !password || password.length < 6) return authError(res, 422, 'weak_password', 'Password should be at least 6 characters.');
    if (await findUser('lower(email)', email.toLowerCase())) return authError(res, 422, 'user_already_exists', 'User already registered');
    const u = await asUser('service', async () => (await db.query(
      `insert into auth.users (id, email, raw_user_meta_data, encrypted_password) values (gen_random_uuid(), $1, $2, $3) returning *`,
      [email.toLowerCase(), JSON.stringify(data ?? {}), hashPassword(password)])).rows[0]);
    return send(res, 200, await sessionFor(u));
  }
  if (req.method === 'POST' && route === '/token') {
    const body = json(await readBody(req));
    const grant = url.searchParams.get('grant_type');
    if (grant === 'password') {
      const u = await findUser('lower(email)', String(body.email ?? '').toLowerCase());
      if (!u || !checkPassword(body.password ?? '', u.encrypted_password)) {
        return authError(res, 400, 'invalid_credentials', 'Invalid login credentials');
      }
      return send(res, 200, await sessionFor(u));
    }
    if (grant === 'refresh_token') {
      const row = await asUser('service', async () =>
        (await db.query(`delete from dev.refresh_tokens where token = $1 returning user_id`, [body.refresh_token])).rows[0]);
      const u = row && (await findUser('id', row.user_id));
      if (!u) return authError(res, 400, 'refresh_token_not_found', 'Invalid Refresh Token: Refresh Token Not Found');
      return send(res, 200, await sessionFor(u));
    }
  }
  if (req.method === 'GET' && route === '/user') {
    const uid = userIdFrom(req);
    const u = uid && (await findUser('id', uid));
    return u ? send(res, 200, userJson(u)) : authError(res, 401, 'bad_jwt', 'invalid JWT');
  }
  // Change password / metadata of the signed-in user.
  if (req.method === 'PUT' && route === '/user') {
    const uid = userIdFrom(req);
    if (!uid) return authError(res, 401, 'bad_jwt', 'invalid JWT');
    const { password, data } = json(await readBody(req)) ?? {};
    if (password !== undefined && String(password).length < 6) {
      return authError(res, 422, 'weak_password', 'Password should be at least 6 characters.');
    }
    const u = await asUser('service', async () => (await db.query(
      `update auth.users set
         encrypted_password = coalesce($2, encrypted_password),
         raw_user_meta_data = raw_user_meta_data || coalesce($3::jsonb, '{}'::jsonb)
       where id = $1 returning *`,
      [uid, password === undefined ? null : hashPassword(String(password)), data ? JSON.stringify(data) : null])).rows[0]);
    return u ? send(res, 200, userJson(u)) : authError(res, 404, 'user_not_found', 'User not found');
  }
  // "Forgot password": email a 6-digit code (shown in the dev mailbox at /mail).
  if (req.method === 'POST' && route === '/recover') {
    const email = String(json(await readBody(req))?.email ?? '').trim().toLowerCase();
    const u = email && (await findUser('lower(email)', email));
    if (u) {
      const code = String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');
      await asUser('service', async () => {
        await db.query(`insert into dev.recovery_codes values ($1, $2, now() + interval '1 hour')
                        on conflict (email) do update set code = excluded.code, expires_at = excluded.expires_at`, [email, code]);
        await db.query(`insert into dev.mail (recipient, subject, body) values ($1, $2, $3)`, [email,
          'Reset your Nouri password',
          `Your password reset code is ${code}. It expires in 1 hour. If you didn't ask to reset your password, ignore this email.`]);
      });
      console.log(`[mail] password reset code for ${email}: ${code}  (see http://localhost:${PORT}/mail)`);
    }
    // Same answer whether or not the account exists, so emails can't be probed.
    return send(res, 200, {});
  }
  if (req.method === 'POST' && route === '/verify') {
    const { email, token, type } = json(await readBody(req)) ?? {};
    if (type !== 'recovery') return authError(res, 400, 'validation_failed', `Only recovery codes are supported locally (got ${type})`);
    const addr = String(email ?? '').trim().toLowerCase();
    const ok = await asUser('service', async () => (await db.query(
      `delete from dev.recovery_codes where email = $1 and code = $2 and expires_at > now() returning email`,
      [addr, String(token ?? '').trim()])).rows.length > 0);
    const u = ok && (await findUser('lower(email)', addr));
    if (!u) return authError(res, 403, 'otp_expired', 'Token has expired or is invalid');
    return send(res, 200, await sessionFor(u));
  }
  if (req.method === 'POST' && route === '/logout') return send(res, 204);
  return authError(res, 404, 'not_found', `Not supported by the local dev server: ${req.method} ${route}`);
}

// ---------------------------------------------------------------------------
// PostgREST (/rest/v1)
// ---------------------------------------------------------------------------
const ident = (s) => {
  if (!/^[a-z_][a-z0-9_]*$/i.test(s)) throw Object.assign(new Error(`Invalid identifier: ${s}`), { code: 'PGRST100' });
  return `"${s}"`;
};

function splitTop(s, sep = ',') {
  const out = [];
  let depth = 0, quote = false, cur = '';
  for (const ch of s) {
    if (ch === '"') quote = !quote;
    if (!quote && ch === '(') depth++;
    if (!quote && ch === ')') depth--;
    if (!quote && depth === 0 && ch === sep) { out.push(cur); cur = ''; } else cur += ch;
  }
  if (cur.trim()) out.push(cur);
  return out.map((x) => x.trim());
}

let fkCache;
async function foreignKeys() {
  if (fkCache) return fkCache;
  const { rows } = await db.query(`
    select c.conrelid::regclass::text as child, c.confrelid::regclass::text as parent,
           a.attname as child_col, af.attname as parent_col
      from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
      join pg_attribute af on af.attrelid = c.confrelid and af.attnum = c.confkey[1]
     where c.contype = 'f' and array_length(c.conkey, 1) = 1`);
  fkCache = rows.map((r) => ({ ...r, child: r.child.replace(/^public\./, ''), parent: r.parent.replace(/^public\./, '') }));
  return fkCache;
}

/** Build the column list for `select=` (supports `*`, columns and one-level-deep embeds). */
async function selectList(select, table, alias, depth = 0) {
  const fks = await foreignKeys();
  const parts = [];
  for (const item of splitTop(select || '*')) {
    const m = item.match(/^(?:(\w+):)?(\w+)(?:!\w+)?\((.*)\)$/s);
    if (m) {
      const [, as, rel, inner] = m;
      const sub = `e${depth}_${rel}`;
      const many = fks.find((f) => f.child === rel && f.parent === table);
      const one = fks.find((f) => f.child === table && f.parent === rel);
      if (many) {
        parts.push(`coalesce((select json_agg(x) from (select ${await selectList(inner, rel, sub, depth + 1)} from public.${ident(rel)} ${sub}
                     where ${sub}.${ident(many.child_col)} = ${alias}.${ident(many.parent_col)}) x), '[]'::json) as ${ident(as ?? rel)}`);
      } else if (one) {
        parts.push(`(select row_to_json(x) from (select ${await selectList(inner, rel, sub, depth + 1)} from public.${ident(rel)} ${sub}
                     where ${sub}.${ident(one.parent_col)} = ${alias}.${ident(one.child_col)}) x) as ${ident(as ?? rel)}`);
      } else {
        throw Object.assign(new Error(`Could not find a relationship between '${table}' and '${rel}'`), { code: 'PGRST200' });
      }
    } else if (item === '*') {
      parts.push(`${alias}.*`);
    } else {
      const [as, col] = item.includes(':') ? item.split(':') : [null, item];
      parts.push(`${alias}.${ident(col.split('::')[0])}${as ? ` as ${ident(as)}` : ''}`);
    }
  }
  return parts.join(', ');
}

function parseList(v) {
  return splitTop(v.replace(/^\(/, '').replace(/\)$/, '')).map((x) => x.replace(/^"|"$/g, ''));
}

/**
 * Quote a value as an untyped SQL string literal, so Postgres converts it to
 * the column/parameter type (PGlite's bound parameters insist on JS types).
 */
function literal(v) {
  const s = String(v);
  if (s.includes('\0')) throw Object.assign(new Error('Invalid value'), { code: 'PGRST100' });
  return `'${s.replaceAll("'", "''")}'`;
}

/** One PostgREST filter (`col`, `op.value` incl. `not.`) -> SQL. */
function condition(alias, col, expr, _params) {
  let negate = false;
  let [op, ...rest] = expr.split('.');
  if (op === 'not') { negate = true; [op, ...rest] = rest; }
  const val = rest.join('.');
  const c = `${alias}.${ident(col)}`;
  const p = (v) => Array.isArray(v) ? `array[${v.map(literal).join(', ') || "''"}]` : literal(v);
  const sql = (() => {
    switch (op) {
      case 'eq': return `${c} = ${p(val)}`;
      case 'neq': return `${c} <> ${p(val)}`;
      case 'gt': return `${c} > ${p(val)}`;
      case 'gte': return `${c} >= ${p(val)}`;
      case 'lt': return `${c} < ${p(val)}`;
      case 'lte': return `${c} <= ${p(val)}`;
      case 'is': return `${c} is ${{ null: 'null', true: 'true', false: 'false', unknown: 'unknown' }[val.toLowerCase()] ?? 'null'}`;
      case 'in': return `${c}::text = any(${p(parseList(val))}::text[])`;
      case 'like': return `${c}::text like ${p(val.replaceAll('*', '%'))}`;
      case 'ilike': return `${c}::text ilike ${p(val.replaceAll('*', '%'))}`;
      case 'cs': return `${c} @> ${p(val)}`;
      default: throw Object.assign(new Error(`Unsupported operator: ${op}`), { code: 'PGRST100' });
    }
  })();
  return negate ? `not (${sql})` : sql;
}

function logicTree(alias, kind, inner, params) {
  const parts = splitTop(inner.replace(/^\(/, '').replace(/\)$/, '')).map((term) => {
    const nested = term.match(/^(not\.)?(or|and)(\(.*\))$/s);
    if (nested) {
      const s = logicTree(alias, nested[2], nested[3], params);
      return nested[1] ? `not ${s}` : s;
    }
    const dot = term.indexOf('.');
    return condition(alias, term.slice(0, dot), term.slice(dot + 1), params);
  });
  return `(${parts.join(kind === 'or' ? ' or ' : ' and ')})`;
}

const RESERVED = new Set(['select', 'order', 'limit', 'offset', 'on_conflict', 'columns']);
function whereClause(url, alias, params) {
  const conds = [];
  for (const [k, v] of url.searchParams) {
    if (RESERVED.has(k) || k.includes('.')) continue;
    if (k === 'or' || k === 'and') conds.push(logicTree(alias, k, v, params));
    else conds.push(condition(alias, k, v, params));
  }
  return conds.length ? `where ${conds.join(' and ')}` : '';
}

function orderClause(url, alias) {
  const o = url.searchParams.get('order');
  if (!o) return '';
  return 'order by ' + o.split(',').map((term) => {
    const [col, ...mods] = term.split('.');
    const dir = mods.includes('desc') ? 'desc' : 'asc';
    const nulls = mods.includes('nullsfirst') ? 'nulls first' : mods.includes('nullslast') ? 'nulls last' : '';
    return `${alias}.${ident(col)} ${dir} ${nulls}`;
  }).join(', ');
}

function limitClause(url) {
  const l = url.searchParams.get('limit');
  const o = url.searchParams.get('offset');
  return `${l ? `limit ${Number(l)}` : ''} ${o ? `offset ${Number(o)}` : ''}`;
}

async function handleRest(req, res, url) {
  const uid = userIdFrom(req);
  const path = url.pathname.replace('/rest/v1/', '');
  const accept = req.headers.accept ?? '';
  const prefer = req.headers.prefer ?? '';
  const wantObject = accept.includes('application/vnd.pgrst.object+json');
  const wantRows = prefer.includes('return=representation') || req.method === 'GET';

  const reply = (rows) => {
    if (!wantRows && req.method !== 'POST') return send(res, 204);
    if (!wantRows) return send(res, 201);
    if (wantObject) {
      if (rows.length !== 1) {
        return send(res, 406, { code: 'PGRST116', message: 'JSON object requested, multiple (or no) rows returned',
          details: `The result contains ${rows.length} rows`, hint: null });
      }
      return send(res, req.method === 'POST' ? 201 : 200, rows[0]);
    }
    return send(res, req.method === 'POST' ? 201 : 200, rows);
  };

  try {
    if (path.startsWith('rpc/')) {
      const fn = path.slice(4);
      // Calls without parameters may send no body or a JSON `null`.
      const args = (req.method === 'GET' ? Object.fromEntries(url.searchParams) : json(await readBody(req))) ?? {};
      const result = await asUser(uid, async () => {
        const meta = (await db.query(
          `select p.proretset, p.prorettype::regtype::text as rt, coalesce(p.proargnames, '{}') as names,
                  array(select format_type(t, null) from unnest(p.proargtypes) t) as types
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = $1`, [ident(fn).slice(1, -1)])).rows[0];
        if (!meta) throw Object.assign(new Error(`Could not find the function public.${fn}`), { code: '42883' });
        const params = [];
        const named = Object.entries(args).map(([k, v]) => {
          const i = meta.names.indexOf(k);
          if (i < 0) throw Object.assign(new Error(`Function public.${fn} has no parameter ${k}`), { code: '42883' });
          const value = v === null || v === undefined ? 'null' : literal(typeof v === 'object' ? JSON.stringify(v) : v);
          return `${ident(k)} => ${value}::${meta.types[i]}`;
        });
        const call = `public.${ident(fn)}(${named.join(', ')})`;
        if (meta.proretset) return (await db.query(`select coalesce(json_agg(x), '[]'::json) as j from ${call} x`, params)).rows[0].j;
        if (meta.rt === 'void') { await db.query(`select ${call}`, params); return null; }
        return (await db.query(`select to_json(${call}) as j`, params)).rows[0].j;
      });
      queueMicrotask(flushRealtime);
      return result === null ? send(res, 204) : send(res, 200, result);
    }

    const table = ident(path).slice(1, -1);
    const select = url.searchParams.get('select');

    if (req.method === 'GET') {
      const rows = await asUser(uid, async () => {
        const params = [];
        const sql = `select coalesce(json_agg(q), '[]'::json) as j from (
            select ${await selectList(select, table, 't')} from public.${ident(table)} t
            ${whereClause(url, 't', params)} ${orderClause(url, 't')} ${limitClause(url)}) q`;
        return (await db.query(sql, params)).rows[0].j;
      });
      return reply(rows);
    }

    const returning = async (cte, params) => {
      if (!wantRows) { await db.query(cte.replace(/returning t\.\*$/, ''), params); return []; }
      const sql = `with r as (${cte}) select coalesce(json_agg(q), '[]'::json) as j from (
          select ${await selectList(select, table, 't')} from r t ${orderClause(url, 't')}) q`;
      return (await db.query(sql, params)).rows[0].j;
    };

    if (req.method === 'POST') {
      let body = json(await readBody(req));
      if (!Array.isArray(body)) body = [body];
      const keys = [...new Set(body.flatMap(Object.keys))].map(ident);
      const upsert = prefer.includes('resolution=merge-duplicates') || prefer.includes('resolution=ignore-duplicates');
      const rows = await asUser(uid, async () => {
        let conflict = '';
        if (upsert) {
          const target = url.searchParams.get('on_conflict')?.split(',').map(ident).join(', ') ??
            (await db.query(`select string_agg(quote_ident(a.attname), ', ') as pk from pg_index i
               join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
              where i.indrelid = $1::regclass and i.indisprimary`, [`public.${table}`])).rows[0].pk;
          conflict = prefer.includes('ignore-duplicates')
            ? `on conflict (${target}) do nothing`
            : `on conflict (${target}) do update set ${keys.map((k) => `${k} = excluded.${k}`).join(', ')}`;
        }
        const cte = `insert into public.${ident(table)} as t (${keys.join(', ')})
          select ${keys.join(', ')} from json_populate_recordset(null::public.${ident(table)}, $1::json)
          ${conflict} returning t.*`;
        return returning(cte, [JSON.stringify(body)]);
      });
      queueMicrotask(flushRealtime);
      return reply(rows);
    }

    if (req.method === 'PATCH') {
      const body = json(await readBody(req));
      const keys = Object.keys(body).map(ident);
      const rows = await asUser(uid, async () => {
        const params = [JSON.stringify(body)];
        const where = whereClause(url, 't', params);
        const cte = `update public.${ident(table)} t set ${keys.map((k) => `${k} = p.${k}`).join(', ')}
          from json_populate_record(null::public.${ident(table)}, $1::json) p ${where} returning t.*`;
        return returning(cte, params);
      });
      queueMicrotask(flushRealtime);
      return reply(rows);
    }

    if (req.method === 'DELETE') {
      const rows = await asUser(uid, async () => {
        const params = [];
        const cte = `delete from public.${ident(table)} t ${whereClause(url, 't', params)} returning t.*`;
        return returning(cte, params);
      });
      queueMicrotask(flushRealtime);
      return reply(rows);
    }

    return send(res, 405, { message: 'Method not allowed' });
  } catch (e) {
    const [status, body] = pgError(e);
    if (status >= 500 || !e.code) console.error(e);
    return send(res, status, body);
  }
}

// ---------------------------------------------------------------------------
// Storage (/storage/v1)
// ---------------------------------------------------------------------------
function parseMultipart(buf, contentType) {
  const boundary = contentType.match(/boundary=(?:"([^"]+)"|([^;]+))/i);
  if (!boundary) return { data: buf, mime: contentType };
  const delim = Buffer.from(`--${boundary[1] ?? boundary[2]}`);
  let start = buf.indexOf(delim);
  while (start >= 0) {
    const next = buf.indexOf(delim, start + delim.length);
    if (next < 0) break;
    const part = buf.subarray(start + delim.length + 2, next - 2);
    const sep = part.indexOf('\r\n\r\n');
    const headers = part.subarray(0, sep).toString();
    if (/filename=/i.test(headers)) {
      return { data: part.subarray(sep + 4), mime: headers.match(/content-type:\s*([^\r\n]+)/i)?.[1] ?? 'application/octet-stream' };
    }
    start = next;
  }
  return { data: Buffer.alloc(0), mime: 'application/octet-stream' };
}

const MIME = { jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', pdf: 'application/pdf', webp: 'image/webp' };

async function handleStorage(req, res, url) {
  const uid = userIdFrom(req);
  const route = decodeURIComponent(url.pathname.replace('/storage/v1', ''));
  const storageErr = (status, message) => send(res, status, { statusCode: String(status), error: 'error', message });
  try {
    // Public bucket download (e.g. avatars).
    let m = route.match(/^\/object\/public\/([^/]+)\/(.+)$/);
    if (m && req.method === 'GET') {
      const [, bucket, name] = m;
      const f = await asUser('service', async () => (await db.query(
        `select f.* from dev.files f join storage.buckets b on b.id = f.bucket and b.public
          where f.bucket = $1 and f.name = $2`, [bucket, name])).rows[0]);
      if (!f) return storageErr(404, 'Object not found');
      res.writeHead(200, { 'Content-Type': f.mime, 'Cache-Control': 'public, max-age=3600' });
      return res.end(Buffer.from(f.content));
    }
    // Download through a signed URL.
    m = route.match(/^\/object\/sign\/([^/]+)\/(.+)$/);
    if (m && req.method === 'GET') {
      const [, bucket, name] = m;
      const token = url.searchParams.get('token') ?? '';
      const [exp, sig] = token.split('.');
      if (hmac(`${bucket}/${name}:${exp}`) !== sig || Number(exp) < Date.now() / 1000) return storageErr(400, 'Invalid or expired signature');
      const f = await asUser('service', async () => (await db.query(`select * from dev.files where bucket = $1 and name = $2`, [bucket, name])).rows[0]);
      if (!f) return storageErr(404, 'Object not found');
      res.writeHead(200, { 'Content-Type': f.mime, 'Cache-Control': 'private, max-age=600' });
      return res.end(Buffer.from(f.content));
    }
    if (m && req.method === 'POST') {
      const [, bucket, name] = m;
      const { expiresIn = 60 } = json(await readBody(req));
      const visible = await asUser(uid, async () =>
        (await db.query(`select 1 from storage.objects where bucket_id = $1 and name = $2`, [bucket, name])).rows.length > 0);
      if (!visible) return storageErr(404, 'Object not found');
      const exp = Math.floor(Date.now() / 1000) + Number(expiresIn);
      const token = `${exp}.${hmac(`${bucket}/${name}:${exp}`)}`;
      return send(res, 200, { signedURL: `/object/sign/${bucket}/${encodeURI(name)}?token=${token}` });
    }
    // Upload.
    m = route.match(/^\/object\/([^/]+)\/(.+)$/);
    if (m && (req.method === 'POST' || req.method === 'PUT')) {
      const [, bucket, name] = m;
      const { data, mime } = parseMultipart(await readBody(req), req.headers['content-type'] ?? '');
      const type = mime === 'application/octet-stream' ? MIME[name.split('.').pop().toLowerCase()] ?? mime : mime;
      await asUser(uid, () => db.query(`insert into storage.objects (bucket_id, name) values ($1, $2)`, [bucket, name]));
      await asUser('service', () => db.query(
        `insert into dev.files values ($1, $2, $3, $4) on conflict (bucket, name) do update set content = excluded.content, mime = excluded.mime`,
        [bucket, name, type, data]));
      return send(res, 200, { Key: `${bucket}/${name}`, Id: crypto.randomUUID() });
    }
    return storageErr(404, `Not supported by the local dev server: ${req.method} ${route}`);
  } catch (e) {
    const [status, body] = pgError(e);
    return send(res, status, { statusCode: String(status), error: body.code, message: body.message });
  }
}

// ---------------------------------------------------------------------------
// Edge Functions (/functions/v1). Mirrors supabase/functions/analyze-meal.
// ---------------------------------------------------------------------------
// Which model reads meal photos: your own endpoint if MEAL_ANALYZER_URL is set,
// else Claude if an Anthropic key is set, else none (the app says so clearly).
const customAnalyzer = process.env.MEAL_ANALYZER_URL || null;
const hasAnthropicCredentials = !!(process.env.ANTHROPIC_API_KEY || process.env.ANTHROPIC_AUTH_TOKEN);
const anthropic = !customAnalyzer && hasAnthropicCredentials ? new Anthropic() : null;

async function handleFunctions(req, res, url) {
  const uid = userIdFrom(req);
  if (req.method !== 'POST') return send(res, 405, { error: 'Method not allowed' });
  if (!uid) return send(res, 401, { error: 'Not signed in' });
  if (url.pathname === '/functions/v1/estimate-meal') {
    // Written description -> foods from the foods table (rule-based, no AI).
    const { text, language } = json(await readBody(req)) ?? {};
    if (typeof text !== 'string' || !text.trim()) return send(res, 400, { error: 'Describe what you ate.' });
    const foods = await asUser(uid, async () =>
      (await db.query(`select private.food_json(id) as f from public.foods where barcode is null`)).rows.map((r) => r.f));
    return send(res, 200, estimateFromText(text.slice(0, 2000), language, foods));
  }
  if (url.pathname === '/functions/v1/lookup-barcode') {
    const { barcode } = json(await readBody(req)) ?? {};
    try {
      return send(res, 200, await lookupBarcode(barcode, {
        userAgent: process.env.OFF_USER_AGENT,
        findCached: (code) => asUser(uid, async () =>
          (await db.query(`select private.food_json(id) as f from public.foods where barcode = $1`, [code])).rows[0]?.f ?? null),
        saveFood: async ({ food, portions }) => {
          const id = await asUser('service', async () => {
            const cols = Object.keys(food);
            const { rows } = await db.query(
              `insert into public.foods (${cols.join(', ')})
               select ${cols.join(', ')} from json_populate_record(null::public.foods, $1::json)
               on conflict (barcode) do update set barcode = excluded.barcode returning id`, [JSON.stringify(food)]);
            for (const [i, p] of portions.entries()) {
              await db.query(`insert into public.portion_units (food_id, unit, grams_per_unit, source, source_note, sort)
                              values ($1, $2, $3, 'open_food_facts', $4, $5) on conflict do nothing`,
                [rows[0].id, p.unit, String(p.grams), p.note, String(i)]);
            }
            return rows[0].id;
          });
          return asUser(uid, async () => (await db.query(`select private.food_json($1) as f`, [id])).rows[0].f);
        },
      }));
    } catch (e) {
      if (e instanceof BarcodeError) return send(res, e.status, { error: e.message });
      throw e;
    }
  }
  if (url.pathname !== '/functions/v1/analyze-meal') return send(res, 404, { error: 'Function not found' });
  // AI photo analysis is switched off for now (no paid AI calls); see app/lib/core/features.dart.
  if (process.env.AI_FEATURES !== 'on') {
    return send(res, 503, { error: 'Photo analysis is not available yet.', code: 'ai_disabled' });
  }
  const { photo_path, meal, language } = json(await readBody(req)) ?? {};
  if (typeof photo_path !== 'string' || !photo_path.startsWith(`${uid}/`)) {
    return send(res, 400, { error: 'photo_path must be one of your own meal photos' });
  }
  // Same access rule as production: the caller must be able to read the object.
  const visible = await asUser(uid, async () =>
    (await db.query(`select 1 from storage.objects where bucket_id = 'meal-photos' and name = $1`, [photo_path])).rows.length > 0);
  const file = visible && await asUser('service', async () =>
    (await db.query(`select mime, content from dev.files where bucket = 'meal-photos' and name = $1`, [photo_path])).rows[0]);
  if (!file) return send(res, 404, { error: 'Photo not found' });

  if (!anthropic && !customAnalyzer) return send(res, 503, { error: NOT_CONFIGURED, code: 'ai_not_configured' });
  try {
    const mediaType = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'].includes(file.mime) ? file.mime : 'image/jpeg';
    const input = { imageBase64: Buffer.from(file.content).toString('base64'), mediaType, mealSlot: meal, language };
    return send(res, 200, customAnalyzer
      ? await analyzeWithEndpoint(customAnalyzer, process.env.MEAL_ANALYZER_TOKEN, input)
      : await analyzeMeal(anthropic, input));
  } catch (e) {
    if (e instanceof MealAnalysisError) return send(res, e.status, { error: e.message });
    if (e instanceof Anthropic.AuthenticationError) {
      return send(res, 502, { error: 'The Anthropic API key in devserver/.env is invalid or has been revoked.' });
    }
    if (e instanceof Anthropic.RateLimitError) return send(res, 429, { error: 'Too many requests, try again shortly' });
    console.error(e);
    // Local server only: show the API's own message (e.g. "credit balance is too low").
    return send(res, 502, { error: `Analysis failed: ${e instanceof Anthropic.APIError ? e.message : 'unexpected error'}` });
  }
}

// ---------------------------------------------------------------------------
// Realtime (/realtime/v1/websocket), Phoenix protocol vsn 2.0.0
// ---------------------------------------------------------------------------
const sockets = new Set();
let nextBindingId = 1;

function onSocket(ws) {
  const state = { ws, channels: new Map() };
  sockets.add(state);
  const push = (msg) => ws.readyState === 1 && ws.send(JSON.stringify(msg));
  ws.on('close', () => sockets.delete(state));
  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }
    const [joinRef, ref, topic, event, payload] = Array.isArray(msg) ? msg : [msg.join_ref, msg.ref, msg.topic, msg.event, msg.payload];
    const ok = (response = {}) => push([joinRef, ref, topic, 'phx_reply', { status: 'ok', response }]);
    if (topic === 'phoenix' && event === 'heartbeat') return ok();
    if (event === 'phx_join') {
      const bindings = (payload?.config?.postgres_changes ?? []).map((b) => ({ ...b, id: nextBindingId++ }));
      state.channels.set(topic, { joinRef, uid: verifyJwt(payload?.access_token)?.sub ?? null, bindings });
      ok({ postgres_changes: bindings });
      return push([joinRef, null, topic, 'system', { extension: 'postgres_changes', status: 'ok', message: 'Subscribed to PostgreSQL', channel: topic }]);
    }
    if (event === 'access_token') {
      const ch = state.channels.get(topic);
      if (ch) ch.uid = verifyJwt(payload?.access_token)?.sub ?? ch.uid;
      return;
    }
    if (event === 'phx_leave') {
      state.channels.delete(topic);
      return ok();
    }
    ok();
  });
}

function filterMatches(filter, rec) {
  if (!filter) return true;
  const m = filter.match(/^(\w+)=(eq|neq)\.(.*)$/);
  if (!m || !rec) return true;
  const v = rec[m[1]] === null || rec[m[1]] === undefined ? null : String(rec[m[1]]);
  return m[2] === 'eq' ? v === m[3] : v !== m[3];
}

/** Deliver queued row changes to subscribers who are allowed to see them (RLS). */
async function flushRealtime() {
  const changes = await asUser('service', async () => (await db.query(`delete from dev.changes returning * `)).rows);
  changes.sort((a, b) => Number(a.id) - Number(b.id));
  for (const c of changes) {
    const record = c.rec ?? c.old;
    for (const s of sockets) {
      for (const [topic, ch] of s.channels) {
        const ids = ch.bindings
          .filter((b) => (b.schema ?? 'public') === 'public' && b.table === c.tbl &&
            (b.event === '*' || b.event?.toUpperCase() === c.op) && filterMatches(b.filter, record))
          .map((b) => b.id);
        if (!ids.length || !ch.uid) continue;
        if (c.op !== 'DELETE') {
          const visible = await asUser(ch.uid, async () =>
            (await db.query(`select 1 from public.${ident(c.tbl)} where id::text = $1`, [String(record.id)])).rows.length > 0).catch(() => false);
          if (!visible) continue;
        }
        if (s.ws.readyState !== 1) continue;
        s.ws.send(JSON.stringify([ch.joinRef, null, topic, 'postgres_changes', {
          ids,
          data: {
            schema: 'public', table: c.tbl, commit_timestamp: new Date().toISOString(), type: c.op,
            record: c.rec ?? {}, old_record: c.old ?? {}, columns: [], errors: null,
          },
        }]));
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Dev mailbox: emails the local server "sends" (password reset codes).
// ---------------------------------------------------------------------------
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
async function mailbox(res) {
  const mails = await asUser('service', async () =>
    (await db.query(`select * from dev.mail order by id desc limit 50`)).rows);
  const items = mails.map((m) => `
    <article>
      <header><b>${esc(m.subject)}</b><span>${esc(m.recipient)} · ${new Date(m.created_at).toLocaleString('tr-TR')}</span></header>
      <p>${esc(m.body).replace(/\b(\d{6})\b/, '<code>$1</code>')}</p>
    </article>`).join('') || '<p class="empty">No emails yet. Use "Forgot password?" in the app.</p>';
  send(res, 200, `<!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="refresh" content="5">
    <title>Nouri dev mailbox</title><style>
      :root { color-scheme: light dark; --bg: #f6f7f6; --card: #fff; --muted: #5f6b66; --accent: #2e7d5b; }
      @media (prefers-color-scheme: dark) { :root { --bg: #111513; --card: #1b201e; --muted: #9aa7a1; --accent: #7fd1a8; } }
      body { font: 15px/1.5 system-ui, sans-serif; background: var(--bg); margin: 0; padding: 24px 16px; }
      main { max-width: 640px; margin: 0 auto; } h1 { font-size: 20px; margin: 0 0 4px; }
      .sub { color: var(--muted); margin: 0 0 20px; }
      article { background: var(--card); border-radius: 12px; padding: 14px 16px; margin-bottom: 12px; }
      header { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 8px; }
      header span, .empty { color: var(--muted); }
      code { font-size: 22px; letter-spacing: 4px; color: var(--accent); font-weight: 700; }
    </style></head><body><main>
      <h1>Nouri dev mailbox</h1>
      <p class="sub">Emails the local server would have sent. Refreshes every 5 seconds. In production, Supabase sends real emails.</p>
      ${items}
    </main></body></html>`, 'text/html; charset=utf-8');
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  cors(req, res);
  if (req.method === 'OPTIONS') return send(res, 204);
  const url = new URL(req.url, `http://localhost:${PORT}`);
  try {
    if (url.pathname.startsWith('/auth/v1')) return await handleAuth(req, res, url);
    if (url.pathname.startsWith('/rest/v1')) return await handleRest(req, res, url);
    if (url.pathname.startsWith('/storage/v1')) return await handleStorage(req, res, url);
    if (url.pathname.startsWith('/functions/v1')) return await handleFunctions(req, res, url);
    if (url.pathname === '/mail') return await mailbox(res);
    if (url.pathname === '/') return send(res, 200, { ok: true, service: 'nouri local dev server' });
    return send(res, 404, { message: 'Not found' });
  } catch (e) {
    console.error(e);
    send(res, 500, { message: e.message });
  }
});
new WebSocketServer({ server, path: '/realtime/v1/websocket' }).on('connection', onSocket);

if (fresh) {
  console.log('Seeding demo data…');
  await seed({ db, asUser, hashPassword });
  await restoreAccounts();
  await asUser('service', () => db.query(`delete from dev.changes`));
}

/** Bring back accounts saved by reset-demo.mjs (same id, email, password, role). */
async function restoreAccounts() {
  const file = here('./.accounts-backup.json');
  if (!existsSync(file)) return;
  const accounts = JSON.parse(readFileSync(file, 'utf8'));
  for (const a of accounts) {
    await asUser('service', async () => {
      // The signup trigger recreates the profile (with role), reminders and dietitian page.
      await db.query(
        `insert into auth.users (id, email, raw_user_meta_data, encrypted_password, created_at)
         values ($1, $2, $3, $4, $5) on conflict do nothing`,
        [a.id, a.email, JSON.stringify({ ...a.raw_user_meta_data, role: a.role }), a.encrypted_password, a.created_at]);
      await db.query(
        `update public.profiles set full_name = $2, birth_date = $3, height_cm = $4, sex = $5, timezone = $6 where id = $1`,
        [a.id, a.full_name, a.birth_date, a.height_cm, a.sex, a.timezone ?? 'UTC']);
    });
  }
  rmSync(file);
  console.log(`Restored ${accounts.length} account(s): ${accounts.map((a) => a.email).join(', ')}`);
}

server.listen(PORT, () => {
  console.log(`Nouri local dev server ready on http://localhost:${PORT}`);
  console.log('Food search, meal descriptions and barcodes: Nouri food database (USDA FoodData Central + Open Food Facts)');
  console.log(process.env.AI_FEATURES === 'on'
    ? `AI photo analysis: ON (${customAnalyzer ? `your model at ${customAnalyzer}` : hasAnthropicCredentials ? 'Claude' : 'no model configured'})`
    : 'AI features: off (no paid AI calls). Set AI_FEATURES=on in devserver/.env to try them.');
});
