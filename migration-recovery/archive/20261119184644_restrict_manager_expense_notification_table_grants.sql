
revoke all on table public.manager_expense_request_notifications from public, anon;
grant select on table public.manager_expense_request_notifications to authenticated;
grant update (is_read, read_at) on table public.manager_expense_request_notifications to authenticated;
