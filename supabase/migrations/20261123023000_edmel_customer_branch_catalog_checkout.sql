-- Make customer checkout and stock availability resolve the same effective menu catalog as the QR context.
DO $patch$
DECLARE v_def text;
BEGIN
  v_def:=pg_get_functiondef('public.edmel_customer_place_order(uuid,text,uuid,text,text,jsonb,text,text,uuid)'::regprocedure);
  v_def:=replace(v_def,'  v_branch_id uuid;','  v_branch_id uuid;\n  v_catalog_branch_id uuid;');
  v_def:=replace(v_def,
$old$
  IF v_branch_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.restaurant_branches b
    WHERE b.id = v_branch_id
      AND b.restaurant_id = p_restaurant_id
      AND b.is_active = true
  ) THEN
    RAISE EXCEPTION 'The selected table does not belong to an active branch';
  END IF;
$old$,
$new$
  IF v_branch_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.restaurant_branches b
    WHERE b.id = v_branch_id
      AND b.restaurant_id = p_restaurant_id
      AND b.is_active = true
  ) THEN
    RAISE EXCEPTION 'The selected table does not belong to an active branch';
  END IF;

  SELECT CASE WHEN b.menu_catalog_mode='inherit'
    THEN coalesce(b.menu_source_branch_id,b.id) ELSE b.id END
  INTO v_catalog_branch_id
  FROM public.restaurant_branches b
  WHERE b.id=v_branch_id AND b.restaurant_id=p_restaurant_id AND b.is_active=true;

  IF v_catalog_branch_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.restaurant_branches b
    WHERE b.id=v_catalog_branch_id AND b.restaurant_id=p_restaurant_id AND b.is_active=true
  ) THEN
    RAISE EXCEPTION 'The selected branch menu catalog is unavailable';
  END IF;
$new$);
  v_def:=replace(v_def,'AND (mi.branch_id IS NULL OR mi.branch_id = v_branch_id)','AND mi.branch_id = v_catalog_branch_id');
  v_def:=replace(v_def,'AND (mc.branch_id IS NULL OR mc.branch_id = v_branch_id)','AND mc.branch_id = v_catalog_branch_id');
  IF position('v_catalog_branch_id' in v_def)=0
     OR position('mi.branch_id = v_catalog_branch_id' in v_def)=0
     OR position('mc.branch_id = v_catalog_branch_id' in v_def)=0 THEN
    RAISE EXCEPTION 'Could not safely patch customer checkout menu catalog resolution';
  END IF;
  EXECUTE v_def;
END;
$patch$;

DO $patch$
DECLARE v_def text;
BEGIN
  v_def:=pg_get_functiondef('public.edmel_get_customer_stock_availability(uuid,text,uuid,text)'::regprocedure);
  v_def:=replace(v_def,'  v_branch_id uuid;','  v_branch_id uuid;\n  v_catalog_branch_id uuid;');
  v_def:=replace(v_def,
$old$
  IF v_branch_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.restaurant_branches b
    WHERE b.id = v_branch_id
      AND b.restaurant_id = p_restaurant_id
      AND b.is_active = true
  ) THEN
    RAISE EXCEPTION 'The selected table is not active for this restaurant';
  END IF;
$old$,
$new$
  IF v_branch_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.restaurant_branches b
    WHERE b.id = v_branch_id
      AND b.restaurant_id = p_restaurant_id
      AND b.is_active = true
  ) THEN
    RAISE EXCEPTION 'The selected table is not active for this restaurant';
  END IF;

  SELECT CASE WHEN b.menu_catalog_mode='inherit'
    THEN coalesce(b.menu_source_branch_id,b.id) ELSE b.id END
  INTO v_catalog_branch_id
  FROM public.restaurant_branches b
  WHERE b.id=v_branch_id AND b.restaurant_id=p_restaurant_id AND b.is_active=true;

  IF v_catalog_branch_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.restaurant_branches b
    WHERE b.id=v_catalog_branch_id AND b.restaurant_id=p_restaurant_id AND b.is_active=true
  ) THEN
    RAISE EXCEPTION 'The selected branch menu catalog is unavailable';
  END IF;
$new$);
  v_def:=replace(v_def,'AND (mi.branch_id IS NULL OR mi.branch_id = v_branch_id)','AND mi.branch_id = v_catalog_branch_id');
  IF position('v_catalog_branch_id' in v_def)=0
     OR position('mi.branch_id = v_catalog_branch_id' in v_def)=0 THEN
    RAISE EXCEPTION 'Could not safely patch customer stock availability menu catalog resolution';
  END IF;
  EXECUTE v_def;
END;
$patch$;
