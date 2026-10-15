begin;

-- Production readiness is determined when payment is approved, not when the
-- runner first submitted the form. Use Philippine-local approval dates for
-- both new and edited supplier batches.
do $$
declare
  function_name text;
  function_definition text;
  match_count integer;
  source_pattern text := 'r\.created_at >= p_cutoff_start::timestamptz\s+and r\.created_at < \(p_cutoff_end::timestamptz \+ interval ''1 day''\)';
  replacement text := '(r.approved_at at time zone ''Asia/Manila'')::date between p_cutoff_start and p_cutoff_end';
begin
  foreach function_name in array array['admin_create_production_batch', 'admin_update_production_batch']
  loop
    select pg_get_functiondef(p.oid)
    into function_definition
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = function_name;

    if function_definition is null then
      raise exception 'Required function public.% was not found.', function_name;
    end if;

    match_count := regexp_count(function_definition, source_pattern);
    if match_count <> 2 then
      raise exception 'Expected 2 registration-date predicates in public.%, found %.', function_name, match_count;
    end if;

    function_definition := regexp_replace(function_definition, source_pattern, replacement, 'g');
    execute function_definition;
  end loop;
end;
$$;

-- Keep approved runners searchable even before they enter a supplier batch.
create or replace function public.admin_sync_unbatched_fulfillment(p_event_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  unbatched_package_count integer := 0;
  promoted_package_count integer := 0;
begin
  if not public.can_access_fulfillment(p_event_id, true) then
    raise exception 'You are not authorized to synchronize approved runners for this event.';
  end if;

  -- Packages first created before batching move into supplier receiving as soon
  -- as the production batch is assigned by the regular synchronization pass.
  update public.fulfillment_packages fp
  set status = 'awaiting_supplier_delivery',
      updated_at = now()
  from public.registrations r
  where fp.registration_id = r.id
    and fp.event_id = p_event_id
    and fp.status = 'awaiting_production_batch'
    and coalesce(r.production_locked, false) = true
    and r.production_batch_id is not null;

  get diagnostics promoted_package_count = row_count;

  insert into public.fulfillment_packages (
    event_id, registration_id, reference_number, runner_name, runner_email,
    race_category, category_type, bib_number, delivery_mode, claiming_city,
    supplier_batch_id, supplier_batch_name, status, is_active, last_synced_at
  )
  select
    r.event_id,
    r.id,
    r.reference_number,
    r.full_name,
    r.email,
    r.race_category,
    case
      when coalesce(ec.category_type, '') = 'virtual' or r.race_category ilike '%virtual%' then 'virtual'
      else 'physical'
    end,
    r.bib_number,
    case
      when coalesce(ec.category_type, '') = 'virtual' or r.race_category ilike '%virtual%' then 'shipment'
      else 'claiming'
    end,
    public.normalize_fulfillment_city(
      case when coalesce(ec.category_type, '') = 'virtual' or r.race_category ilike '%virtual%' then 'virtual' else 'physical' end,
      r.race_kit_delivery_method,
      r.race_kit_claiming_site
    ),
    null,
    null,
    'awaiting_production_batch',
    true,
    now()
  from public.registrations r
  left join public.event_categories ec on ec.id = r.category_id
  where r.event_id = p_event_id
    and r.payment_status = 'approved'
    and r.voided_at is null
    and coalesce(r.is_test_registration, false) = false
    and upper(coalesce(r.onsite_control_number, '')) not like 'TEST-%'
    and coalesce(r.production_locked, false) = false
  on conflict (registration_id) do update
  set reference_number = excluded.reference_number,
      runner_name = excluded.runner_name,
      runner_email = excluded.runner_email,
      race_category = excluded.race_category,
      category_type = excluded.category_type,
      bib_number = excluded.bib_number,
      delivery_mode = excluded.delivery_mode,
      claiming_city = excluded.claiming_city,
      is_active = true,
      last_synced_at = now(),
      updated_at = now();

  get diagnostics unbatched_package_count = row_count;

  insert into public.fulfillment_items (
    package_id, event_id, registration_id, source_type, source_key,
    production_batch_id, production_batch_name, item_name, variant,
    quantity, is_addon, is_active
  )
  select
    fp.id, r.event_id, r.id, 'category_inclusion', inclusion.source_key,
    null, null, inclusion.item_name, inclusion.variant, 1, false, true
  from public.fulfillment_packages fp
  join public.registrations r on r.id = fp.registration_id
  join lateral (
    select ec.*
    from public.event_categories ec
    where ec.event_id = r.event_id
      and coalesce(ec.is_deleted, false) = false
      and (
        ec.id = r.category_id
        or regexp_replace(lower(trim(ec.name)), '[^a-z0-9]+', '', 'g') =
           regexp_replace(lower(trim(coalesce(r.race_category, ''))), '[^a-z0-9]+', '', 'g')
      )
    order by case when ec.id = r.category_id then 0 else 1 end, ec.sort_order, ec.created_at
    limit 1
  ) ec on true
  cross join lateral (
    select 'category:singlet'::text, 'Singlet'::text,
      coalesce(nullif(upper(trim(coalesce(r.singlet_size, ''))), ''), 'SIZE MISSING')::text
      where ec.includes_singlet
    union all
    select 'category:finisher-shirt', 'Finisher Shirt',
      coalesce(nullif(upper(trim(coalesce(r.finisher_shirt_size, ''))), ''), 'SIZE MISSING')
      where ec.includes_finisher_shirt
    union all
    select 'category:medal', 'Finisher Medal', null::text where ec.includes_medal
    union all
    select 'category:bib', 'Race Bib',
      coalesce(nullif(trim(coalesce(r.bib_number, '')), ''), 'BIB MISSING')
      where ec.requires_bib_number
  ) inclusion(source_key, item_name, variant)
  where fp.event_id = p_event_id
    and fp.is_active = true
    and fp.status = 'awaiting_production_batch'
  on conflict (package_id, source_key) do update
  set production_batch_id = excluded.production_batch_id,
      production_batch_name = excluded.production_batch_name,
      item_name = excluded.item_name,
      variant = excluded.variant,
      quantity = excluded.quantity,
      is_addon = false,
      is_active = true,
      updated_at = now();

  insert into public.fulfillment_items (
    package_id, event_id, registration_id, source_type, source_key,
    production_batch_id, production_batch_name, item_name, variant,
    quantity, is_addon, is_active
  )
  select
    fp.id, r.event_id, r.id, 'registration_addon',
    'registration:addon:' || product_item.ordinality::text,
    null, null,
    coalesce(nullif(product_item.value ->> 'name', ''), 'Add-on'),
    nullif(upper(trim(coalesce(
      product_item.value ->> 'size_variant', product_item.value ->> 'variant',
      product_item.value ->> 'size', product_item.value ->> 'selected_size', ''
    ))), ''),
    greatest(1, coalesce(nullif(product_item.value ->> 'quantity', '')::integer, 1)),
    true,
    true
  from public.fulfillment_packages fp
  join public.registrations r on r.id = fp.registration_id
  cross join lateral jsonb_array_elements(coalesce(r.selected_products, '[]'::jsonb))
    with ordinality as product_item(value, ordinality)
  where fp.event_id = p_event_id
    and fp.is_active = true
    and fp.status = 'awaiting_production_batch'
  on conflict (package_id, source_key) do update
  set item_name = excluded.item_name,
      variant = excluded.variant,
      quantity = excluded.quantity,
      is_addon = true,
      is_active = true,
      updated_at = now();

  update public.fulfillment_packages fp
  set package_count = greatest(1, coalesce(batch_counts.batch_count, 1)),
      updated_at = now()
  from (
    select fi.package_id,
      count(distinct coalesce(fi.production_batch_id::text, 'unbatched'))::integer as batch_count
    from public.fulfillment_items fi
    where fi.event_id = p_event_id and fi.is_active = true
    group by fi.package_id
  ) batch_counts
  where fp.id = batch_counts.package_id;

  insert into public.fulfillment_audit_logs (event_id, action, note, metadata, actor_email)
  values (
    p_event_id,
    'sync_unbatched_approved',
    'Approved runners not yet assigned to production were synchronized for fulfillment visibility.',
    jsonb_build_object('unbatched_packages', unbatched_package_count, 'promoted_packages', promoted_package_count),
    actor_email
  );

  return jsonb_build_object(
    'ok', true,
    'unbatched_packages', unbatched_package_count,
    'promoted_packages', promoted_package_count
  );
end;
$$;

revoke all on function public.admin_sync_unbatched_fulfillment(text) from public;
grant execute on function public.admin_sync_unbatched_fulfillment(text) to authenticated;

-- Recover every currently approved SKM runner that was omitted from production.
do $$
declare
  recovery_batch_id uuid;
  affected_count integer;
  cutoff_start_value date;
  cutoff_end_value date;
begin
  select count(*)::integer,
         min((r.approved_at at time zone 'Asia/Manila')::date),
         max((r.approved_at at time zone 'Asia/Manila')::date)
  into affected_count, cutoff_start_value, cutoff_end_value
  from public.registrations r
  where r.event_id = 'skm2026'
    and r.payment_status = 'approved'
    and r.voided_at is null
    and coalesce(r.is_test_registration, false) = false
    and upper(coalesce(r.onsite_control_number, '')) not like 'TEST-%'
    and coalesce(r.production_locked, false) = false
    and not exists (
      select 1 from public.fulfillment_packages fp
      where fp.registration_id = r.id and fp.is_active = true
    );

  if affected_count > 0 then
    select pb.id into recovery_batch_id
    from public.production_batches pb
    where pb.event_id = 'skm2026'
      and pb.batch_name = 'Recovery Batch - Previously Omitted Approved Runners'
    limit 1;

    if recovery_batch_id is null then
      insert into public.production_batches (
        event_id, batch_name, cutoff_start, cutoff_end, status,
        runner_count, supplier_payable_total, created_by
      ) values (
        'skm2026', 'Recovery Batch - Previously Omitted Approved Runners',
        cutoff_start_value, cutoff_end_value, 'in_production',
        affected_count, 0, 'system-recovery@offgroundevents.com'
      ) returning id into recovery_batch_id;
    end if;

    update public.registrations r
    set production_batch_id = recovery_batch_id,
        production_batch_name = 'Recovery Batch - Previously Omitted Approved Runners',
        production_status = 'in_production',
        production_locked = true,
        production_locked_at = now(),
        production_locked_by = 'system-recovery@offgroundevents.com',
        updated_at = now()
    where r.event_id = 'skm2026'
      and r.payment_status = 'approved'
      and r.voided_at is null
      and coalesce(r.is_test_registration, false) = false
      and upper(coalesce(r.onsite_control_number, '')) not like 'TEST-%'
      and coalesce(r.production_locked, false) = false
      and not exists (
        select 1 from public.fulfillment_packages fp
        where fp.registration_id = r.id and fp.is_active = true
      );

    update public.production_batches pb
    set runner_count = (
          select count(*)::integer from public.registrations r
          where r.production_batch_id = recovery_batch_id
        ),
        updated_at = now()
    where pb.id = recovery_batch_id;

    insert into public.production_batch_email_recipients (
      batch_id, event_id, registration_id, reference_number, status
    )
    select recovery_batch_id, r.event_id, r.id, r.reference_number, 'pending'
    from public.registrations r
    where r.production_batch_id = recovery_batch_id
      and nullif(trim(coalesce(r.reference_number, '')), '') is not null
    on conflict on constraint production_batch_email_recipients_batch_id_reference_number_key do nothing;
  end if;
end;
$$;

-- Materialize packages for the recovery batch immediately; staff should not
-- need to press Sync before the omitted runners become searchable.
insert into public.fulfillment_packages (
  event_id, registration_id, reference_number, runner_name, runner_email,
  race_category, category_type, bib_number, delivery_mode, claiming_city,
  supplier_batch_id, supplier_batch_name, status, is_active, last_synced_at
)
select
  r.event_id, r.id, r.reference_number, r.full_name, r.email, r.race_category,
  case when coalesce(ec.category_type, '') = 'virtual' or r.race_category ilike '%virtual%' then 'virtual' else 'physical' end,
  r.bib_number,
  case when coalesce(ec.category_type, '') = 'virtual' or r.race_category ilike '%virtual%' then 'shipment' else 'claiming' end,
  public.normalize_fulfillment_city(
    case when coalesce(ec.category_type, '') = 'virtual' or r.race_category ilike '%virtual%' then 'virtual' else 'physical' end,
    r.race_kit_delivery_method,
    r.race_kit_claiming_site
  ),
  r.production_batch_id, r.production_batch_name,
  'awaiting_supplier_delivery', true, now()
from public.registrations r
left join public.event_categories ec on ec.id = r.category_id
where r.event_id = 'skm2026'
  and r.production_batch_name = 'Recovery Batch - Previously Omitted Approved Runners'
on conflict (registration_id) do update
set reference_number = excluded.reference_number,
    runner_name = excluded.runner_name,
    runner_email = excluded.runner_email,
    race_category = excluded.race_category,
    category_type = excluded.category_type,
    bib_number = excluded.bib_number,
    delivery_mode = excluded.delivery_mode,
    claiming_city = excluded.claiming_city,
    supplier_batch_id = excluded.supplier_batch_id,
    supplier_batch_name = excluded.supplier_batch_name,
    status = case
      when fulfillment_packages.status = 'awaiting_production_batch' then 'awaiting_supplier_delivery'
      else fulfillment_packages.status
    end,
    is_active = true,
    last_synced_at = now(),
    updated_at = now();

insert into public.fulfillment_items (
  package_id, event_id, registration_id, source_type, source_key,
  production_batch_id, production_batch_name, item_name, variant,
  quantity, is_addon, is_active
)
select
  fp.id, r.event_id, r.id, 'category_inclusion', inclusion.source_key,
  r.production_batch_id, r.production_batch_name, inclusion.item_name,
  inclusion.variant, 1, false, true
from public.fulfillment_packages fp
join public.registrations r on r.id = fp.registration_id
join lateral (
  select ec.*
  from public.event_categories ec
  where ec.event_id = r.event_id
    and coalesce(ec.is_deleted, false) = false
    and (
      ec.id = r.category_id
      or regexp_replace(lower(trim(ec.name)), '[^a-z0-9]+', '', 'g') =
         regexp_replace(lower(trim(coalesce(r.race_category, ''))), '[^a-z0-9]+', '', 'g')
    )
  order by case when ec.id = r.category_id then 0 else 1 end, ec.sort_order, ec.created_at
  limit 1
) ec on true
cross join lateral (
  select 'category:singlet'::text, 'Singlet'::text,
    coalesce(nullif(upper(trim(coalesce(r.singlet_size, ''))), ''), 'SIZE MISSING')::text
    where ec.includes_singlet
  union all
  select 'category:finisher-shirt', 'Finisher Shirt',
    coalesce(nullif(upper(trim(coalesce(r.finisher_shirt_size, ''))), ''), 'SIZE MISSING')
    where ec.includes_finisher_shirt
  union all
  select 'category:medal', 'Finisher Medal', null::text where ec.includes_medal
  union all
  select 'category:bib', 'Race Bib',
    coalesce(nullif(trim(coalesce(r.bib_number, '')), ''), 'BIB MISSING')
    where ec.requires_bib_number
) inclusion(source_key, item_name, variant)
where r.event_id = 'skm2026'
  and r.production_batch_name = 'Recovery Batch - Previously Omitted Approved Runners'
on conflict (package_id, source_key) do update
set production_batch_id = excluded.production_batch_id,
    production_batch_name = excluded.production_batch_name,
    item_name = excluded.item_name,
    variant = excluded.variant,
    quantity = excluded.quantity,
    is_addon = false,
    is_active = true,
    updated_at = now();

insert into public.fulfillment_items (
  package_id, event_id, registration_id, source_type, source_key,
  production_batch_id, production_batch_name, item_name, variant,
  quantity, is_addon, is_active
)
select
  fp.id, r.event_id, r.id, 'registration_addon',
  'registration:addon:' || product_item.ordinality::text,
  r.production_batch_id, r.production_batch_name,
  coalesce(nullif(product_item.value ->> 'name', ''), 'Add-on'),
  nullif(upper(trim(coalesce(
    product_item.value ->> 'size_variant', product_item.value ->> 'variant',
    product_item.value ->> 'size', product_item.value ->> 'selected_size', ''
  ))), ''),
  greatest(1, coalesce(nullif(product_item.value ->> 'quantity', '')::integer, 1)),
  true, true
from public.fulfillment_packages fp
join public.registrations r on r.id = fp.registration_id
cross join lateral jsonb_array_elements(coalesce(r.selected_products, '[]'::jsonb))
  with ordinality as product_item(value, ordinality)
where r.event_id = 'skm2026'
  and r.production_batch_name = 'Recovery Batch - Previously Omitted Approved Runners'
on conflict (package_id, source_key) do update
set production_batch_id = excluded.production_batch_id,
    production_batch_name = excluded.production_batch_name,
    item_name = excluded.item_name,
    variant = excluded.variant,
    quantity = excluded.quantity,
    is_addon = true,
    is_active = true,
    updated_at = now();

update public.fulfillment_packages fp
set package_count = greatest(1, coalesce(batch_counts.batch_count, 1)),
    updated_at = now()
from (
  select fi.package_id,
    count(distinct coalesce(fi.production_batch_id::text, 'unbatched'))::integer as batch_count
  from public.fulfillment_items fi
  where fi.event_id = 'skm2026' and fi.is_active = true
  group by fi.package_id
) batch_counts
where fp.id = batch_counts.package_id;

insert into public.fulfillment_audit_logs (event_id, action, note, metadata, actor_email)
select
  'skm2026',
  'recover_omitted_approved_runners',
  'Recovered approved bib-assigned runners omitted by registration-date production batching.',
  jsonb_build_object(
    'batch_name', 'Recovery Batch - Previously Omitted Approved Runners',
    'runner_count', count(*)
  ),
  'system-recovery@offgroundevents.com'
from public.registrations r
where r.event_id = 'skm2026'
  and r.production_batch_name = 'Recovery Batch - Previously Omitted Approved Runners';

commit;

