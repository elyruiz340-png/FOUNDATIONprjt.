-- EDMEL Phase 1: branch-scoped action permission foundation.
-- Isolated from Customer Ordering, Inventory, Tables and Cashier order-policy changes.
-- Legacy boolean permissions remain supported; new "modules" permissions are authoritative.

BEGIN;

CREATE OR REPLACE FUNCTION public.edmel_permission_json_allows(
  p_permissions jsonb,
  p_module text,
  p_action text
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_module_permissions jsonb;
BEGIN
  IF p_permissions IS NULL
     OR jsonb_typeof(p_permissions) <> 'object'
     OR p_module IS NULL
     OR p_action IS NULL
     OR p_action NOT IN ('view','create','edit','delete','approve','manage','void') THEN
    RETURN false;
  END IF;

  IF p_permissions ? 'modules' THEN
    IF jsonb_typeof(p_permissions->'modules') <> 'object' THEN
      RETURN false;
    END IF;

    v_module_permissions := p_permissions->'modules'->p_module;
    IF v_module_permissions IS NULL
       OR jsonb_typeof(v_module_permissions) <> 'object' THEN
      RETURN false;
    END IF;

    RETURN coalesce((v_module_permissions->>p_action)::boolean, false);
  END IF;

  -- Legacy mappings preserve the existing access model during migration.
  IF p_module = 'orders' AND p_action = 'void' THEN
    RETURN coalesce((p_permissions->>'void')::boolean, false)
       OR coalesce((p_permissions->>'orders')::boolean, false);
  END IF;
  IF p_module = 'payments' OR p_module = 'transactions' THEN
    RETURN coalesce((p_permissions->>'orders')::boolean, false);
  END IF;
  IF p_module = 'inventory' THEN
    RETURN coalesce((p_permissions->>'stocks')::boolean, false);
  END IF;
  IF p_module = 'staff' THEN
    RETURN coalesce((p_permissions->>'staff_management')::boolean, false);
  END IF;

  RETURN coalesce((p_permissions->>p_module)::boolean, false);
EXCEPTION
  WHEN invalid_text_representation THEN
    RETURN false;
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_permission_json_allows(jsonb,text,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.edmel_permission_json_allows(jsonb,text,text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.edmel_has_branch_action_permission(
  p_branch_id uuid,
  p_module text,
  p_action text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_restaurant_id uuid;
  v_role text;
  v_permissions jsonb;
BEGIN
  IF (SELECT auth.uid()) IS NULL
     OR p_branch_id IS NULL
     OR p_module IS NULL
     OR p_action IS NULL
     OR p_action NOT IN ('view','create','edit','delete','approve','manage','void') THEN
    RETURN false;
  END IF;

  SELECT b.restaurant_id
    INTO v_restaurant_id
  FROM public.restaurant_branches b
  WHERE b.id = p_branch_id
    AND b.is_active = true;

  IF v_restaurant_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT lower(coalesce(ru.role,'')), sba.permissions
    INTO v_role, v_permissions
  FROM public.restaurant_users ru
  LEFT JOIN public.staff_branch_access sba
    ON sba.restaurant_user_id = ru.id
   AND sba.restaurant_id = ru.restaurant_id
   AND sba.branch_id = p_branch_id
   AND sba.is_active = true
  WHERE ru.user_id = (SELECT auth.uid())
    AND ru.restaurant_id = v_restaurant_id
    AND ru.is_active = true
  ORDER BY CASE lower(ru.role)
    WHEN 'owner' THEN 1
    WHEN 'admin' THEN 2
    ELSE 3
  END
  LIMIT 1;

  IF v_role IS NULL THEN
    RETURN false;
  END IF;

  IF v_role IN ('owner','admin') THEN
    RETURN true;
  END IF;

  RETURN public.edmel_permission_json_allows(v_permissions,p_module,p_action);
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_has_branch_action_permission(uuid,text,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edmel_has_branch_action_permission(uuid,text,text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.edmel_can_assign_branch_permissions(
  p_branch_id uuid,
  p_permissions jsonb
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_actor_permissions jsonb;
  v_restaurant_id uuid;
  v_module record;
  v_action record;
  v_entry record;
  v_allowed_modules text[] := ARRAY[
    'overview','sales','settings','orders','expenses','staff','audit','branches','health','ai',
    'inventory','tables','dispatcher','payments','menu','discounts','vouchers','tax',
    'service_charge','receipts','printers','transactions'
  ];
  v_allowed_actions text[] := ARRAY['view','create','edit','delete','approve','manage'];
  v_allowed_legacy text[] := ARRAY[
    'orders','tables','stocks','dispatcher','settings','void','staff_management','modules'
  ];
BEGIN
  IF p_permissions IS NULL OR jsonb_typeof(p_permissions) <> 'object' THEN
    RETURN false;
  END IF;

  SELECT b.restaurant_id
    INTO v_restaurant_id
  FROM public.restaurant_branches b
  WHERE b.id = p_branch_id AND b.is_active = true;

  IF v_restaurant_id IS NULL THEN
    RETURN false;
  END IF;

  IF public.edmel_is_restaurant_owner_admin(v_restaurant_id) THEN
    RETURN true;
  END IF;

  SELECT sba.permissions
    INTO v_actor_permissions
  FROM public.staff_branch_access sba
  JOIN public.restaurant_users ru ON ru.id = sba.restaurant_user_id
  WHERE sba.branch_id = p_branch_id
    AND sba.restaurant_id = v_restaurant_id
    AND sba.is_active = true
    AND ru.user_id = (SELECT auth.uid())
    AND ru.is_active = true
    AND lower(coalesce(ru.position,'')) = 'manager'
    AND lower(coalesce(ru.role,'')) = 'staff'
  LIMIT 1;

  IF v_actor_permissions IS NULL
     OR NOT public.edmel_permission_json_allows(v_actor_permissions,'staff','manage') THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_each(p_permissions) e
    WHERE NOT (e.key = ANY(v_allowed_legacy))
  ) THEN
    RETURN false;
  END IF;

  IF coalesce((p_permissions->>'staff_management')::boolean,false) THEN
    RETURN false;
  END IF;

  IF p_permissions ? 'modules' THEN
    IF jsonb_typeof(p_permissions->'modules') <> 'object' THEN
      RETURN false;
    END IF;

    FOR v_module IN SELECT key,value FROM jsonb_each(p_permissions->'modules') LOOP
      IF NOT (v_module.key = ANY(v_allowed_modules))
         OR jsonb_typeof(v_module.value) <> 'object' THEN
        RETURN false;
      END IF;

      FOR v_action IN SELECT key,value FROM jsonb_each(v_module.value) LOOP
        IF NOT (v_action.key = ANY(v_allowed_actions))
           OR jsonb_typeof(v_action.value) <> 'boolean' THEN
          RETURN false;
        END IF;

        IF v_action.value = 'true'::jsonb
           AND NOT public.edmel_permission_json_allows(v_actor_permissions,v_module.key,v_action.key) THEN
          RETURN false;
        END IF;
      END LOOP;
    END LOOP;
  END IF;

  -- Validate and constrain any legacy flags included in the payload.
  FOR v_entry IN
    SELECT key,value FROM jsonb_each(p_permissions)
    WHERE key <> 'modules' AND key <> 'staff_management'
  LOOP
    IF jsonb_typeof(v_entry.value) <> 'boolean' THEN
      RETURN false;
    END IF;

    IF v_entry.value = 'true'::jsonb
       AND NOT public.edmel_permission_json_allows(v_actor_permissions,v_entry.key,'view') THEN
      RETURN false;
    END IF;
  END LOOP;

  RETURN true;
EXCEPTION
  WHEN invalid_text_representation THEN
    RETURN false;
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_can_assign_branch_permissions(uuid,jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edmel_can_assign_branch_permissions(uuid,jsonb)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.edmel_manager_update_staff_branch_permissions(
  p_actor_user_id uuid,
  p_restaurant_id uuid,
  p_branch_id uuid,
  p_target_restaurant_user_id uuid,
  p_permissions jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_actor public.restaurant_users%ROWTYPE;
  v_target public.restaurant_users%ROWTYPE;
  v_manager_permissions jsonb;
  v_target_permissions jsonb;
  v_target_access_id uuid;
  v_new_permissions jsonb;
  v_module record;
  v_action record;
  v_entry record;
  v_actor_name text;
  v_target_name text;
  v_branch_name text;
  v_allowed_modules text[] := ARRAY[
    'overview','sales','settings','orders','expenses','staff','audit','branches','health','ai',
    'inventory','tables','dispatcher','payments','menu','discounts','vouchers','tax',
    'service_charge','receipts','printers','transactions'
  ];
  v_allowed_actions text[] := ARRAY['view','create','edit','delete','approve','manage'];
  v_allowed_legacy text[] := ARRAY[
    'orders','tables','stocks','dispatcher','settings','void','staff_management','modules'
  ];
BEGIN
  IF p_actor_user_id IS NULL OR p_restaurant_id IS NULL
     OR p_branch_id IS NULL OR p_target_restaurant_user_id IS NULL THEN
    RAISE EXCEPTION 'Missing required account or branch context' USING ERRCODE = '22023';
  END IF;

  IF p_permissions IS NULL OR jsonb_typeof(p_permissions) <> 'object' THEN
    RAISE EXCEPTION 'Invalid staff permissions' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (SELECT 1 FROM jsonb_each(p_permissions) e WHERE NOT (e.key = ANY(v_allowed_legacy))) THEN
    RAISE EXCEPTION 'Unsupported staff permission field' USING ERRCODE = '22023';
  END IF;

  IF coalesce((p_permissions->>'staff_management')::boolean,false) THEN
    RAISE EXCEPTION 'Managers cannot grant staff management access' USING ERRCODE = '42501';
  END IF;

  SELECT ru.* INTO v_actor
  FROM public.restaurant_users ru
  WHERE ru.user_id = p_actor_user_id
    AND ru.restaurant_id = p_restaurant_id
    AND ru.is_active = true
  ORDER BY CASE lower(coalesce(ru.role,'')) WHEN 'owner' THEN 1 WHEN 'admin' THEN 2 ELSE 3 END
  LIMIT 1;

  IF v_actor.id IS NULL
     OR lower(coalesce(v_actor.role,'')) <> 'staff'
     OR lower(coalesce(v_actor.position,'')) <> 'manager' THEN
    RAISE EXCEPTION 'Manager access required' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.restaurant_branches b
    WHERE b.id = p_branch_id AND b.restaurant_id = p_restaurant_id AND b.is_active = true
  ) THEN
    RAISE EXCEPTION 'Branch not found or inactive' USING ERRCODE = '22023';
  END IF;

  SELECT sba.permissions INTO v_manager_permissions
  FROM public.staff_branch_access sba
  WHERE sba.restaurant_user_id = v_actor.id
    AND sba.restaurant_id = p_restaurant_id
    AND sba.branch_id = p_branch_id
    AND sba.is_active = true
  FOR SHARE;

  IF v_manager_permissions IS NULL
     OR NOT public.edmel_permission_json_allows(v_manager_permissions,'staff','manage') THEN
    RAISE EXCEPTION 'Staff management access is not enabled for this branch' USING ERRCODE = '42501';
  END IF;

  IF p_target_restaurant_user_id = v_actor.id THEN
    RAISE EXCEPTION 'Managers cannot edit their own staff permissions' USING ERRCODE = '42501';
  END IF;

  SELECT ru.* INTO v_target
  FROM public.restaurant_users ru
  WHERE ru.id = p_target_restaurant_user_id AND ru.restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF v_target.id IS NULL
     OR lower(coalesce(v_target.role,'')) <> 'staff'
     OR lower(coalesce(v_target.position,'')) = 'manager'
     OR v_target.user_id = p_actor_user_id THEN
    RAISE EXCEPTION 'Only subordinate staff accounts in this restaurant can be edited' USING ERRCODE = '42501';
  END IF;

  SELECT sba.id,sba.permissions INTO v_target_access_id,v_target_permissions
  FROM public.staff_branch_access sba
  WHERE sba.restaurant_user_id = v_target.id
    AND sba.restaurant_id = p_restaurant_id
    AND sba.branch_id = p_branch_id
    AND sba.is_active = true
  FOR UPDATE;

  IF v_target_access_id IS NULL THEN
    RAISE EXCEPTION 'Staff account is not assigned to this branch' USING ERRCODE = 'P0002';
  END IF;

  v_target_permissions := coalesce(v_target_permissions,'{}'::jsonb);

  IF p_permissions ? 'modules' THEN
    IF jsonb_typeof(p_permissions->'modules') <> 'object' THEN
      RAISE EXCEPTION 'Invalid module permission map' USING ERRCODE = '22023';
    END IF;

    FOR v_module IN SELECT key,value FROM jsonb_each(p_permissions->'modules') LOOP
      IF NOT (v_module.key = ANY(v_allowed_modules)) OR jsonb_typeof(v_module.value) <> 'object' THEN
        RAISE EXCEPTION 'Unsupported permission module' USING ERRCODE = '22023';
      END IF;

      FOR v_action IN SELECT key,value FROM jsonb_each(v_module.value) LOOP
        IF NOT (v_action.key = ANY(v_allowed_actions)) OR jsonb_typeof(v_action.value) <> 'boolean' THEN
          RAISE EXCEPTION 'Unsupported module action' USING ERRCODE = '22023';
        END IF;

        IF v_action.value = 'true'::jsonb
           AND NOT public.edmel_permission_json_allows(v_target_permissions,v_module.key,v_action.key)
           AND NOT public.edmel_permission_json_allows(v_manager_permissions,v_module.key,v_action.key) THEN
          RAISE EXCEPTION 'You cannot grant permissions beyond your own branch access' USING ERRCODE = '42501';
        END IF;
      END LOOP;
    END LOOP;
  ELSE
    IF NOT (p_permissions ?& ARRAY['orders','tables','stocks','dispatcher','settings']) THEN
      RAISE EXCEPTION 'Required legacy permissions are missing' USING ERRCODE = '22023';
    END IF;

    FOR v_entry IN SELECT key,value FROM jsonb_each(p_permissions) WHERE key <> 'staff_management' LOOP
      IF jsonb_typeof(v_entry.value) <> 'boolean' THEN
        RAISE EXCEPTION 'Legacy permissions must be boolean values' USING ERRCODE = '22023';
      END IF;

      IF v_entry.value = 'true'::jsonb
         AND NOT public.edmel_permission_json_allows(v_target_permissions,v_entry.key,'view')
         AND NOT public.edmel_permission_json_allows(v_manager_permissions,v_entry.key,'view') THEN
        RAISE EXCEPTION 'You cannot grant permissions beyond your own branch access' USING ERRCODE = '42501';
      END IF;
    END LOOP;
  END IF;

  -- New action-level grants are authoritative. Legacy-only updates preserve any existing modules map.
  IF p_permissions ? 'modules' THEN
    v_new_permissions := v_target_permissions || p_permissions;
  ELSE
    v_new_permissions := (v_target_permissions - ARRAY['orders','tables','stocks','dispatcher','settings','void'])
      || p_permissions;
  END IF;

  v_actor_name := coalesce(nullif(btrim(v_actor.display_name),''),nullif(btrim(v_actor.full_name),''),nullif(btrim(v_actor.cashier_username),''),'Manager');
  v_target_name := coalesce(nullif(btrim(v_target.display_name),''),nullif(btrim(v_target.full_name),''),nullif(btrim(v_target.cashier_username),''),'Staff');

  SELECT b.name INTO v_branch_name
  FROM public.restaurant_branches b WHERE b.id = p_branch_id;

  INSERT INTO public.audit_logs (
    restaurant_id,actor_user_id,actor_name,actor_role,
    action_category,action,record_type,record_id,result,details
  ) VALUES (
    p_restaurant_id,p_actor_user_id,v_actor_name,'manager',
    'Staff & Security','Updated staff branch permissions',
    'staff_branch_access',v_target.id::text,'success',
    jsonb_build_object(
      'branch_id',p_branch_id,
      'branch_name',coalesce(v_branch_name,'Assigned branch'),
      'staff_name',v_target_name,
      'username',coalesce(v_target.cashier_username,''),
      'permissions',p_permissions
    )
  );

  RETURN jsonb_build_object(
    'success',true,
    'branch_id',p_branch_id,
    'staff_id',v_target.id,
    'permissions',v_new_permissions,
    'audit_logged',true
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_manager_update_staff_branch_permissions(uuid,uuid,uuid,uuid,jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.edmel_manager_update_staff_branch_permissions(uuid,uuid,uuid,uuid,jsonb)
  TO service_role;

COMMIT;
