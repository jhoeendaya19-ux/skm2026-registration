alter table public.event_categories
  add column if not exists public_tag text,
  add column if not exists public_description text;

update public.event_categories
set
  public_tag = case
    when category_type = 'virtual' then 'YOUR PLACE. YOUR PACE.'
    when lower(name) like '%3k%' then 'EVERY PACE WELCOME'
    when lower(name) like '%5k%' then 'FIND YOUR STRIDE'
    when lower(name) like '%10k%' then 'THE MAIN EVENT'
    else coalesce(public_tag, 'YOUR EXPERIENCE')
  end,
  public_description = case
    when category_type = 'virtual' then 'Be part of the day wherever life takes you.'
    when lower(name) like '%3k%' then 'An easygoing route for friends, families, and first-timers.'
    when lower(name) like '%5k%' then 'A little further. A little faster. Make it your personal best.'
    when lower(name) like '%10k%' then 'Run farther, glow brighter, and own the full Neon Run experience.'
    else coalesce(public_description, '')
  end,
  updated_at = now()
where event_id = 'mcdonalds-neon-run-2026'
  and is_deleted = false;

update public.event_products
set
  name = 'Optional Finisher Shirt',
  description = 'Add the official finisher shirt to your race order.',
  applicable_category_ids = array(
    select category.id::text
    from public.event_categories category
    where category.event_id = 'mcdonalds-neon-run-2026'
      and category.is_deleted = false
    order by category.sort_order, category.name
  ),
  updated_at = now()
where event_id = 'mcdonalds-neon-run-2026'
  and lower(name) in ('extra event shirt', 'optional finisher shirt');

update public.event_settings
set
  content = coalesce(content, '{}'::jsonb) || jsonb_build_object(
    'formFields', coalesce(content -> 'formFields', '{}'::jsonb) || jsonb_build_object(
      'showLguAdmin', false
    ),
    'externalRegistration', coalesce(content -> 'externalRegistration', '{}'::jsonb) || jsonb_build_object(
      'featuredCategoryId', (
        select category.id::text
        from public.event_categories category
        where category.event_id = 'mcdonalds-neon-run-2026'
          and category.is_deleted = false
          and category.category_type = 'physical'
          and lower(category.name) like '%10k%'
        order by category.sort_order
        limit 1
      ),
      'kit', coalesce(content #> '{externalRegistration,kit}', '{}'::jsonb) || jsonb_build_object(
        'label', 'Singlet size'
      )
    )
  ),
  updated_at = now()
where id = 'mcdonalds-neon-run-2026';

create or replace function public.admin_void_test_registration(
  p_registration_id uuid,
  p_reason text
)
returns table (
  id uuid,
  reference_number text,
  payment_status text,
  is_test_registration boolean,
  test_registration_note text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_registration public.registrations%rowtype;
  v_actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_event_role text;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  if v_reason is null then
    raise exception 'A reason is required to void a test registration.';
  end if;

  select registration.*
  into v_registration
  from public.registrations registration
  where registration.id = p_registration_id
  for update;

  if not found then
    raise exception 'Registration not found.';
  end if;

  select event_admin.role
  into v_event_role
  from public.event_admins event_admin
  where event_admin.event_id = v_registration.event_id
    and lower(event_admin.email) = v_actor_email
  limit 1;

  if coalesce(public.current_admin_role(), '') <> 'owner'
    and coalesce(v_event_role, '') <> 'owner' then
    raise exception 'Only an event owner can void test registrations.' using errcode = '42501';
  end if;

  if coalesce(v_registration.production_locked, false) then
    raise exception 'This registration is already in production and cannot be voided.';
  end if;

  if not coalesce(v_registration.is_test_registration, false)
    and not coalesce(v_registration.onsite_control_number, '') ~* '^TEST-' then
    raise exception 'Only registrations already marked as tests can be voided with this action.';
  end if;

  if exists (
    select 1
    from public.fulfillment_packages package
    where package.registration_id = p_registration_id
      and package.is_active = true
  ) then
    raise exception 'This registration already has an active fulfillment package and cannot be voided.';
  end if;

  if exists (
    select 1
    from public.rfid_assignments assignment
    where assignment.registration_id = p_registration_id
      and assignment.is_active = true
  ) then
    raise exception 'This registration already has an active RFID assignment and cannot be voided.';
  end if;

  return query
  update public.registrations registration
  set
    payment_status = 'rejected',
    is_test_registration = true,
    test_registration_note = 'VOIDED: ' || v_reason,
    approved_at = null,
    approved_by = null,
    edited_at = now(),
    edited_by = v_actor_email,
    edit_note = 'Test registration voided: ' || v_reason,
    admin_note = concat_ws(E'\n', nullif(registration.admin_note, ''), 'Test registration voided: ' || v_reason),
    updated_at = now()
  where registration.id = p_registration_id
  returning
    registration.id,
    registration.reference_number,
    registration.payment_status,
    registration.is_test_registration,
    registration.test_registration_note;
end;
$$;

revoke all on function public.admin_void_test_registration(uuid, text) from public;
grant execute on function public.admin_void_test_registration(uuid, text) to authenticated;
