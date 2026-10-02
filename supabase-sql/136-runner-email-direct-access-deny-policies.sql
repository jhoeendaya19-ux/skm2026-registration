create policy "No direct authenticated campaign access"
  on public.runner_email_campaigns
  for all
  to authenticated
  using (false)
  with check (false);

create policy "No direct authenticated recipient access"
  on public.runner_email_campaign_recipients
  for all
  to authenticated
  using (false)
  with check (false);

comment on policy "No direct authenticated campaign access" on public.runner_email_campaigns is
  'Campaign access is intentionally restricted to the authenticated Edge Function.';

comment on policy "No direct authenticated recipient access" on public.runner_email_campaign_recipients is
  'Recipient access is intentionally restricted to the authenticated Edge Function.';
