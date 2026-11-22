-- table_shared_carts and restaurant_table_qr_tokens do not store restaurant_id.
-- Derive tenant ownership for validation, but only assign their branch_id column.

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

  IF TG_TABLE_NAME = 'PRODUCT_STOCK' AND v_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'restaurant_id is required when creating inventory for EDMEL tenants';
  END IF;

  IF TG_TABLE_NAME IN ('table_shared_carts', 'restaurant_table_qr_tokens') THEN
    v_table_id := nullif(v_row->>'table_id', '')::uuid;
    IF v_table_id IS NULL THEN
      RAISE EXCEPTION 'table_id is required for table-scoped records';
    END IF;
    SELECT t.branch_id, t.restaurant_id
    INTO v_branch_id, v_restaurant_id
    FROM public.restaurant_tables t
    WHERE t.id = v_table_id;
    IF v_branch_id IS NULL OR v_restaurant_id IS NULL THEN
      RAISE EXCEPTION 'The selected table does not belong to an active restaurant branch';
    END IF;
    IF v_current_branch_id IS NOT NULL AND v_current_branch_id <> v_branch_id THEN
      RAISE EXCEPTION 'The supplied branch does not match the selected table';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.restaurant_branches b
      WHERE b.id = v_branch_id AND b.restaurant_id = v_restaurant_id AND b.is_active = true
    ) THEN
      RAISE EXCEPTION 'The selected table branch is inactive';
    END IF;
    NEW.branch_id := v_branch_id;
    RETURN NEW;
  END IF;

  IF v_current_branch_id IS NULL THEN
    IF TG_TABLE_NAME = 'orders' THEN
      v_table_id := nullif(v_row->>'table_id', '')::uuid;
      IF v_table_id IS NOT NULL THEN
        SELECT t.branch_id INTO v_branch_id
        FROM public.restaurant_tables t
        WHERE t.id = v_table_id AND t.restaurant_id = v_restaurant_id;
      END IF;
    ELSIF TG_TABLE_NAME IN ('payments', 'order_void_requests') THEN
      v_order_id := nullif(v_row->>'order_id', '')::uuid;
      IF v_order_id IS NOT NULL THEN
        SELECT o.branch_id INTO v_branch_id
        FROM public.orders o
        WHERE o.id = v_order_id AND o.restaurant_id = v_restaurant_id;
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
  ELSE
    v_branch_id := v_current_branch_id;
  END IF;

  IF v_restaurant_id IS NOT NULL AND v_branch_id IS NULL THEN
    RAISE EXCEPTION 'An active branch is required for this tenant record';
  END IF;

  IF v_branch_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.restaurant_branches b
    WHERE b.id = v_branch_id
      AND b.restaurant_id = v_restaurant_id
      AND b.is_active = true
  ) THEN
    RAISE EXCEPTION 'The selected branch is not active for this restaurant';
  END IF;

  NEW.branch_id := v_branch_id;
  RETURN NEW;
END;
$function$;
