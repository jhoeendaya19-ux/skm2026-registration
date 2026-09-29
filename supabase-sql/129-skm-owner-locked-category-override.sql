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

    v_last_history_index := v_new_history_count - 1;
    new.category_change_history := jsonb_set(
      new.category_change_history,
      array[v_last_history_index::text],
      (new.category_change_history -> v_last_history_index) || jsonb_build_object(
        'owner_locked_override', true,
        'production_batch_id', old.production_batch_id,
        'production_batch_name', old.production_batch_name
      ),
      false
    );
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_registration_category_change_guard() from public, anon, authenticated;

drop trigger if exists registrations_category_change_guard on public.registrations;
create trigger registrations_category_change_guard
before update of category_id, race_category on public.registrations
for each row
execute function public.enforce_registration_category_change_guard();

alter function public.admin_change_registration_category(uuid, uuid, text)
  set search_path = '';

revoke all on function public.admin_change_registration_category(uuid, uuid, text)
  from public, anon;
grant execute on function public.admin_change_registration_category(uuid, uuid, text)
  to authenticated;
