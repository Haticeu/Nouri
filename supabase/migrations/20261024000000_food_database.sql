-- =============================================================================
-- Nouri: food database (Phase 1)
--
--   * foods          per-100 g nutrition. Every number comes from a cited
--                    source (USDA FoodData Central, Open Food Facts, or a
--                    verified dietitian); dishes with no source are kept as
--                    `todo` rows with no values until a dietitian fills them.
--   * portion_units  Turkish household measures (adet, dilim, su bardağı,
--                    yemek kaşığı, kase, ...) as grams per unit, with source.
--   * food_revisions history of every dietitian change.
--
-- Everyone signed in can read foods; changes go through RPCs that only
-- verified dietitians (and admins) may call. Barcode products are cached
-- here by the lookup-barcode Edge Function (service role).
--
-- Also: the app is free, so the subscription tier no longer limits clients.
-- Only unverified dietitians stay capped at 3 active clients (safety).
-- =============================================================================

create extension if not exists pg_trgm with schema extensions;

create type public.food_source as enum ('usda_fdc', 'open_food_facts', 'dietitian', 'todo');

-- Lower-case and fold Turkish letters, so "corba" finds "çorba" and
-- "Isparta" / "ısparta" / "İSPARTA" are the same word.
create function private.fold_tr(p text) returns text
language sql immutable parallel safe set search_path = '' as $$
  select lower(translate(coalesce(p, ''),
    'İIıÇçĞğÖöŞşÜüÂâÎîÛû',
    'iiiccggoossuuaaiiuu'))
$$;

create table public.foods (
  id               uuid primary key default gen_random_uuid(),
  seed_key         text unique,                -- stable key for rows from supabase/seed
  name_tr          text not null check (length(trim(name_tr)) > 0),
  name_en          text not null check (length(trim(name_en)) > 0),
  aliases          text[] not null default '{}',
  category         text,
  brand            text,
  barcode          text unique check (barcode ~ '^[0-9]{8,14}$'),
  is_liquid        boolean not null default false,
  -- per 100 g (for liquids too; ml <-> g is in portion_units)
  kcal_per_100g    numeric(6,1) check (kcal_per_100g between 0 and 900),
  protein_per_100g numeric(5,2) check (protein_per_100g between 0 and 100),
  carbs_per_100g   numeric(5,2) check (carbs_per_100g between 0 and 100),
  fat_per_100g     numeric(5,2) check (fat_per_100g between 0 and 100),
  fiber_per_100g   numeric(5,2) check (fiber_per_100g between 0 and 100),
  source           public.food_source not null,
  source_ref       text,                       -- e.g. 'USDA FDC 171287 (SR Legacy)'
  source_note      text,                       -- e.g. 'Approximation: USDA "Soup, lentil"'
  verified         boolean not null default false,
  verified_by      uuid references public.profiles (id) on delete set null,
  verified_at      timestamptz,
  search_text      text not null default '',
  created_by       uuid references public.profiles (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  -- A food without a source has no numbers; every other food has all of them.
  constraint foods_values_match_source check (
    case when source = 'todo'
      then kcal_per_100g is null and protein_per_100g is null and carbs_per_100g is null and fat_per_100g is null
      else kcal_per_100g is not null and protein_per_100g is not null and carbs_per_100g is not null and fat_per_100g is not null
    end),
  constraint foods_todo_not_verified check (source <> 'todo' or not verified)
);
create index foods_search_trgm on public.foods using gin (search_text extensions.gin_trgm_ops);

create function private.foods_search_text() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.search_text := private.fold_tr(concat_ws(' ', new.name_tr, new.name_en,
    array_to_string(new.aliases, ' '), new.brand));
  new.updated_at := now();
  return new;
end $$;
create trigger foods_search_text before insert or update on public.foods
  for each row execute function private.foods_search_text();

create table public.portion_units (
  id             uuid primary key default gen_random_uuid(),
  food_id        uuid not null references public.foods (id) on delete cascade,
  unit           text not null check (unit in (
                   'adet', 'dilim', 'su bardağı', 'çay bardağı', 'yemek kaşığı', 'tatlı kaşığı',
                   'çay kaşığı', 'kase', 'kepçe', 'porsiyon', 'avuç', 'ml')),
  size           text check (size in ('küçük', 'orta', 'büyük')),  -- only for adet / dilim
  grams_per_unit numeric(7,2) not null check (grams_per_unit > 0 and grams_per_unit <= 5000),
  source         text not null check (source in ('usda_fdc', 'open_food_facts', 'dietitian')),
  source_note    text,                          -- e.g. 'USDA "1 cup" = 255 g, scaled to 200 ml'
  sort           smallint not null default 0
);
create unique index portion_units_unique on public.portion_units (food_id, unit, coalesce(size, ''));

create table public.food_revisions (
  id         uuid primary key default gen_random_uuid(),
  food_id    uuid not null references public.foods (id) on delete cascade,
  changed_by uuid references public.profiles (id) on delete set null,
  changed_at timestamptz not null default now(),
  action     text not null check (action in ('create', 'update', 'verify', 'unverify')),
  before     jsonb,
  after      jsonb
);
create index on public.food_revisions (food_id, changed_at desc);

-- How a logged entry was made, and which food/portion it came from. Nutrition
-- on the entry is still stored (computed from the food at logging time).
alter table public.food_entries
  add column food_id        uuid references public.foods (id) on delete set null,
  add column portion_unit   text,
  add column portion_amount numeric(8,2) check (portion_amount > 0),
  add column grams          numeric(8,1) check (grams > 0),
  add column source         text check (source in ('photo', 'voice', 'text', 'manual', 'barcode')),
  add column ai_raw         jsonb;

-- -----------------------------------------------------------------------------
-- RLS: shared reference data, readable by everyone signed in, written via RPCs
-- -----------------------------------------------------------------------------
alter table public.foods          enable row level security;
alter table public.portion_units  enable row level security;
alter table public.food_revisions enable row level security;

create function private.can_curate_foods() returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_admin() or exists (
    select 1 from public.dietitian_profiles
     where user_id = auth.uid() and verification_status = 'approved')
$$;

create policy foods_select on public.foods for select to authenticated using (true);
create policy portion_units_select on public.portion_units for select to authenticated using (true);
create policy food_revisions_select on public.food_revisions for select to authenticated
  using ((select private.can_curate_foods()));

revoke insert, update, delete on public.foods, public.portion_units, public.food_revisions from authenticated, anon;

-- -----------------------------------------------------------------------------
-- Search
-- -----------------------------------------------------------------------------
create function private.food_json(p_food uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select to_jsonb(f) - 'search_text' || jsonb_build_object('portions', coalesce((
           select jsonb_agg(jsonb_build_object('unit', u.unit, 'size', u.size,
                    'grams', u.grams_per_unit, 'source', u.source, 'source_note', u.source_note)
                  order by u.sort, u.grams_per_unit)
             from public.portion_units u where u.food_id = f.id), '[]'::jsonb))
    from public.foods f where f.id = p_food
$$;

-- Typo-tolerant search over Turkish and English names, aliases and brands.
-- Foods with values come first; `todo` rows last (they can't be logged yet).
create function public.search_foods(p_query text, p_limit int default 20)
returns setof jsonb
language sql stable security invoker set search_path = '' as $$
  with q as (select private.fold_tr(trim(p_query)) as q),
  hits as (
    select f.id, f.source, f.name_tr,
           greatest(extensions.similarity(f.search_text, q.q), extensions.word_similarity(q.q, f.search_text))
           -- exactly a name or alias ("yumurta" -> Haşlanmış yumurta)
           + case when exists (select 1 from unnest(f.aliases || array[f.name_tr, f.name_en]) a
                                where private.fold_tr(a) = q.q) then 1 else 0 end
           + case when f.search_text like q.q || '%' then 0.6
                  when strpos(f.search_text, ' ' || q.q) > 0 then 0.4
                  when strpos(f.search_text, q.q) > 0 then 0.2 else 0 end
           + case when f.verified then 0.05 else 0 end as score
      from public.foods f, q
     where length(q.q) >= 2
       and (strpos(f.search_text, q.q) > 0 or extensions.word_similarity(q.q, f.search_text) >= 0.45)
  )
  select private.food_json(h.id) || jsonb_build_object('score', round(h.score::numeric, 3))
    from hits h
   order by (h.source = 'todo'), h.score desc, length(h.name_tr)
   limit least(greatest(coalesce(p_limit, 20), 1), 50)
$$;

create function public.get_food(p_food uuid) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select private.food_json(f.id) from public.foods f where f.id = p_food
$$;

-- -----------------------------------------------------------------------------
-- Curation by verified dietitians
-- -----------------------------------------------------------------------------
-- p_data keys (all optional): name_tr, name_en, aliases[], category, is_liquid,
-- kcal_per_100g, protein_per_100g, carbs_per_100g, fat_per_100g, fiber_per_100g,
-- source_note, portions [{unit, size, grams}] (replaces the whole list).
create function private.apply_food_data(p_food uuid, p_data jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  f public.foods;
  v_numbers_changed boolean := false;
  k text;
  p jsonb;
begin
  select * into f from public.foods where id = p_food for update;
  foreach k in array array['kcal_per_100g', 'protein_per_100g', 'carbs_per_100g', 'fat_per_100g', 'fiber_per_100g'] loop
    if p_data ? k and (p_data ->> k)::numeric is distinct from (to_jsonb(f) ->> k)::numeric then
      v_numbers_changed := true;
    end if;
  end loop;

  update public.foods set
    name_tr          = coalesce(nullif(trim(p_data ->> 'name_tr'), ''), name_tr),
    name_en          = coalesce(nullif(trim(p_data ->> 'name_en'), ''), name_en),
    aliases          = case when p_data ? 'aliases'
                         then array(select trim(a) from jsonb_array_elements_text(p_data -> 'aliases') a where trim(a) <> '')
                         else aliases end,
    category         = case when p_data ? 'category' then nullif(trim(p_data ->> 'category'), '') else category end,
    is_liquid        = coalesce((p_data ->> 'is_liquid')::boolean, is_liquid),
    kcal_per_100g    = case when p_data ? 'kcal_per_100g'    then (p_data ->> 'kcal_per_100g')::numeric    else kcal_per_100g end,
    protein_per_100g = case when p_data ? 'protein_per_100g' then (p_data ->> 'protein_per_100g')::numeric else protein_per_100g end,
    carbs_per_100g   = case when p_data ? 'carbs_per_100g'   then (p_data ->> 'carbs_per_100g')::numeric   else carbs_per_100g end,
    fat_per_100g     = case when p_data ? 'fat_per_100g'     then (p_data ->> 'fat_per_100g')::numeric     else fat_per_100g end,
    fiber_per_100g   = case when p_data ? 'fiber_per_100g'   then (p_data ->> 'fiber_per_100g')::numeric   else fiber_per_100g end,
    source_note      = case when p_data ? 'source_note' then nullif(trim(p_data ->> 'source_note'), '') else source_note end,
    -- Numbers entered by a dietitian are the dietitian's, whatever the row came from.
    source           = case when v_numbers_changed then 'dietitian'::public.food_source else source end,
    source_ref       = case when v_numbers_changed
                         then concat_ws('; ', 'Dietitian ' || (select full_name from public.profiles where id = auth.uid()),
                                        case when source <> 'todo' then 'was ' || coalesce(source_ref, source::text) end)
                         else source_ref end
   where id = p_food;

  if p_data ? 'portions' then
    -- Keep rows whose grams didn't change (and their source); replace the rest.
    delete from public.portion_units u
     where u.food_id = p_food
       and not exists (
         select 1 from jsonb_array_elements(p_data -> 'portions') x
          where x ->> 'unit' = u.unit
            and coalesce(nullif(x ->> 'size', ''), '') = coalesce(u.size, '')
            and (x ->> 'grams')::numeric = u.grams_per_unit);
    for p in select * from jsonb_array_elements(p_data -> 'portions') loop
      insert into public.portion_units (food_id, unit, size, grams_per_unit, source, source_note, sort)
      values (p_food, p ->> 'unit', nullif(p ->> 'size', ''), (p ->> 'grams')::numeric, 'dietitian',
              'Set by a dietitian', 50)
      on conflict (food_id, unit, coalesce(size, '')) do nothing;
    end loop;
  end if;
end $$;

create function public.update_food(p_food uuid, p_data jsonb, p_verify boolean default false)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_before jsonb; v_after jsonb;
begin
  if not private.can_curate_foods() then
    raise exception 'only verified dietitians can edit foods';
  end if;
  v_before := private.food_json(p_food);
  if v_before is null then raise exception 'food not found'; end if;

  perform private.apply_food_data(p_food, coalesce(p_data, '{}'));
  update public.foods set
    verified    = p_verify and source <> 'todo',
    verified_by = case when p_verify and source <> 'todo' then auth.uid() end,
    verified_at = case when p_verify and source <> 'todo' then now() end
   where id = p_food;

  v_after := private.food_json(p_food);
  insert into public.food_revisions (food_id, changed_by, action, before, after)
  values (p_food, auth.uid(), 'update', v_before, v_after);
  return v_after;
end $$;

create function public.verify_food(p_food uuid, p_verified boolean default true)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_before jsonb; v_after jsonb;
begin
  if not private.can_curate_foods() then
    raise exception 'only verified dietitians can verify foods';
  end if;
  v_before := private.food_json(p_food);
  if v_before is null then raise exception 'food not found'; end if;
  if p_verified and v_before ->> 'source' = 'todo' then
    raise exception 'add the nutrition values before verifying this food';
  end if;

  update public.foods set
    verified = p_verified,
    verified_by = case when p_verified then auth.uid() end,
    verified_at = case when p_verified then now() end
   where id = p_food;

  v_after := private.food_json(p_food);
  insert into public.food_revisions (food_id, changed_by, action, before, after)
  values (p_food, auth.uid(), case when p_verified then 'verify' else 'unverify' end, v_before, v_after);
  return v_after;
end $$;

create function public.create_food(p_data jsonb, p_verify boolean default false)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_after jsonb;
begin
  if not private.can_curate_foods() then
    raise exception 'only verified dietitians can add foods';
  end if;
  insert into public.foods (name_tr, name_en, source, source_ref, created_by,
                            kcal_per_100g, protein_per_100g, carbs_per_100g, fat_per_100g)
  values (trim(p_data ->> 'name_tr'), coalesce(nullif(trim(p_data ->> 'name_en'), ''), trim(p_data ->> 'name_tr')),
          'dietitian', 'Dietitian ' || (select full_name from public.profiles where id = auth.uid()), auth.uid(),
          (p_data ->> 'kcal_per_100g')::numeric, (p_data ->> 'protein_per_100g')::numeric,
          (p_data ->> 'carbs_per_100g')::numeric, (p_data ->> 'fat_per_100g')::numeric)
  returning id into v_id;
  perform private.apply_food_data(v_id, p_data - 'kcal_per_100g' - 'protein_per_100g' - 'carbs_per_100g' - 'fat_per_100g');
  if p_verify then
    update public.foods set verified = true, verified_by = auth.uid(), verified_at = now() where id = v_id;
  end if;
  v_after := private.food_json(v_id);
  insert into public.food_revisions (food_id, changed_by, action, after) values (v_id, auth.uid(), 'create', v_after);
  return v_after;
end $$;

-- Dietitian "Foods" screen: counts for the filter chips.
create function public.food_stats()
returns table (total int, todo int, unverified int, verified int)
language sql stable security invoker set search_path = '' as $$
  select count(*)::int,
         count(*) filter (where source = 'todo')::int,
         count(*) filter (where source <> 'todo' and not verified)::int,
         count(*) filter (where verified)::int
    from public.foods
$$;

-- -----------------------------------------------------------------------------
-- Free app: no tier limit. Unverified dietitians stay capped at 3 clients;
-- verified dietitians have no limit (NULL).
-- -----------------------------------------------------------------------------
create or replace function private.client_limit(p_dietitian uuid) returns int
language sql stable security definer set search_path = '' as $$
  select case
    when (select verification_status from public.dietitian_profiles where user_id = p_dietitian) = 'approved'
      then null
    else 3
  end
$$;

-- accept_invite compares `count >= client_limit`; NULL (no limit) never blocks.

revoke execute on all functions in schema public, private from public, anon;
grant execute on function
  public.search_foods(text, int),
  public.get_food(uuid),
  public.update_food(uuid, jsonb, boolean),
  public.verify_food(uuid, boolean),
  public.create_food(jsonb, boolean),
  public.food_stats(),
  private.fold_tr(text),
  private.food_json(uuid),
  private.can_curate_foods()
to authenticated;
