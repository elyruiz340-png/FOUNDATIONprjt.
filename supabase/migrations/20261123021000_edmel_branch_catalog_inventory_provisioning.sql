-- EDMEL branch catalog and inventory provisioning.
-- Existing operational records are retained. Branch stock starts at zero.

ALTER TABLE public.restaurant_branches
  ADD COLUMN IF NOT EXISTS menu_catalog_mode text NOT NULL DEFAULT 'inherit',
  ADD COLUMN IF NOT EXISTS menu_source_branch_id uuid;

ALTER TABLE public.restaurant_branches
  DROP CONSTRAINT IF EXISTS restaurant_branches_menu_catalog_mode_check;
ALTER TABLE public.restaurant_branches
  ADD CONSTRAINT restaurant_branches_menu_catalog_mode_check
  CHECK (menu_catalog_mode = ANY (ARRAY['inherit'::text,'override'::text,'independent'::text]));

UPDATE public.restaurant_branches b
SET menu_catalog_mode = CASE WHEN b.is_default THEN 'independent' ELSE 'inherit' END,
    menu_source_branch_id = coalesce(
      (SELECT d.id FROM public.restaurant_branches d
       WHERE d.restaurant_id=b.restaurant_id AND d.is_default=true AND d.is_active=true LIMIT 1),
      b.id
    )
WHERE b.menu_source_branch_id IS NULL;

ALTER TABLE public.restaurant_branches
  DROP CONSTRAINT IF EXISTS restaurant_branches_menu_source_branch_fk;
ALTER TABLE public.restaurant_branches
  ADD CONSTRAINT restaurant_branches_menu_source_branch_fk
  FOREIGN KEY (menu_source_branch_id,restaurant_id)
  REFERENCES public.restaurant_branches(id,restaurant_id)
  ON DELETE RESTRICT;

-- Menu categories are unique within a branch, not across every branch of a tenant.
DROP INDEX IF EXISTS public.menu_categories_restaurant_name_ci_uidx;
CREATE UNIQUE INDEX IF NOT EXISTS menu_categories_restaurant_branch_name_ci_uidx
ON public.menu_categories(
  restaurant_id,
  coalesce(branch_id,'00000000-0000-0000-0000-000000000000'::uuid),
  lower(btrim(name))
);

-- Inventory product identifiers are tenant-wide logical IDs with one physical
-- stock row per branch. This allows the same menu item to deduct from each branch's
-- independent quantity without changing the menu item's stock_product_id.
DROP INDEX IF EXISTS public.product_stock_product_id_key;
DROP INDEX IF EXISTS public.product_stock_product_id_unique_idx;
CREATE UNIQUE INDEX IF NOT EXISTS product_stock_unassigned_product_id_uidx
ON public."PRODUCT_STOCK"(product_id)
WHERE product_id IS NOT NULL AND branch_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS product_stock_branch_product_id_uidx
ON public."PRODUCT_STOCK"(restaurant_id,branch_id,product_id)
WHERE product_id IS NOT NULL AND branch_id IS NOT NULL;

CREATE OR REPLACE FUNCTION private.edmel_clone_branch_catalog(
  p_restaurant_id uuid,
  p_source_branch_id uuid,
  p_target_branch_id uuid,
  p_menu_mode text,
  p_actor_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor public.restaurant_users%rowtype;
  v_category_map jsonb := '{}'::jsonb;
  v_stock_copied integer := 0;
  v_categories_copied integer := 0;
  v_items_copied integer := 0;
  v_target_categories integer := 0;
  v_target_items integer := 0;
  v_missing_links integer := 0;
BEGIN
  IF p_restaurant_id IS NULL OR p_source_branch_id IS NULL OR p_target_branch_id IS NULL
     OR p_actor_user_id IS NULL OR p_menu_mode NOT IN ('inherit','override','independent') THEN
    RAISE EXCEPTION 'Invalid branch catalog provisioning request' USING errcode='22023';
  END IF;

  SELECT * INTO v_actor
  FROM public.restaurant_users ru
  WHERE ru.restaurant_id=p_restaurant_id AND ru.user_id=p_actor_user_id
    AND ru.is_active=true AND lower(ru.role)='owner'
  LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'Owner access required for branch catalog provisioning' USING errcode='42501'; END IF;

  IF NOT EXISTS(SELECT 1 FROM public.restaurant_branches b
    WHERE b.id=p_source_branch_id AND b.restaurant_id=p_restaurant_id AND b.is_active=true)
    OR NOT EXISTS(SELECT 1 FROM public.restaurant_branches b
    WHERE b.id=p_target_branch_id AND b.restaurant_id=p_restaurant_id AND b.is_active=true) THEN
    RAISE EXCEPTION 'Source or target branch is unavailable' USING errcode='22023';
  END IF;

  IF p_source_branch_id=p_target_branch_id THEN
    RETURN jsonb_build_object('success',true,'stock_items_copied',0,'categories_copied',0,'menu_items_copied',0,'menu_copy_skipped',true);
  END IF;

  -- Copy inventory definitions, never stock quantities. Every new branch starts at zero.
  INSERT INTO public."PRODUCT_STOCK"(
    product_name,stock_total,stock_remaining,product_id,stock_group,category,image_url,
    is_available,is_archived,restaurant_id,branch_id
  )
  SELECT s.product_name,0,0,s.product_id,s.stock_group,s.category,s.image_url,
         s.is_available,s.is_archived,s.restaurant_id,p_target_branch_id
  FROM public."PRODUCT_STOCK" s
  WHERE s.restaurant_id=p_restaurant_id AND s.branch_id=p_source_branch_id
    AND s.product_id IS NOT NULL
    AND NOT EXISTS(
      SELECT 1 FROM public."PRODUCT_STOCK" t
      WHERE t.restaurant_id=p_restaurant_id AND t.branch_id=p_target_branch_id
        AND t.product_id=s.product_id
    );
  GET DIAGNOSTICS v_stock_copied = ROW_COUNT;

  IF p_menu_mode IN ('override','independent') THEN
    SELECT count(*) INTO v_target_categories FROM public.menu_categories
    WHERE restaurant_id=p_restaurant_id AND branch_id=p_target_branch_id;
    SELECT count(*) INTO v_target_items FROM public.menu_items
    WHERE restaurant_id=p_restaurant_id AND branch_id=p_target_branch_id;

    IF v_target_categories=0 AND v_target_items=0 THEN
      SELECT coalesce(jsonb_object_agg(c.id::text,gen_random_uuid()::text),'{}'::jsonb)
      INTO v_category_map
      FROM public.menu_categories c
      WHERE c.restaurant_id=p_restaurant_id AND c.branch_id=p_source_branch_id;

      INSERT INTO public.menu_categories(id,restaurant_id,name,description,sort_order,is_active,image_url,branch_id)
      SELECT (v_category_map->>c.id::text)::uuid,c.restaurant_id,c.name,c.description,
             c.sort_order,c.is_active,c.image_url,p_target_branch_id
      FROM public.menu_categories c
      WHERE c.restaurant_id=p_restaurant_id AND c.branch_id=p_source_branch_id;
      GET DIAGNOSTICS v_categories_copied = ROW_COUNT;

      SELECT count(*) INTO v_missing_links
      FROM public.menu_items m
      WHERE m.restaurant_id=p_restaurant_id AND m.branch_id=p_source_branch_id
        AND m.stock_product_id IS NOT NULL
        AND NOT EXISTS(
          SELECT 1 FROM public."PRODUCT_STOCK" s
          WHERE s.restaurant_id=p_restaurant_id AND s.branch_id=p_target_branch_id
            AND s.product_id=m.stock_product_id
        );
      IF v_missing_links>0 THEN
        RAISE EXCEPTION 'Some menu items reference inventory products that are not available in the source branch. Fix the stock links before copying this catalog.';
      END IF;

      INSERT INTO public.menu_items(
        restaurant_id,category_id,name,description,price,image_url,is_available,
        sort_order,stock_product_id,branch_id
      )
      SELECT m.restaurant_id,
        CASE WHEN m.category_id IS NULL THEN NULL ELSE (v_category_map->>m.category_id::text)::uuid END,
        m.name,m.description,m.price,m.image_url,m.is_available,m.sort_order,m.stock_product_id,p_target_branch_id
      FROM public.menu_items m
      WHERE m.restaurant_id=p_restaurant_id AND m.branch_id=p_source_branch_id;
      GET DIAGNOSTICS v_items_copied = ROW_COUNT;
    END IF;
  END IF;

  INSERT INTO public.audit_logs(
    restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
    record_type,record_id,result,details
  ) VALUES(
    p_restaurant_id,p_actor_user_id,
    coalesce(nullif(btrim(v_actor.display_name),''),nullif(btrim(v_actor.full_name),''),'Owner'),
    'owner','Branch Management','Branch catalog initialized',
    'restaurant_branch',p_target_branch_id::text,'success',
    jsonb_build_object('source_branch_id',p_source_branch_id,'menu_mode',p_menu_mode,
      'stock_items_copied',v_stock_copied,'categories_copied',v_categories_copied,
      'menu_items_copied',v_items_copied)
  );

  RETURN jsonb_build_object(
    'success',true,'stock_items_copied',v_stock_copied,
    'categories_copied',v_categories_copied,'menu_items_copied',v_items_copied,
    'menu_copy_skipped',(p_menu_mode IN ('override','independent') AND (v_target_categories>0 OR v_target_items>0))
  );
END;
$function$;

REVOKE ALL ON FUNCTION private.edmel_clone_branch_catalog(uuid,uuid,uuid,text,uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.edmel_create_restaurant_branch_configured(
  p_restaurant_slug text,p_name text,p_code text,p_address text DEFAULT NULL,
  p_timezone text DEFAULT NULL,p_settings_modes jsonb DEFAULT '{}'::jsonb,
  p_menu_catalog_mode text DEFAULT 'inherit'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_result jsonb;
  v_branch_id uuid;
  v_restaurant_id uuid;
  v_source_branch_id uuid;
  v_catalog_result jsonb;
BEGIN
  IF p_menu_catalog_mode NOT IN ('inherit','override','independent') THEN
    RAISE EXCEPTION 'Unsupported menu catalog mode' USING errcode='22023';
  END IF;
  v_result:=public.edmel_create_restaurant_branch_with_modes(
    p_restaurant_slug,p_name,p_code,p_address,p_timezone,p_settings_modes
  );
  v_branch_id:=(v_result#>>'{branch,id}')::uuid;
  SELECT b.restaurant_id INTO v_restaurant_id
  FROM public.restaurant_branches b WHERE b.id=v_branch_id;
  SELECT b.id INTO v_source_branch_id
  FROM public.restaurant_branches b
  WHERE b.restaurant_id=v_restaurant_id AND b.is_default=true AND b.is_active=true
  LIMIT 1;
  IF v_source_branch_id IS NULL THEN RAISE EXCEPTION 'An active main branch is required to provision branch catalog data'; END IF;

  UPDATE public.restaurant_branches
  SET menu_catalog_mode=p_menu_catalog_mode,menu_source_branch_id=v_source_branch_id,updated_at=now()
  WHERE id=v_branch_id AND restaurant_id=v_restaurant_id;

  v_catalog_result:=private.edmel_clone_branch_catalog(
    v_restaurant_id,v_source_branch_id,v_branch_id,p_menu_catalog_mode,auth.uid()
  );
  RETURN v_result || jsonb_build_object('menu_catalog',v_catalog_result,'menu_catalog_mode',p_menu_catalog_mode);
END;
$function$;

CREATE OR REPLACE FUNCTION public.edmel_update_restaurant_branch_configured(
  p_restaurant_slug text,p_branch_id uuid,p_name text,p_code text,
  p_address text,p_timezone text,p_settings_modes jsonb DEFAULT '{}'::jsonb,
  p_menu_catalog_mode text DEFAULT 'inherit'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_result jsonb;
  v_restaurant_id uuid;
  v_source_branch_id uuid;
  v_is_default boolean;
  v_catalog_result jsonb;
BEGIN
  IF p_menu_catalog_mode NOT IN ('inherit','override','independent') THEN
    RAISE EXCEPTION 'Unsupported menu catalog mode' USING errcode='22023';
  END IF;
  v_result:=public.edmel_update_restaurant_branch(
    p_restaurant_slug,p_branch_id,p_name,p_code,p_address,p_timezone,p_settings_modes
  );
  v_restaurant_id:=(v_result#>>'{branch,restaurant_id}')::uuid;
  SELECT b.is_default INTO v_is_default FROM public.restaurant_branches b
  WHERE b.id=p_branch_id AND b.restaurant_id=v_restaurant_id;
  SELECT b.id INTO v_source_branch_id FROM public.restaurant_branches b
  WHERE b.restaurant_id=v_restaurant_id AND b.is_default=true AND b.is_active=true LIMIT 1;
  IF v_is_default THEN
    p_menu_catalog_mode:='independent';
    v_source_branch_id:=p_branch_id;
  END IF;
  IF v_source_branch_id IS NULL THEN RAISE EXCEPTION 'An active main branch is required to provision branch catalog data'; END IF;

  UPDATE public.restaurant_branches
  SET menu_catalog_mode=p_menu_catalog_mode,menu_source_branch_id=v_source_branch_id,updated_at=now()
  WHERE id=p_branch_id AND restaurant_id=v_restaurant_id;

  v_catalog_result:=private.edmel_clone_branch_catalog(
    v_restaurant_id,v_source_branch_id,p_branch_id,p_menu_catalog_mode,auth.uid()
  );
  RETURN v_result || jsonb_build_object('menu_catalog',v_catalog_result,'menu_catalog_mode',p_menu_catalog_mode);
END;
$function$;

CREATE OR REPLACE FUNCTION public.edmel_get_branch_menu_catalog_context(
  p_restaurant_id uuid,p_branch_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_branch public.restaurant_branches%rowtype;
  v_source_branch_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.edmel_has_branch_permission(p_branch_id,'orders') THEN
    RAISE EXCEPTION 'Menu access is not assigned for this branch' USING errcode='42501';
  END IF;
  SELECT * INTO v_branch FROM public.restaurant_branches b
  WHERE b.id=p_branch_id AND b.restaurant_id=p_restaurant_id AND b.is_active=true;
  IF NOT FOUND THEN RAISE EXCEPTION 'Branch not found or inactive' USING errcode='22023'; END IF;
  v_source_branch_id:=CASE WHEN v_branch.menu_catalog_mode='inherit'
    THEN coalesce(v_branch.menu_source_branch_id,p_branch_id)
    ELSE p_branch_id END;
  IF NOT EXISTS(SELECT 1 FROM public.restaurant_branches b
    WHERE b.id=v_source_branch_id AND b.restaurant_id=p_restaurant_id AND b.is_active=true) THEN
    RAISE EXCEPTION 'The source menu branch is unavailable' USING errcode='22023';
  END IF;
  RETURN jsonb_build_object('branch_id',p_branch_id,'menu_catalog_mode',v_branch.menu_catalog_mode,
    'catalog_branch_id',v_source_branch_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_create_restaurant_branch_configured(text,text,text,text,text,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.edmel_create_restaurant_branch_configured(text,text,text,text,text,jsonb,text) TO authenticated;
REVOKE ALL ON FUNCTION public.edmel_update_restaurant_branch_configured(text,uuid,text,text,text,text,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.edmel_update_restaurant_branch_configured(text,uuid,text,text,text,text,jsonb,text) TO authenticated;
REVOKE ALL ON FUNCTION public.edmel_get_branch_menu_catalog_context(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.edmel_get_branch_menu_catalog_context(uuid,uuid) TO authenticated;
