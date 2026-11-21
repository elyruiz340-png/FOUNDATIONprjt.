CREATE OR REPLACE FUNCTION public.edmel_assign_default_branch_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_row jsonb := to_jsonb(NEW);
  v_restaurant_id uuid;
  v_branch_id uuid;
  v_table_id uuid;
  v_order_id uuid;
  v_current_branch_id uuid;
BEGIN
  v_restaurant_id := nullif(v_row->>'restaurant_id', '')::uuid;
  v_current_branch_id := nullif(v_row->>'branch_id', '')::uuid;

  IF TG_TABLE_NAME = 'PRODUCT_STOCK' THEN
    IF v_restaurant_id IS NULL THEN
      NEW.restaurant_id := '5e562ca7-38aa-4894-8265-ddca2f4e61b6'::uuid;
      v_restaurant_id := NEW.restaurant_id;
    END IF;
  ELSIF TG_TABLE_NAME IN ('table_shared_carts', 'restaurant_table_qr_tokens') THEN
    IF v_current_branch_id IS NULL THEN
      v_table_id := nullif(v_row->>'table_id', '')::uuid;
      IF v_table_id IS NOT NULL THEN
        SELECT t.branch_id INTO v_branch_id
        FROM public.restaurant_tables t
        WHERE t.id = v_table_id;
      END IF;
      NEW.branch_id := v_branch_id;
    END IF;
    RETURN NEW;
  END IF;

  IF v_current_branch_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'orders' THEN
    v_table_id := nullif(v_row->>'table_id', '')::uuid;
    IF v_table_id IS NOT NULL THEN
      SELECT t.branch_id INTO v_branch_id
      FROM public.restaurant_tables t
      WHERE t.id = v_table_id
        AND t.restaurant_id = v_restaurant_id;
    END IF;
  ELSIF TG_TABLE_NAME IN ('payments', 'order_void_requests') THEN
    v_order_id := nullif(v_row->>'order_id', '')::uuid;
    IF v_order_id IS NOT NULL THEN
      SELECT o.branch_id INTO v_branch_id
      FROM public.orders o
      WHERE o.id = v_order_id
        AND o.restaurant_id = v_restaurant_id;
    END IF;
  END IF;

  IF v_branch_id IS NULL AND v_restaurant_id IS NOT NULL THEN
    SELECT b.id INTO v_branch_id
    FROM public.restaurant_branches b
    WHERE b.restaurant_id = v_restaurant_id
      AND b.is_default = true
      AND b.is_active = true
    LIMIT 1;
  END IF;

  NEW.branch_id := v_branch_id;
  RETURN NEW;
END;
$function$;