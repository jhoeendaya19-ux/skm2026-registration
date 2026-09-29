create or replace function public.enforce_registration_category_change_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_global_role text := coalesce(public.current_admin_role(), '');
  v_old_history_count integer := coalesce(jsonb_array_length(old.category_change_history), 0);
  v_new_history_count integer := coalesce(jsonb_array_length(new.category_change_history), 0);
  v_override_note text := nullif(trim(coalesce(new.edit_note, '')), '');
  v_last_history_index integer;
  v_source_category_type text := 'physical';
  v_target_category_type text := 'physical';
  v_current_shipping numeric(10,2) := 0;
  v_target_shipping numeric(10,2) := 0;
  v_existing_balance numeric(10,2) := 0;
  v_adjusted_balance numeric(10,2) := 0;
begin
  if new.category_id is not distinct from old.category_id
    and new.race_category is not distinct from old.race_category then
    return new;
  end if;

  if exists (
    select 1
    from public.bib_print_items print_item
    where print_item.registration_id = old.id
      and print_item.event_id = old.event_id
      and print_item.state = 'printed'
  ) then
    raise exception 'This runner''s bib has already been printed. The race category cannot be changed.'
      using errcode = 'P0001';
  end if;

  if coalesce(old.production_locked, false) then
    if old.event_id <> 'skm2026' or v_global_role <> 'owner' then
      raise exception 'This registration is production-locked. Only the platform owner may override locked SKM2026 categories before bib printing.'
        using errcode = '42501';
    end if;

    if v_override_note is null or char_length(v_override_note) < 5 then
      raise exception 'A clear owner override reason of at least 5 characters is required.';
    end if;

    if v_new_history_count <= v_old_history_count then
      raise exception 'Use the registration category-change control so the locked owner override is recorded in the audit history.';
    end if;
  end if;

  if old.event_id = 'skm2026' then
    select coalesce(lower(category.category_type), 'physical')
    into v_source_category_type
    from public.event_categories category
    where category.id = old.category_id
      and category.event_id = old.event_id
    limit 1;

    select coalesce(lower(category.category_type), 'physical')
    into v_target_category_type
    from public.event_categories category
    where category.id = new.category_id
      and category.event_id = new.event_id
    limit 1;

    v_source_category_type := coalesce(v_source_category_type, 'physical');
    v_target_category_type := coalesce(v_target_category_type, 'physical');
    v_current_shipping := case
      when v_source_category_type = 'virtual' then greatest(coalesce(old.shipping_fee, 0), 100)
      else coalesce(old.shipping_fee, 0)
    end;
    v_target_shipping := case when v_target_category_type = 'virtual' then 100 else 0 end;
    v_existing_balance := greatest(coalesce(new.category_change_balance_due, 0), 0);
    v_adjusted_balance := greatest(v_existing_balance + v_target_shipping - v_current_shipping, 0);

    new.total_amount := greatest(
      round(coalesce(new.total_amount, 0) + v_adjusted_balance - v_existing_balance, 2),
      0
    );
    new.category_change_balance_due := v_adjusted_balance;
    new.shipping_fee := v_target_shipping;

    if v_target_category_type = 'virtual' then
      new.race_kit_delivery_method := 'shipping';
      new.shipping_region := coalesce(nullif(new.shipping_region, ''), new.address_region);
      new.shipping_province := coalesce(nullif(new.shipping_province, ''), new.address_province);
      new.shipping_city := coalesce(nullif(new.shipping_city, ''), new.address_city);
      new.shipping_barangay := coalesce(nullif(new.shipping_barangay, ''), new.address_barangay);
      new.shipping_street := coalesce(nullif(new.shipping_street, ''), new.address_street);
      new.shipping_contact_number := coalesce(nullif(new.shipping_contact_number, ''), new.contact_number);
      new.shipping_same_as_runner_address := true;
      new.shipping_address := coalesce(
        nullif(new.shipping_address, ''),
        nullif(concat_ws(', ',
          nullif(new.address_street, ''),
          nullif(new.address_barangay, ''),
          nullif(new.address_city, ''),
          nullif(new.address_province, ''),
          nullif(new.address_region, '')
        ), '')
      );
    else
      new.race_kit_delivery_method := 'pickup';
    end if;

    if v_adjusted_balance > 0 then
      new.payment_status := 'pending_payment_verification';
      new.approved_at := null;
      new.approved_by := null;
    elsif v_existing_balance > 0 then
      new.payment_status := old.payment_status;
      new.approved_at := old.approved_at;
      new.approved_by := old.approved_by;
    end if;
  end if;

  if coalesce(old.production_locked, false) then
    v_last_history_index := v_new_history_count - 1;
    new.category_change_history := jsonb_set(
      new.category_change_history,
      array[v_last_history_index::text],
      (new.category_change_history -> v_last_history_index) || jsonb_build_object(
        'owner_locked_override', true,
        'production_batch_id', old.production_batch_id,
        'production_batch_name', old.production_batch_name,
        'balance_due', new.category_change_balance_due,
        'shipping_fee', new.shipping_fee
      ),
      false
    );
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_registration_category_change_guard() from public, anon, authenticated;

create or replace function public.prevent_locked_production_registration_changes()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_is_category_change boolean := new.category_id is distinct from old.category_id
    or new.race_category is distinct from old.race_category;
  v_has_override_audit boolean := coalesce(jsonb_array_length(new.category_change_history), 0)
    > coalesce(jsonb_array_length(old.category_change_history), 0);
begin
  if not coalesce(old.production_locked, false) then
    return new;
  end if;

  if v_is_category_change
    and old.event_id = 'skm2026'
    and coalesce(public.current_admin_role(), '') = 'owner'
    and v_has_override_audit
    and nullif(trim(coalesce(new.edit_note, '')), '') is not null
    and char_length(trim(new.edit_note)) >= 5
    and new.singlet_size is not distinct from old.singlet_size
    and new.finisher_shirt_size is not distinct from old.finisher_shirt_size
  then
    return new;
  end if;

  raise exception 'Entitlements are already in production. Category, size, add-on, and fulfillment changes are locked.';
end;
$$;
