begin;

alter table public.fulfillment_packages
  add column if not exists manual_added_at timestamptz,
  add column if not exists manual_added_by text,
  add column if not exists manual_add_note text;

create index if not exists fulfillment_packages_manual_added_idx
  on public.fulfillment_packages (event_id, manual_added_at desc)
  where manual_added_at is not null;

-- The approved-runner pre-batch queue was introduced after the original status
-- constraint. Keep the database constraint aligned with the current workflow.
alter table public.fulfillment_packages
  drop constraint if exists fulfillment_packages_status_check;

alter table public.fulfillment_packages
  add constraint fulfillment_packages_status_check check (
    status = any (array[
      'awaiting_production_batch'::text,
      'awaiting_supplier_delivery'::text,
      'ready_for_sorting'::text,
      'sorting_in_progress'::text,
      'apparel_sorting_completed'::text,
      'bib_included'::text,
      'quality_check_completed'::text,
      'released'::text,
      'shipped'::text
    ])
  );

create or replace function public.admin_search_fulfillment_candidates(
  p_event_id text,
  p_query text
)
returns table (
  registration_id uuid,
  reference_number text,
  runner_name text,
  runner_email text,
  bib_number text,
  race_category text,
  payment_status text,
  production_batch_name text,
  package_id uuid,
  fulfillment_status text,
  package_is_active boolean,
  is_manual boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  search_value text := lower(trim(coalesce(p_query, '')));
begin
  if not public.can_access_fulfillment(p_event_id, true) then
    raise exception 'You are not authorized to search fulfillment candidates for this event.';
  end if;

  if length(search_value) < 2 then
    raise exception 'Enter at least two characters of the runner name, reference, bib, or email.';
  end if;

  return query
  select
    r.id,
    r.reference_number,
    r.full_name,
    r.email,
    r.bib_number,
    r.race_category,
    r.payment_status,
    r.production_batch_name,
    fp.id,
    fp.status,
    coalesce(fp.is_active, false),
    fp.manual_added_at is not null
  from public.registrations r
  left join public.fulfillment_packages fp on fp.registration_id = r.id
  where r.event_id = p_event_id
    and r.voided_at is null
    and coalesce(r.is_test_registration, false) = false
    and upper(coalesce(r.onsite_control_number, '')) not like 'TEST-%'
    and r.payment_status in (
      'approved',
      'needs_correction',
      'needs_encoder_correction',
      'pending_payment_verification',
      'pending_onsite_verification'
    )
    and (
      strpos(lower(coalesce(r.full_name, '')), search_value) > 0
      or strpos(lower(coalesce(r.reference_number, '')), search_value) > 0
      or strpos(lower(coalesce(r.bib_number, '')), search_value) > 0
      or strpos(lower(coalesce(r.email, '')), search_value) > 0
    )
  order by
    case
      when lower(coalesce(r.reference_number, '')) = search_value then 0
      when lower(coalesce(r.bib_number, '')) = search_value then 1
      when lower(coalesce(r.full_name, '')) = search_value then 2
      else 3
    end,
    r.full_name,
    r.created_at desc
  limit 25;
end;
$$;

revoke all on function public.admin_search_fulfillment_candidates(text, text) from public;
grant execute on function public.admin_search_fulfillment_candidates(text, text) to authenticated;

create or replace function public.admin_add_runner_to_fulfillment(
  p_event_id text,
  p_registration_id uuid,
  p_note text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  runner public.registrations%rowtype;
  category public.event_categories%rowtype;
  package public.fulfillment_packages%rowtype;
  previous_status text;
  category_type_value text;
  delivery_mode_value text;
  claiming_city_value text;
  item_total integer := 0;
  already_in_workflow boolean := false;
  automatic_hold_reason text;
begin
  if not public.can_access_fulfillment(p_event_id, true) then
    raise exception 'You are not authorized to add runners to fulfillment for this event.';
  end if;

  select r.* into runner
  from public.registrations r
  where r.id = p_registration_id
    and r.event_id = p_event_id
  for update;

  if not found then
    raise exception 'Registration was not found for this event.';
  end if;

  if runner.voided_at is not null then
    raise exception 'Voided registrations cannot be added to fulfillment.';
  end if;

  if coalesce(runner.is_test_registration, false)
     or upper(coalesce(runner.onsite_control_number, '')) like 'TEST-%' then
    raise exception 'Test registrations cannot be added to live fulfillment.';
  end if;

  if runner.payment_status = 'rejected' then
    raise exception 'Rejected registrations cannot be added to fulfillment.';
  end if;

  if runner.payment_status not in (
    'approved',
    'needs_correction',
    'needs_encoder_correction',
    'pending_payment_verification',
    'pending_onsite_verification'
  ) then
    raise exception 'This registration status is not eligible for manual fulfillment.';
  end if;

  select ec.* into category
  from public.event_categories ec
  where ec.event_id = runner.event_id
    and coalesce(ec.is_deleted, false) = false
    and (
      ec.id = runner.category_id
      or regexp_replace(lower(trim(ec.name)), '[^a-z0-9]+', '', 'g') =
         regexp_replace(lower(trim(coalesce(runner.race_category, ''))), '[^a-z0-9]+', '', 'g')
    )
  order by case when ec.id = runner.category_id then 0 else 1 end,
           ec.sort_order,
           ec.created_at
  limit 1;

  if not found then
    raise exception 'The runner category could not be matched. Correct the category before adding this runner.';
  end if;

  category_type_value := case
    when coalesce(category.category_type, '') = 'virtual' or runner.race_category ilike '%virtual%' then 'virtual'
    else 'physical'
  end;
  delivery_mode_value := case when category_type_value = 'virtual' then 'shipment' else 'claiming' end;
  claiming_city_value := public.normalize_fulfillment_city(
    category_type_value,
    runner.race_kit_delivery_method,
    runner.race_kit_claiming_site
  );
  automatic_hold_reason := 'Registration approval pending (status: ' || replace(runner.payment_status, '_', ' ') || ').';

  select fp.* into package
  from public.fulfillment_packages fp
  where fp.registration_id = runner.id
  for update;

  if found then
    previous_status := package.status;
    if package.status in ('released', 'shipped') then
      raise exception 'This runner already has a completed fulfillment record and cannot be added again.';
    end if;
    if package.status in (
      'sorting_in_progress',
      'apparel_sorting_completed',
      'bib_included',
      'quality_check_completed'
    ) then
      already_in_workflow := true;
    end if;
  else
    previous_status := null;
  end if;

  if already_in_workflow then
    update public.fulfillment_packages fp
    set is_active = true,
        manual_added_at = coalesce(fp.manual_added_at, now()),
        manual_added_by = coalesce(fp.manual_added_by, actor_email),
        manual_add_note = coalesce(nullif(trim(coalesce(p_note, '')), ''), fp.manual_add_note),
        last_synced_at = now(),
        updated_at = now()
    where fp.id = package.id;

    update public.fulfillment_items fi
    set is_active = true,
        updated_at = now()
    where fi.package_id = package.id;

    return jsonb_build_object(
      'ok', true,
      'already_in_workflow', true,
      'package_id', package.id,
      'reference_number', package.reference_number,
      'status', package.status,
      'payment_status', runner.payment_status,
      'items', (
        select count(*) from public.fulfillment_items fi
        where fi.package_id = package.id and fi.is_active
      )
    );
  end if;

  insert into public.fulfillment_packages (
    event_id,
    registration_id,
    reference_number,
    runner_name,
    runner_email,
    race_category,
    category_type,
    bib_number,
    delivery_mode,
    claiming_city,
    supplier_batch_id,
    supplier_batch_name,
    status,
    qc_status,
    claim_on_hold,
    hold_reason,
    held_at,
    held_by,
    is_active,
    last_synced_at,
    manual_added_at,
    manual_added_by,
    manual_add_note
  ) values (
    runner.event_id,
    runner.id,
    runner.reference_number,
    runner.full_name,
    runner.email,
    runner.race_category,
    category_type_value,
    runner.bib_number,
    delivery_mode_value,
    claiming_city_value,
    runner.production_batch_id,
    coalesce(runner.production_batch_name, 'Manual / Unbatched'),
    'ready_for_sorting',
    'pending',
    runner.payment_status <> 'approved',
    case when runner.payment_status <> 'approved' then automatic_hold_reason else null end,
    case when runner.payment_status <> 'approved' then now() else null end,
    case when runner.payment_status <> 'approved' then actor_email else null end,
    true,
    now(),
    now(),
    actor_email,
    nullif(trim(coalesce(p_note, '')), '')
  )
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
      status = 'ready_for_sorting',
      qc_status = 'pending',
      qc_failure_reason = null,
      claim_on_hold = excluded.claim_on_hold,
      hold_reason = excluded.hold_reason,
      held_at = excluded.held_at,
      held_by = excluded.held_by,
      is_active = true,
      last_synced_at = now(),
      manual_added_at = coalesce(public.fulfillment_packages.manual_added_at, now()),
      manual_added_by = coalesce(public.fulfillment_packages.manual_added_by, actor_email),
      manual_add_note = coalesce(excluded.manual_add_note, public.fulfillment_packages.manual_add_note),
      updated_at = now()
  returning * into package;

  update public.fulfillment_items fi
  set is_active = false,
      updated_at = now()
  where fi.package_id = package.id;

  insert into public.fulfillment_items (
    package_id,
    event_id,
    registration_id,
    source_type,
    source_key,
    production_batch_id,
    production_batch_name,
    item_name,
    variant,
    quantity,
    is_addon,
    item_status,
    qc_status,
    is_active
  )
  select
    package.id,
    runner.event_id,
    runner.id,
    'category_inclusion',
    inclusion.source_key,
    runner.production_batch_id,
    coalesce(runner.production_batch_name, 'Manual / Unbatched'),
    inclusion.item_name,
    inclusion.variant,
    1,
    false,
    'ready_for_sorting',
    'pending',
    true
  from (
    select 'category:singlet'::text as source_key,
           'Singlet'::text as item_name,
           coalesce(nullif(upper(trim(coalesce(runner.singlet_size, ''))), ''), 'SIZE MISSING')::text as variant
      where category.includes_singlet
    union all
    select 'category:finisher-shirt',
           'Finisher Shirt',
           coalesce(nullif(upper(trim(coalesce(runner.finisher_shirt_size, ''))), ''), 'SIZE MISSING')
      where category.includes_finisher_shirt
    union all
    select 'category:medal', 'Finisher Medal', null::text
      where category.includes_medal
    union all
    select 'category:bib',
           'Race Bib',
           coalesce(nullif(trim(coalesce(runner.bib_number, '')), ''), 'BIB MISSING')
      where category.requires_bib_number
  ) inclusion
  on conflict (package_id, source_key) do update
  set production_batch_id = excluded.production_batch_id,
      production_batch_name = excluded.production_batch_name,
      item_name = excluded.item_name,
      variant = excluded.variant,
      quantity = excluded.quantity,
      is_addon = false,
      item_status = 'ready_for_sorting',
      qc_status = 'pending',
      qc_failure_reason = null,
      is_active = true,
      updated_at = now();

  insert into public.fulfillment_items (
    package_id,
    event_id,
    registration_id,
    source_type,
    source_key,
    production_batch_id,
    production_batch_name,
    item_name,
    variant,
    quantity,
    is_addon,
    item_status,
    qc_status,
    is_active
  )
  select
    package.id,
    runner.event_id,
    runner.id,
    'registration_addon',
    'registration:addon:' || product_item.ordinality::text,
    runner.production_batch_id,
    coalesce(runner.production_batch_name, 'Manual / Unbatched'),
    coalesce(nullif(product_item.value ->> 'name', ''), 'Add-on'),
    nullif(upper(trim(coalesce(
      product_item.value ->> 'size_variant',
      product_item.value ->> 'variant',
      product_item.value ->> 'size',
      product_item.value ->> 'selected_size',
      ''
    ))), ''),
    greatest(1, coalesce(nullif(product_item.value ->> 'quantity', '')::integer, 1)),
    true,
    'ready_for_sorting',
    'pending',
    true
  from jsonb_array_elements(coalesce(runner.selected_products, '[]'::jsonb))
    with ordinality as product_item(value, ordinality)
  on conflict (package_id, source_key) do update
  set production_batch_id = excluded.production_batch_id,
      production_batch_name = excluded.production_batch_name,
      item_name = excluded.item_name,
      variant = excluded.variant,
      quantity = excluded.quantity,
      is_addon = true,
      item_status = 'ready_for_sorting',
      qc_status = 'pending',
      qc_failure_reason = null,
      is_active = true,
      updated_at = now();

  insert into public.fulfillment_items (
    package_id,
    event_id,
    registration_id,
    source_type,
    source_id,
    source_key,
    production_batch_id,
    production_batch_name,
    item_name,
    variant,
    quantity,
    is_addon,
    item_status,
    qc_status,
    is_active
  )
  select
    package.id,
    order_row.event_id,
    order_row.registration_id,
    'locked_additional',
    order_row.id,
    'locked-additional:' || order_row.id::text || ':' || product_item.ordinality::text,
    order_row.production_batch_id,
    coalesce(order_row.production_batch_name, 'Manual / Unbatched'),
    coalesce(nullif(product_item.value ->> 'name', ''), 'Add-on'),
    nullif(upper(trim(coalesce(
      product_item.value ->> 'size_variant',
      product_item.value ->> 'variant',
      product_item.value ->> 'size',
      product_item.value ->> 'selected_size',
      ''
    ))), ''),
    greatest(1, coalesce(nullif(product_item.value ->> 'quantity', '')::integer, 1)),
    true,
    'ready_for_sorting',
    'pending',
    true
  from public.locked_additional_orders order_row
  cross join lateral jsonb_array_elements(coalesce(order_row.selected_products, '[]'::jsonb))
    with ordinality as product_item(value, ordinality)
  where order_row.registration_id = runner.id
    and order_row.status <> 'cancelled'
  on conflict (package_id, source_key) do update
  set source_id = excluded.source_id,
      production_batch_id = excluded.production_batch_id,
      production_batch_name = excluded.production_batch_name,
      item_name = excluded.item_name,
      variant = excluded.variant,
      quantity = excluded.quantity,
      is_addon = true,
      item_status = 'ready_for_sorting',
      qc_status = 'pending',
      qc_failure_reason = null,
      is_active = true,
      updated_at = now();

  select count(*)::integer into item_total
  from public.fulfillment_items fi
  where fi.package_id = package.id
    and fi.is_active;

  update public.fulfillment_packages fp
  set package_count = greatest(1, (
        select count(distinct coalesce(fi.production_batch_id::text, 'manual-unbatched'))::integer
        from public.fulfillment_items fi
        where fi.package_id = package.id and fi.is_active
      )),
      updated_at = now()
  where fp.id = package.id;

  insert into public.fulfillment_audit_logs (
    event_id,
    package_id,
    registration_id,
    action,
    from_status,
    to_status,
    note,
    metadata,
    actor_email
  ) values (
    runner.event_id,
    package.id,
    runner.id,
    'manual_add_to_fulfillment',
    previous_status,
    'ready_for_sorting',
    coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Corrected or late registration manually added to fulfillment.'),
    jsonb_build_object(
      'payment_status', runner.payment_status,
      'production_batch_id', runner.production_batch_id,
      'manual_unbatched', runner.production_batch_id is null,
      'items', item_total
    ),
    actor_email
  );

  return jsonb_build_object(
    'ok', true,
    'already_in_workflow', false,
    'package_id', package.id,
    'reference_number', runner.reference_number,
    'status', 'ready_for_sorting',
    'payment_status', runner.payment_status,
    'claim_on_hold', runner.payment_status <> 'approved',
    'items', item_total
  );
end;
$$;

revoke all on function public.admin_add_runner_to_fulfillment(text, uuid, text) from public;
grant execute on function public.admin_add_runner_to_fulfillment(text, uuid, text) to authenticated;

create or replace function public.admin_restore_manual_fulfillment(p_event_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  package_total integer := 0;
  item_total integer := 0;
begin
  if not public.can_access_fulfillment(p_event_id, true) then
    raise exception 'You are not authorized to restore manual fulfillment records for this event.';
  end if;

  update public.fulfillment_packages fp
  set reference_number = r.reference_number,
      runner_name = r.full_name,
      runner_email = r.email,
      race_category = r.race_category,
      bib_number = r.bib_number,
      claiming_city = public.normalize_fulfillment_city(
        fp.category_type,
        r.race_kit_delivery_method,
        r.race_kit_claiming_site
      ),
      is_active = (
        r.voided_at is null
        and coalesce(r.is_test_registration, false) = false
        and upper(coalesce(r.onsite_control_number, '')) not like 'TEST-%'
        and r.payment_status <> 'rejected'
      ),
      claim_on_hold = case
        when r.payment_status = 'approved'
             and coalesce(fp.hold_reason, '') like 'Registration approval pending%'
          then false
        when r.payment_status <> 'approved' and fp.released_at is null
          then true
        else fp.claim_on_hold
      end,
      hold_reason = case
        when r.payment_status = 'approved'
             and coalesce(fp.hold_reason, '') like 'Registration approval pending%'
          then null
        when r.payment_status <> 'approved' and fp.released_at is null
          then 'Registration approval pending (status: ' || replace(r.payment_status, '_', ' ') || ').'
        else fp.hold_reason
      end,
      held_at = case
        when r.payment_status = 'approved'
             and coalesce(fp.hold_reason, '') like 'Registration approval pending%'
          then null
        when r.payment_status <> 'approved' and fp.released_at is null
          then coalesce(fp.held_at, now())
        else fp.held_at
      end,
      held_by = case
        when r.payment_status = 'approved'
             and coalesce(fp.hold_reason, '') like 'Registration approval pending%'
          then null
        when r.payment_status <> 'approved' and fp.released_at is null
          then coalesce(fp.held_by, actor_email)
        else fp.held_by
      end,
      last_synced_at = now(),
      updated_at = now()
  from public.registrations r
  where fp.registration_id = r.id
    and fp.event_id = p_event_id
    and fp.manual_added_at is not null;

  get diagnostics package_total = row_count;

  update public.fulfillment_items fi
  set is_active = fp.is_active,
      updated_at = now()
  from public.fulfillment_packages fp
  where fi.package_id = fp.id
    and fp.event_id = p_event_id
    and fp.manual_added_at is not null;

  get diagnostics item_total = row_count;

  return jsonb_build_object(
    'ok', true,
    'manual_packages', package_total,
    'manual_items', item_total
  );
end;
$$;

revoke all on function public.admin_restore_manual_fulfillment(text) from public;
grant execute on function public.admin_restore_manual_fulfillment(text) to authenticated;

create or replace function public.guard_manual_fulfillment_final_qc()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  registration_status text;
begin
  if new.manual_added_at is null
     or new.status <> 'quality_check_completed'
     or old.status = 'quality_check_completed' then
    return new;
  end if;

  select r.payment_status into registration_status
  from public.registrations r
  where r.id = new.registration_id;

  if registration_status is distinct from 'approved' then
    raise exception 'Registration Verification must approve this runner before final QC and the claim stub can be completed.';
  end if;

  return new;
end;
$$;

drop trigger if exists guard_manual_fulfillment_final_qc_trigger
  on public.fulfillment_packages;

create trigger guard_manual_fulfillment_final_qc_trigger
before update of status on public.fulfillment_packages
for each row
execute function public.guard_manual_fulfillment_final_qc();

commit;

