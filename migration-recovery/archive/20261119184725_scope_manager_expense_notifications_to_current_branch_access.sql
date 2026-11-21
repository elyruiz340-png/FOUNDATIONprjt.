
drop policy if exists manager_expense_request_notifications_select_recipient
  on public.manager_expense_request_notifications;
create policy manager_expense_request_notifications_select_recipient
  on public.manager_expense_request_notifications
  for select to authenticated
  using (
    (recipient_role='admin' and public.edmel_is_restaurant_owner_admin(restaurant_id))
    or
    (recipient_role='manager'
      and recipient_user_id=(select auth.uid())
      and public.edmel_expense_has_access(restaurant_id,branch_id,'view'))
  );

drop policy if exists manager_expense_request_notifications_update_recipient
  on public.manager_expense_request_notifications;
create policy manager_expense_request_notifications_update_recipient
  on public.manager_expense_request_notifications
  for update to authenticated
  using (
    (recipient_role='admin' and public.edmel_is_restaurant_owner_admin(restaurant_id))
    or
    (recipient_role='manager'
      and recipient_user_id=(select auth.uid())
      and public.edmel_expense_has_access(restaurant_id,branch_id,'view'))
  )
  with check (
    (recipient_role='admin' and public.edmel_is_restaurant_owner_admin(restaurant_id))
    or
    (recipient_role='manager'
      and recipient_user_id=(select auth.uid())
      and public.edmel_expense_has_access(restaurant_id,branch_id,'view'))
  );
