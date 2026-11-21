create or replace function public.halina_create_restaurant_table(
  p_restaurant_id uuid,
  p_table_number text,
  p_seating_capacity integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_id uuid;
  v_token text;
begin
  if not public.halina_can_manage_tables(p_restaurant_id) then
    raise exception 'Not authorized';
  end if;

  if nullif(btrim(p_table_number),'') is null then
    raise exception 'Table number is required';
  end if;

  if p_seating_capacity < 1 or p_seating_capacity > 50 then
    raise exception 'Capacity must be between 1 and 50';
  end if;

  if exists (
    select 1 from public.restaurant_tables
    where restaurant_id = p_restaurant_id
      and lower(table_number) = lower(btrim(p_table_number))
  ) then
    raise exception 'That table number already exists';
  end if;

  v_token := encode(extensions.gen_random_bytes(24), 'hex');

  insert into public.restaurant_tables
    (restaurant_id, table_number, seating_capacity, is_active, is_locked)
  values
    (p_restaurant_id, btrim(p_table_number), p_seating_capacity, true, false)
  returning id into v_id;

  insert into public.restaurant_table_qr_tokens(table_id, token)
  values (v_id, v_token);

  insert into public.table_shared_carts(table_id)
  values (v_id);

  return jsonb_build_object(
    'id', v_id,
    'token', v_token,
    'table_number', btrim(p_table_number),
    'seating_capacity', p_seating_capacity,
    'is_active', true,
    'is_locked', false
  );
end;
$function$;