-- Branch-scoped Manager reporting. No direct table writes or broad reporting access.
CREATE OR REPLACE FUNCTION public.edmel_get_manager_sales_summary(
  p_restaurant_id uuid,
  p_branch_id uuid,
  p_module text DEFAULT 'sales'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
  v_timezone text;
  v_currency text;
  v_today date;
  v_start date;
  v_order_count bigint := 0;
  v_sales numeric(16,2) := 0;
  v_average numeric(16,2) := 0;
  v_paid_count bigint := 0;
  v_daily jsonb := '[]'::jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required.' USING errcode='42501';
  END IF;
  IF p_module NOT IN ('overview','sales') THEN
    RAISE EXCEPTION 'Unsupported reporting module.' USING errcode='22023';
  END IF;
  IF NOT public.edmel_manager_has_module_access(p_restaurant_id,p_branch_id,p_module,'view') THEN
    RAISE EXCEPTION 'You do not have reporting access for this branch.' USING errcode='42501';
  END IF;

  SELECT COALESCE(NULLIF(b.timezone,''),NULLIF(r.timezone,''),'UTC'),
         upper(COALESCE(r.currency,'USD'))
    INTO v_timezone,v_currency
  FROM public.restaurant_branches b
  JOIN public.restaurants r ON r.id=b.restaurant_id
  WHERE b.id=p_branch_id AND b.restaurant_id=p_restaurant_id AND b.is_active=true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The selected branch is unavailable.' USING errcode='22023';
  END IF;

  v_today := (now() AT TIME ZONE v_timezone)::date;
  v_start := v_today - 6;

  SELECT count(*),COALESCE(sum(o.total),0),COALESCE(avg(o.total),0)
    INTO v_paid_count,v_sales,v_average
  FROM public.orders o
  WHERE o.restaurant_id=p_restaurant_id
    AND o.branch_id=p_branch_id
    AND o.payment_status='paid'
    AND o.settled_at IS NOT NULL
    AND (o.settled_at AT TIME ZONE v_timezone)::date=v_today
    AND lower(COALESCE(o.order_status,o.status,'')) NOT IN ('cancelled','canceled','voided','refunded');

  SELECT count(*)
    INTO v_order_count
  FROM public.orders o
  WHERE o.restaurant_id=p_restaurant_id
    AND o.branch_id=p_branch_id
    AND o.settled_at IS NOT NULL
    AND (o.settled_at AT TIME ZONE v_timezone)::date BETWEEN v_start AND v_today
    AND lower(COALESCE(o.order_status,o.status,'')) NOT IN ('cancelled','canceled','voided','refunded');

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'day',d.day,
      'paid_orders',d.paid_orders,
      'sales',d.sales
    ) ORDER BY d.day),'[]'::jsonb)
    INTO v_daily
  FROM (
    SELECT days.day,
      count(o.id) FILTER (WHERE o.payment_status='paid' AND o.settled_at IS NOT NULL) AS paid_orders,
      COALESCE(sum(o.total) FILTER (WHERE o.payment_status='paid' AND o.settled_at IS NOT NULL),0)::numeric(16,2) AS sales
    FROM generate_series(v_start,v_today,interval '1 day') AS days(day)
    LEFT JOIN public.orders o
      ON o.restaurant_id=p_restaurant_id
     AND o.branch_id=p_branch_id
     AND o.settled_at IS NOT NULL
     AND (o.settled_at AT TIME ZONE v_timezone)::date=days.day::date
     AND lower(COALESCE(o.order_status,o.status,'')) NOT IN ('cancelled','canceled','voided','refunded')
    GROUP BY days.day
  ) d;

  RETURN jsonb_build_object(
    'branch_id',p_branch_id,
    'module',p_module,
    'currency',v_currency,
    'timezone',v_timezone,
    'today',v_today,
    'period_start',v_start,
    'period_end',v_today,
    'paid_orders_today',v_paid_count,
    'sales_today',v_sales,
    'average_paid_order_today',v_average,
    'settled_orders_7d',v_order_count,
    'daily',v_daily
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_get_manager_sales_summary(uuid,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edmel_get_manager_sales_summary(uuid,uuid,text) TO authenticated;
