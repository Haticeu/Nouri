# Nouri

Nutrition tracking with a two-sided Dietitian & Client mode.
One Flutter app (`app/`) for iOS, Android and the web; dietitians use the web build as their desktop dashboard.
The backend is Supabase (`supabase/`). All access rules are enforced with Row Level Security.

## Try it locally (no Supabase account needed)

`devserver/` is a local stand-in for Supabase. It runs the real migrations, including all
RLS rules, in PGlite and comes with demo data. New migrations are applied on start, keeping your data.

```sh
npm run dev          # from the Nouri folder: app on http://localhost:8080, backend on :54321
npm run build:web    # rebuild the web app after changing Flutter code
npm run reset-demo   # recreate the demo data on next start (stop `npm run dev` first)
```

- Accounts you create yourself survive `reset-demo`: email, password, role and profile details
  are restored. Their logged data (meals, messages, ...) is reset.
- "Forgot password?" emails a 6-digit code. Locally no real email is sent; open
  http://localhost:54321/mail to see it.
- In production, edit the Supabase **Reset password** email template so it includes `{{ .Token }}`
  (the app asks for the code, not a link).

Run these from the `Nouri` folder itself. The parent `AI Projects` folder contains a separate,
unrelated Vite template ("My App" on port 5173).

For hot reload while developing the app, run instead:
`cd app && flutter run -d chrome --dart-define=SUPABASE_URL=http://localhost:54321 --dart-define=SUPABASE_KEY=local-dev-key`
(with `cd devserver && npm start` running).

Demo accounts (password `demo1234`): `selin@nouri.demo` (verified dietitian), `can@nouri.demo`
(dietitian awaiting verification), `elif@`, `mert@`, `zeynep@nouri.demo` (Selin's clients),
`deniz@nouri.demo` (no dietitian; join with code `DEMO2026`), `admin@nouri.demo` (admin).
Delete `devserver/.pgdata` to reset the data.

## Food database

Every calorie and macro number comes from the `foods` table (per 100 g), with household
measures in `portion_units` (adet, dilim, su bardağı = 200 ml, çay bardağı = 100 ml, yemek
kaşığı, porsiyon, ...). No nutrition value is written in code.

- **Sources:** USDA FoodData Central (public domain; please credit "USDA FoodData Central"):
  SR Legacy and Foundation for basic foods, FNDDS for dishes. Turkish dishes use a close USDA
  equivalent where one exists (marked "Approximation" in `source_note`). Dishes with no source
  are `todo` rows with no values until a dietitian fills them in. Everything starts unverified.
- **Seed:** `supabase/seed/catalog.mjs` lists the foods (names, aliases, FDC ids);
  `node supabase/seed/build_foods.mjs` regenerates `supabase/migrations/20261024000100_food_seed.sql`
  from the USDA CSV downloads in `supabase/seed/.cache/` (see `fdc.mjs` for the files).
- **Barcodes:** the `lookup-barcode` function looks products up in Open Food Facts and caches
  them in `foods`. Open Food Facts data is under the ODbL: the app shows "Open Food Facts" as the
  source, and cached products must stay open. Set `OFF_USER_AGENT` to `Nouri/<version> (<contact>)`,
  as Open Food Facts asks.
- **Package size:** barcode products get a "paket" measure from the label quantity ("52 g").
  If it is missing or wrong, anyone can set it from the label while logging (`set_package_size`).
  Only the grams per package change, never the nutrition values; every change is kept in `food_revisions`.
  The barcode camera works on phones and in the browser (typing the number also works).
- **Dietitians** (verified ones only) use the **Foods** tab to fill in missing values, correct
  values and measures, and mark foods verified. Every change is kept in `food_revisions`.
- **Describing a meal** ("2 haşlanmış yumurta, 1 dilim ekmek") is matched to foods by rules in
  `supabase/functions/estimate-meal/estimate.mjs`, no AI. Clients confirm every item before logging.

## Find a dietitian (free)

- Clients browse **verified** dietitians (who leave "Show me in Find a dietitian" on), read anonymous
  reviews and send a request. They agree to the consent text when sending it. Invite codes still work.
- Before accepting, the dietitian sees only the client's name and message. Requests also arrive
  when the dietitian is full (it shows demand), but accepting needs a free place. Accepting a client
  who already has a dietitian ends that connection.
- Dietitians can set their own maximum number of clients; unverified dietitians stay capped at 3.
- Clients can rate a dietitian after 14 days together (1–5 stars + comment, shown without names).
- Former clients appear in the dietitian's client list as **Inactive**; opening one shows only the
  dietitian's own notes and plans.
- No prices or payments yet. Planned later: monthly prices with a price ceiling and admin-approved
  raises, a price locked for a year per client, a 3-day trial and in-app payment.

## AI features (off for now)

Photo analysis and other AI features call a paid model, so they are switched off:
`kAiEnabled = false` in `app/lib/core/features.dart` hides their buttons, and the local server
answers `analyze-meal` with "not available" unless `AI_FEATURES=on` is set in `devserver/.env`.
When they are built, keys go only in Supabase secrets (never in the app) and the model will only
name foods and portions. Calories always come from the foods table.
## Food photos (free, on the phone)

The camera button recognises food with MobileCLIP-S0 running on the device (no API, no cost,
works offline; on the web it runs in the browser). We "teach" it our foods by describing each one:
`supabase/seed/looks.mjs` (what dishes look like) plus the catalog names. After changing foods or
descriptions, run `cd supabase/seed && npm install && node build_photo_index.mjs` (writes
`app/assets/ai/`). The user picks from the suggestions; calories always come from the foods table.
Test photos: `node fetch_test_images.mjs`, then `node build_photo_index.mjs --test`.
The model file (`app/assets/ai/food_vision.onnx`, 43 MB) is not in the repository: MobileCLIP's
weights come with Apple's own license, so the script downloads them. Run it once before building the app.

## Google sign-in (ready, off)

1. Google Cloud console: create an OAuth client (Web application) with
   `https://<project>.supabase.co/auth/v1/callback` as redirect URI.
2. Supabase -> Authentication -> Providers -> Google: paste the client ID and secret; under URL
   configuration add `io.supabase.nouri://login-callback`.
3. Build the app with `--dart-define=GOOGLE_SIGN_IN=true`. Google accounts start as clients.

## Push notifications (ready, off)

Meal reminders already work on the phone without this. Push is for messages, dietitian changes etc.
1. Firebase console: create a project and add the Android app.
2. Build with `--dart-define=FIREBASE_API_KEY=...`, `FIREBASE_APP_ID`, `FIREBASE_SENDER_ID`, `FIREBASE_PROJECT_ID`.
3. Deploy `supabase/functions/send-push` and add the webhook described at the top of its `index.ts`.

## Language

The app follows the device language: Turkish on Turkish devices, English otherwise (no setting).
UI strings are written in English and wrapped in `t(...)`; Turkish lives in `app/lib/core/i18n_tr.dart`.
Sentences generated by the database (notifications, change history, consent) are translated on
display by `tServer(...)`.

## Setup

1. Create a Supabase project and apply the migrations in `supabase/migrations/` in name order,
   either with `supabase db push` (CLI) or by pasting each file into the SQL editor.
   Deploy the functions: `supabase functions deploy estimate-meal lookup-barcode` and
   `supabase secrets set OFF_USER_AGENT="Nouri/0.1 (you@example.com)"`.
2. Make yourself an admin so you can review dietitian credentials:
   ```sql
   insert into public.admins (user_id)
   select id from auth.users where email = 'you@example.com';
   ```
3. Run the app with your project URL and publishable (or legacy anon) key:
   ```sh
   cd app
   flutter run -d chrome --dart-define=SUPABASE_URL=https://xxxx.supabase.co --dart-define=SUPABASE_KEY=sb_publishable_...
   ```

## Public copy (GitHub)

`npm run export:public` copies everything git would commit into `Desktop/Nouri` (all `.gitignore`
files apply: no local database, `.env`, builds, caches or the model) and refuses to copy if it finds
a private IP, an API key, a private key or a personal e-mail address. Run it again after changes; the
folder is updated in place and its `.git` is kept.

## Tests

- Database rules: `cd supabase/tests && npm install && npm test`
  (runs the migration in PGlite with stubs for Supabase's auth and storage schemas)
- App: `cd app && flutter analyze && flutter test`

## Not built yet

- **Push notifications**: rows in `notifications` are created by triggers, and devices can
  register in `device_tokens`. A Database Webhook calling an Edge Function to send via FCM
  can deliver them; it should set `notifications.pushed_at` once sent.
- **Appointment reminders**: `appointments.remind_minutes_before` stores when to remind.
  Delivery needs a scheduled job.
- **Payments**: none; the app is free. `dietitian_subscriptions.tier` is kept in the database
  but not used. Only unverified dietitians are limited (3 active clients).
