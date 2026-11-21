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
SET search_path TO ''
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
  WHERE ru.user_id = p_actor_user_id AND ru.restaurant_id = p_restaurant_id AND ru.is_active = true
  ORDER BY CASE lower(coalesce(ru.role,'')) WHEN 'owner' THEN 1 WHEN 'admin' THEN 2 ELSE 3 END
  LIMIT 1;
  IF v_actor.id IS NULL OR lower(coalesce(v_actor.role,'')) <> 'staff'
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
  WHERE sba.restaurant_user_id = v_actor.id AND sba.restaurant_id = p_restaurant_id
    AND sba.branch_id = p_branch_id AND sba.is_active = true
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
  IF v_target.id IS NULL OR lower(coalesce(v_target.role,'')) <> 'staff'
     OR lower(coalesce(v_target.position,'')) = 'manager' OR v_target.user_id = p_actor_user_id THEN
    RAISE EXCEPTION 'Only subordinate staff accounts in this restaurant can be edited' USING ERRCODE = '42501';
  END IF;

  SELECT sba.id,sba.permissions INTO v_target_access_id,v_target_permissions
  FROM public.staff_branch_access sba
  WHERE sba.restaurant_user_id = v_target.id AND sba.restaurant_id = p_restaurant_id
    AND sba.branch_id = p_branch_id AND sba.is_active = true
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

  IF p_permissions ? 'modules' THEN
    v_new_permissions := v_target_permissions || p_permissions;
  ELSE
    v_new_permissions := (v_target_permissions - ARRAY['orders','tables','stocks','dispatcher','settings','void'])
      || p_permissions;
  END IF;

  UPDATE public.staff_branch_access
  SET permissions = v_new_permissions, updated_at = now()
  WHERE id = v_target_access_id AND restaurant_user_id = v_target.id
    AND branch_id = p_branch_id AND restaurant_id = p_restaurant_id AND is_active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Staff branch access could not be updated' USING ERRCODE = 'P0002';
  END IF;

  v_actor_name := coalesce(nullif(btrim(v_actor.display_name),''),nullif(btrim(v_actor.full_name),''),nullif(btrim(v_actor.cashier_username),''),'Manager');
  v_target_name := coalesce(nullif(btrim(v_target.display_name),''),nullif(btrim(v_target.full_name),''),nullif(btrim(v_target.cashier_username),''),'Staff');
  SELECT b.name INTO v_branch_name FROM public.restaurant_branches b WHERE b.id = p_branch_id;

  INSERT INTO public.audit_logs (
    restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,record_type,record_id,result,details
  ) VALUES (
    p_restaurant_id,p_actor_user_id,v_actor_name,'manager','Staff & Security',
    'Updated staff branch permissions','staff_branch_access',v_target.id::text,'success',
    jsonb_build_object('branch_id',p_branch_id,'branch_name',coalesce(v_branch_name,'Assigned branch'),
      'staff_name',v_target_name,'username',coalesce(v_target.cashier_username,''),'permissions',p_permissions)
  );

  RETURN jsonb_build_object('success',true,'branch_id',p_branch_id,'staff_id',v_target.id,
    'permissions',v_new_permissions,'audit_logged',true);
END;
$function$;