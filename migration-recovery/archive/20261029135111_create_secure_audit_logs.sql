
create table if not exists public.audit_logs (
  id bigint generated always as identity primary key,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  actor_user_id uuid null,
  actor_name text not null default 'System / customer',
  actor_role text not null default 'system',
  action_category text not null,
  action text not null,
  record_type text not null,
  record_id text null,
  result text not null default 'success' check (result in ('success','failed')),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists audit_logs_restaurant_created_idx on public.audit_logs (restaurant_id, created_at desc);
create index if not exists audit_logs_restaurant_category_idx on public.audit_logs (restaurant_id, action_category, created_at desc);
create index if not exists audit_logs_actor_idx on public.audit_logs (restaurant_id, actor_user_id, created_at desc);
alter table public.audit_logs enable row level security;
revoke all on public.audit_logs from anon, authenticated;
grant select on public.audit_logs to authenticated;
drop policy if exists "Owners and admins can view audit logs" on public.audit_logs;
create policy "Owners and admins can view audit logs"
on public.audit_logs for select to authenticated
using (
  exists (
    select 1 from public.restaurant_users ru
    where ru.restaurant_id = audit_logs.restaurant_id
      and ru.user_id = (select auth.uid())
      and lower(coalesce(ru.role,'')) in ('owner','admin')
      and coalesce(ru.is_active,true) = true
  )
);
create or replace function public.write_audit_log_for_row()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_restaurant_id uuid;
  v_actor uuid := auth.uid();
  v_actor_name text := 'System / customer';
  v_actor_role text := 'system';
  v_category text;
  v_action text;
  v_record_id text;
  v_details jsonb := '{}'::jsonb;
  v_old jsonb := '{}'::jsonb;
  v_new jsonb := '{}'::jsonb;
  v_row jsonb;
begin
  if TG_OP = 'DELETE' then v_row := to_jsonb(OLD); else v_row := to_jsonb(NEW); end if;

  if TG_TABLE_NAME = 'PRODUCT_STOCK' then
    v_restaurant_id := '5e562ca7-38aa-4894-8265-ddca2f4e61b6'::uuid;
    v_record_id := coalesce(v_row->>'id', v_row->>'product_id');
    v_category := 'Inventory';
    v_old := case when TG_OP = 'INSERT' then '{}'::jsonb else jsonb_build_object(
      'product_name', to_jsonb(OLD)->'product_name',
      'stock_total', to_jsonb(OLD)->'stock_total',
      'stock_remaining', to_jsonb(OLD)->'stock_remaining',
      'is_available', to_jsonb(OLD)->'is_available',
      'is_archived', to_jsonb(OLD)->'is_archived') end;
    v_new := case when TG_OP = 'DELETE' then '{}'::jsonb else jsonb_build_object(
      'product_name', to_jsonb(NEW)->'product_name',
      'stock_total', to_jsonb(NEW)->'stock_total',
      'stock_remaining', to_jsonb(NEW)->'stock_remaining',
      'is_available', to_jsonb(NEW)->'is_available',
      'is_archived', to_jsonb(NEW)->'is_archived') end;
  else
    v_restaurant_id := nullif(v_row->>'restaurant_id','')::uuid;
    v_record_id := v_row->>'id';
    if TG_TABLE_NAME = 'orders' then
      v_category := 'Orders';
      v_old := case when TG_OP='INSERT' then '{}'::jsonb else jsonb_build_object('order_number',to_jsonb(OLD)->'order_number','order_status',to_jsonb(OLD)->'order_status','status',to_jsonb(OLD)->'status','payment_status',to_jsonb(OLD)->'payment_status','payment_method',to_jsonb(OLD)->'payment_method','total',to_jsonb(OLD)->'total') end;
      v_new := case when TG_OP='DELETE' then '{}'::jsonb else jsonb_build_object('order_number',to_jsonb(NEW)->'order_number','order_status',to_jsonb(NEW)->'order_status','status',to_jsonb(NEW)->'status','payment_status',to_jsonb(NEW)->'payment_status','payment_method',to_jsonb(NEW)->'payment_method','total',to_jsonb(NEW)->'total') end;
    elsif TG_TABLE_NAME = 'menu_items' then
      v_category := 'Menu';
      v_old := case when TG_OP='INSERT' then '{}'::jsonb else jsonb_build_object('name',to_jsonb(OLD)->'name','price',to_jsonb(OLD)->'price','is_available',to_jsonb(OLD)->'is_available','category_id',to_jsonb(OLD)->'category_id') end;
      v_new := case when TG_OP='DELETE' then '{}'::jsonb else jsonb_build_object('name',to_jsonb(NEW)->'name','price',to_jsonb(NEW)->'price','is_available',to_jsonb(NEW)->'is_available','category_id',to_jsonb(NEW)->'category_id') end;
    elsif TG_TABLE_NAME = 'menu_categories' then
      v_category := 'Menu';
      v_old := case when TG_OP='INSERT' then '{}'::jsonb else jsonb_build_object('name',to_jsonb(OLD)->'name','is_active',to_jsonb(OLD)->'is_active','sort_order',to_jsonb(OLD)->'sort_order') end;
      v_new := case when TG_OP='DELETE' then '{}'::jsonb else jsonb_build_object('name',to_jsonb(NEW)->'name','is_active',to_jsonb(NEW)->'is_active','sort_order',to_jsonb(NEW)->'sort_order') end;
    elsif TG_TABLE_NAME = 'restaurant_users' then
      v_restaurant_id := coalesce(nullif(v_row->>'restaurant_id','')::uuid, (to_jsonb(OLD)->>'restaurant_id')::uuid);
      v_category := 'Staff & Security';
      v_old := case when TG_OP='INSERT' then '{}'::jsonb else jsonb_build_object('display_name',to_jsonb(OLD)->'display_name','full_name',to_jsonb(OLD)->'full_name','cashier_username',to_jsonb(OLD)->'cashier_username','role',to_jsonb(OLD)->'role','position',to_jsonb(OLD)->'position','permissions',to_jsonb(OLD)->'permissions','is_active',to_jsonb(OLD)->'is_active') end;
      v_new := case when TG_OP='DELETE' then '{}'::jsonb else jsonb_build_object('display_name',to_jsonb(NEW)->'display_name','full_name',to_jsonb(NEW)->'full_name','cashier_username',to_jsonb(NEW)->'cashier_username','role',to_jsonb(NEW)->'role','position',to_jsonb(NEW)->'position','permissions',to_jsonb(NEW)->'permissions','is_active',to_jsonb(NEW)->'is_active') end;
    elsif TG_TABLE_NAME = 'payments' then
      v_category := 'Payments';
      v_old := case when TG_OP='INSERT' then '{}'::jsonb else jsonb_build_object('status',to_jsonb(OLD)->'status','amount',to_jsonb(OLD)->'amount','provider',to_jsonb(OLD)->'provider','order_id',to_jsonb(OLD)->'order_id') end;
      v_new := case when TG_OP='DELETE' then '{}'::jsonb else jsonb_build_object('status',to_jsonb(NEW)->'status','amount',to_jsonb(NEW)->'amount','provider',to_jsonb(NEW)->'provider','order_id',to_jsonb(NEW)->'order_id') end;
    else
      return coalesce(NEW, OLD);
    end if;
  end if;

  if v_restaurant_id is null then return coalesce(NEW, OLD); end if;
  if v_actor is not null then
    select coalesce(nullif(ru.display_name,''),nullif(ru.full_name,''),nullif(ru.cashier_username,''),au.email,'Authenticated user'),
           coalesce(ru.role,'authenticated')
      into v_actor_name, v_actor_role
    from auth.users au
    left join public.restaurant_users ru on ru.user_id=au.id and ru.restaurant_id=v_restaurant_id
    where au.id=v_actor
    limit 1;
    v_actor_name := coalesce(v_actor_name,'Authenticated user');
    v_actor_role := coalesce(v_actor_role,'authenticated');
  end if;

  v_action := case TG_OP
    when 'INSERT' then 'Created'
    when 'UPDATE' then 'Updated'
    when 'DELETE' then 'Deleted'
    else TG_OP end;
  if TG_TABLE_NAME='orders' and TG_OP='UPDATE' then
    if (to_jsonb(OLD)->>'order_status') is distinct from (to_jsonb(NEW)->>'order_status')
       or (to_jsonb(OLD)->>'status') is distinct from (to_jsonb(NEW)->>'status') then
      v_action := 'Order status changed';
    elsif (to_jsonb(OLD)->>'payment_status') is distinct from (to_jsonb(NEW)->>'payment_status') then
      v_action := 'Payment status changed';
    end if;
  elsif TG_TABLE_NAME='menu_items' and TG_OP='UPDATE'
    and (to_jsonb(OLD)->>'price') is distinct from (to_jsonb(NEW)->>'price') then
    v_action := 'Menu price changed';
  elsif TG_TABLE_NAME='PRODUCT_STOCK' and TG_OP='UPDATE'
    and (to_jsonb(OLD)->>'stock_remaining') is distinct from (to_jsonb(NEW)->>'stock_remaining') then
    v_action := 'Stock quantity changed';
  end if;

  v_details := jsonb_build_object('before',v_old,'after',v_new,'operation',TG_OP,'source_table',TG_TABLE_NAME);
  insert into public.audit_logs(restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,record_type,record_id,details)
  values(v_restaurant_id,v_actor,v_actor_name,v_actor_role,v_category,v_action,TG_TABLE_NAME,v_record_id,v_details);
  return coalesce(NEW, OLD);
end;
$$;
revoke all on function public.write_audit_log_for_row() from public, anon, authenticated;
drop trigger if exists audit_orders_changes on public.orders;
create trigger audit_orders_changes after insert or update or delete on public.orders for each row execute function public.write_audit_log_for_row();
drop trigger if exists audit_menu_items_changes on public.menu_items;
create trigger audit_menu_items_changes after insert or update or delete on public.menu_items for each row execute function public.write_audit_log_for_row();
drop trigger if exists audit_menu_categories_changes on public.menu_categories;
create trigger audit_menu_categories_changes after insert or update or delete on public.menu_categories for each row execute function public.write_audit_log_for_row();
drop trigger if exists audit_restaurant_users_changes on public.restaurant_users;
create trigger audit_restaurant_users_changes after insert or update or delete on public.restaurant_users for each row execute function public.write_audit_log_for_row();
drop trigger if exists audit_payments_changes on public.payments;
create trigger audit_payments_changes after insert or update or delete on public.payments for each row execute function public.write_audit_log_for_row();
drop trigger if exists audit_product_stock_changes on public."PRODUCT_STOCK";
create trigger audit_product_stock_changes after insert or update or delete on public."PRODUCT_STOCK" for each row execute function public.write_audit_log_for_row();
