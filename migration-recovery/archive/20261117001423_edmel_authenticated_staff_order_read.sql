
drop policy if exists "Staff can view restaurant orders" on public.orders;
create policy "Staff can view restaurant orders" on public.orders for select to authenticated
using (exists(select 1 from public.restaurant_users ru where ru.user_id=auth.uid()
  and ru.restaurant_id=orders.restaurant_id and ru.is_active=true
  and lower(coalesce(ru.role,'')) in ('staff','cashier','owner','admin')));
drop policy if exists "Staff can view restaurant order items" on public.order_items;
create policy "Staff can view restaurant order items" on public.order_items for select to authenticated
using (exists(select 1 from public.orders o join public.restaurant_users ru on ru.restaurant_id=o.restaurant_id
  where o.id=order_items.order_id and ru.user_id=auth.uid() and ru.is_active=true
  and lower(coalesce(ru.role,'')) in ('staff','cashier','owner','admin')));
