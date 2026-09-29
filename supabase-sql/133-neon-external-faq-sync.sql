begin;

update public.event_settings
set content = jsonb_set(
      coalesce(content, '{}'::jsonb),
      '{externalRegistration}',
      coalesce(content->'externalRegistration', '{}'::jsonb)
        || jsonb_build_object('faq', coalesce(content->'faqItems', '[]'::jsonb)),
      true
    ),
    updated_at = now(),
    updated_by = 'system:neon-external-faq-sync'
where id = 'mcdonalds-neon-run-2026';

commit;
