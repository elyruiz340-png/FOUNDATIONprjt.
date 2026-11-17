
create table public.restaurant_branches (
 id uuid primary key default gen_random_uuid(),
 restaurant_id uuid not null references public.restaurants(id) on delete cascade,
 name text not null, code text not null,
 timezone text not null default 'America/Chicago',
 address text, is_default boolean not null default false,
 is_active boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 constraint restaurant_branches_name_nonempty check(length(btrim(name)) between 1 and 80),
 constraint restaurant_branches_code_format check(code ~ '^[A-Z0-9_-]{2,20}$'),
 constraint restaurant_branches_id_restaurant_unique unique(id,restaurant_id)
);
create unique index restaurant_branches_restaurant_code_uidx on public.restaurant_branches(restaurant_id,code);
create unique index restaurant_branches_one_default_uidx on public.restaurant_branches(restaurant_id) where is_default=true;
create unique index if not exists restaurant_users_id_restaurant_uidx on public.restaurant_users(id,restaurant_id);

create table public.staff_branch_access (
 id uuid primary key default gen_random_uuid(),
 restaurant_user_id uuid not null, restaurant_id uuid not null, branch_id uuid not null,
 permissions jsonb not null default '{}'::jsonb,
 is_active boolean not null default true, created_by uuid,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 constraint staff_branch_access_permissions_object check(jsonb_typeof(permissions)='object'),
 constraint staff_branch_access_user_branch_unique unique(restaurant_user_id,branch_id),
 constraint staff_branch_access_user_restaurant_fk foreign key(restaurant_user_id,restaurant_id)
  references public.restaurant_users(id,restaurant_id) on delete cascade,
 constraint staff_branch_access_branch_restaurant_fk foreign key(branch_id,restaurant_id)
  references public.restaurant_branches(id,restaurant_id) on delete cascade
);

alter table public.orders add column if not exists branch_id uuid;
alter table public.restaurant_tables add column if not exists branch_id uuid;
alter table public.menu_categories add column if not exists branch_id uuid;
alter table public.menu_items add column if not exists branch_id uuid;
alter table public."PRODUCT_STOCK" add column if not exists restaurant_id uuid;
alter table public."PRODUCT_STOCK" add column if not exists branch_id uuid;
alter table public.payments add column if not exists branch_id uuid;
alter table public.reservations add column if not exists branch_id uuid;
alter table public.staff_sessions add column if not exists branch_id uuid;
alter table public.order_void_requests add column if not exists branch_id uuid;
alter table public.restaurant_table_qr_tokens add column if not exists branch_id uuid;
alter table public.table_shared_carts add column if not exists branch_id uuid;

insert into public.restaurant_branches(restaurant_id,name,code,timezone,is_default,is_active)
select r.id,'Main Branch','MAIN',r.timezone,true,true
from public.restaurants r where r.slug='halina-bistro-cafe'
on conflict do nothing;

do $$
declare v_restaurant uuid; v_branch uuid;
begin
 select id into v_restaurant from public.restaurants where slug='halina-bistro-cafe';
 if v_restaurant is null then raise exception 'EDMEL BISTRO CAFE restaurant record was not found'; end if;
 select id into v_branch from public.restaurant_branches where restaurant_id=v_restaurant and is_default=true;
 if v_branch is null then raise exception 'Main Branch was not created'; end if;

 alter table public.orders disable trigger audit_orders_changes;
 alter table public.restaurant_tables disable trigger audit_restaurant_tables_changes;
 alter table public.menu_categories disable trigger audit_menu_categories_changes;
 alter table public.menu_items disable trigger audit_menu_items_changes;
 alter table public."PRODUCT_STOCK" disable trigger audit_product_stock_changes;
 alter table public.staff_sessions disable trigger audit_staff_sessions_changes;

 update public.restaurant_tables set branch_id=v_branch where restaurant_id=v_restaurant and branch_id is null;
 update public.orders set branch_id=v_branch where restaurant_id=v_restaurant and branch_id is null;
 update public.menu_categories set branch_id=v_branch where restaurant_id=v_restaurant and branch_id is null;
 update public.menu_items set branch_id=v_branch where restaurant_id=v_restaurant and branch_id is null;
 update public."PRODUCT_STOCK" set restaurant_id=v_restaurant,branch_id=v_branch where restaurant_id is null and branch_id is null;
 update public.payments p set branch_id=o.branch_id from public.orders o where p.order_id=o.id and p.restaurant_id=v_restaurant and p.branch_id is null;
 update public.reservations set branch_id=v_branch where restaurant_id=v_restaurant and branch_id is null;
 update public.staff_sessions ss set branch_id=v_branch where ss.restaurant_id=v_restaurant and ss.branch_id is null
  and exists(select 1 from public.restaurant_users ru where ru.id=ss.restaurant_user_id and ru.restaurant_id=v_restaurant);
 update public.order_void_requests vr set branch_id=o.branch_id from public.orders o where vr.order_id=o.id and vr.restaurant_id=v_restaurant and vr.branch_id is null;
 update public.restaurant_table_qr_tokens qt set branch_id=t.branch_id from public.restaurant_tables t where qt.table_id=t.id and t.restaurant_id=v_restaurant and qt.branch_id is null;
 update public.table_shared_carts sc set branch_id=t.branch_id from public.restaurant_tables t where sc.table_id=t.id and t.restaurant_id=v_restaurant and sc.branch_id is null;

 alter table public.orders enable trigger audit_orders_changes;
 alter table public.restaurant_tables enable trigger audit_restaurant_tables_changes;
 alter table public.menu_categories enable trigger audit_menu_categories_changes;
 alter table public.menu_items enable trigger audit_menu_items_changes;
 alter table public."PRODUCT_STOCK" enable trigger audit_product_stock_changes;
 alter table public.staff_sessions enable trigger audit_staff_sessions_changes;

 insert into public.staff_branch_access(restaurant_user_id,restaurant_id,branch_id,permissions,is_active)
 select ru.id,ru.restaurant_id,v_branch,
  case when lower(coalesce(ru.position,''))='manager'
   then coalesce(ru.permissions,'{}'::jsonb)||jsonb_build_object('staff_management',true)
   else coalesce(ru.permissions,'{}'::jsonb)||jsonb_build_object('staff_management',false) end,
  ru.is_active
 from public.restaurant_users ru
 where ru.restaurant_id=v_restaurant and lower(ru.role)='staff'
 on conflict(restaurant_user_id,branch_id) do nothing;
end $$;

alter table public.orders add constraint orders_branch_restaurant_fk foreign key(branch_id,restaurant_id) references public.restaurant_branches(id,restaurant_id) not valid;
alter table public.restaurant_tables add constraint restaurant_tables_branch_restaurant_fk foreign key(branch_id,restaurant_id) references public.restaurant_branches(id,restaurant_id) not valid;
alter table public.menu_categories add constraint menu_categories_branch_restaurant_fk foreign key(branch_id,restaurant_id) references public.restaurant_branches(id,restaurant_id) not valid;
alter table public.menu_items add constraint menu_items_branch_restaurant_fk foreign key(branch_id,restaurant_id) references public.restaurant_branches(id,restaurant_id) not valid;
alter table public."PRODUCT_STOCK" add constraint product_stock_branch_restaurant_fk foreign key(branch_id,restaurant_id) references public.restaurant_branches(id,restaurant_id) not valid;
alter table public.payments add constraint payments_branch_restaurant_fk foreign key(branch_id,restaurant_id) references public.restaurant_branches(id,restaurant_id) not valid;
alter table public.reservations add constraint reservations_branch_restaurant_fk foreign key(branch_id,restaurant_id) references public.restaurant_branches(id,restaurant_id) not valid;
alter table public.staff_sessions add constraint staff_sessions_branch_restaurant_fk foreign key(branch_id,restaurant_id) references public.restaurant_branches(id,restaurant_id) not valid;
alter table public.order_void_requests add constraint order_void_requests_branch_restaurant_fk foreign key(branch_id,restaurant_id) references public.restaurant_branches(id,restaurant_id) not valid;
alter table public.restaurant_table_qr_tokens add constraint restaurant_table_qr_tokens_branch_fk foreign key(branch_id) references public.restaurant_branches(id) not valid;
alter table public.table_shared_carts add constraint table_shared_carts_branch_fk foreign key(branch_id) references public.restaurant_branches(id) not valid;

create index orders_branch_created_idx on public.orders(branch_id,created_at desc);
create index restaurant_tables_branch_idx on public.restaurant_tables(branch_id);
create index menu_categories_branch_idx on public.menu_categories(branch_id);
create index menu_items_branch_idx on public.menu_items(branch_id);
create index product_stock_branch_idx on public."PRODUCT_STOCK"(branch_id);
create index payments_branch_created_idx on public.payments(branch_id,created_at desc);
create index reservations_branch_date_idx on public.reservations(branch_id,reservation_date);
create index staff_sessions_branch_login_idx on public.staff_sessions(branch_id,login_at desc);
create index order_void_requests_branch_idx on public.order_void_requests(branch_id);
create index staff_branch_access_branch_idx on public.staff_branch_access(branch_id,is_active);

create or replace function public.edmel_is_restaurant_owner_admin(p_restaurant_id uuid)
returns boolean language sql stable security definer set search_path=''
as $$
 select exists(select 1 from public.restaurant_users ru
  where ru.user_id=(select auth.uid()) and ru.restaurant_id=p_restaurant_id
   and lower(ru.role) in ('owner','admin') and coalesce(ru.is_active,true)=true);
$$;
create or replace function public.edmel_has_branch_permission(p_branch_id uuid,p_permission text default null)
returns boolean language sql stable security definer set search_path=''
as $$
 select exists(select 1 from public.restaurant_branches b
  join public.restaurant_users ru on ru.restaurant_id=b.restaurant_id
   and ru.user_id=(select auth.uid()) and coalesce(ru.is_active,true)=true
  where b.id=p_branch_id and b.is_active=true and (
   lower(ru.role) in ('owner','admin') or exists(
    select 1 from public.staff_branch_access sba where sba.restaurant_user_id=ru.id
     and sba.branch_id=b.id and sba.restaurant_id=b.restaurant_id and sba.is_active=true
     and (p_permission is null or sba.permissions @> jsonb_build_object(p_permission,true))
   )
  ));
$$;
create or replace function public.edmel_can_manage_branch_staff(p_branch_id uuid)
returns boolean language sql stable security definer set search_path=''
as $$ select public.edmel_has_branch_permission(p_branch_id,'staff_management'); $$;
create or replace function public.edmel_can_assign_branch_permissions(p_branch_id uuid,p_permissions jsonb)
returns boolean language plpgsql stable security definer set search_path=''
as $$
declare v_actor_permissions jsonb; v_restaurant_id uuid;
begin
 if p_permissions is null or jsonb_typeof(p_permissions)<>'object' then return false; end if;
 if exists(select 1 from jsonb_each(p_permissions) e
   where e.key not in ('orders','tables','stocks','dispatcher','settings','void','staff_management')
      or jsonb_typeof(e.value)<>'boolean') then return false; end if;
 select b.restaurant_id into v_restaurant_id from public.restaurant_branches b where b.id=p_branch_id and b.is_active=true;
 if v_restaurant_id is null then return false; end if;
 if public.edmel_is_restaurant_owner_admin(v_restaurant_id) then return true; end if;
 select sba.permissions into v_actor_permissions from public.staff_branch_access sba
 join public.restaurant_users ru on ru.id=sba.restaurant_user_id
 where sba.branch_id=p_branch_id and sba.restaurant_id=v_restaurant_id and sba.is_active=true
  and ru.user_id=(select auth.uid()) and ru.is_active=true
  and lower(coalesce(ru.position,''))='manager' and lower(ru.role)='staff' limit 1;
 if v_actor_permissions is null then return false; end if;
 if p_permissions ? 'staff_management' and coalesce((p_permissions->>'staff_management')::boolean,false) then return false; end if;
 if exists(select 1 from jsonb_each(p_permissions) e
  where e.value='true'::jsonb and not (v_actor_permissions @> jsonb_build_object(e.key,true))) then return false; end if;
 return true;
end;
$$;

revoke all on function public.edmel_is_restaurant_owner_admin(uuid) from public,anon;
revoke all on function public.edmel_has_branch_permission(uuid,text) from public,anon;
revoke all on function public.edmel_can_manage_branch_staff(uuid) from public,anon;
revoke all on function public.edmel_can_assign_branch_permissions(uuid,jsonb) from public,anon;
grant execute on function public.edmel_is_restaurant_owner_admin(uuid) to authenticated,service_role;
grant execute on function public.edmel_has_branch_permission(uuid,text) to authenticated,service_role;
grant execute on function public.edmel_can_manage_branch_staff(uuid) to authenticated,service_role;
grant execute on function public.edmel_can_assign_branch_permissions(uuid,jsonb) to authenticated,service_role;

alter table public.restaurant_branches enable row level security;
alter table public.staff_branch_access enable row level security;
create policy "Users can view assigned restaurant branches" on public.restaurant_branches
 for select to authenticated using(public.edmel_is_restaurant_owner_admin(restaurant_id) or public.edmel_has_branch_permission(id,null));
create policy "Owners and admins can create restaurant branches" on public.restaurant_branches
 for insert to authenticated with check(public.edmel_is_restaurant_owner_admin(restaurant_id));
create policy "Owners and admins can update restaurant branches" on public.restaurant_branches
 for update to authenticated using(public.edmel_is_restaurant_owner_admin(restaurant_id))
 with check(public.edmel_is_restaurant_owner_admin(restaurant_id));
create policy "Owners and admins can delete restaurant branches" on public.restaurant_branches
 for delete to authenticated using(public.edmel_is_restaurant_owner_admin(restaurant_id));
create policy "Users can view their own branch access and authorized staff access" on public.staff_branch_access
 for select to authenticated using(
  exists(select 1 from public.restaurant_users ru where ru.id=restaurant_user_id and ru.user_id=(select auth.uid()))
  or public.edmel_is_restaurant_owner_admin(restaurant_id)
  or public.edmel_can_manage_branch_staff(branch_id)
 );
create policy "Authorized managers can add subordinate branch access" on public.staff_branch_access
 for insert to authenticated with check(
  public.edmel_is_restaurant_owner_admin(restaurant_id) or (
   public.edmel_can_manage_branch_staff(branch_id)
   and public.edmel_can_assign_branch_permissions(branch_id,permissions)
   and exists(select 1 from public.restaurant_users target where target.id=restaurant_user_id
    and target.restaurant_id=staff_branch_access.restaurant_id and lower(target.role)='staff'
    and lower(coalesce(target.position,''))<>'manager')
  )
 );
create policy "Authorized managers can update subordinate branch access" on public.staff_branch_access
 for update to authenticated using(
  public.edmel_is_restaurant_owner_admin(restaurant_id) or (
   public.edmel_can_manage_branch_staff(branch_id)
   and exists(select 1 from public.restaurant_users target where target.id=restaurant_user_id
    and target.restaurant_id=staff_branch_access.restaurant_id and lower(target.role)='staff'
    and lower(coalesce(target.position,''))<>'manager')
  )
 ) with check(
  public.edmel_is_restaurant_owner_admin(restaurant_id) or (
   public.edmel_can_manage_branch_staff(branch_id)
   and public.edmel_can_assign_branch_permissions(branch_id,permissions)
   and exists(select 1 from public.restaurant_users target where target.id=restaurant_user_id
    and target.restaurant_id=staff_branch_access.restaurant_id and lower(target.role)='staff'
    and lower(coalesce(target.position,''))<>'manager')
  )
 );
create policy "Authorized managers can remove subordinate branch access" on public.staff_branch_access
 for delete to authenticated using(
  public.edmel_is_restaurant_owner_admin(restaurant_id) or (
   public.edmel_can_manage_branch_staff(branch_id)
   and exists(select 1 from public.restaurant_users target where target.id=restaurant_user_id
    and target.restaurant_id=staff_branch_access.restaurant_id and lower(target.role)='staff'
    and lower(coalesce(target.position,''))<>'manager')
  )
 );
grant select,insert,update,delete on public.restaurant_branches to authenticated;
grant select,insert,update,delete on public.staff_branch_access to authenticated;
