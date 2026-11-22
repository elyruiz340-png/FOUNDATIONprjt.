-- Public shared-cart RPCs now require an active table in an active tenant branch.

CREATE OR REPLACE FUNCTION public.get_shared_table_cart(p_table_id uuid, p_qr_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurant_tables t
    JOIN public.restaurant_table_qr_tokens q ON q.table_id=t.id
    JOIN public.restaurant_branches b
      ON b.id=t.branch_id
     AND b.restaurant_id=t.restaurant_id
     AND b.is_active=true
    WHERE t.id=p_table_id
      AND t.is_active=true
      AND t.is_locked=false
      AND q.token=p_qr_token
  ) THEN
    RAISE EXCEPTION 'Invalid, inactive, locked, or unavailable table QR';
  END IF;

  INSERT INTO public.table_shared_carts(table_id)
  VALUES(p_table_id)
  ON CONFLICT DO NOTHING;

  SELECT jsonb_build_object('cart_items',cart_items,'revision',revision)
  INTO v
  FROM public.table_shared_carts
  WHERE table_id=p_table_id;

  RETURN v;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_shared_table_cart(
  p_table_id uuid,
  p_qr_token text,
  p_cart_items jsonb,
  p_expected_revision bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_revision bigint;
  v_locked boolean;
BEGIN
  IF jsonb_typeof(p_cart_items)<>'array' THEN RAISE EXCEPTION 'Cart must be an array'; END IF;
  IF jsonb_array_length(p_cart_items)>100 THEN RAISE EXCEPTION 'Cart has too many items'; END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurant_tables t
    JOIN public.restaurant_table_qr_tokens q ON q.table_id=t.id
    JOIN public.restaurant_branches b
      ON b.id=t.branch_id
     AND b.restaurant_id=t.restaurant_id
     AND b.is_active=true
    WHERE t.id=p_table_id
      AND t.is_active=true
      AND t.is_locked=false
      AND q.token=p_qr_token
  ) THEN
    RAISE EXCEPTION 'Invalid, inactive, locked, or unavailable table QR';
  END IF;

  INSERT INTO public.table_shared_carts(table_id) VALUES(p_table_id) ON CONFLICT DO NOTHING;
  SELECT revision,checkout_locked INTO v_revision,v_locked
  FROM public.table_shared_carts WHERE table_id=p_table_id FOR UPDATE;

  IF v_locked THEN RAISE EXCEPTION 'Checkout is in progress'; END IF;
  IF v_revision<>p_expected_revision THEN
    RETURN jsonb_build_object('conflict',true,'revision',v_revision);
  END IF;

  UPDATE public.table_shared_carts
  SET cart_items=p_cart_items,revision=revision+1,updated_at=now()
  WHERE table_id=p_table_id
  RETURNING revision INTO v_revision;

  RETURN jsonb_build_object('conflict',false,'revision',v_revision);
END;
$function$;

CREATE OR REPLACE FUNCTION public.halina_lock_shared_cart_for_checkout(
  p_table_id uuid,
  p_qr_token text,
  p_expected_revision bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_items jsonb;
  v_rev bigint;
  v_locked boolean;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurant_tables t
    JOIN public.restaurant_table_qr_tokens q ON q.table_id=t.id
    JOIN public.restaurant_branches b
      ON b.id=t.branch_id
     AND b.restaurant_id=t.restaurant_id
     AND b.is_active=true
    WHERE t.id=p_table_id
      AND t.is_active=true
      AND t.is_locked=false
      AND q.token=p_qr_token
  ) THEN
    RAISE EXCEPTION 'Invalid, inactive, locked, or unavailable table QR';
  END IF;

  SELECT cart_items,revision,checkout_locked
  INTO v_items,v_rev,v_locked
  FROM public.table_shared_carts
  WHERE table_id=p_table_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Shared cart not found'; END IF;
  IF v_locked THEN RAISE EXCEPTION 'Another device is already checking out'; END IF;
  IF v_rev<>p_expected_revision THEN
    RETURN jsonb_build_object('success',false,'conflict',true,'revision',v_rev);
  END IF;
  IF jsonb_array_length(v_items)=0 THEN RAISE EXCEPTION 'Shared cart is empty'; END IF;

  UPDATE public.table_shared_carts
  SET checkout_locked=true,updated_at=now()
  WHERE table_id=p_table_id;

  RETURN jsonb_build_object('success',true,'revision',v_rev,'cart_items',v_items);
END;
$function$;

CREATE OR REPLACE FUNCTION public.halina_finish_shared_cart_checkout(
  p_table_id uuid,
  p_qr_token text,
  p_clear boolean,
  p_submission_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_restaurant_id uuid;
  v_branch_id uuid;
  v_locked boolean;
BEGIN
  SELECT rt.restaurant_id,rt.branch_id
  INTO v_restaurant_id,v_branch_id
  FROM public.restaurant_tables rt
  JOIN public.restaurant_table_qr_tokens q ON q.table_id=rt.id
  JOIN public.restaurant_branches b
    ON b.id=rt.branch_id
   AND b.restaurant_id=rt.restaurant_id
   AND b.is_active=true
  WHERE rt.id=p_table_id
    AND q.token=p_qr_token
    AND rt.is_active=true
    AND rt.is_locked=false;

  IF v_restaurant_id IS NULL OR v_branch_id IS NULL THEN
    RAISE EXCEPTION 'Invalid, inactive, locked, or unavailable table QR';
  END IF;

  SELECT c.checkout_locked INTO v_locked
  FROM public.table_shared_carts c
  WHERE c.table_id=p_table_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Shared cart not found'; END IF;

  IF p_clear THEN
    IF p_submission_key IS NULL OR NOT EXISTS (
      SELECT 1
      FROM public.orders o
      WHERE o.restaurant_id=v_restaurant_id
        AND o.branch_id=v_branch_id
        AND o.table_id=p_table_id
        AND o.submission_key=p_submission_key
    ) THEN
      RAISE EXCEPTION 'The shared cart cannot be cleared without a matching saved order';
    END IF;
  END IF;

  IF v_locked IS DISTINCT FROM true THEN
    IF p_clear=false THEN
      RETURN jsonb_build_object('success',true,'already_unlocked',true);
    END IF;
    RAISE EXCEPTION 'Shared cart is not locked';
  END IF;

  UPDATE public.table_shared_carts
  SET cart_items=CASE WHEN p_clear THEN '[]'::jsonb ELSE cart_items END,
      revision=revision+CASE WHEN p_clear THEN 1 ELSE 0 END,
      checkout_locked=false,
      updated_at=now()
  WHERE table_id=p_table_id;

  RETURN jsonb_build_object('success',true);
END;
$function$;

REVOKE ALL ON FUNCTION public.halina_finish_shared_cart_checkout(uuid,text,boolean) FROM PUBLIC, anon, authenticated;
