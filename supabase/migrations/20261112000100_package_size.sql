-- =============================================================================
-- Nouri: package size for barcode products
--
-- Open Food Facts gives a "serving" (often a suggested 30 g) and the package
-- quantity ("52 g"). Packaged snacks are usually eaten as a whole package, so
-- barcode products now get a "paket" measure from the label quantity.
--
-- When the package size is missing or wrong, any signed-in user can set it
-- from the package label. That changes only how many grams one package is,
-- never the nutrition values (those still come only from the label data or a
-- verified dietitian). Every change is kept in food_revisions.
-- =============================================================================

alter table public.portion_units drop constraint portion_units_unit_check;
alter table public.portion_units add constraint portion_units_unit_check check (unit in (
  'adet', 'dilim', 'su bardağı', 'çay bardağı', 'yemek kaşığı', 'tatlı kaşığı',
  'çay kaşığı', 'kase', 'kepçe', 'porsiyon', 'avuç', 'ml', 'paket'));

alter table public.portion_units drop constraint portion_units_source_check;
alter table public.portion_units add constraint portion_units_source_check
  check (source in ('usda_fdc', 'open_food_facts', 'dietitian', 'user_label'));

alter table public.food_revisions drop constraint food_revisions_action_check;
alter table public.food_revisions add constraint food_revisions_action_check
  check (action in ('create', 'update', 'verify', 'unverify', 'package_size'));

create function public.set_package_size(p_food uuid, p_grams numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  f      public.foods;
  v_old  numeric;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into f from public.foods where id = p_food;
  if not found then raise exception 'food not found'; end if;
  if f.barcode is null then raise exception 'package size can only be set for packaged (barcode) products'; end if;
  if p_grams is null or p_grams <= 0 or p_grams > 5000 then
    raise exception 'package size must be between 1 and 5000 g';
  end if;

  select grams_per_unit into v_old from public.portion_units where food_id = p_food and unit = 'paket' and size is null;
  if v_old is not null and exists (select 1 from public.portion_units
                                    where food_id = p_food and unit = 'paket' and source = 'dietitian') then
    raise exception 'a dietitian has set this package size';
  end if;

  delete from public.portion_units where food_id = p_food and unit = 'paket';
  insert into public.portion_units (food_id, unit, grams_per_unit, source, source_note, sort)
  values (p_food, 'paket', round(p_grams, 1), 'user_label',
          'Package size entered by a user from the label; not checked by a dietitian', -1);

  insert into public.food_revisions (food_id, changed_by, action, before, after)
  values (p_food, auth.uid(), 'package_size',
          jsonb_build_object('paket_g', v_old), jsonb_build_object('paket_g', round(p_grams, 1)));
  return private.food_json(p_food);
end $$;

revoke execute on all functions in schema public, private from public, anon;
grant execute on function public.set_package_size(uuid, numeric) to authenticated;
