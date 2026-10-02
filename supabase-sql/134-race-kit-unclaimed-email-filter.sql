create or replace function public.admin_race_kit_claiming_dashboard(p_event_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
begin
  if not public.can_access_fulfillment(p_event_id, false) then
    raise exception 'You are not authorized to access race kit claiming for this event.';
  end if;

  select jsonb_build_object(
    'roster', coalesce((
      select jsonb_agg(to_jsonb(roster_row) order by roster_row.claiming_city, roster_row.runner_name, roster_row.bib_number)
      from (
        select
          fp.id as package_id,
          fp.registration_id,
          fp.reference_number,
          fp.runner_name,
          fp.runner_email,
          fp.race_category,
          fp.bib_number,
          fp.claiming_city,
          fp.status,
          fp.qc_status,
          fp.claim_token,
          fp.claim_on_hold,
          fp.hold_reason,
          fp.released_at,
          fp.released_by,
          r.medical_clearance_required,
          r.medical_clearance_status,
          ra.epc,
          ra.assignment_status as chip_status,
          ra.assigned_at as chip_assigned_at,
          cs.id as schedule_id,
          cs.venue,
          cs.schedule_details,
          cs.status as schedule_status,
          csm.email_status,
          csm.email_sent_at,
          rc.claimant_type,
          rc.claimant_name,
          rc.claimed_at,
          rc.medical_document_received_on_site,
          ci.id as open_issue_id,
          ci.issue_type as open_issue_type,
          ci.details as open_issue_details,
          (
            fp.status = 'quality_check_completed'
            and fp.qc_status = 'passed'
            and not coalesce(fp.claim_on_hold, false)
            and fp.released_at is null
            and ra.id is not null
            and ra.assignment_status = 'qc_passed'
            and nullif(trim(coalesce(ra.epc, '')), '') is not null
            and nullif(trim(coalesce(fp.runner_email, '')), '') is not null
            and ci.id is null
            and csm.id is null
          ) as schedule_eligible,
          case
            when fp.released_at is not null then 'Already claimed'
            when fp.claim_on_hold then 'Claim stub is on hold'
            when ci.id is not null then 'Kit concern is open'
            when csm.id is not null then 'Schedule already released'
            when ra.id is null or nullif(trim(coalesce(ra.epc, '')), '') is null then 'Timing chip not assigned'
            when ra.assignment_status <> 'qc_passed' then 'Chip assignment QC not passed'
            when nullif(trim(coalesce(fp.runner_email, '')), '') is null then 'Runner email is missing'
            else 'Ready for schedule release'
          end as eligibility_reason
        from public.fulfillment_packages fp
        join public.registrations r on r.id = fp.registration_id
        left join lateral (
          select assignment.*
          from public.rfid_assignments assignment
          where assignment.event_id = fp.event_id
            and assignment.registration_id = fp.registration_id
            and assignment.is_active
          order by assignment.assigned_at desc nulls last, assignment.created_at desc
          limit 1
        ) ra on true
        left join public.race_kit_claiming_schedule_members csm on csm.package_id = fp.id
        left join public.race_kit_claiming_schedules cs on cs.id = csm.schedule_id
        left join public.race_kit_claims rc on rc.package_id = fp.id
        left join public.race_kit_claiming_issues ci on ci.package_id = fp.id and ci.status = 'open'
        where fp.event_id = p_event_id
          and fp.is_active
          and fp.category_type = 'physical'
          and fp.qc_status = 'passed'
          and fp.status in ('quality_check_completed', 'released')
      ) roster_row
    ), '[]'::jsonb),
    'updates', coalesce((
      select jsonb_agg(to_jsonb(update_row) order by update_row.created_at desc)
      from (
        select u.id, u.change_type, u.schedule_ids, u.new_venue, u.new_schedule_details,
          u.message, u.created_by, u.created_at,
          count(ur.id)::integer as recipient_count,
          count(ur.id) filter (where ur.email_status = 'sent')::integer as emails_sent,
          count(ur.id) filter (where ur.email_status = 'failed')::integer as emails_failed,
          count(ur.id) filter (where ur.email_status in ('pending', 'sending'))::integer as emails_pending,
          count(ur.id) filter (where ur.email_status = 'skipped')::integer as emails_skipped
        from public.race_kit_claiming_updates u
        left join public.race_kit_claiming_update_recipients ur on ur.update_id = u.id
        where u.event_id = p_event_id
        group by u.id
      ) update_row
    ), '[]'::jsonb),
    'schedules', coalesce((
      select jsonb_agg(to_jsonb(schedule_row) order by schedule_row.released_at desc)
      from (
        select
          cs.id,
          cs.claiming_city,
          cs.venue,
          cs.schedule_details,
          cs.staff_note,
          cs.status,
          cs.released_at,
          cs.released_by,
          count(csm.id)::integer as runner_count,
          count(csm.id) filter (where csm.email_status = 'sent')::integer as emails_sent,
          count(csm.id) filter (
            where csm.email_status in ('failed', 'skipped')
              and csm.claimed_at is null
              and schedule_fp.released_at is null
          )::integer as emails_failed,
          count(csm.id) filter (
            where csm.email_status in ('pending', 'sending')
              and csm.claimed_at is null
              and schedule_fp.released_at is null
          )::integer as emails_pending,
          count(csm.id) filter (where csm.claimed_at is not null or schedule_fp.released_at is not null)::integer as kits_claimed,
          count(csm.id) filter (
            where csm.email_status = 'sent'
              and csm.claimed_at is null
              and schedule_fp.released_at is null
          )::integer as unclaimed_emailed_count,
          count(csm.id) filter (
            where csm.email_status in ('pending', 'failed', 'skipped', 'sending')
              and csm.claimed_at is null
              and schedule_fp.released_at is null
          )::integer as unclaimed_email_retry_count
        from public.race_kit_claiming_schedules cs
        left join public.race_kit_claiming_schedule_members csm on csm.schedule_id = cs.id
        left join public.fulfillment_packages schedule_fp on schedule_fp.id = csm.package_id
        where cs.event_id = p_event_id
        group by cs.id
      ) schedule_row
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

revoke all on function public.admin_race_kit_claiming_dashboard(text) from public, anon;
grant execute on function public.admin_race_kit_claiming_dashboard(text) to authenticated;
