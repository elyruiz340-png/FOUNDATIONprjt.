begin;

alter table public.restaurant_tables
  add column if not exists seating_capacity integer not null default 4,
  add column if not exists is_locked boolean not null default false;

create table if not exists public.restaurant_table_qr_tokens (
  table_id uuid primary key references public.restaurant_tables(id) on delete cascade,
  token text not null unique,
  created_at timestamptz not null default now(),
  rotated_at timestamptz not null default now()
);
alter table public.restaurant_table_qr_tokens enable row level security;

create table if not exists public.table_shared_carts (
  table_id uuid primary key references public.restaurant_tables(id) on delete cascade,
  cart_items jsonb not null default '[]'::jsonb,
  revision bigint not null default 0,
  checkout_locked boolean not null default false,
  updated_at timestamptz not null default now(),
  constraint table_shared_carts_items_array check (jsonb_typeof(cart_items) = 'array')
);
alter table public.table_shared_carts enable row level security;

create or replace function public.halina_can_manage_tables(p_restaurant_id uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = auth.uid()
      and ru.restaurant_id = p_restaurant_id
      and ru.role in ('owner','admin')
      and ru.is_active = true
  );
$$;
revoke all on function public.halina_can_manage_tables(uuid) from public;
grant execute on function public.halina_can_manage_tables(uuid) to authenticated;

create or replace function public.halina_list_restaurant_tables(p_restaurant_id uuid)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare v jsonb;
begin
  if not public.halina_can_manage_tables(p_restaurant_id) then
    raise exception 'Not authorized';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',t.id,'table_number',t.table_number,'seating_capacity',t.seating_capacity,
    'is_active',t.is_active,'is_locked',t.is_locked,'token',q.token,
    'cart_items',coalesce(c.cart_items,'[]'::jsonb),'updated_at',c.updated_at
  ) order by t.table_number),'[]'::jsonb)
  into v
  from public.restaurant_tables t
  left join public.restaurant_table_qr_tokens q on q.table_id=t.id
  left join public.table_shared_carts c on c.table_id=t.id
  where t.restaurant_id=p_restaurant_id;
  return v;
end;
$$;

create or replace function public.halina_create_restaurant_table(
  p_restaurant_id uuid,p_table_number text,p_seating_capacity integer
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare v_id uuid; v_token text;
begin
  if not public.halina_can_manage_tables(p_restaurant_id) then raise exception 'Not authorized'; end if;
  if nullif(btrim(p_table_number),'') is null then raise exception 'Table number is required'; end if;
  if p_seating_capacity < 1 or p_seating_capacity > 50 then raise exception 'Capacity must be between 1 and 50'; end if;
  if exists(select 1 from public.restaurant_tables where restaurant_id=p_restaurant_id and lower(table_number)=lower(btrim(p_table_number))) then
    raise exception 'That table number already exists';
  end if;
  v_token := encode(gen_random_bytes(24),'hex');
  insert into public.restaurant_tables(restaurant_id,table_number,seating_capacity,is_active,is_locked)
  values(p_restaurant_id,btrim(p_table_number),p_seating_capacity,true,false) returning id into v_id;
  insert into public.restaurant_table_qr_tokens(table_id,token) values(v_id,v_token);
  insert into public.table_shared_carts(table_id) values(v_id);
  return jsonb_build_object('id',v_id,'token',v_token,'table_number',btrim(p_table_number),'seating_capacity',p_seating_capacity,'is_active',true,'is_locked',false);
end;
$$;

create or replace function public.halina_update_restaurant_table(
  p_restaurant_id uuid,p_table_id uuid,p_table_number text,p_seating_capacity integer,p_is_active boolean,p_is_locked boolean
) returns jsonb
language plpgsql security definer set search_path=public
as $$
begin
  if not public.halina_can_manage_tables(p_restaurant_id) then raise exception 'Not authorized'; end if;
  if p_seating_capacity < 1 or p_seating_capacity > 50 then raise exception 'Capacity must be between 1 and 50'; end if;
  update public.restaurant_tables
  set table_number=btrim(p_table_number),seating_capacity=p_seating_capacity,is_active=p_is_active,is_locked=p_is_locked
  where id=p_table_id and restaurant_id=p_restaurant_id;
  if not found then raise exception 'Table not found'; end if;
  return jsonb_build_object('success',true);
end;
$$;

create or replace function public.halina_rotate_table_qr(p_restaurant_id uuid,p_table_id uuid)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare v_token text;
begin
  if not public.halina_can_manage_tables(p_restaurant_id) then raise exception 'Not authorized'; end if;
  if not exists(select 1 from public.restaurant_tables where id=p_table_id and restaurant_id=p_restaurant_id) then raise exception 'Table not found'; end if;
  v_token:=encode(gen_random_bytes(24),'hex');
  insert into public.restaurant_table_qr_tokens(table_id,token,rotated_at)
  values(p_table_id,v_token,now())
  on conflict(table_id) do update set token=excluded.token,rotated_at=now();
  return jsonb_build_object('token',v_token);
end;
$$;

create or replace function public.get_shared_table_cart(p_table_id uuid,p_qr_token text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v jsonb;
begin
  if not exists(select 1 from public.restaurant_tables t join public.restaurant_table_qr_tokens q on q.table_id=t.id
    where t.id=p_table_id and t.is_active=true and t.is_locked=false and q.token=p_qr_token) then
    raise exception 'Invalid, inactive, or locked table QR';
  end if;
  insert into public.table_shared_carts(table_id) values(p_table_id) on conflict do nothing;
  select jsonb_build_object('cart_items',cart_items,'revision',revision)
  into v from public.table_shared_carts where table_id=p_table_id;
  return v;
end;
$$;

create or replace function public.set_shared_table_cart(
  p_table_id uuid,p_qr_token text,p_cart_items jsonb,p_expected_revision bigint
) returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_revision bigint; v_locked boolean;
begin
  if jsonb_typeof(p_cart_items)<>'array' then raise exception 'Cart must be an array'; end if;
  if jsonb_array_length(p_cart_items)>100 then raise exception 'Cart has too many items'; end if;
  if not exists(select 1 from public.restaurant_tables t join public.restaurant_table_qr_tokens q on q.table_id=t.id
    where t.id=p_table_id and t.is_active=true and t.is_locked=false and q.token=p_qr_token) then
    raise exception 'Invalid, inactive, or locked table QR';
  end if;
  insert into public.table_shared_carts(table_id) values(p_table_id) on conflict do nothing;
  select revision,checkout_locked into v_revision,v_locked from public.table_shared_carts where table_id=p_table_id for update;
  if v_locked then raise exception 'Checkout is in progress'; end if;
  if v_revision<>p_expected_revision then
    return jsonb_build_object('conflict',true,'revision',v_revision);
  end if;
  update public.table_shared_carts set cart_items=p_cart_items,revision=revision+1,updated_at=now() where table_id=p_table_id returning revision into v_revision;
  return jsonb_build_object('conflict',false,'revision',v_revision);
end;
$$;

create or replace function public.halina_lock_shared_cart_for_checkout(p_table_id uuid,p_qr_token text,p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_items jsonb; v_rev bigint; v_locked boolean;
begin
  if not exists(select 1 from public.restaurant_tables t join public.restaurant_table_qr_tokens q on q.table_id=t.id
    where t.id=p_table_id and t.is_active=true and t.is_locked=false and q.token=p_qr_token) then raise exception 'Invalid, inactive, or locked table QR'; end if;
  select cart_items,revision,checkout_locked into v_items,v_rev,v_locked from public.table_shared_carts where table_id=p_table_id for update;
  if v_locked then raise exception 'Another device is already checking out'; end if;
  if v_rev<>p_expected_revision then return jsonb_build_object('success',false,'conflict',true,'revision',v_rev); end if;
  if jsonb_array_length(v_items)=0 then raise exception 'Shared cart is empty'; end if;
  update public.table_shared_carts set checkout_locked=true where table_id=p_table_id;
  return jsonb_build_object('success',true,'revision',v_rev,'cart_items',v_items);
end;
$$;

create or replace function public.halina_finish_shared_cart_checkout(p_table_id uuid,p_qr_token text,p_clear boolean)
returns jsonb language plpgsql security definer set search_path=public
as $$
begin
  if not exists(select 1 from public.restaurant_table_qr_tokens where table_id=p_table_id and token=p_qr_token) then raise exception 'Invalid table QR'; end if;
  update public.table_shared_carts
  set cart_items=case when p_clear then '[]'::jsonb else cart_items end,
      revision=revision+case when p_clear then 1 else 0 end,
      checkout_locked=false,updated_at=now()
  where table_id=p_table_id;
  return jsonb_build_object('success',true);
end;
$$;

revoke all on function public.halina_list_restaurant_tables(uuid) from public;
revoke all on function public.halina_create_restaurant_table(uuid,text,integer) from public;
revoke all on function public.halina_update_restaurant_table(uuid,uuid,text,integer,boolean,boolean) from public;
revoke all on function public.halina_rotate_table_qr(uuid,uuid) from public;
revoke all on function public.get_shared_table_cart(uuid,text) from public;
revoke all on function public.set_shared_table_cart(uuid,text,jsonb,bigint) from public;
revoke all on function public.halina_lock_shared_cart_for_checkout(uuid,text,bigint) from public;
revoke all on function public.halina_finish_shared_cart_checkout(uuid,text,boolean) from public;

grant execute on function public.halina_list_restaurant_tables(uuid) to authenticated;
grant execute on function public.halina_create_restaurant_table(uuid,text,integer) to authenticated;
grant execute on function public.halina_update_restaurant_table(uuid,uuid,text,integer,boolean,boolean) to authenticated;
grant execute on function public.halina_rotate_table_qr(uuid,uuid) to authenticated;
grant execute on function public.get_shared_table_cart(uuid,text) to anon,authenticated;
grant execute on function public.set_shared_table_cart(uuid,text,jsonb,bigint) to anon,authenticated;
grant execute on function public.halina_lock_shared_cart_for_checkout(uuid,text,bigint) to anon,authenticated;
grant execute on function public.halina_finish_shared_cart_checkout(uuid,text,boolean) to anon,authenticated;

commit;