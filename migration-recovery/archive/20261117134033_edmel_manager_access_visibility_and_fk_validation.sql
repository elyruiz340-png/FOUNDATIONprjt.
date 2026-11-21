
drop policy if exists "Managers can view subordinate restaurant staff links" on public.restaurant_users;
create policy "Managers can view subordinate restaurant staff links"
on public.restaurant_users for select to authenticated
using (
 lower(coalesce(role,''))='staff'
 and lower(coalesce(position,''))<>'manager'
 and exists (
  select 1 from public.staff_branch_access target_access
  where target_access.restaurant_user_id=restaurant_users.id
   and target_access.restaurant_id=restaurant_users.restaurant_id
   and public.edmel_can_manage_branch_staff(target_access.branch_id)
 )
);
alter table public.orders validate constraint orders_branch_restaurant_fk;
alter table public.restaurant_tables validate constraint restaurant_tables_branch_restaurant_fk;
alter table public.menu_categories validate constraint menu_categories_branch_restaurant_fk;
alter table public.menu_items validate constraint menu_items_branch_restaurant_fk;
alter table public."PRODUCT_STOCK" validate constraint product_stock_branch_restaurant_fk;
alter table public.payments validate constraint payments_branch_restaurant_fk;
alter table public.reservations validate constraint reservations_branch_restaurant_fk;
alter table public.staff_sessions validate constraint staff_sessions_branch_restaurant_fk;
alter table public.order_void_requests validate constraint order_void_requests_branch_restaurant_fk;
alter table public.restaurant_table_qr_tokens validate constraint restaurant_table_qr_tokens_branch_fk;
alter table public.table_shared_carts validate constraint table_shared_carts_branch_fk;
