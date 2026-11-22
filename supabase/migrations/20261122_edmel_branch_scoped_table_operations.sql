-- Legacy table-management RPCs are now Owner/Admin only.
-- Staff use the branch-scoped RPCs below.

CREATE OR REPLACE FUNCTION public.halina_can_manage_tables(p_restaurant_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.restaurant_users ru
    WHERE ru.user_id = auth.uid()
      AND ru.restaurant_id = p_restaurant_id
      AND ru.is_active = true
      AND lower(ru.role) IN ('owner','admin')
  );
$function$;

CREATE OR REPLACE FUNCTION public.edmel_list_branch_restaurant_tables(
  p_restaurant_id uuid,
  p_branch_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.restaurant_branches b
    WHERE b.id = p_branch_id
      AND b.restaurant_id = p_restaurant_id
      AND b.is_active = true
  ) OR NOT public.edmel_has_branch_permission(p_branch_id, 'tables') THEN
    RAISE EXCEPTION 'Table access is not assigned for this branch';
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', t.id,
    'table_number', t.table_number,
    'seating_capacity', t.seating_capacity,
    'is_active', t.is_active,
    'is_locked', t.is_locked,
    'token', q.token,
    'cart_items', coalesce(c.cart_items, '[]'::jsonb),
    'updated_at', c.updated_at
  ) ORDER BY t.table_number), '[]'::jsonb)
  INTO v
  FROM public.restaurant_tables t
  LEFT JOIN public.restaurant_table_qr_tokens q ON q.table_id = t.id
  LEFT JOIN public.table_shared_carts c ON c.table_id = t.id
  WHERE t.restaurant_id = p_restaurant_id
    AND t.branch_id = p_branch_id;

  RETURN v;
END;
$function$;

CREATE OR REPLACE FUNCTION public.edmel_update_branch_restaurant_table(
  p_restaurant_id uuid,
  p_branch_id uuid,
  p_table_id uuid,
  p_table_number text,
  p_seating_capacity integer,
  p_is_active boolean,
  p_is_locked boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.edmel_has_branch_permission(p_branch_id, 'tables')
     OR NOT EXISTS (
       SELECT 1 FROM public.restaurant_branches b
       WHERE b.id = p_branch_id
         AND b.restaurant_id = p_restaurant_id
         AND b.is_active = true
     ) THEN
    RAISE EXCEPTION 'Table access is not assigned for this branch';
  END IF;

  IF p_seating_capacity < 1 OR p_seating_capacity > 50 THEN
    RAISE EXCEPTION 'Capacity must be between 1 and 50';
  END IF;

  IF nullif(btrim(p_table_number), '') IS NULL OR length(btrim(p_table_number)) > 40 THEN
    RAISE EXCEPTION 'A valid table number is required';
  END IF;

  UPDATE public.restaurant_tables
  SET table_number = btrim(p_table_number),
      seating_capacity = p_seating_capacity,
      is_active = p_is_active,
      is_locked = p_is_locked
  WHERE id = p_table_id
    AND restaurant_id = p_restaurant_id
    AND branch_id = p_branch_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'Table not found for this branch'; END IF;
  RETURN jsonb_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_list_branch_restaurant_tables(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edmel_list_branch_restaurant_tables(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.edmel_update_branch_restaurant_table(uuid, uuid, uuid, text, integer, boolean, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edmel_update_branch_restaurant_table(uuid, uuid, uuid, text, integer, boolean, boolean) TO authenticated;
