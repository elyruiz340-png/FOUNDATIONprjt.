create policy "Owners and admins can insert audit logs"
on public.audit_logs
for insert
to authenticated
with check (
  exists (
    select 1
    from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = audit_logs.restaurant_id
      and lower(coalesce(ru.role, '')) in ('owner', 'admin')
      and coalesce(ru.is_active, true) = true
  )
);