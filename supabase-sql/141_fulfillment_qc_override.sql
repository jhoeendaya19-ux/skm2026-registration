create or replace function public.admin_fulfillment_quality_check_override(
  p_package_id uuid,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  pkg public.fulfillment_packages%rowtype;
  old_status text;
  email_required boolean := false;
  already_completed boolean := false;
begin
  select fp.* into pkg
  from public.fulfillment_packages fp
  where fp.id = p_package_id
  for update;

  if not found then
    raise exception 'Fulfillment package was not found.';
  end if;

  if not public.can_access_fulfillment(pkg.event_id, true) then
    raise exception 'You are not authorized to update this fulfillment package.';
  end if;

  old_status := pkg.status;

  if pkg.status in ('quality_check_completed', 'shipped') then
    already_completed := true;
    email_required := pkg.category_type = 'physical'
      and pkg.claim_stub_issued_at is not null
      and pkg.claim_stub_email_sent_at is null;
  elsif pkg.status not in (
    'ready_for_sorting',
    'sorting_in_progress',
    'apparel_sorting_completed',
    'bib_included'
  ) then
    raise exception 'Only received, unreleased packages can use the quality-check override.';
  elsif exists (
    select 1
    from public.fulfillment_items fi
    where fi.package_id = p_package_id
      and fi.is_active
      and fi.item_status = 'awaiting_supplier_delivery'
  ) then
    raise exception 'Receive every supplier order represented in this package before using the override.';
  elsif pkg.category_type = 'physical'
    and nullif(trim(coalesce(pkg.bib_number, '')), '') is null then
    raise exception 'This physical runner has no bib number. Correct the registration before completing quality control.';
  else
    email_required := pkg.category_type = 'physical'
      and pkg.claim_stub_email_sent_at is null;

    update public.fulfillment_packages fp
    set status = 'quality_check_completed',
        qc_status = 'passed',
        qc_failure_reason = null,
        qc_passed_at = coalesce(fp.qc_passed_at, now()),
        qc_passed_by = coalesce(fp.qc_passed_by, actor_email),
        quality_check_completed_at = coalesce(fp.quality_check_completed_at, now()),
        quality_check_completed_by = coalesce(fp.quality_check_completed_by, actor_email),
        bib_not_applicable = case when fp.category_type = 'virtual' then true else fp.bib_not_applicable end,
        claim_token = case when fp.category_type = 'physical' then coalesce(fp.claim_token, gen_random_uuid()) else null end,
        claim_stub_issued_at = case when fp.category_type = 'physical' then coalesce(fp.claim_stub_issued_at, now()) else null end,
        claim_stub_issued_by = case when fp.category_type = 'physical' then coalesce(fp.claim_stub_issued_by, actor_email) else null end,
        claim_on_hold = false,
        hold_reason = null,
        held_at = null,
        held_by = null,
        updated_at = now()
    where fp.id = p_package_id;

    update public.fulfillment_items fi
    set item_status = 'quality_check_completed',
        qc_status = 'passed',
        qc_failure_reason = null,
        quality_check_completed_at = coalesce(fi.quality_check_completed_at, now()),
        quality_check_completed_by = coalesce(fi.quality_check_completed_by, actor_email),
        updated_at = now()
    where fi.package_id = p_package_id
      and fi.is_active;

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
      pkg.event_id,
      pkg.id,
      pkg.registration_id,
      'complete_quality_check_override',
      old_status,
      'quality_check_completed',
      'Rush override: quality check completed directly without intermediate sorting scans.',
      coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object(
        'rush_override', true,
        'skipped_from_status', old_status
      ),
      actor_email
    );
  end if;

  select fp.* into pkg
  from public.fulfillment_packages fp
  where fp.id = p_package_id;

  return jsonb_build_object(
    'ok', true,
    'package_id', pkg.id,
    'reference_number', pkg.reference_number,
    'category_type', pkg.category_type,
    'status', pkg.status,
    'claim_token', pkg.claim_token,
    'claim_on_hold', pkg.claim_on_hold,
    'email_required', email_required,
    'already_completed', already_completed,
    'package', to_jsonb(pkg)
  );
end;
$function$;

revoke all on function public.admin_fulfillment_quality_check_override(uuid, jsonb) from public;
revoke all on function public.admin_fulfillment_quality_check_override(uuid, jsonb) from anon;
grant execute on function public.admin_fulfillment_quality_check_override(uuid, jsonb) to authenticated;

comment on function public.admin_fulfillment_quality_check_override(uuid, jsonb) is
  'Allows authorized fulfillment staff to move a received, unreleased package directly to quality-check completed while preserving claim-stub issuance and an explicit audit entry.';

