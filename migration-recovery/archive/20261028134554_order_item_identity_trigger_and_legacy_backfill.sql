begin;

create or replace function public.sync_order_items_from_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_item jsonb;
  v_menu_item_id uuid;
  v_name text;
  v_qty integer;
  v_price numeric;
  v_count integer;
begin
  if new.items is null or jsonb_typeof(new.items) <> 'array' then
    return new;
  end if;

  for v_item in select value from jsonb_array_elements(new.items)
  loop
    v_name := coalesce(nullif(btrim(v_item->>'name'), ''), 'Unknown item');
    v_qty := coalesce(nullif(coalesce(v_item->>'quantity', v_item->>'qty'), '')::integer, 1);
    v_price := coalesce(nullif(v_item->>'price', '')::numeric, 0);

    if v_qty < 1 or v_price < 0 then
      raise exception 'Invalid order item quantity or price for order %', new.id;
    end if;

    v_menu_item_id := null;
    begin
      if nullif(v_item->>'menu_item_id', '') is not null then
        v_menu_item_id := (v_item->>'menu_item_id')::uuid;
      elsif coalesce(v_item->>'id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        v_menu_item_id := (v_item->>'id')::uuid;
      end if;
    exception when invalid_text_representation then
      v_menu_item_id := null;
    end;

    if v_menu_item_id is not null and not exists (
      select 1 from public.menu_items mi
      where mi.id = v_menu_item_id and mi.restaurant_id = new.restaurant_id
    ) then
      v_menu_item_id := null;
    end if;

    if v_menu_item_id is null and nullif(v_item->>'product_id', '') is not null then
      select count(*), min(mi.id::text)::uuid
        into v_count, v_menu_item_id
      from public.menu_items mi
      where mi.restaurant_id = new.restaurant_id
        and mi.stock_product_id = v_item->>'product_id';
      if v_count <> 1 then v_menu_item_id := null; end if;
    end if;

    insert into public.order_items (
      order_id, menu_item_id, item_name, quantity, unit_price, subtotal,
      special_instructions
    ) values (
      new.id, v_menu_item_id, v_name, v_qty, v_price, round(v_price * v_qty, 2),
      nullif(btrim(coalesce(v_item->>'special_instructions', '')), '')
    );
  end loop;
  return new;
end;
$function$;

revoke all on function public.sync_order_items_from_order() from public, anon, authenticated;

drop trigger if exists trg_sync_order_items_from_order on public.orders;
create trigger trg_sync_order_items_from_order
after insert on public.orders
for each row execute function public.sync_order_items_from_order();

do $backfill$
declare
  r record;
  v_item jsonb;
  v_menu_item_id uuid;
  v_name text;
  v_qty integer;
  v_price numeric;
  v_count integer;
begin
  for r in
    select o.id, o.restaurant_id, o.items
    from public.orders o
    where o.items is not null
      and jsonb_typeof(o.items) = 'array'
      and jsonb_array_length(o.items) > 0
      and not exists (select 1 from public.order_items oi where oi.order_id = o.id)
    order by o.created_at, o.id
  loop
    for v_item in select value from jsonb_array_elements(r.items)
    loop
      v_name := coalesce(nullif(btrim(v_item->>'name'), ''), 'Unknown item');
      v_qty := coalesce(nullif(coalesce(v_item->>'quantity', v_item->>'qty'), '')::integer, 1);
      v_price := coalesce(nullif(v_item->>'price', '')::numeric, 0);
      if v_qty < 1 or v_price < 0 then
        raise exception 'Invalid historical line item on order %', r.id;
      end if;

      v_menu_item_id := null;
      begin
        if nullif(v_item->>'menu_item_id', '') is not null then
          v_menu_item_id := (v_item->>'menu_item_id')::uuid;
        elsif coalesce(v_item->>'id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
          v_menu_item_id := (v_item->>'id')::uuid;
        end if;
      exception when invalid_text_representation then
        v_menu_item_id := null;
      end;

      if v_menu_item_id is not null and not exists (
        select 1 from public.menu_items mi
        where mi.id = v_menu_item_id and mi.restaurant_id = r.restaurant_id
      ) then
        v_menu_item_id := null;
      end if;

      if v_menu_item_id is null and nullif(v_item->>'product_id', '') is not null then
        select count(*), min(mi.id::text)::uuid
          into v_count, v_menu_item_id
        from public.menu_items mi
        where mi.restaurant_id = r.restaurant_id
          and mi.stock_product_id = v_item->>'product_id';
        if v_count <> 1 then v_menu_item_id := null; end if;
      end if;

      insert into public.order_items (
        order_id, menu_item_id, item_name, quantity, unit_price, subtotal,
        special_instructions
      ) values (
        r.id, v_menu_item_id, v_name, v_qty, v_price, round(v_price * v_qty, 2),
        nullif(btrim(coalesce(v_item->>'special_instructions', '')), '')
      );
    end loop;
  end loop;
end;
$backfill$;

commit;