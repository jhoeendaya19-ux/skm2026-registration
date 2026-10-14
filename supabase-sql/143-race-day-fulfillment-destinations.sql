create or replace function public.normalize_fulfillment_city(
  p_category_type text,
  p_delivery_method text,
  p_claiming_site text
)
returns text
language sql
immutable
as $fn$
  select case
    when lower(coalesce(p_category_type, '')) = 'virtual' then 'SHIPMENT'
    when lower(coalesce(p_claiming_site, '')) like '%day before%' then 'DAY BEFORE RACE DAY'
    when lower(coalesce(p_claiming_site, '')) like '%on race day%'
      or lower(trim(coalesce(p_claiming_site, ''))) = 'race day' then 'RACE DAY'
    when lower(coalesce(p_claiming_site, '')) like '%gubat%' then 'GUBAT'
    when lower(coalesce(p_claiming_site, '')) like '%irosin%' then 'IROSIN'
    when lower(coalesce(p_claiming_site, '')) like '%legazpi%' then 'LEGAZPI CITY'
    when lower(coalesce(p_claiming_site, '')) like '%sorsogon%' then 'SORSOGON CITY'
    else 'SORSOGON CITY'
  end;
$fn$;

update public.fulfillment_packages fp
set claiming_city = public.normalize_fulfillment_city(
      fp.category_type,
      r.race_kit_delivery_method,
      r.race_kit_claiming_site
    ),
    updated_at = now()
from public.registrations r
where r.id = fp.registration_id
  and fp.is_active = true
  and fp.category_type = 'physical'
  and lower(coalesce(r.race_kit_claiming_site, '')) like '%race day%'
  and fp.claiming_city is distinct from public.normalize_fulfillment_city(
    fp.category_type,
    r.race_kit_delivery_method,
    r.race_kit_claiming_site
  );

comment on function public.normalize_fulfillment_city(text, text, text) is
  'Normalizes fulfillment destinations while preserving separate day-before-race-day and race-day pickup worklists.';