-- =============================================================================
-- Nouri: find a dietitian (directory, requests, ratings)
--
--   * Clients browse verified dietitians and send a request. The dietitian
--     accepts or declines. Invite codes keep working as before.
--   * Requests can be sent even when the dietitian is full (it shows demand);
--     only accepting is limited by capacity.
--   * The client agrees to the consent text when sending the request; the link
--     created on acceptance records that version.
--   * Before acceptance the dietitian sees only the client's name and message.
--   * Clients who worked with a dietitian for at least 14 days can rate them.
--     Reviews are shown without names.
--   * Everything is free: no prices or payments here.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Profile fields shown in the directory
-- -----------------------------------------------------------------------------
alter table public.dietitian_profiles
  add column city             text check (char_length(city) <= 60),
  add column years_experience smallint check (years_experience between 0 and 60),
  add column works_online     boolean not null default true,
  add column works_in_person  boolean not null default false,
  add column listed           boolean not null default true,    -- appear in "Find a dietitian"
  add column capacity         int check (capacity between 1 and 1000);  -- own client limit; null = none

grant update (city, years_experience, works_online, works_in_person, listed, capacity)
  on public.dietitian_profiles to authenticated;

-- Effective limit: the dietitian's own capacity, and at most 3 until verified.
create or replace function private.client_limit(p_dietitian uuid) returns int
language sql stable security definer set search_path = '' as $$
  select case
    when d.verification_status = 'approved' then d.capacity
    else least(3, coalesce(d.capacity, 3))
  end
  from public.dietitian_profiles d where d.user_id = p_dietitian
$$;

create function private.active_client_count(p_dietitian uuid) returns int
language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.client_links where dietitian_id = p_dietitian and status = 'active'
$$;

-- -----------------------------------------------------------------------------
-- Requests
-- -----------------------------------------------------------------------------
create type public.connection_request_status as enum ('pending', 'accepted', 'declined', 'cancelled');

create table public.connection_requests (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null references public.profiles (id) on delete cascade,
  dietitian_id    uuid not null references public.dietitian_profiles (user_id) on delete cascade,
  message         text check (char_length(message) <= 500),
  consent_version text not null,
  status          public.connection_request_status not null default 'pending',
  decline_reason  text check (char_length(decline_reason) <= 300),
  created_at      timestamptz not null default now(),
  responded_at    timestamptz
);
-- One open request per client at a time.
create unique index connection_requests_one_pending
  on public.connection_requests (client_id) where status = 'pending';
create index on public.connection_requests (dietitian_id, status, created_at desc);

-- For links made from a request: when the client agreed to the consent text.
alter table public.client_links add column consent_at_request timestamptz;

alter table public.connection_requests enable row level security;
-- Both sides can read their own requests; all changes go through the RPCs below.
create policy conn_req_select on public.connection_requests for select to authenticated
  using (client_id = (select auth.uid()) or dietitian_id = (select auth.uid()));
revoke insert, update, delete on public.connection_requests from authenticated, anon;

-- -----------------------------------------------------------------------------
-- Ratings
-- -----------------------------------------------------------------------------
create table public.dietitian_ratings (
  id           uuid primary key default gen_random_uuid(),
  link_id      uuid not null unique references public.client_links (id) on delete cascade,
  dietitian_id uuid not null references public.dietitian_profiles (user_id) on delete cascade,
  client_id    uuid not null references public.profiles (id) on delete cascade,
  stars        smallint not null check (stars between 1 and 5),
  comment      text check (char_length(comment) <= 500),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index on public.dietitian_ratings (dietitian_id);

alter table public.dietitian_ratings enable row level security;
-- A client sees their own ratings. Everyone else reads them through
-- dietitian_reviews(), which leaves out who wrote them.
create policy ratings_select on public.dietitian_ratings for select to authenticated
  using (client_id = (select auth.uid()));
revoke insert, update, delete on public.dietitian_ratings from authenticated, anon;

-- The client's most recent link with this dietitian that lasted 14+ days.
create function private.rateable_link(p_client uuid, p_dietitian uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select id from public.client_links
   where client_id = p_client and dietitian_id = p_dietitian
     and coalesce(ended_at, now()) - started_at >= interval '14 days'
   order by started_at desc limit 1
$$;

-- -----------------------------------------------------------------------------
-- Consent text (same as the invite flow)
-- -----------------------------------------------------------------------------
create function public.consent_info()
returns table (consent_version text, shared_data text[], after_leaving text[])
language sql stable security definer set search_path = '' as $$
  select consent_version, shared_data, after_leaving from (
    select private.consent_version() as consent_version,
           array[
             'Your profile answers: goal, body details, eating preferences, allergies and health notes',
             'Your food log, including meal photos and satiety/energy ratings',
             'Your weight and body measurement history',
             'Your water intake',
             'Progress charts built from the data above',
             'Messages you exchange with your dietitian',
             'Requests you send about your targets'
           ] as shared_data,
           array[
             'You can leave at any time from the "My Dietitian" tab.',
             'When you leave, your dietitian immediately loses access to your food log, weight, measurements, water, photos and messages.',
             'Nothing you log after leaving is ever visible to them.',
             'Your dietitian keeps their own private notes about you and copies of the meal plans they wrote for you.',
             'You keep everything your dietitian shared with you: plans, recommendations, comments and the change history.'
           ] as after_leaving
  ) c
$$;

-- -----------------------------------------------------------------------------
-- Directory
-- -----------------------------------------------------------------------------
-- Verified, listed dietitians. Best rated first (dietitians with few ratings
-- are pulled towards the average so one 5-star review doesn't top the list).
create function public.list_dietitians(p_query text default null)
returns table (
  dietitian_id uuid, full_name text, photo_url text, title text, specialties text[], bio text,
  city text, years_experience smallint, works_online boolean, works_in_person boolean,
  rating_avg numeric, rating_count int, is_full boolean, my_request text, is_my_dietitian boolean
)
language sql stable security definer set search_path = '' as $$
  with r as (
    select dietitian_id, avg(stars)::numeric as avg, count(*)::int as n
      from public.dietitian_ratings group by dietitian_id
  )
  select d.user_id, p.full_name, coalesce(d.photo_url, p.avatar_url), d.title, d.specialties, d.bio,
         d.city, d.years_experience, d.works_online, d.works_in_person,
         round(r.avg, 1), coalesce(r.n, 0),
         private.client_limit(d.user_id) is not null
           and private.active_client_count(d.user_id) >= private.client_limit(d.user_id),
         (select q.status::text from public.connection_requests q
           where q.client_id = auth.uid() and q.dietitian_id = d.user_id
           order by q.created_at desc limit 1),
         private.has_active_link(d.user_id, auth.uid())
    from public.dietitian_profiles d
    join public.profiles p on p.id = d.user_id
    left join r on r.dietitian_id = d.user_id
   where d.listed and d.verification_status = 'approved'
     and (coalesce(trim(p_query), '') = ''
          or private.fold_tr(concat_ws(' ', p.full_name, d.title, d.city, d.bio, array_to_string(d.specialties, ' ')))
             like '%' || private.fold_tr(trim(p_query)) || '%')
   order by (coalesce(r.avg, 0) * coalesce(r.n, 0) + 4 * 3) / (coalesce(r.n, 0) + 3) desc,
            coalesce(r.n, 0) desc, p.full_name
$$;

-- Anonymous reviews of one dietitian.
create function public.dietitian_reviews(p_dietitian uuid)
returns table (stars smallint, comment text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select stars, comment, updated_at from public.dietitian_ratings
   where dietitian_id = p_dietitian
   order by updated_at desc limit 50
$$;

-- -----------------------------------------------------------------------------
-- Client: send / cancel a request, rate
-- -----------------------------------------------------------------------------
create function public.request_dietitian(p_dietitian uuid, p_message text, p_consent_version text)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid  uuid := auth.uid();
  v_name text;
  v_id   uuid;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if coalesce(trim(p_consent_version), '') = '' then raise exception 'consent is required'; end if;
  if p_consent_version <> private.consent_version() then
    raise exception 'consent text has changed, please review it again';
  end if;
  select full_name into v_name from public.profiles where id = v_uid and role = 'client';
  if not found then raise exception 'only client accounts can join a dietitian'; end if;
  if not exists (select 1 from public.dietitian_profiles
                  where user_id = p_dietitian and listed and verification_status = 'approved') then
    raise exception 'this dietitian is not accepting requests';
  end if;
  if private.has_active_link(p_dietitian, v_uid) then
    raise exception 'this is already your dietitian';
  end if;
  if exists (select 1 from public.connection_requests where client_id = v_uid and status = 'pending') then
    raise exception 'you already have a pending request';
  end if;
  if exists (select 1 from public.connection_requests
              where client_id = v_uid and dietitian_id = p_dietitian and status = 'declined'
                and responded_at > now() - interval '7 days') then
    raise exception 'this dietitian declined your request recently, please try again later';
  end if;

  insert into public.connection_requests (client_id, dietitian_id, message, consent_version)
  values (v_uid, p_dietitian, nullif(trim(p_message), ''), p_consent_version)
  returning id into v_id;

  perform private.notify(p_dietitian, 'link_request', 'New client request',
    format('%s wants to work with you', coalesce(v_name, 'A client')),
    jsonb_build_object('request_id', v_id));
  return v_id;
end $$;

create function public.cancel_dietitian_request() returns void
language sql security definer set search_path = '' as $$
  update public.connection_requests set status = 'cancelled', responded_at = now()
   where client_id = auth.uid() and status = 'pending'
$$;

create function public.rate_dietitian(p_dietitian uuid, p_stars int, p_comment text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_link uuid := private.rateable_link(auth.uid(), p_dietitian);
begin
  if v_link is null then
    raise exception 'you can rate a dietitian after working with them for 14 days';
  end if;
  if p_stars not between 1 and 5 then raise exception 'rating must be 1 to 5 stars'; end if;
  insert into public.dietitian_ratings (link_id, dietitian_id, client_id, stars, comment)
  values (v_link, p_dietitian, auth.uid(), p_stars, nullif(trim(p_comment), ''))
  on conflict (link_id) do update
    set stars = excluded.stars, comment = excluded.comment, updated_at = now();
end $$;

-- Dietitians the caller can rate (or update their rating for).
create function public.my_rateable_dietitians()
returns table (dietitian_id uuid, full_name text, my_stars smallint, my_comment text)
language sql stable security definer set search_path = '' as $$
  select distinct on (l.dietitian_id) l.dietitian_id, p.full_name, r.stars, r.comment
    from public.client_links l
    join public.profiles p on p.id = l.dietitian_id
    left join public.dietitian_ratings r on r.link_id = l.id
   where l.client_id = auth.uid()
     and coalesce(l.ended_at, now()) - l.started_at >= interval '14 days'
   order by l.dietitian_id, l.started_at desc
$$;

-- -----------------------------------------------------------------------------
-- Dietitian: see and answer requests
-- -----------------------------------------------------------------------------
create function public.my_connection_requests()
returns table (request_id uuid, client_name text, client_avatar text, message text,
               created_at timestamptz, has_dietitian boolean)
language sql stable security definer set search_path = '' as $$
  select q.id, p.full_name, p.avatar_url, q.message, q.created_at,
         private.has_active_dietitian(q.client_id)
    from public.connection_requests q
    join public.profiles p on p.id = q.client_id
   where q.dietitian_id = auth.uid() and q.status = 'pending'
   order by q.created_at
$$;

create function public.respond_to_request(p_request uuid, p_accept boolean, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  q      public.connection_requests;
  v_name text;
  v_old  public.client_links;
  v_link uuid;
begin
  select * into q from public.connection_requests
   where id = p_request and dietitian_id = auth.uid() and status = 'pending' for update;
  if not found then raise exception 'request not found or already answered'; end if;

  if not p_accept then
    update public.connection_requests
       set status = 'declined', responded_at = now(), decline_reason = nullif(trim(p_reason), '')
     where id = q.id;
    perform private.notify(q.client_id, 'link', 'Your request was declined',
      coalesce(nullif(trim(p_reason), ''), 'The dietitian cannot take you on right now.'),
      jsonb_build_object('dietitian_id', q.dietitian_id));
    return null;
  end if;

  perform pg_advisory_xact_lock(hashtext(q.dietitian_id::text));
  if private.client_limit(q.dietitian_id) is not null
     and private.active_client_count(q.dietitian_id) >= private.client_limit(q.dietitian_id) then
    raise exception 'your client list is full, raise your capacity or end a client first';
  end if;

  -- Joining a new dietitian ends the previous connection (the client was told
  -- this when sending the request).
  update public.client_links set status = 'ended', ended_at = now(), ended_by = q.client_id
   where client_id = q.client_id and status = 'active'
  returning * into v_old;
  if found then
    perform private.notify(v_old.dietitian_id, 'link', 'Client left',
      format('%s left your workspace', coalesce(v_old.client_display_name, 'A client')),
      jsonb_build_object('client_id', v_old.client_id));
  end if;

  select full_name into v_name from public.profiles where id = q.client_id;
  insert into public.client_links (dietitian_id, client_id, consent_version, consent_at_request, client_display_name)
  values (q.dietitian_id, q.client_id, q.consent_version, q.created_at, v_name)
  returning id into v_link;

  update public.connection_requests set status = 'accepted', responded_at = now() where id = q.id;

  perform private.notify(q.client_id, 'link', 'Your request was accepted',
    format('You are now connected with %s', coalesce((select full_name from public.profiles where id = q.dietitian_id), 'your dietitian')),
    jsonb_build_object('dietitian_id', q.dietitian_id));
  return v_link;
end $$;

-- -----------------------------------------------------------------------------
-- Former clients, shown as "inactive" in the dietitian's client list
-- -----------------------------------------------------------------------------
create function public.dietitian_former_clients()
returns table (client_id uuid, client_name text, started_at timestamptz, ended_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select distinct on (l.client_id) l.client_id, l.client_display_name, l.started_at, l.ended_at
    from public.client_links l
   where l.dietitian_id = auth.uid() and l.status = 'ended'
     and not private.has_active_link(auth.uid(), l.client_id)
   order by l.client_id, l.ended_at desc
$$;

-- -----------------------------------------------------------------------------
revoke execute on all functions in schema public, private from public, anon;
grant execute on function
  public.consent_info(),
  public.list_dietitians(text),
  public.dietitian_reviews(uuid),
  public.request_dietitian(uuid, text, text),
  public.cancel_dietitian_request(),
  public.rate_dietitian(uuid, int, text),
  public.my_rateable_dietitians(),
  public.my_connection_requests(),
  public.respond_to_request(uuid, boolean, text),
  public.dietitian_former_clients()
to authenticated;
