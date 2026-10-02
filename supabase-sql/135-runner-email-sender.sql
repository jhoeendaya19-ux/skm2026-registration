create table if not exists public.runner_email_campaigns (
  id uuid primary key default gen_random_uuid(),
  event_id text not null references public.events(id) on delete cascade,
  subject text not null check (char_length(subject) between 3 and 180),
  body_text text not null check (char_length(body_text) between 10 and 8000),
  closing_text text not null check (char_length(closing_text) between 2 and 1000),
  filters jsonb not null default '{}'::jsonb,
  status text not null default 'ready'
    check (status in ('ready', 'sending', 'completed', 'completed_with_errors')),
  recipient_count integer not null default 0 check (recipient_count >= 0),
  sent_count integer not null default 0 check (sent_count >= 0),
  failed_count integer not null default 0 check (failed_count >= 0),
  skipped_count integer not null default 0 check (skipped_count >= 0),
  created_by text not null,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists public.runner_email_campaign_recipients (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.runner_email_campaigns(id) on delete cascade,
  recipient_email text not null,
  runner_name text not null,
  reference_number text not null,
  race_category text not null,
  registration_ids uuid[] not null default '{}'::uuid[],
  student_registration_ids uuid[] not null default '{}'::uuid[],
  email_status text not null default 'pending'
    check (email_status in ('pending', 'sending', 'sent', 'failed', 'skipped')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  sent_at timestamptz,
  resend_email_id text,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists runner_email_campaign_recipient_unique_email
  on public.runner_email_campaign_recipients (campaign_id, lower(recipient_email));

create index if not exists runner_email_campaigns_event_created_idx
  on public.runner_email_campaigns (event_id, created_at desc);

create index if not exists runner_email_campaign_recipients_queue_idx
  on public.runner_email_campaign_recipients (campaign_id, email_status, created_at);

alter table public.runner_email_campaigns enable row level security;
alter table public.runner_email_campaign_recipients enable row level security;

revoke all on table public.runner_email_campaigns from public, anon, authenticated;
revoke all on table public.runner_email_campaign_recipients from public, anon, authenticated;

grant select, insert, update, delete on table public.runner_email_campaigns to service_role;
grant select, insert, update, delete on table public.runner_email_campaign_recipients to service_role;

comment on table public.runner_email_campaigns is
  'Audited bulk runner announcements created by authorized event administrators.';

comment on table public.runner_email_campaign_recipients is
  'Immutable per-campaign recipient snapshots with send, retry, and skip state.';
