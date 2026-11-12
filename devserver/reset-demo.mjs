// Reset the local database to fresh demo data WITHOUT losing accounts people
// created themselves: their login (email, password, role, name and profile
// details) is saved to .accounts-backup.json and restored on the next start.
// Their logged data (meals, messages, ...) is not kept.
//
//   npm run reset-demo        (stop `npm run dev` first)

import { PGlite } from '@electric-sql/pglite';
import { existsSync, rmSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { fileURLToPath } from 'node:url';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
const dataDir = here('./.pgdata');
const backupFile = here('./.accounts-backup.json');

const inUse = await new Promise((resolve) => {
  const s = net.connect(54321, '127.0.0.1');
  s.on('connect', () => { s.end(); resolve(true); });
  s.on('error', () => resolve(false));
});
if (inUse) {
  console.error('The local server is running. Stop `npm run dev` (Ctrl+C) and run this again.');
  process.exit(1);
}

if (existsSync(dataDir)) {
  const db = new PGlite(dataDir);
  const { rows } = await db.query(`
    select u.id, u.email, u.raw_user_meta_data, u.encrypted_password, u.created_at,
           p.role, p.full_name, p.birth_date, p.height_cm, p.sex, p.timezone
      from auth.users u join public.profiles p on p.id = u.id
     where u.email not like '%@nouri.demo'`);
  await db.close();
  if (rows.length) {
    writeFileSync(backupFile, JSON.stringify(rows, null, 2));
    console.log(`Saved ${rows.length} account(s): ${rows.map((r) => r.email).join(', ')}`);
  }
  rmSync(dataDir, { recursive: true, force: true });
}
console.log('Demo data will be recreated on the next `npm run dev`.');
