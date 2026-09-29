alter table public.registrations
  add column if not exists admin_fee numeric(10,2) not null default 0 check (admin_fee >= 0),
  add column if not exists shipping_fee numeric(10,2) not null default 0 check (shipping_fee >= 0);

comment on column public.registrations.admin_fee is
  'Event-configured online registration administration fee captured at checkout.';

comment on column public.registrations.shipping_fee is
  'Event-configured shipping fee captured at checkout for virtual categories.';

create or replace function public.apply_external_registration_fees()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  fee_config jsonb;
  configured_admin numeric(10,2) := 0;
  configured_shipping numeric(10,2) := 0;
  current_shipping numeric(10,2) := 0;
  category_is_virtual boolean := false;
begin
  if coalesce(new.registration_channel, '') <> 'online' then
    return new;
  end if;

  select es.content #> '{externalRegistration,fees}'
  into fee_config
  from public.event_settings es
  where es.id = new.event_id
  limit 1;

  if fee_config is null or jsonb_typeof(fee_config) <> 'object' then
    return new;
  end if;

  begin
    configured_admin := round(coalesce(nullif(fee_config ->> 'adminFee', '')::numeric, 0), 2);
    configured_shipping := round(coalesce(nullif(fee_config ->> 'virtualShippingFee', '')::numeric, 0), 2);
  exception when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'The event checkout fee settings are invalid.';
  end;

  if configured_admin < 0 or configured_admin > 1000000
    or configured_shipping < 0 or configured_shipping > 1000000 then
    raise exception 'The event checkout fees must be between PHP 0 and PHP 1,000,000.';
  end if;

  select exists (
    select 1
    from public.event_categories ec
    where ec.id = new.category_id
      and ec.event_id = new.event_id
      and ec.category_type = 'virtual'
  ) into category_is_virtual;

  new.admin_fee := configured_admin;
  new.shipping_fee := case when category_is_virtual then configured_shipping else 0 end;

  if category_is_virtual then
    current_shipping := greatest(round(
      coalesce(new.total_amount, 0)
        + coalesce(new.discount_amount, 0)
        - greatest(coalesce(new.race_fee, 0) - coalesce(new.statutory_discount_amount, 0), 0)
        - coalesce(new.product_total, 0),
      2
    ), 0);
    new.total_amount := greatest(round(
      coalesce(new.total_amount, 0)
        + configured_admin
        + configured_shipping
        - current_shipping,
      2
    ), 0);
  else
    new.total_amount := greatest(round(coalesce(new.total_amount, 0) + configured_admin, 2), 0);
  end if;

  return new;
end;
$$;

revoke all on function public.apply_external_registration_fees() from public, anon, authenticated;

drop trigger if exists registrations_z_apply_external_fees on public.registrations;
create trigger registrations_z_apply_external_fees
before insert on public.registrations
for each row
execute function public.apply_external_registration_fees();

update public.event_settings
set content = jsonb_set(
  coalesce(content, '{}'::jsonb),
  '{externalRegistration}',
  coalesce(content -> 'externalRegistration', '{}'::jsonb)
    || jsonb_build_object(
      'fees',
      coalesce(content #> '{externalRegistration,fees}', '{}'::jsonb)
        || jsonb_build_object('adminFee', 25, 'virtualShippingFee', 100)
    ),
  true
)
where id = 'mcdonalds-neon-run-2026';
