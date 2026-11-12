-- =============================================================================
-- Nouri: first-run questions (onboarding)
--
-- New clients answer a few questions (goal, body, activity, eating style,
-- allergies, health notes, habits) so the app can suggest targets and tips.
-- The answers live on the client's own profile row, so the existing RLS
-- applies: the client reads and edits them; a linked dietitian can read them.
-- Because the dietitian sees them, the consent text now lists them (new
-- consent version).
-- =============================================================================

alter table public.profiles
  add column goal             text check (goal in ('lose', 'maintain', 'gain', 'healthy')),
  add column goal_pace        text check (goal_pace in ('slow', 'normal')),
  add column target_weight_kg numeric(5,2) check (target_weight_kg between 30 and 300),
  add column activity_level   text check (activity_level in ('sedentary', 'light', 'moderate', 'active', 'athlete')),
  add column diet_preferences text[] not null default '{}',   -- vegetarian, vegan, pescatarian, gluten_free, lactose_free, halal
  add column allergies        text[] not null default '{}',   -- nuts, peanuts, milk, egg, gluten, seafood, soy, sesame, or free text
  add column health_flags     text[] not null default '{}',   -- pregnant, diabetes, kidney, eating_disorder, under_18, other
  add column challenges       text[] not null default '{}',   -- night_snacking, low_water, irregular_meals, portions, sweets, eating_out
  add column meals_per_day    smallint check (meals_per_day between 1 and 8),
  add column onboarded_at     timestamptz;

grant update (goal, goal_pace, target_weight_kg, activity_level, diet_preferences, allergies,
              health_flags, challenges, meals_per_day, onboarded_at)
  on public.profiles to authenticated;

-- People who were already using the app don't get the questions forced on
-- them (they can answer them from their profile).
update public.profiles set onboarded_at = created_at where onboarded_at is null;

-- Consent: the dietitian now also sees the profile answers.
create or replace function private.consent_version() returns text
language sql immutable as $$ select '2026-10-25' $$;

create or replace function public.get_invite_preview(p_code text)
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
           'Your profile answers: goal, body details, eating preferences, allergies and health notes',
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

revoke execute on all functions in schema public, private from public, anon;
grant execute on function public.get_invite_preview(text) to authenticated;
