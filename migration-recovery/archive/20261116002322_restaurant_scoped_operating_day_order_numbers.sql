
CREATE TABLE IF NOT EXISTS public.restaurant_daily_order_counters (
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE RESTRICT,
  operating_date date NOT NULL,
  last_number bigint NOT NULL DEFAULT 0 CHECK (last_number >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (restaurant_id, operating_date)
);

ALTER TABLE public.restaurant_daily_order_counters ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.restaurant_daily_order_counters FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.generate_daily_order_number()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
  v_timezone text;
  v_operating_hours jsonb;
  v_local_now timestamp;
  v_local_date date;
  v_candidate_date date;
  v_day_name text;
  v_day_config jsonb;
  v_open_time time;
  v_operating_date date;
  v_operating_start timestamptz;
  v_existing_max bigint;
  v_next_number bigint;
  v_offset integer;
BEGIN
  IF NEW.restaurant_id IS NULL THEN
    RAISE EXCEPTION 'A restaurant_id is required to generate an order number';
  END IF;

  SELECT
    COALESCE(NULLIF(BTRIM(r.timezone), ''), 'UTC'),
    COALESCE(r.operating_hours, '{}'::jsonb)
  INTO v_timezone, v_operating_hours
  FROM public.restaurants r
  WHERE r.id = NEW.restaurant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Restaurant not found while generating order number';
  END IF;

  v_local_now := now() AT TIME ZONE v_timezone;
  v_local_date := v_local_now::date;

  -- Match the restaurant's latest scheduled opening time, as used by the
  -- Cashier operating-day view. Search the previous seven calendar days.
  FOR v_offset IN 0..7 LOOP
    v_candidate_date := v_local_date - v_offset;
    v_day_name := lower(to_char(v_candidate_date, 'FMDay'));
    v_day_config := v_operating_hours -> v_day_name;

    IF COALESCE((v_day_config ->> 'is_open')::boolean, false) THEN
      v_open_time := COALESCE(
        NULLIF(v_day_config ->> 'open_time', '')::time,
        time '00:00'
      );

      IF (v_candidate_date + v_open_time) <= v_local_now THEN
        v_operating_date := v_candidate_date;
        v_operating_start := (v_candidate_date + v_open_time) AT TIME ZONE v_timezone;
        EXIT;
      END IF;
    END IF;
  END LOOP;

  -- If no open day is configured in the lookback window, use local midnight.
  IF v_operating_date IS NULL THEN
    v_operating_date := v_local_date;
    v_operating_start := v_local_date::timestamp AT TIME ZONE v_timezone;
  END IF;

  -- Preserve the highest number already used during this operating day.
  SELECT COALESCE(MAX(o.order_number), 0)
  INTO v_existing_max
  FROM public.orders o
  WHERE o.restaurant_id = NEW.restaurant_id
    AND o.created_at >= v_operating_start;

  -- The UPSERT serializes concurrent orders for the same tenant and day.
  INSERT INTO public.restaurant_daily_order_counters (
    restaurant_id, operating_date, last_number, updated_at
  )
  VALUES (
    NEW.restaurant_id, v_operating_date, v_existing_max + 1, now()
  )
  ON CONFLICT (restaurant_id, operating_date)
  DO UPDATE SET
    last_number = GREATEST(
      public.restaurant_daily_order_counters.last_number,
      EXCLUDED.last_number - 1
    ) + 1,
    updated_at = now()
  RETURNING last_number INTO v_next_number;

  NEW.order_number := v_next_number;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.place_order_with_stock(
  p_restaurant_id uuid,
  p_table_number text,
  p_order_type text,
  p_items jsonb,
  p_total numeric,
  p_payment_method text,
  p_payment_status text,
  p_payment_reference text,
  p_special_instructions text,
  p_submission_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  item jsonb;
  v_product_id text;
  v_quantity integer;
  v_stock_group text;
  v_remaining integer;
  v_order_id uuid;
  v_order_number bigint;
  v_existing_order_id uuid;
  v_existing_order_number bigint;
BEGIN
  IF p_submission_key IS NULL THEN
    RAISE EXCEPTION 'A submission key is required';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Order must contain at least one item';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_restaurant_id::text || ':' || p_submission_key::text, 0)
  );

  SELECT id, order_number
  INTO v_existing_order_id, v_existing_order_number
  FROM public.orders
  WHERE restaurant_id = p_restaurant_id
    AND submission_key = p_submission_key
  LIMIT 1;

  IF v_existing_order_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'order_id', v_existing_order_id,
      'order_number', v_existing_order_number,
      'duplicate_submission', true
    );
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := NULLIF(BTRIM(item->>'product_id'), '');
    IF v_product_id IS NULL THEN
      RAISE EXCEPTION 'Every order item must have a product_id';
    END IF;

    IF COALESCE(item->>'quantity','') !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'Invalid quantity for product: %', v_product_id;
    END IF;
    v_quantity := (item->>'quantity')::integer;
    IF v_quantity < 1 THEN
      RAISE EXCEPTION 'Quantity must be at least 1 for product: %', v_product_id;
    END IF;

    SELECT ps.stock_group, ps.stock_remaining
      INTO v_stock_group, v_remaining
    FROM public."PRODUCT_STOCK" ps
    WHERE ps.product_id = v_product_id
       OR (ps.stock_group = 'chicken-wings'
           AND EXISTS (
             SELECT 1 FROM public."PRODUCT_STOCK" wing
             WHERE wing.product_id = v_product_id
               AND wing.stock_group = 'chicken-wings'
           ))
    ORDER BY CASE WHEN ps.product_id = v_product_id THEN 0 ELSE 1 END
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Stock not configured for product: %', v_product_id;
    END IF;

    IF v_remaining < v_quantity THEN
      RAISE EXCEPTION 'Not enough stock for product: %. Remaining: %, Requested: %',
        v_product_id, v_remaining, v_quantity;
    END IF;
  END LOOP;

  INSERT INTO public.orders (
    restaurant_id, table_number, order_type, items, total, status,
    payment_method, payment_status, payment_reference, special_instructions,
    submission_key
  )
  VALUES (
    p_restaurant_id, p_table_number, p_order_type, p_items, p_total, 'new',
    p_payment_method, p_payment_status, p_payment_reference,
    NULLIF(BTRIM(p_special_instructions), ''), p_submission_key
  )
  RETURNING id, order_number INTO v_order_id, v_order_number;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := item->>'product_id';
    v_quantity := (item->>'quantity')::integer;

    SELECT stock_group INTO v_stock_group
    FROM public."PRODUCT_STOCK"
    WHERE product_id = v_product_id
    LIMIT 1;

    IF v_stock_group = 'chicken-wings' THEN
      UPDATE public."PRODUCT_STOCK"
      SET stock_remaining = stock_remaining - v_quantity
      WHERE stock_group = 'chicken-wings';
    ELSE
      UPDATE public."PRODUCT_STOCK"
      SET stock_remaining = stock_remaining - v_quantity
      WHERE product_id = v_product_id;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'order_id', v_order_id,
    'order_number', v_order_number,
    'duplicate_submission', false
  );
END;
$function$;
