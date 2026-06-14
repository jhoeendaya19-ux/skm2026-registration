-- Phase 6 race kit fulfillment fields.
-- Run this in Supabase SQL Editor before deploying the updated website.

alter table public.registrations
add column if not exists race_kit_delivery_method text
  check (race_kit_delivery_method in ('pickup', 'shipping')),
add column if not exists race_kit_claiming_site text
  check (
    race_kit_claiming_site is null
    or race_kit_claiming_site in ('Ayala Malls Legazpi', 'SM City Sorsogon', 'Beans N Grapes Gubat')
  ),
add column if not exists shipping_address text,
add column if not exists shipping_contact_number text,
add column if not exists shipping_status text not null default 'not_applicable'
  check (shipping_status in ('not_applicable', 'requested', 'for_booking', 'booked', 'in_transit', 'delivered')),
add column if not exists shipping_tracking_number text,
add column if not exists race_kit_fulfillment_status text not null default 'not_claimed'
  check (race_kit_fulfillment_status in ('not_claimed', 'claimed', 'for_shipping', 'shipped', 'delivered'));

create or replace function public.submit_registration(payload jsonb)
returns table(id uuid, reference_number text, payment_status text)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  new_id uuid;
  new_reference text;
  race_day date := date '2026-10-18';
  runner_birthdate date;
  runner_age integer;
  runner_is_minor boolean;
  kit_method text;
begin
  runner_birthdate := (payload ->> 'birthdate')::date;
  runner_age := date_part('year', age(race_day, runner_birthdate))::integer;
  runner_is_minor := runner_age < 18;
  kit_method := payload ->> 'race_kit_delivery_method';
  new_reference := 'SKM2026-' || lpad(nextval('registration_ref_seq')::text, 3, '0');

  if runner_is_minor and (
    nullif(payload ->> 'guardian_name', '') is null
    or nullif(payload ->> 'guardian_relationship', '') is null
    or nullif(payload ->> 'guardian_contact_number', '') is null
    or nullif(payload ->> 'parental_consent_path', '') is null
  ) then
    raise exception 'Parental consent details are required for minor participants.';
  end if;

  if kit_method = 'pickup' and nullif(payload ->> 'race_kit_claiming_site', '') is null then
    raise exception 'Race kit claiming site is required.';
  end if;

  if kit_method = 'shipping' and (
    nullif(payload ->> 'shipping_address', '') is null
    or nullif(payload ->> 'shipping_contact_number', '') is null
  ) then
    raise exception 'Shipping address and contact number are required.';
  end if;

  insert into public.registrations (
    reference_number,
    full_name,
    birthdate,
    age_on_race_day,
    sex,
    complete_address,
    contact_number,
    email,
    race_category,
    race_fee,
    singlet_size,
    team,
    emergency_contact_name,
    emergency_relationship,
    emergency_contact_number,
    add_finisher_shirt,
    finisher_shirt_size,
    add_warmer,
    warmer_size,
    add_tumbler,
    total_amount,
    payment_method,
    transaction_reference,
    proof_of_payment_path,
    race_kit_delivery_method,
    race_kit_claiming_site,
    shipping_address,
    shipping_contact_number,
    shipping_status,
    race_kit_fulfillment_status,
    is_minor,
    guardian_name,
    guardian_relationship,
    guardian_contact_number,
    parental_consent_path,
    waiver_accepted,
    privacy_accepted
  )
  values (
    new_reference,
    payload ->> 'full_name',
    runner_birthdate,
    runner_age,
    payload ->> 'sex',
    payload ->> 'complete_address',
    payload ->> 'contact_number',
    payload ->> 'email',
    payload ->> 'race_category',
    (payload ->> 'race_fee')::numeric,
    payload ->> 'singlet_size',
    nullif(payload ->> 'team', ''),
    payload ->> 'emergency_contact_name',
    payload ->> 'emergency_relationship',
    payload ->> 'emergency_contact_number',
    coalesce((payload ->> 'add_finisher_shirt')::boolean, false),
    nullif(payload ->> 'finisher_shirt_size', ''),
    coalesce((payload ->> 'add_warmer')::boolean, false),
    nullif(payload ->> 'warmer_size', ''),
    coalesce((payload ->> 'add_tumbler')::boolean, false),
    (payload ->> 'total_amount')::numeric,
    payload ->> 'payment_method',
    payload ->> 'transaction_reference',
    payload ->> 'proof_of_payment_path',
    kit_method,
    nullif(payload ->> 'race_kit_claiming_site', ''),
    nullif(payload ->> 'shipping_address', ''),
    nullif(payload ->> 'shipping_contact_number', ''),
    case when kit_method = 'shipping' then 'requested' else 'not_applicable' end,
    case when kit_method = 'shipping' then 'for_shipping' else 'not_claimed' end,
    runner_is_minor,
    nullif(payload ->> 'guardian_name', ''),
    nullif(payload ->> 'guardian_relationship', ''),
    nullif(payload ->> 'guardian_contact_number', ''),
    nullif(payload ->> 'parental_consent_path', ''),
    (payload ->> 'waiver_accepted')::boolean,
    (payload ->> 'privacy_accepted')::boolean
  )
  returning registrations.id into new_id;

  return query
  select new_id, new_reference, 'pending_payment_verification'::text;
end;
$fn$;

grant execute on function public.submit_registration(jsonb) to anon;
grant execute on function public.submit_registration(jsonb) to authenticated;
