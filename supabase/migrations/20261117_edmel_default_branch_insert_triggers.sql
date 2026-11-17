
create or replace function public.edmel_assign_default_branch_before_insert()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
declare
 v_restaurant_id uuid;
 v_branch_id uuid;
begin
 if tg_table_name='PRODUCT_STOCK' then
  if new.restaurant_id is null then
   new.restaurant_id := '5e562ca7-38aa-4894-8265-ddca2f4e61b6'::uuid;
  end if;
  v_restaurant_id := new.restaurant_id;
 elsif tg_table_name in ('table_shared_carts','restaurant_table_qr_tokens') then
  if new.branch_id is null then
   select t.branch_id into v_branch_id
   from public.restaurant_tables t
   where t.id=new.table_id;
   new.branch_id := v_branch_id;
  end if;
  return new;
 else
  v_restaurant_id := new.restaurant_id;
 end if;

 if new.branch_id is not null then
  return new;
 end if;

 if tg_table_name='orders' and new.table_id is not null then
  select t.branch_id into v_branch_id
  from public.restaurant_tables t
  where t.id=new.table_id and t.restaurant_id=v_restaurant_id;
 elsif tg_table_name='payments' and new.order_id is not null then
  select o.branch_id into v_branch_id
  from public.orders o
  where o.id=new.order_id and o.restaurant_id=v_restaurant_id;
 elsif tg_table_name='order_void_requests' and new.order_id is not null then
  select o.branch_id into v_branch_id
  from public.orders o
  where o.id=new.order_id and o.restaurant_id=v_restaurant_id;
 end if;

 if v_branch_id is null and v_restaurant_id is not null then
  select b.id into v_branch_id
  from public.restaurant_branches b
  where b.restaurant_id=v_restaurant_id and b.is_default=true and b.is_active=true
  limit 1;
 end if;

 new.branch_id := v_branch_id;
 return new;
end;
$function$;

revoke all on function public.edmel_assign_default_branch_before_insert() from public,anon,authenticated;

create trigger edmel_assign_branch_orders
before insert on public.orders
for each row execute function public.edmel_assign_default_branch_before_insert();

create trigger edmel_assign_branch_tables
before insert on public.restaurant_tables
for each row execute function public.edmel_assign_default_branch_before_insert();

create trigger edmel_assign_branch_menu_categories
before insert on public.menu_categories
for each row execute function public.edmel_assign_default_branch_before_insert();

create trigger edmel_assign_branch_menu_items
before insert on public.menu_items
for each row execute function public.edmel_assign_default_branch_before_insert();

create trigger edmel_assign_branch_product_stock
before insert on public."PRODUCT_STOCK"
for each row execute function public.edmel_assign_default_branch_before_insert();

create trigger edmel_assign_branch_payments
before insert on public.payments
for each row execute function public.edmel_assign_default_branch_before_insert();

create trigger edmel_assign_branch_reservations
before insert on public.reservations
for each row execute function public.edmel_assign_default_branch_before_insert();

create trigger edmel_assign_branch_void_requests
before insert on public.order_void_requests
for each row execute function public.edmel_assign_default_branch_before_insert();

create trigger edmel_assign_branch_qr_tokens
before insert on public.restaurant_table_qr_tokens
for each row execute function public.edmel_assign_default_branch_before_insert();

create trigger edmel_assign_branch_shared_carts
before insert on public.table_shared_carts
for each row execute function public.edmel_assign_default_branch_before_insert();
