-- =============================================================================
-- Nouri: Dietitian & Client mode
--
-- Access model (enforced here with RLS, never only in the UI):
--   * A client reads/writes only rows where client_id = auth.uid().
--   * A dietitian reads a client's data only while an ACTIVE, accepted link
--     exists in client_links. Ending the link revokes access immediately.
--   * After a client leaves, the dietitian keeps only what they authored for
--     themselves: their private notes and the meal plans they wrote (read-only).
--   * Private dietitian notes are readable only by the authoring dietitian.
--   * Dietitians start unverified (max 3 clients) until an admin approves the
--     credential they uploaded.
--   * client_links, audit_log, notifications and subscriptions are never written
--     directly by users: links go through accept_invite()/leave_dietitian(), the
--     audit log and notifications are filled by triggers, subscriptions by the
--     billing backend (service_role).
-- =============================================================================


-- Helpers used by policies and triggers. Not in an API-exposed schema, so
-- they cannot be called directly over PostgREST.
create schema if not exists private;
grant usage on schema private to authenticated;

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------
create type public.user_role     as enum ('client', 'dietitian');
create type public.link_status   as enum ('active', 'ended');
create type public.invite_status as enum ('pending', 'accepted', 'revoked');
create type public.meal_slot     as enum ('breakfast', 'lunch', 'dinner', 'snack');
create type public.appt_status   as enum ('scheduled', 'completed', 'cancelled');
create type public.sub_tier      as enum ('free', 'pro', 'clinic');
create type public.verification_status as enum ('unsubmitted', 'pending', 'approved', 'rejected');
create type public.request_status as enum ('open', 'resolved', 'declined');

-- -----------------------------------------------------------------------------
-- Accounts
-- -----------------------------------------------------------------------------
create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  role          public.user_role not null default 'client',
  full_name     text,
  avatar_url    text,
  timezone      text not null default 'UTC',   -- defines "today" for a client
  birth_date    date,
  height_cm     numeric(5,1) check (height_cm between 50 and 260),
  sex           text check (sex in ('female', 'male', 'other')),
  premium_until timestamptz,                   -- self-purchased premium (billing backend)
  created_at    timestamptz not null default now()
);

-- Role and premium are not user-editable after signup.
revoke update on public.profiles from authenticated, anon;
grant  update (full_name, avatar_url, timezone, birth_date, height_cm, sex) on public.profiles to authenticated;

-- Create a profile on signup; role comes from signUp({ options: { data: { role } } }).
create function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, role, full_name)
  values (
    new.id,
    case when new.raw_user_meta_data ->> 'role' = 'dietitian'
         then 'dietitian'::public.user_role else 'client'::public.user_role end,
    new.raw_user_meta_data ->> 'full_name'
  );
  if new.raw_user_meta_data ->> 'role' = 'dietitian' then
    insert into public.dietitian_profiles (user_id) values (new.id);
  end if;
  -- Meal reminders start with sensible default times; the user can change them.
  insert into public.reminder_settings (user_id) values (new.id);
  return new;
end $$;

-- Meal reminders ("What did you have for lunch?"). Delivered as local
-- notifications by the mobile app, which reads these times.
create table public.reminder_settings (
  user_id    uuid primary key references public.profiles (id) on delete cascade,
  enabled    boolean not null default true,
  breakfast  time not null default '08:30',
  lunch      time not null default '12:30',
  dinner     time not null default '19:30',
  updated_at timestamptz not null default now()
);
revoke update on public.reminder_settings from authenticated, anon;
grant  update (enabled, breakfast, lunch, dinner, updated_at) on public.reminder_settings to authenticated;

-- The dietitian's public workspace page.
create table public.dietitian_profiles (
  user_id     uuid primary key references public.profiles (id) on delete cascade,
  title       text,                       -- e.g. "RD, MSc Clinical Nutrition"
  specialties text[] not null default '{}',
  bio         text,
  photo_url   text,
  slug        text unique,                -- public workspace URL
  -- Public so clients can see the "Unverified" badge. Changed only by
  -- submit_verification() / admin_review_dietitian().
  verification_status public.verification_status not null default 'unsubmitted',
  updated_at  timestamptz not null default now()
);
revoke update on public.dietitian_profiles from authenticated, anon;
grant  update (title, specialties, bio, photo_url, slug) on public.dietitian_profiles to authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- Platform admins (added manually with the service role / SQL editor).
create table public.admins (
  user_id    uuid primary key references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);

create function private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;

-- Credential uploads. Kept out of dietitian_profiles because that table is
-- publicly readable. Document lives in storage: credentials/{dietitian_id}/...
create table public.verification_submissions (
  id            uuid primary key default gen_random_uuid(),
  dietitian_id  uuid not null references public.dietitian_profiles (user_id) on delete cascade,
  document_path text not null,
  status        public.verification_status not null default 'pending',
  submitted_at  timestamptz not null default now(),
  reviewed_at   timestamptz,
  reviewed_by   uuid references public.profiles (id) on delete set null,
  review_note   text                     -- shown to the dietitian, e.g. reason for rejection
);
create index on public.verification_submissions (status, submitted_at);
create index on public.verification_submissions (dietitian_id, submitted_at desc);

-- Written only by the billing backend (service_role). No row = free tier.
-- Payments are not wired up yet; the tier field and limit are already enforced.
create table public.dietitian_subscriptions (
  dietitian_id       uuid primary key references public.dietitian_profiles (user_id) on delete cascade,
  tier               public.sub_tier not null default 'free',
  max_active_clients int  not null default 10,
  status             text not null default 'active',   -- mirrors the payment provider
  current_period_end timestamptz,
  updated_at         timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Notifications (in-app now; a push sender can later consume inserts here,
-- e.g. a Database Webhook -> Edge Function -> FCM/APNs using device_tokens)
-- -----------------------------------------------------------------------------
create table public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  type       text not null,          -- 'message' | 'change' | 'target_request' | 'verification' | 'link' ...
  title      text not null,
  body       text,
  data       jsonb not null default '{}',   -- deep-link payload, e.g. {"client_id": ...}
  read_at    timestamptz,
  pushed_at  timestamptz,            -- set by the push sender once delivered
  created_at timestamptz not null default now()
);
create index on public.notifications (user_id, created_at desc);
revoke update on public.notifications from authenticated, anon;
grant  update (read_at) on public.notifications to authenticated;

create table public.device_tokens (
  token      text primary key,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  platform   text not null check (platform in ('ios', 'android', 'web')),
  updated_at timestamptz not null default now()
);
create index on public.device_tokens (user_id);

create function private.notify(p_user uuid, p_type text, p_title text, p_body text, p_data jsonb default '{}')
returns void
language sql security definer set search_path = '' as $$
  insert into public.notifications (user_id, type, title, body, data)
  values (p_user, p_type, p_title, p_body, coalesce(p_data, '{}'))
$$;

-- -----------------------------------------------------------------------------
-- Dietitian <-> client relationship
-- -----------------------------------------------------------------------------
create table public.invites (
  id           uuid primary key default gen_random_uuid(),
  dietitian_id uuid not null references public.dietitian_profiles (user_id) on delete cascade,
  code         text not null unique
                 default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  status       public.invite_status not null default 'pending',
  expires_at   timestamptz not null default now() + interval '14 days',
  accepted_by  uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);

create table public.client_links (
  id               uuid primary key default gen_random_uuid(),
  dietitian_id     uuid not null references public.dietitian_profiles (user_id) on delete cascade,
  client_id        uuid not null references public.profiles (id) on delete cascade,
  invite_id        uuid references public.invites (id) on delete set null,
  -- Name as it was when the client joined, so a dietitian can still label
  -- their retained notes/plans after the client leaves without profile access.
  client_display_name text,
  status           public.link_status not null default 'active',
  consent_version  text not null,         -- which consent text the client agreed to
  consented_at     timestamptz not null default now(),
  started_at       timestamptz not null default now(),
  ended_at         timestamptz,
  ended_by         uuid references public.profiles (id) on delete set null
);
-- A client has at most one dietitian at a time.
create unique index client_links_one_active_per_client
  on public.client_links (client_id) where status = 'active';
create index client_links_active_by_dietitian
  on public.client_links (dietitian_id, client_id) where status = 'active';

-- Core access check used by every policy. SECURITY DEFINER so it can read
-- client_links regardless of the caller's own RLS on that table.
create function private.has_active_link(p_dietitian uuid, p_client uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.client_links
    where dietitian_id = p_dietitian and client_id = p_client and status = 'active'
  )
$$;

-- "Am I (the caller) this client's current dietitian?"
create function private.is_dietitian_of(p_client uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.has_active_link(auth.uid(), p_client)
$$;

create function private.has_active_dietitian(p_client uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.client_links where client_id = p_client and status = 'active'
  )
$$;

create function private.is_dietitian() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'dietitian')
$$;

-- Storage paths are "{owner uuid}/...". Returns that uuid, or null if malformed.
create function private.storage_client_id(p_name text) returns uuid
language sql immutable set search_path = '' as $$
  select case when split_part(p_name, '/', 1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then split_part(p_name, '/', 1)::uuid end
$$;

-- -----------------------------------------------------------------------------
-- Client-owned tracking data (written by the client, read by their dietitian)
-- -----------------------------------------------------------------------------
create table public.food_entries (
  id             uuid primary key default gen_random_uuid(),
  client_id      uuid not null references public.profiles (id) on delete cascade,
  logged_on      date not null,                     -- client's local date
  logged_at      timestamptz not null default now(),
  meal           public.meal_slot not null,
  name           text not null,
  calories       numeric(7,1) not null default 0,
  protein_g      numeric(6,1),
  carbs_g        numeric(6,1),
  fat_g          numeric(6,1),
  satiety_rating smallint check (satiety_rating between 1 and 5),
  energy_rating  smallint check (energy_rating between 1 and 5),
  photo_path     text,                              -- storage: meal-photos/{client_id}/...
  created_at     timestamptz not null default now()
);
create index on public.food_entries (client_id, logged_on desc);

create table public.weight_entries (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references public.profiles (id) on delete cascade,
  measured_on date not null,
  weight_kg   numeric(5,2) not null check (weight_kg > 0),
  created_at  timestamptz not null default now()
);
create index on public.weight_entries (client_id, measured_on desc);

create table public.body_measurements (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references public.profiles (id) on delete cascade,
  measured_on date not null,
  waist_cm    numeric(5,1),
  hip_cm      numeric(5,1),
  chest_cm    numeric(5,1),
  body_fat_pct numeric(4,1),
  created_at  timestamptz not null default now()
);
create index on public.body_measurements (client_id, measured_on desc);

create table public.water_entries (
  id         uuid primary key default gen_random_uuid(),
  client_id  uuid not null references public.profiles (id) on delete cascade,
  logged_on  date not null,
  amount_ml  int not null check (amount_ml > 0),
  created_at timestamptz not null default now()
);
create index on public.water_entries (client_id, logged_on desc);

-- -----------------------------------------------------------------------------
-- Dietitian-managed data for a client
-- -----------------------------------------------------------------------------
-- Safety warnings for low targets are shown in the app (lib/core/nutrition_safety.dart)
-- for both client- and dietitian-set targets; this check only rejects nonsense.
create table public.nutrition_targets (
  client_id  uuid primary key references public.profiles (id) on delete cascade,
  calories   int check (calories between 0 and 10000),
  protein_g  int,
  carbs_g    int,
  fat_g      int,
  water_ml   int,
  updated_by uuid references public.profiles (id) on delete set null,
  updated_at timestamptz not null default now()
);

-- Client asks their dietitian to change targets.
create table public.target_change_requests (
  id                 uuid primary key default gen_random_uuid(),
  client_id          uuid not null references public.profiles (id) on delete cascade,
  dietitian_id       uuid not null references public.dietitian_profiles (user_id) on delete cascade,
  message            text not null,
  requested_calories int check (requested_calories between 0 and 10000),
  requested_protein_g int,
  status             public.request_status not null default 'open',
  response           text,
  resolved_at        timestamptz,
  created_at         timestamptz not null default now()
);
create index on public.target_change_requests (dietitian_id, status, created_at desc);
create index on public.target_change_requests (client_id, created_at desc);
revoke update on public.target_change_requests from authenticated, anon;
grant  update (status, response) on public.target_change_requests to authenticated;

-- client_id null  => reusable template owned by the dietitian.
-- client_id set   => plan assigned to that client (a copy, so editing the
--                    template never silently changes an assigned plan).
create table public.meal_plans (
  id           uuid primary key default gen_random_uuid(),
  dietitian_id uuid not null references public.dietitian_profiles (user_id) on delete cascade,
  client_id    uuid references public.profiles (id) on delete cascade,
  source_template_id uuid references public.meal_plans (id) on delete set null,
  name         text not null,
  description  text,
  period       text not null default 'weekly' check (period in ('daily', 'weekly')),
  starts_on    date,
  ends_on      date,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index on public.meal_plans (client_id) where client_id is not null;
create index on public.meal_plans (dietitian_id);

create table public.meal_plan_items (
  id         uuid primary key default gen_random_uuid(),
  plan_id    uuid not null references public.meal_plans (id) on delete cascade,
  day_index  smallint not null default 0 check (day_index between 0 and 6),  -- 0 = Monday
  meal       public.meal_slot not null,
  title      text not null,
  details    text,
  calories   int,
  protein_g  int,
  carbs_g    int,
  fat_g      int,
  sort_order int not null default 0
);
create index on public.meal_plan_items (plan_id);

-- Comment on a specific meal (food_entry_id) or a whole day (log_date).
create table public.comments (
  id            uuid primary key default gen_random_uuid(),
  dietitian_id  uuid not null references public.dietitian_profiles (user_id) on delete cascade,
  client_id     uuid not null references public.profiles (id) on delete cascade,
  food_entry_id uuid references public.food_entries (id) on delete cascade,
  log_date      date,
  body          text not null,
  created_at    timestamptz not null default now(),
  check (food_entry_id is not null or log_date is not null)
);
create index on public.comments (client_id, created_at desc);

-- Visible to the client.
create table public.recommendations (
  id           uuid primary key default gen_random_uuid(),
  dietitian_id uuid not null references public.dietitian_profiles (user_id) on delete cascade,
  client_id    uuid not null references public.profiles (id) on delete cascade,
  title        text,
  body         text not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index on public.recommendations (client_id, created_at desc);

-- General posts from a dietitian to ALL of their active clients (tips,
-- recipes, announcements). Personal advice goes in `recommendations`.
create table public.broadcasts (
  id           uuid primary key default gen_random_uuid(),
  dietitian_id uuid not null references public.dietitian_profiles (user_id) on delete cascade,
  category     text not null default 'tip' check (category in ('tip', 'recipe', 'announcement')),
  title        text not null check (length(title) between 1 and 120),
  body         text not null check (length(body) between 1 and 4000),
  created_at   timestamptz not null default now()
);
create index on public.broadcasts (dietitian_id, created_at desc);

-- Separate table (not a visibility flag) so no client policy can ever match it.
create table public.private_notes (
  id           uuid primary key default gen_random_uuid(),
  dietitian_id uuid not null references public.dietitian_profiles (user_id) on delete cascade,
  client_id    uuid not null references public.profiles (id) on delete cascade,
  body         text not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index on public.private_notes (dietitian_id, client_id);
-- Notes can be edited but never re-pointed at another client.
revoke update on public.private_notes from authenticated, anon;
grant  update (body, updated_at) on public.private_notes to authenticated;

create table public.appointments (
  id               uuid primary key default gen_random_uuid(),
  dietitian_id     uuid not null references public.dietitian_profiles (user_id) on delete cascade,
  client_id        uuid not null references public.profiles (id) on delete cascade,
  starts_at        timestamptz not null,
  duration_min     int not null default 30 check (duration_min > 0),
  location         text,                                -- address or video link
  agenda           text,
  status           public.appt_status not null default 'scheduled',
  remind_minutes_before int[] not null default '{1440,60}',
  created_at       timestamptz not null default now()
);
create index on public.appointments (client_id, starts_at);
create index on public.appointments (dietitian_id, starts_at);

-- 1:1 messaging. Exactly one of sender being the client or the dietitian.
create table public.messages (
  id           uuid primary key default gen_random_uuid(),
  dietitian_id uuid not null references public.dietitian_profiles (user_id) on delete cascade,
  client_id    uuid not null references public.profiles (id) on delete cascade,
  sender_id    uuid not null references public.profiles (id) on delete cascade,
  body         text,
  photo_path   text,                                    -- storage: message-photos/{client_id}/...
  read_at      timestamptz,
  created_at   timestamptz not null default now(),
  check (sender_id in (dietitian_id, client_id)),
  check (body is not null or photo_path is not null)
);
create index on public.messages (client_id, dietitian_id, created_at desc);
-- Only read_at may change after sending.
revoke update on public.messages from authenticated, anon;
grant  update (read_at) on public.messages to authenticated;

-- Change history shown to the client ("Your dietitian updated ...").
-- Insert-only, filled by triggers below.
create table public.audit_log (
  id           bigint generated always as identity primary key,
  dietitian_id uuid not null references public.profiles (id) on delete cascade,
  client_id    uuid not null references public.profiles (id) on delete cascade,
  actor_id     uuid references public.profiles (id) on delete set null,
  entity       text not null,
  entity_id    text,
  action       text not null,
  summary      text not null,
  old_value    jsonb,
  new_value    jsonb,
  created_at   timestamptz not null default now()
);
create index on public.audit_log (client_id, created_at desc);

-- =============================================================================
-- Row Level Security
-- =============================================================================
alter table public.profiles                enable row level security;
alter table public.dietitian_profiles      enable row level security;
alter table public.dietitian_subscriptions enable row level security;
alter table public.invites                 enable row level security;
alter table public.client_links            enable row level security;
alter table public.food_entries            enable row level security;
alter table public.weight_entries          enable row level security;
alter table public.body_measurements       enable row level security;
alter table public.water_entries           enable row level security;
alter table public.nutrition_targets       enable row level security;
alter table public.meal_plans              enable row level security;
alter table public.meal_plan_items         enable row level security;
alter table public.comments                enable row level security;
alter table public.recommendations         enable row level security;
alter table public.private_notes           enable row level security;
alter table public.appointments            enable row level security;
alter table public.messages                enable row level security;
alter table public.audit_log               enable row level security;
alter table public.admins                  enable row level security;
alter table public.verification_submissions enable row level security;
alter table public.notifications           enable row level security;
alter table public.device_tokens           enable row level security;
alter table public.target_change_requests  enable row level security;
alter table public.reminder_settings       enable row level security;
alter table public.broadcasts              enable row level security;

create policy reminders_select on public.reminder_settings for select to authenticated
  using (user_id = (select auth.uid()));
create policy reminders_update on public.reminder_settings for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Broadcasts: written by the dietitian, readable by their current clients.
create policy broadcasts_select on public.broadcasts for select to authenticated
  using (dietitian_id = (select auth.uid())
         or private.has_active_link(dietitian_id, (select auth.uid())));
create policy broadcasts_write on public.broadcasts for all to authenticated
  using (dietitian_id = (select auth.uid()))
  with check (dietitian_id = (select auth.uid()) and private.is_dietitian());

create policy admins_select on public.admins for select to authenticated
  using (user_id = (select auth.uid()));

-- Submissions: the dietitian sees their own, admins see all. Writes via RPCs.
create policy vsub_select on public.verification_submissions for select to authenticated
  using (dietitian_id = (select auth.uid()) or private.is_admin());

create policy notifications_select on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));
create policy notifications_update on public.notifications for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy device_tokens_all on public.device_tokens for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Target change requests: client creates (to their active dietitian) and
-- reads their own; the active dietitian reads and answers.
create policy tcr_select on public.target_change_requests for select to authenticated
  using (client_id = (select auth.uid())
         or (dietitian_id = (select auth.uid()) and private.is_dietitian_of(client_id)));
create policy tcr_insert on public.target_change_requests for insert to authenticated
  with check (client_id = (select auth.uid())
              and private.has_active_link(dietitian_id, client_id)
              and status = 'open' and response is null);
create policy tcr_update on public.target_change_requests for update to authenticated
  using (dietitian_id = (select auth.uid()) and private.is_dietitian_of(client_id))
  with check (dietitian_id = (select auth.uid()));

-- profiles: yourself, your active clients, or your active dietitian.
create policy profiles_select on public.profiles for select to authenticated
  using (
    id = (select auth.uid())
    or private.is_dietitian_of(id)
    or private.has_active_link(id, (select auth.uid()))
  );
create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- dietitian_profiles: public workspace pages, edited only by their owner.
create policy dprof_select on public.dietitian_profiles for select to authenticated using (true);
create policy dprof_update on public.dietitian_profiles for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy dsub_select on public.dietitian_subscriptions for select to authenticated
  using (dietitian_id = (select auth.uid()));

-- invites: managed by the issuing dietitian. Clients go through RPCs.
create policy invites_select on public.invites for select to authenticated
  using (dietitian_id = (select auth.uid()));
create policy invites_insert on public.invites for insert to authenticated
  with check (dietitian_id = (select auth.uid()) and status = 'pending');
create policy invites_update on public.invites for update to authenticated
  using (dietitian_id = (select auth.uid()) and status = 'pending')
  with check (dietitian_id = (select auth.uid()) and status in ('pending', 'revoked'));

-- client_links: both parties can see the link; changes only via RPCs.
create policy links_select on public.client_links for select to authenticated
  using (client_id = (select auth.uid()) or dietitian_id = (select auth.uid()));

-- Client-owned tracking tables: client full access, active dietitian read-only.
do $$
declare t text;
begin
  foreach t in array array['food_entries', 'weight_entries', 'body_measurements', 'water_entries'] loop
    execute format($f$
      create policy %1$s_select on public.%1$I for select to authenticated
        using (client_id = (select auth.uid()) or private.is_dietitian_of(client_id));
      create policy %1$s_insert on public.%1$I for insert to authenticated
        with check (client_id = (select auth.uid()));
      create policy %1$s_update on public.%1$I for update to authenticated
        using (client_id = (select auth.uid())) with check (client_id = (select auth.uid()));
      create policy %1$s_delete on public.%1$I for delete to authenticated
        using (client_id = (select auth.uid()));
    $f$, t);
  end loop;
end $$;

-- nutrition_targets: managed by the active dietitian; the client manages
-- their own targets only while they have no dietitian.
create policy targets_select on public.nutrition_targets for select to authenticated
  using (client_id = (select auth.uid()) or private.is_dietitian_of(client_id));
create policy targets_insert on public.nutrition_targets for insert to authenticated
  with check (
    private.is_dietitian_of(client_id)
    or (client_id = (select auth.uid()) and not private.has_active_dietitian(client_id))
  );
create policy targets_update on public.nutrition_targets for update to authenticated
  using (
    private.is_dietitian_of(client_id)
    or (client_id = (select auth.uid()) and not private.has_active_dietitian(client_id))
  )
  with check (
    private.is_dietitian_of(client_id)
    or (client_id = (select auth.uid()) and not private.has_active_dietitian(client_id))
  );

-- meal_plans: the authoring dietitian can always read their plans (including
-- ones written for former clients) but only edit templates and plans of active
-- clients; the client reads plans assigned to them.
create policy plans_select on public.meal_plans for select to authenticated
  using (client_id = (select auth.uid()) or dietitian_id = (select auth.uid()));
create policy plans_write on public.meal_plans for all to authenticated
  using (
    dietitian_id = (select auth.uid())
    and (client_id is null or private.is_dietitian_of(client_id))
  )
  with check (
    dietitian_id = (select auth.uid())
    and private.is_dietitian()
    and (client_id is null or private.is_dietitian_of(client_id))
  );

-- meal_plan_items inherit access from their plan.
create function private.can_read_plan(p_plan uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.meal_plans p
    where p.id = p_plan and (p.client_id = auth.uid() or p.dietitian_id = auth.uid())
  )
$$;
create function private.can_write_plan(p_plan uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.meal_plans p
    where p.id = p_plan
      and p.dietitian_id = auth.uid()
      and (p.client_id is null or private.is_dietitian_of(p.client_id))
  )
$$;
create policy items_select on public.meal_plan_items for select to authenticated
  using (private.can_read_plan(plan_id));
create policy items_write on public.meal_plan_items for all to authenticated
  using (private.can_write_plan(plan_id)) with check (private.can_write_plan(plan_id));

-- comments / recommendations / appointments: written by the active dietitian,
-- readable by the client (it is shared with them and stays theirs after leaving).
do $$
declare t text;
begin
  foreach t in array array['comments', 'recommendations', 'appointments'] loop
    execute format($f$
      create policy %1$s_select on public.%1$I for select to authenticated
        using (client_id = (select auth.uid())
               or (dietitian_id = (select auth.uid()) and private.is_dietitian_of(client_id)));
      create policy %1$s_write on public.%1$I for all to authenticated
        using (dietitian_id = (select auth.uid()) and private.is_dietitian_of(client_id))
        with check (dietitian_id = (select auth.uid()) and private.is_dietitian_of(client_id));
    $f$, t);
  end loop;
end $$;

-- A comment's food entry must belong to the same client.
create function private.check_comment_entry() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.food_entry_id is not null and not exists (
    select 1 from public.food_entries where id = new.food_entry_id and client_id = new.client_id
  ) then
    raise exception 'food entry does not belong to this client';
  end if;
  return new;
end $$;
create trigger comments_entry_check before insert or update on public.comments
  for each row execute function private.check_comment_entry();

-- private_notes: authoring dietitian only. New notes need an active link;
-- existing notes stay readable/editable by their author after the client leaves.
create policy private_notes_select on public.private_notes for select to authenticated
  using (dietitian_id = (select auth.uid()));
create policy private_notes_insert on public.private_notes for insert to authenticated
  with check (dietitian_id = (select auth.uid()) and private.is_dietitian_of(client_id));
create policy private_notes_update on public.private_notes for update to authenticated
  using (dietitian_id = (select auth.uid())) with check (dietitian_id = (select auth.uid()));
create policy private_notes_delete on public.private_notes for delete to authenticated
  using (dietitian_id = (select auth.uid()));

-- messages: the client sees their own history; the dietitian only while linked.
-- Sending requires an active link in both directions.
create policy messages_select on public.messages for select to authenticated
  using (
    client_id = (select auth.uid())
    or (dietitian_id = (select auth.uid()) and private.is_dietitian_of(client_id))
  );
create policy messages_insert on public.messages for insert to authenticated
  with check (
    sender_id = (select auth.uid())
    and private.has_active_link(dietitian_id, client_id)
    and read_at is null
  );
create policy messages_mark_read on public.messages for update to authenticated
  using (
    sender_id <> (select auth.uid())
    and (client_id = (select auth.uid())
         or (dietitian_id = (select auth.uid()) and private.is_dietitian_of(client_id)))
  )
  with check (sender_id <> (select auth.uid()));

-- audit_log: read-only for both parties.
create policy audit_select on public.audit_log for select to authenticated
  using (
    client_id = (select auth.uid())
    or (dietitian_id = (select auth.uid()) and private.is_dietitian_of(client_id))
  );

-- =============================================================================
-- Audit log triggers (dietitian changes to targets, plans, notes, appointments)
-- =============================================================================
create function private.audit_targets() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_dietitian uuid := auth.uid();
  f record;
begin
  -- Only log changes made by the client's dietitian, not by the client.
  if v_dietitian is null or not private.has_active_link(v_dietitian, new.client_id) then
    return new;
  end if;

  for f in
    select * from (values
      ('calories',  'calorie target', ' kcal', old.calories,  new.calories),
      ('protein_g', 'protein target', ' g',    old.protein_g, new.protein_g),
      ('carbs_g',   'carb target',    ' g',    old.carbs_g,   new.carbs_g),
      ('fat_g',     'fat target',     ' g',    old.fat_g,     new.fat_g),
      ('water_ml',  'water target',   ' ml',   old.water_ml,  new.water_ml)
    ) as x(col, label, unit, old_v, new_v)
    where old_v is distinct from new_v
  loop
    insert into public.audit_log
      (dietitian_id, client_id, actor_id, entity, entity_id, action, summary, old_value, new_value)
    values (
      v_dietitian, new.client_id, v_dietitian, 'nutrition_targets', f.col, 'update',
      case when f.new_v is null
           then format('Your dietitian removed your %s', f.label)
           else format('Your dietitian updated your %s to %s%s', f.label, f.new_v, f.unit) end,
      to_jsonb(f.old_v), to_jsonb(f.new_v)
    );
  end loop;
  return new;
end $$;

-- old.* is not available on INSERT, so inserts get their own trigger.
create function private.audit_targets_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v uuid := auth.uid();
begin
  if v is null or not private.has_active_link(v, new.client_id) then return new; end if;
  insert into public.audit_log
    (dietitian_id, client_id, actor_id, entity, entity_id, action, summary, new_value)
  select v, new.client_id, v, 'nutrition_targets', x.col, 'set',
         format('Your dietitian set your %s to %s%s', x.label, x.val, x.unit), to_jsonb(x.val)
  from (values
    ('calories',  'calorie target', ' kcal', new.calories),
    ('protein_g', 'protein target', ' g',    new.protein_g),
    ('carbs_g',   'carb target',    ' g',    new.carbs_g),
    ('fat_g',     'fat target',     ' g',    new.fat_g),
    ('water_ml',  'water target',   ' ml',   new.water_ml)
  ) as x(col, label, unit, val)
  where x.val is not null;
  return new;
end $$;

create trigger nutrition_targets_audit_insert after insert on public.nutrition_targets
  for each row execute function private.audit_targets_insert();
create trigger nutrition_targets_audit_update after update on public.nutrition_targets
  for each row execute function private.audit_targets();

-- Stamp who/when on target changes.
create function private.stamp_targets() returns trigger
language plpgsql as $$
begin
  new.updated_by := auth.uid();
  new.updated_at := now();
  return new;
end $$;
create trigger nutrition_targets_stamp before insert or update on public.nutrition_targets
  for each row execute function private.stamp_targets();

-- Generic audit for client-facing dietitian content.
create function private.audit_dietitian_content() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  r          record;
  v_client   uuid;
  v_summary  text;
  v_when     text;
  v_plan_new boolean;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;

  if tg_table_name = 'meal_plans' then
    v_client := r.client_id;
    if v_client is null then return r; end if;           -- templates are not client-facing
    v_summary := case
      when tg_op = 'INSERT' then format('Your dietitian assigned you the meal plan "%s"', r.name)
      when tg_op = 'DELETE' then format('Your dietitian removed your meal plan "%s"', r.name)
      when old.is_active and not new.is_active
        then format('Your dietitian archived your meal plan "%s"', r.name)
      else format('Your dietitian updated your meal plan "%s"', r.name) end;
  elsif tg_table_name = 'meal_plan_items' then
    -- now() is the transaction start, so this is true while the plan itself is
    -- being created (e.g. by assign_meal_plan): one "assigned" entry, not one per item.
    select p.client_id, format('Your dietitian edited your meal plan "%s"', p.name),
           p.created_at = now()
      into v_client, v_summary, v_plan_new
      from public.meal_plans p where p.id = r.plan_id;
    if v_client is null or v_plan_new then return r; end if;
  elsif tg_table_name = 'recommendations' then
    v_client := r.client_id;
    v_summary := case tg_op
      when 'INSERT' then 'Your dietitian added a new recommendation'
      when 'UPDATE' then 'Your dietitian updated a recommendation'
      else 'Your dietitian removed a recommendation' end;
  elsif tg_table_name = 'appointments' then
    v_client := r.client_id;
    -- Show the time in the client's own time zone.
    v_when := to_char(r.starts_at at time zone coalesce(
                (select timezone from public.profiles where id = v_client), 'UTC'), 'DD Mon YYYY, HH24:MI');
    v_summary := case
      when tg_op = 'INSERT' then format('Your dietitian scheduled an appointment for %s', v_when)
      when tg_op = 'DELETE' or r.status = 'cancelled' then format('Your dietitian cancelled your appointment on %s', v_when)
      else format('Your dietitian updated your appointment (%s)', v_when) end;
  else
    return r;
  end if;

  -- Only log when the actor is that client's active dietitian.
  if auth.uid() is null or not private.has_active_link(auth.uid(), v_client) then
    return r;
  end if;

  insert into public.audit_log
    (dietitian_id, client_id, actor_id, entity, entity_id, action, summary, old_value, new_value)
  values (
    auth.uid(), v_client, auth.uid(), tg_table_name, r.id::text, lower(tg_op), v_summary,
    case when tg_op <> 'INSERT' then to_jsonb(old) end,
    case when tg_op <> 'DELETE' then to_jsonb(new) end
  );
  return r;
end $$;

create trigger meal_plans_audit after insert or update or delete on public.meal_plans
  for each row execute function private.audit_dietitian_content();
create trigger meal_plan_items_audit after insert or update or delete on public.meal_plan_items
  for each row execute function private.audit_dietitian_content();
create trigger recommendations_audit after insert or update or delete on public.recommendations
  for each row execute function private.audit_dietitian_content();
create trigger appointments_audit after insert or update or delete on public.appointments
  for each row execute function private.audit_dietitian_content();

-- =============================================================================
-- RPCs
-- =============================================================================

-- Active-client limit: tier limit (free = 10 when no subscription row),
-- capped at 3 until the dietitian's credential is approved.
create function private.client_limit(p_dietitian uuid) returns int
language sql stable security definer set search_path = '' as $$
  select case
    when (select verification_status from public.dietitian_profiles where user_id = p_dietitian) = 'approved'
      then coalesce(
        (select max_active_clients from public.dietitian_subscriptions
          where dietitian_id = p_dietitian and status = 'active'),
        10)
    else least(3, coalesce(
        (select max_active_clients from public.dietitian_subscriptions
          where dietitian_id = p_dietitian and status = 'active'),
        10))
  end
$$;

-- Bump this whenever the consent text below changes; accept_invite only
-- accepts the current version, so clients always agree to what they were shown.
create function private.consent_version() returns text
language sql immutable as $$ select '2026-10-22' $$;

-- What the consent screen shows before joining. Readable by any signed-in user
-- who holds the code; reveals only the dietitian's public profile.
create function public.get_invite_preview(p_code text)
returns table (
  dietitian_id uuid, full_name text, title text, specialties text[], bio text,
  photo_url text, verified boolean, expires_at timestamptz,
  consent_version text, shared_data text[], after_leaving text[]
)
language sql stable security definer set search_path = '' as $$
  select d.user_id, p.full_name, d.title, d.specialties, d.bio, d.photo_url,
         d.verification_status = 'approved', i.expires_at,
         private.consent_version(),
         array[
           'Your food log, including meal photos and satiety/energy ratings',
           'Your weight and body measurement history',
           'Your water intake',
           'Progress charts built from the data above',
           'Messages you exchange with your dietitian',
           'Requests you send about your targets'
         ],
         array[
           'You can leave at any time from the "My Dietitian" tab.',
           'When you leave, your dietitian immediately loses access to your food log, weight, measurements, water, photos and messages.',
           'Nothing you log after leaving is ever visible to them.',
           'Your dietitian keeps their own private notes about you and copies of the meal plans they wrote for you.',
           'You keep everything your dietitian shared with you: plans, recommendations, comments and the change history.'
         ]
  from public.invites i
  join public.dietitian_profiles d on d.user_id = i.dietitian_id
  join public.profiles p on p.id = d.user_id
  where i.code = upper(trim(p_code)) and i.status = 'pending' and i.expires_at > now()
$$;

-- Client accepts an invite after the consent screen.
create function public.accept_invite(p_code text, p_consent_version text)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid    uuid := auth.uid();
  v_invite public.invites;
  v_name   text;
  v_link   uuid;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if coalesce(trim(p_consent_version), '') = '' then
    raise exception 'consent is required';
  end if;
  if p_consent_version <> private.consent_version() then
    raise exception 'consent text has changed, please review it again';
  end if;
  select full_name into v_name from public.profiles where id = v_uid and role = 'client';
  if not found then
    raise exception 'only client accounts can join a dietitian';
  end if;

  select * into v_invite from public.invites
   where code = upper(trim(p_code)) for update;
  if not found or v_invite.status <> 'pending' or v_invite.expires_at <= now() then
    raise exception 'invite is invalid or has expired';
  end if;

  if private.has_active_dietitian(v_uid) then
    raise exception 'leave your current dietitian before joining another';
  end if;

  -- Serialize concurrent accepts for the same dietitian so the limit holds.
  perform pg_advisory_xact_lock(hashtext(v_invite.dietitian_id::text));
  if (select count(*) from public.client_links
       where dietitian_id = v_invite.dietitian_id and status = 'active')
     >= private.client_limit(v_invite.dietitian_id) then
    raise exception 'this dietitian has reached their client limit';
  end if;

  insert into public.client_links
    (dietitian_id, client_id, invite_id, consent_version, client_display_name)
  values (v_invite.dietitian_id, v_uid, v_invite.id, p_consent_version, v_name)
  returning id into v_link;

  update public.invites set status = 'accepted', accepted_by = v_uid where id = v_invite.id;

  perform private.notify(v_invite.dietitian_id, 'link', 'New client joined',
    format('%s joined your workspace', coalesce(v_name, 'A client')),
    jsonb_build_object('client_id', v_uid));
  return v_link;
end $$;

-- Client leaves; the dietitian loses access immediately (all policies check
-- for an active link).
create function public.leave_dietitian() returns void
language plpgsql security definer set search_path = '' as $$
declare l public.client_links;
begin
  update public.client_links
     set status = 'ended', ended_at = now(), ended_by = auth.uid()
   where client_id = auth.uid() and status = 'active'
  returning * into l;
  if found then
    perform private.notify(l.dietitian_id, 'link', 'Client left',
      format('%s left your workspace', coalesce(l.client_display_name, 'A client')),
      jsonb_build_object('client_id', l.client_id));
  end if;
end $$;

-- Dietitian removes a client from their workspace.
create function public.remove_client(p_client uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.client_links
     set status = 'ended', ended_at = now(), ended_by = auth.uid()
   where dietitian_id = auth.uid() and client_id = p_client and status = 'active';
  if found then
    perform private.notify(p_client, 'link', 'Your dietitian ended the connection',
      'Your dietitian no longer has access to your data.', '{}');
  end if;
end $$;

-- Dietitian submits (or resubmits) a credential already uploaded to
-- storage at credentials/{their id}/...
create function public.submit_verification(p_document_path text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_admin uuid;
begin
  if not private.is_dietitian() then raise exception 'only dietitians can submit credentials'; end if;
  if private.storage_client_id(p_document_path) is distinct from auth.uid() then
    raise exception 'document must be in your own credentials folder';
  end if;
  if (select verification_status from public.dietitian_profiles where user_id = auth.uid()) = 'approved' then
    raise exception 'already verified';
  end if;

  insert into public.verification_submissions (dietitian_id, document_path)
  values (auth.uid(), p_document_path) returning id into v_id;
  update public.dietitian_profiles set verification_status = 'pending', updated_at = now()
   where user_id = auth.uid();

  for v_admin in select user_id from public.admins loop
    perform private.notify(v_admin, 'verification', 'Credential to review',
      'A dietitian submitted a credential for verification.',
      jsonb_build_object('submission_id', v_id));
  end loop;
  return v_id;
end $$;

-- Admin approves or rejects a pending submission.
create function public.admin_review_verification(p_submission uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare s public.verification_submissions;
begin
  if not private.is_admin() then raise exception 'admins only'; end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then
    raise exception 'a reason is required when rejecting';
  end if;

  update public.verification_submissions
     set status = case when p_approve then 'approved' else 'rejected' end::public.verification_status,
         reviewed_at = now(), reviewed_by = auth.uid(), review_note = p_note
   where id = p_submission and status = 'pending'
  returning * into s;
  if not found then raise exception 'submission not found or already reviewed'; end if;

  update public.dietitian_profiles set verification_status = s.status, updated_at = now()
   where user_id = s.dietitian_id;

  perform private.notify(s.dietitian_id, 'verification',
    case when p_approve then 'You are verified' else 'Verification not approved' end,
    case when p_approve then 'Your credential was approved. The 3-client limit no longer applies.'
         else format('Reason: %s', p_note) end,
    '{}');
end $$;

-- Pending queue for the admin view (includes the dietitian's name).
create function public.admin_pending_verifications()
returns table (submission_id uuid, dietitian_id uuid, full_name text, title text,
               document_path text, submitted_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only'; end if;
  return query
    select s.id, s.dietitian_id, p.full_name, d.title, s.document_path, s.submitted_at
      from public.verification_submissions s
      join public.dietitian_profiles d on d.user_id = s.dietitian_id
      join public.profiles p on p.id = s.dietitian_id
     where s.status = 'pending'
     order by s.submitted_at;
end $$;

-- Dietitian dashboard header: verification, tier and capacity.
create function public.my_workspace_status()
returns table (verification_status public.verification_status, tier public.sub_tier,
               client_limit int, active_clients int, last_review_note text)
language sql stable security definer set search_path = '' as $$
  select d.verification_status,
         coalesce(s.tier, 'free'),
         private.client_limit(d.user_id),
         (select count(*)::int from public.client_links
           where dietitian_id = d.user_id and status = 'active'),
         (select review_note from public.verification_submissions
           where dietitian_id = d.user_id order by submitted_at desc limit 1)
    from public.dietitian_profiles d
    left join public.dietitian_subscriptions s on s.dietitian_id = d.user_id
   where d.user_id = auth.uid()
$$;

-- Copy a template into a plan assigned to a client.
create function public.assign_meal_plan(
  p_template uuid, p_client uuid, p_starts_on date default null, p_ends_on date default null
) returns uuid
language plpgsql security invoker set search_path = '' as $$
declare v_plan uuid;
begin
  -- Runs as the caller, so RLS on meal_plans/meal_plan_items applies.
  insert into public.meal_plans
    (dietitian_id, client_id, source_template_id, name, description, period, starts_on, ends_on)
  select dietitian_id, p_client, id, name, description, period, p_starts_on, p_ends_on
    from public.meal_plans
   where id = p_template and client_id is null and dietitian_id = auth.uid()
  returning id into v_plan;
  if v_plan is null then raise exception 'template not found'; end if;

  -- Deactivate the client's previous plans from this dietitian.
  update public.meal_plans set is_active = false, updated_at = now()
   where client_id = p_client and dietitian_id = auth.uid() and id <> v_plan and is_active;

  insert into public.meal_plan_items
    (plan_id, day_index, meal, title, details, calories, protein_g, carbs_g, fat_g, sort_order)
  select v_plan, day_index, meal, title, details, calories, protein_g, carbs_g, fat_g, sort_order
    from public.meal_plan_items where plan_id = p_template;
  return v_plan;
end $$;

-- Premium features: own purchase, or currently linked to a dietitian.
create function public.has_premium(p_user uuid default auth.uid()) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_user = auth.uid() and (
    exists (select 1 from public.profiles where id = p_user and premium_until > now())
    or private.has_active_dietitian(p_user)
  )
$$;

-- Client overview dashboard: one row per active client.
create function public.dietitian_client_overview()
returns table (
  client_id        uuid,
  full_name        text,
  avatar_url       text,
  linked_since     timestamptz,
  last_log_at      timestamptz,
  today_calories   numeric,
  target_calories  int,
  latest_weight_kg numeric,
  weight_trend     text,          -- 'up' | 'down' | 'flat' | null
  logging_streak   int,           -- consecutive days with a food entry, ending today or yesterday
  unread_messages  int
)
language sql stable security definer set search_path = '' as $$
  with my_clients as (
    select l.client_id, l.started_at, p.full_name, p.avatar_url,
           (now() at time zone p.timezone)::date as today
      from public.client_links l
      join public.profiles p on p.id = l.client_id
     where l.dietitian_id = auth.uid() and l.status = 'active'
  )
  select
    c.client_id, c.full_name, c.avatar_url, c.started_at,
    (select max(f.logged_at) from public.food_entries f where f.client_id = c.client_id),
    (select coalesce(sum(f.calories), 0) from public.food_entries f
      where f.client_id = c.client_id and f.logged_on = c.today),
    (select t.calories from public.nutrition_targets t where t.client_id = c.client_id),
    w.latest,
    case when w.latest is null or w.previous is null then null
         when w.latest - w.previous >  0.2 then 'up'
         when w.latest - w.previous < -0.2 then 'down'
         else 'flat' end,
    coalesce((
      -- Walking back from the latest logged day, the n-th distinct day equals
      -- latest - (n-1) exactly while the run is unbroken.
      select count(*)::int
        from (select d, row_number() over (order by d desc) as rn
                from (select distinct logged_on as d from public.food_entries
                       where client_id = c.client_id and logged_on <= c.today) days) y,
             (select max(logged_on) as latest from public.food_entries
               where client_id = c.client_id and logged_on <= c.today) a
       where a.latest >= c.today - 1
         and y.d = a.latest - (y.rn - 1)::int
    ), 0),
    (select count(*)::int from public.messages m
      where m.client_id = c.client_id and m.dietitian_id = auth.uid()
        and m.sender_id = c.client_id and m.read_at is null)
  from my_clients c
  left join lateral (
    -- latest weigh-in vs. the most recent one at least 7 days earlier (or the previous one)
    select
      (select weight_kg from public.weight_entries
        where client_id = c.client_id order by measured_on desc limit 1) as latest,
      coalesce(
        (select weight_kg from public.weight_entries
          where client_id = c.client_id
            and measured_on <= (select max(measured_on) from public.weight_entries
                                 where client_id = c.client_id) - 7
          order by measured_on desc limit 1),
        (select weight_kg from public.weight_entries
          where client_id = c.client_id order by measured_on desc offset 1 limit 1)
      ) as previous
  ) w on true
$$;

-- Functions are executable by PUBLIC by default; restrict to signed-in users.
revoke execute on all functions in schema public, private from public, anon;
grant execute on function
  public.get_invite_preview(text),
  public.accept_invite(text, text),
  public.leave_dietitian(),
  public.remove_client(uuid),
  public.assign_meal_plan(uuid, uuid, date, date),
  public.has_premium(uuid),
  public.dietitian_client_overview(),
  public.submit_verification(text),
  public.admin_review_verification(uuid, boolean, text),
  public.admin_pending_verifications(),
  public.my_workspace_status(),
  -- called from policies, so the caller needs EXECUTE (schema is not API-exposed)
  private.has_active_link(uuid, uuid),
  private.is_dietitian_of(uuid),
  private.has_active_dietitian(uuid),
  private.is_dietitian(),
  private.can_read_plan(uuid),
  private.can_write_plan(uuid),
  private.is_admin(),
  private.storage_client_id(text)
to authenticated;

-- =============================================================================
-- Notification triggers
-- =============================================================================
create function private.notify_on_message() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.notify(
    case when new.sender_id = new.client_id then new.dietitian_id else new.client_id end,
    'message',
    coalesce((select full_name from public.profiles where id = new.sender_id), 'New message'),
    coalesce(left(new.body, 140), 'Sent a photo'),
    jsonb_build_object('client_id', new.client_id, 'message_id', new.id));
  return new;
end $$;
create trigger messages_notify after insert on public.messages
  for each row execute function private.notify_on_message();

create function private.notify_on_change() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.notify(new.client_id, 'change', 'Update from your dietitian', new.summary,
    jsonb_build_object('audit_id', new.id, 'entity', new.entity));
  return new;
end $$;
create trigger audit_log_notify after insert on public.audit_log
  for each row execute function private.notify_on_change();

create function private.notify_on_target_request() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.notify(new.dietitian_id, 'target_request', 'Target change requested',
      left(new.message, 140), jsonb_build_object('client_id', new.client_id, 'request_id', new.id));
  elsif new.status <> old.status then
    perform private.notify(new.client_id, 'target_request',
      case new.status when 'resolved' then 'Your target request was handled'
                      else 'Your target request was declined' end,
      coalesce(new.response, ''), jsonb_build_object('request_id', new.id));
  end if;
  return new;
end $$;
create trigger target_requests_notify after insert or update on public.target_change_requests
  for each row execute function private.notify_on_target_request();

create function private.notify_on_broadcast() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_client uuid; v_name text;
begin
  select full_name into v_name from public.profiles where id = new.dietitian_id;
  for v_client in
    select client_id from public.client_links where dietitian_id = new.dietitian_id and status = 'active'
  loop
    perform private.notify(v_client, 'broadcast',
      format('%s from %s', initcap(new.category), coalesce(v_name, 'your dietitian')),
      new.title, jsonb_build_object('broadcast_id', new.id));
  end loop;
  return new;
end $$;
create trigger broadcasts_notify after insert on public.broadcasts
  for each row execute function private.notify_on_broadcast();

create function private.stamp_target_request() returns trigger
language plpgsql as $$
begin
  if new.status <> old.status then
    new.resolved_at := case when new.status = 'open' then null else now() end;
  end if;
  return new;
end $$;
create trigger target_requests_stamp before update on public.target_change_requests
  for each row execute function private.stamp_target_request();

-- =============================================================================
-- Storage: meal-photos/{client_id}/..., message-photos/{client_id}/...,
--          credentials/{dietitian_id}/...
-- =============================================================================
insert into storage.buckets (id, name, public)
values ('meal-photos', 'meal-photos', false), ('message-photos', 'message-photos', false),
       ('credentials', 'credentials', false),
       ('avatars', 'avatars', true)   -- profile photos: public URLs, owner-only writes
on conflict (id) do nothing;

create policy avatars_write on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and private.storage_client_id(name) = (select auth.uid()));
create policy avatars_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and private.storage_client_id(name) = (select auth.uid()));
create policy avatars_read on storage.objects for select to authenticated
  using (bucket_id = 'avatars');

create policy credentials_read on storage.objects for select to authenticated
  using (bucket_id = 'credentials'
         and (private.storage_client_id(name) = (select auth.uid()) or private.is_admin()));
create policy credentials_write on storage.objects for insert to authenticated
  with check (bucket_id = 'credentials'
              and private.storage_client_id(name) = (select auth.uid())
              and private.is_dietitian());

create policy meal_photos_read on storage.objects for select to authenticated
  using (bucket_id = 'meal-photos'
         and (private.storage_client_id(name) = (select auth.uid())
              or private.is_dietitian_of(private.storage_client_id(name))));
create policy meal_photos_write on storage.objects for insert to authenticated
  with check (bucket_id = 'meal-photos' and private.storage_client_id(name) = (select auth.uid()));
create policy meal_photos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'meal-photos' and private.storage_client_id(name) = (select auth.uid()));

create policy message_photos_read on storage.objects for select to authenticated
  using (bucket_id = 'message-photos'
         and (private.storage_client_id(name) = (select auth.uid())
              or private.is_dietitian_of(private.storage_client_id(name))));
create policy message_photos_write on storage.objects for insert to authenticated
  with check (bucket_id = 'message-photos'
              and private.has_active_dietitian(private.storage_client_id(name))
              and (private.storage_client_id(name) = (select auth.uid())
                   or private.is_dietitian_of(private.storage_client_id(name))));

-- Realtime for chat, the change-history feed and notifications.
alter publication supabase_realtime add table
  public.messages, public.audit_log, public.notifications, public.target_change_requests, public.broadcasts;
