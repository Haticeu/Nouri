// Demo data for the local dev server. Every action runs as the user who
// would do it in the app, so triggers (audit log, notifications) and RLS
// behave exactly as they would for real.
//
// All demo accounts use the password: demo1234

import zlib from 'node:zlib';

export const DEMO_PASSWORD = 'demo1234';
const uuid = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;

export const users = {
  admin:  { id: uuid(1),  email: 'admin@nouri.demo',  name: 'Nouri Admin',   role: 'client' },
  selin:  { id: uuid(2),  email: 'selin@nouri.demo',  name: 'Dr. Selin Kaya', role: 'dietitian' },
  can:    { id: uuid(3),  email: 'can@nouri.demo',    name: 'Can Öztürk',    role: 'dietitian' },
  ayse:   { id: uuid(4),  email: 'ayse@nouri.demo',   name: 'Ayşe Yıldız',   role: 'dietitian' },
  elif:   { id: uuid(11), email: 'elif@nouri.demo',   name: 'Elif Demir',    role: 'client' },
  mert:   { id: uuid(12), email: 'mert@nouri.demo',   name: 'Mert Yılmaz',   role: 'client' },
  zeynep: { id: uuid(13), email: 'zeynep@nouri.demo', name: 'Zeynep Arslan', role: 'client' },
  burak:  { id: uuid(14), email: 'burak@nouri.demo',  name: 'Burak Şahin',   role: 'client' },
  deniz:  { id: uuid(15), email: 'deniz@nouri.demo',  name: 'Deniz Aydın',   role: 'client' },
};

const MEALS = {
  breakfast: [['Menemen with whole-grain bread', 420, 22, 38, 20], ['Oatmeal with banana and walnuts', 380, 12, 58, 12],
              ['Greek yogurt, honey and berries', 290, 18, 36, 8], ['Boiled eggs, cheese, olives, cucumber', 410, 24, 10, 30]],
  lunch:     [['Lentil soup with bread', 450, 20, 68, 10], ['Grilled chicken with bulgur pilaf', 610, 45, 62, 18],
              ['Chickpea and tuna salad', 520, 34, 40, 22], ['Stuffed peppers with yogurt', 480, 16, 58, 20]],
  dinner:    [['Salmon with roasted vegetables', 590, 40, 22, 36], ['Turkey meatballs with salad', 560, 42, 24, 30],
              ['Green beans in olive oil with rice', 520, 12, 72, 18], ['Chicken stir-fry with vegetables', 540, 44, 36, 22]],
  snack:     [['Apple and almonds', 210, 5, 24, 11], ['Ayran', 110, 6, 8, 6], ['Dried apricots', 150, 2, 36, 0]],
};

export async function seed({ db, asUser, hashPassword }) {
  const as = (who, sql, params = []) => asUser(users[who].id, async () => (await db.query(sql, params)).rows);
  const service = (sql, params = []) => asUser('service', async () => (await db.query(sql, params)).rows);

  // --- Accounts -------------------------------------------------------------
  for (const u of Object.values(users)) {
    await service(
      `insert into auth.users (id, email, raw_user_meta_data, encrypted_password) values ($1, $2, $3, $4)`,
      [u.id, u.email, JSON.stringify({ role: u.role, full_name: u.name }), hashPassword(DEMO_PASSWORD)],
    );
    await as(Object.keys(users).find((k) => users[k] === u), `update profiles set timezone = 'Europe/Istanbul' where id = auth.uid()`);
  }
  await service(`insert into admins (user_id) values ($1)`, [users.admin.id]);

  await as('selin', `update dietitian_profiles set title = $1, specialties = $2, bio = $3 where user_id = auth.uid()`, [
    'RD, MSc Clinical Nutrition',
    ['Weight management', 'Sports nutrition', 'PCOS'],
    'Registered dietitian with 9 years of experience. I focus on sustainable, Mediterranean-style eating that fits your life.',
  ]);
  await as('can', `update dietitian_profiles set title = $1, specialties = $2, bio = $3 where user_id = auth.uid()`, [
    'Dietitian, BSc Nutrition', ['Diabetes', 'Gut health'], 'Newly registered dietitian based in Izmir.',
  ]);
  await as('ayse', `update dietitian_profiles set title = $1, specialties = $2, bio = $3 where user_id = auth.uid()`, [
    'Dietitian, MSc Paediatric Nutrition', ['Child nutrition', 'Pregnancy', 'Vegetarian diets'],
    'Family-focused dietitian in Ankara. Practical plans for busy parents, pregnancy and plant-based eating.',
  ]);
  // Directory details (Selin also sees clients at her clinic).
  await as('selin', `update dietitian_profiles set city = 'İstanbul', years_experience = 9, works_in_person = true where user_id = auth.uid()`);
  await as('can', `update dietitian_profiles set city = 'İzmir', years_experience = 1 where user_id = auth.uid()`);
  await as('ayse', `update dietitian_profiles set city = 'Ankara', years_experience = 6 where user_id = auth.uid()`);

  // --- Verification: Selin and Ayşe approved, Can waiting for review ------------
  for (const who of ['selin', 'can', 'ayse']) {
    const path = `${users[who].id}/diploma.png`;
    await as(who, `insert into storage.objects (bucket_id, name) values ('credentials', $1)`, [path]);
    await service(`insert into dev.files values ('credentials', $1, 'image/png', $2)`, [path, certificatePng(who === 'selin' ? [46, 125, 91] : [61, 90, 160])]);
    await as(who, `select submit_verification($1)`, [path]);
  }
  const [{ id: selinSub }] = await service(`select id from verification_submissions where dietitian_id = $1`, [users.selin.id]);
  await as('admin', `select admin_review_verification($1, true)`, [selinSub]);
  const [{ id: ayseSub }] = await service(`select id from verification_submissions where dietitian_id = $1`, [users.ayse.id]);
  await as('admin', `select admin_review_verification($1, true)`, [ayseSub]);

  // --- Clients join Selin ------------------------------------------------------
  const [{ v: consent }] = await service(`select private.consent_version() as v`);
  for (const [who, code] of [['elif', 'ELIF2026'], ['mert', 'MERT2026'], ['zeynep', 'ZEYN2026'], ['burak', 'BURK2026']]) {
    await as('selin', `insert into invites (dietitian_id, code) values ($1, $2)`, [users.selin.id, code]);
    await as(who, `select accept_invite($1, $2)`, [code, consent]);
  }
  // Open code for trying the join flow as Deniz.
  await as('selin', `insert into invites (dietitian_id, code, expires_at) values ($1, 'DEMO2026', now() + interval '365 days')`, [users.selin.id]);

  // --- Client logs ------------------------------------------------------------------
  const hours = { breakfast: 8, lunch: 13, dinner: 19, snack: 16 };
  async function logDay(who, daysAgo, slots, pick, extra = {}) {
    for (const slot of slots) {
      const options = MEALS[slot];
      const [name, kcal, p, c, f] = options[(daysAgo + pick) % options.length];
      await as(who, `insert into food_entries (client_id, logged_on, logged_at, meal, name, calories, protein_g, carbs_g, fat_g, satiety_rating, energy_rating)
                     values ($1, (now() at time zone 'Europe/Istanbul')::date - $2::int, (((now() at time zone 'Europe/Istanbul')::date - $2::int) + make_interval(hours => $3)) at time zone 'Europe/Istanbul', $4, $5, $6, $7, $8, $9, $10, $11)`,
        [users[who].id, daysAgo, hours[slot], slot, name, kcal * (extra.scale ?? 1), p, c, f, 3 + ((daysAgo + pick) % 3), 2 + ((daysAgo * 7 + pick) % 4)]);
    }
  }
  // Elif: consistent logger (9-day streak, today breakfast + lunch so far).
  await logDay('elif', 0, ['breakfast', 'lunch'], 0);
  for (let d = 1; d <= 8; d++) await logDay('elif', d, ['breakfast', 'lunch', 'snack', 'dinner'], 1);
  for (const d of [10, 11, 13, 14, 16]) await logDay('elif', d, ['breakfast', 'lunch', 'dinner'], 2);
  // Mert: stopped logging 3 days ago.
  for (let d = 3; d <= 12; d++) await logDay('mert', d, ['breakfast', 'lunch', 'dinner'], 3, { scale: 1.25 });
  // Zeynep: logs daily, already over her (low) target today.
  for (let d = 0; d <= 4; d++) await logDay('zeynep', d, ['breakfast', 'lunch', 'snack', 'dinner'], 0, { scale: d === 0 ? 1.1 : 0.9 });
  // Burak (will leave) and Deniz (no dietitian).
  for (let d = 2; d <= 6; d++) await logDay('burak', d, ['breakfast', 'lunch', 'dinner'], 1);
  await logDay('deniz', 0, ['breakfast'], 2);

  const weights = {
    elif: [[42, 79.0], [35, 78.2], [28, 77.6], [21, 76.9], [14, 76.1], [7, 75.6], [1, 75.2]],
    mert: [[28, 92.3], [21, 92.1], [14, 92.4], [7, 92.2]],
    zeynep: [[21, 63.5], [14, 63.8], [7, 63.9], [0, 64.2]],
    burak: [[14, 85.0], [7, 84.1]],
  };
  for (const [who, list] of Object.entries(weights)) {
    for (const [d, kg] of list) {
      await as(who, `insert into weight_entries (client_id, measured_on, weight_kg) values ($1, (now() at time zone 'Europe/Istanbul')::date - $2::int, $3)`, [users[who].id, d, kg]);
    }
  }
  await as('elif', `insert into body_measurements (client_id, measured_on, waist_cm, hip_cm, body_fat_pct) values
                    ($1, (now() at time zone 'Europe/Istanbul')::date - 30, 84, 104, 31.5), ($1, (now() at time zone 'Europe/Istanbul')::date - 2, 80.5, 101, 29.8)`, [users.elif.id]);
  for (let d = 0; d <= 6; d++) {
    for (let i = 0; i < (d === 2 ? 2 : 6); i++) {
      await as('elif', `insert into water_entries (client_id, logged_on, amount_ml) values ($1, (now() at time zone 'Europe/Istanbul')::date - $2::int, 300)`, [users.elif.id, d]);
    }
  }
  await as('deniz', `insert into nutrition_targets (client_id, calories, protein_g, carbs_g, fat_g) values ($1, 2000, 90, 250, 70)`, [users.deniz.id]);

  // --- Selin's work ---------------------------------------------------------------------
  await as('selin', `insert into nutrition_targets (client_id, calories, protein_g, carbs_g, fat_g, water_ml) values ($1, 1700, 100, 180, 57, 2000)`, [users.elif.id]);
  await as('selin', `update nutrition_targets set protein_g = 110 where client_id = $1`, [users.elif.id]);
  await as('selin', `insert into nutrition_targets (client_id, calories, protein_g, carbs_g, fat_g, water_ml) values ($1, 2200, 140, 240, 70, 2500)`, [users.mert.id]);
  await as('selin', `insert into nutrition_targets (client_id, calories, protein_g, carbs_g, fat_g, water_ml) values ($1, 1150, 90, 110, 40, 2000)`, [users.zeynep.id]);

  const [{ id: med }] = await as('selin', `insert into meal_plans (dietitian_id, name, description, period)
      values ($1, 'Balanced Mediterranean week', 'Around 1700 kcal/day. Swap meals within the same slot freely.', 'weekly') returning id`, [users.selin.id]);
  for (let day = 0; day < 7; day++) {
    for (const [i, slot] of ['breakfast', 'lunch', 'snack', 'dinner'].entries()) {
      const [title, kcal] = MEALS[slot][(day + i) % MEALS[slot].length];
      await as('selin', `insert into meal_plan_items (plan_id, day_index, meal, title, calories, sort_order) values ($1, $2, $3, $4, $5, $6)`,
        [med, day, slot, title, kcal, i]);
    }
  }
  const [{ id: hp }] = await as('selin', `insert into meal_plans (dietitian_id, name, description, period)
      values ($1, 'High-protein training day', 'For strength-training days.', 'daily') returning id`, [users.selin.id]);
  for (const [slot, title, details, kcal] of [
    ['breakfast', 'Egg-white omelette with spinach', '4 egg whites + 1 egg, 1 slice whole-grain bread', 380],
    ['lunch', 'Grilled chicken with bulgur pilaf', '150 g chicken, 1 cup bulgur', 610],
    ['snack', 'Greek yogurt with oats', '200 g yogurt, 30 g oats', 300],
    ['dinner', 'Salmon with sweet potato', '150 g salmon, 1 medium sweet potato', 620],
  ]) {
    await as('selin', `insert into meal_plan_items (plan_id, day_index, meal, title, details, calories) values ($1, 0, $2, $3, $4, $5)`, [hp, slot, title, details, kcal]);
  }
  await as('selin', `select assign_meal_plan($1, $2)`, [med, users.elif.id]);
  await as('selin', `select assign_meal_plan($1, $2)`, [hp, users.burak.id]);

  await as('selin', `insert into recommendations (dietitian_id, client_id, title, body) values
      ($1, $2, 'More fibre', 'Aim for 25–30 g of fibre a day: add lentils or chickpeas to lunch three times a week.'),
      ($1, $2, 'Evening routine', 'Leave 3–4 hours between dinner and bedtime, and keep a glass of water by your bed.')`, [users.selin.id, users.elif.id]);
  await as('selin', `insert into private_notes (dietitian_id, client_id, body) values
      ($1, $2, 'Mentioned stress eating in the evenings. Revisit at the next session.'),
      ($1, $3, 'Lactose intolerant. Prefers early dinners. Goal: lose 5 kg before summer.')`, [users.selin.id, users.elif.id, users.burak.id]);

  const [{ id: dinner }] = await service(`select id from food_entries where client_id = $1 and meal = 'dinner' and logged_on = (now() at time zone 'Europe/Istanbul')::date - 1`, [users.elif.id]);
  await as('selin', `insert into comments (dietitian_id, client_id, food_entry_id, body) values ($1, $2, $3, 'Great portion size, and a nice balance of protein and vegetables!')`,
    [users.selin.id, users.elif.id, dinner]);
  await as('selin', `insert into comments (dietitian_id, client_id, log_date, body) values ($1, $2, (now() at time zone 'Europe/Istanbul')::date - 2, 'Water was low this day. Try a glass with every meal.')`,
    [users.selin.id, users.elif.id]);

  await as('selin', `insert into appointments (dietitian_id, client_id, starts_at, duration_min, location, agenda) values
      ($1, $2, date_trunc('day', now()) + interval '3 days 7 hours', 45, 'Video call', 'Monthly check-in, review of the Mediterranean plan'),
      ($1, $3, date_trunc('day', now()) + interval '5 days 11 hours', 30, 'Clinic, Kadıköy', 'Restart plan')`,
    [users.selin.id, users.elif.id, users.mert.id]);

  const say = (who, client, body, minutesAgo) => as(who,
    `insert into messages (dietitian_id, client_id, sender_id, body, created_at) values ($1, $2, auth.uid(), $3, now() - make_interval(mins => $4))`,
    [users.selin.id, users[client].id, body, minutesAgo]);
  await say('selin', 'elif', 'Hi Elif! How are you finding the new plan?', 2900);
  await say('elif', 'elif', 'Loving it so far, the lentil soup lunches are great.', 2850);
  await say('selin', 'elif', 'Glad to hear! Keep logging your water too.', 2800);
  await as('elif', `update messages set read_at = now() where client_id = auth.uid() and sender_id <> auth.uid()`);
  await as('selin', `update messages set read_at = now() where client_id = $1 and sender_id <> auth.uid()`, [users.elif.id]);
  await say('elif', 'elif', 'Quick question: can I swap the salmon for chicken on Thursday?', 35);
  await say('selin', 'mert', 'Hi Mert, I haven\'t seen any logs for a few days. Is everything OK?', 600);

  await as('zeynep', `insert into target_change_requests (client_id, dietitian_id, message, requested_calories) values
      ($1, $2, '1150 kcal feels too low. I''m hungry by mid-afternoon and I train three times a week.', 1500)`, [users.zeynep.id, users.selin.id]);

  // General posts to all of Selin's clients (Burak still linked here, so he'll have the first two).
  const post = (category, title, body) => as('selin',
    `insert into broadcasts (dietitian_id, category, title, body) values ($1, $2, $3, $4)`, [users.selin.id, category, title, body]);
  await post('tip', 'Autumn hydration', 'Cooler days make it easy to forget water. Keep a bottle on your desk and have a glass with every meal. Herbal teas count too!');
  await post('recipe', 'Lentil köfte (mercimek köftesi)', 'Cook 1 cup red lentils with 1 cup fine bulgur, then knead with sautéed onion, tomato paste, cumin, chilli and plenty of parsley. About 90 kcal per piece; serve with lettuce leaves and lemon.');
  await post('announcement', 'Clinic closed on 29 October', 'The clinic will be closed for Republic Day. Messages will be answered on 30 October. Happy holiday!');

  await as('elif', `update profiles set birth_date = '1994-03-12', height_cm = 165, sex = 'female' where id = auth.uid()`);
  await as('mert', `update profiles set birth_date = '1988-11-02', height_cm = 181, sex = 'male' where id = auth.uid()`);
  await as('zeynep', `update profiles set birth_date = '1999-07-21', height_cm = 168, sex = 'female' where id = auth.uid()`);
  await as('elif', `update reminder_settings set breakfast = '08:00', dinner = '20:00' where user_id = auth.uid()`);

  // Burak leaves: Selin keeps her private note and the plan she wrote, nothing else.
  await as('burak', `select leave_dietitian()`);

  // --- Ratings (allowed after 14 days together; demo links are backdated) ---------
  await service(`update client_links set started_at = now() - interval '60 days' where client_id in ($1, $2)`, [users.elif.id, users.burak.id]);
  await as('elif', `select rate_dietitian($1, 5, 'Very supportive, and the plans are easy to follow.')`, [users.selin.id]);
  await as('burak', `select rate_dietitian($1, 4, 'Good advice. Replies sometimes took a day.')`, [users.selin.id]);
}

// --- A small PNG "certificate" for the admin review screen -----------------------------
function certificatePng([r, g, b]) {
  const w = 600, h = 420;
  const px = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) {
    px[y * (w * 3 + 1)] = 0;
    for (let x = 0; x < w; x++) {
      const border = x < 14 || y < 14 || x >= w - 14 || y >= h - 14;
      const inner = (x >= 24 && x < 28) || (y >= 24 && y < 28) || (x >= w - 28 && x < w - 24) || (y >= h - 28 && y < h - 24);
      const title = y >= 70 && y < 92 && x >= 150 && x < 450;
      const lines = [140, 170, 200, 230].some((ly) => y >= ly && y < ly + 8) && x >= 90 && x < 510;
      const sign = y >= 330 && y < 334 && ((x >= 80 && x < 240) || (x >= 360 && x < 520));
      const dx = x - 300, dy = y - 320;
      const seal = dx * dx + dy * dy < 38 * 38;
      let c = [250, 246, 235];
      if (lines || sign) c = [150, 150, 150];
      if (border || inner || title || seal) c = [r, g, b];
      const o = y * (w * 3 + 1) + 1 + x * 3;
      px[o] = c[0]; px[o + 1] = c[1]; px[o + 2] = c[2];
    }
  }
  const crcTable = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc = (buf) => {
    let c = 0xffffffff;
    for (const byte of buf) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type), data]);
    const c = Buffer.alloc(4); c.writeUInt32BE(crc(td));
    return Buffer.concat([len, td, c]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(px)), chunk('IEND', Buffer.alloc(0)),
  ]);
}
