-- Require a verified table QR for public customer stock and checkout RPCs.
-- The Customer Ordering frontend already requires table_id + token before loading.
-- Keep anon execution for QR customers, but remove the legacy table-number-only fallback.

DO $patch$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := pg_get_functiondef(
    'public.edmel_customer_place_order(uuid,text,uuid,text,text,jsonb,text,text,uuid)'::regprocedure
  );

  v_old := $old$
  ELSE
    SELECT rt.id, rt.table_number, rt.branch_id
      INTO v_table_id, v_table_number, v_branch_id
    FROM public.restaurant_tables rt
    WHERE rt.restaurant_id=p_restaurant_id
      AND lower(BTRIM(rt.table_number))=lower(BTRIM(p_table_number))
      AND rt.is_active=true
      AND rt.is_locked=false
    LIMIT 1;
  END IF;
$old$;

  v_new := $new$
  ELSE
    RAISE EXCEPTION 'A verified table QR is required to place a customer order'
      USING errcode='42501';
  END IF;
$new$;

  IF position(v_old in v_def)=0 THEN
    RAISE EXCEPTION 'Customer order QR hardening stopped: expected legacy fallback was not found';
  END IF;

  v_def := replace(v_def,v_old,v_new);
  EXECUTE v_def;
END;
$patch$;

DO $patch$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := pg_get_functiondef(
    'public.edmel_get_customer_stock_availability(uuid,text,uuid,text)'::regprocedure
  );

  v_old := $old$
  ELSE
    SELECT rt.branch_id INTO v_branch_id
    FROM public.restaurant_tables rt
    WHERE rt.restaurant_id = p_restaurant_id
      AND lower(btrim(rt.table_number)) = lower(btrim(p_table_number))
      AND rt.is_active = true
      AND rt.is_locked = false
    ORDER BY rt.created_at
    LIMIT 1;
  END IF;
$old$;

  v_new := $new$
  ELSE
    RAISE EXCEPTION 'A verified table QR is required to view customer stock availability'
      USING errcode='42501';
  END IF;
$new$;

  IF position(v_old in v_def)=0 THEN
    RAISE EXCEPTION 'Customer stock QR hardening stopped: expected legacy fallback was not found';
  END IF;

  v_def := replace(v_def,v_old,v_new);
  EXECUTE v_def;
END;
$patch$;
