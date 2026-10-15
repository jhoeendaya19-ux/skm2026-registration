begin;

revoke execute on function public.admin_search_fulfillment_candidates(text, text) from anon;
revoke execute on function public.admin_add_runner_to_fulfillment(text, uuid, text) from anon;
revoke execute on function public.admin_restore_manual_fulfillment(text) from anon;

grant execute on function public.admin_search_fulfillment_candidates(text, text) to authenticated;
grant execute on function public.admin_add_runner_to_fulfillment(text, uuid, text) to authenticated;
grant execute on function public.admin_restore_manual_fulfillment(text) to authenticated;

commit;

