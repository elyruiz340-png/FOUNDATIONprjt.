CREATE OR REPLACE FUNCTION public.edmel_admin_save_manager_branch_permissions(
  p_actor_user_id uuid,
  p_restaurant_id uuid,
  p_manager_id uuid,
  p_assignments jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor public.restaurant_users%ROWTYPE;
  v_manager public.restaurant_users%ROWTYPE;
  v_assignment jsonb;
  v_branch_id uuid;
  v_permissions jsonb;
  v_modules jsonb;
  v_module record;
  v_action record;
  v_entry record;
  v_branch_ids uuid[] := ARRAY[]::uuid[];
  v_branch_count integer := 0;
  v_actor_name text;
  v_manager_name text;
  v_branch_name text;
  v_allowed_modules text[] := ARRAY[
    'overview','sales','settings','orders','expenses','staff','audit','branches','health','ai',
    'inventory','tables','dispatcher','payments','menu','discounts','vouchers','tax',
    'service_charge','receipts','printers','transactions'
  ];
  v_allowed_actions text[] := ARRAY['view','create','edit','delete','approve','manage'];
  v_allowed_legacy text[] := ARRAY['orders','tables','stocks','dispatcher','settings','void'];
BEGIN
  IF p_actor_user_id IS NULL OR p_restaurant_id IS NULL OR p_manager_id IS NULL THEN
    RAISE EXCEPTION 'Missing required account context' USING ERRCODE = '22023';
  END IF;

  IF jsonb_typeof(p_assignments) <> 'array' OR jsonb_array_length(p_assignments) < 1
     OR jsonb_array_length(p_assignments) > 100 THEN
    RAISE EXCEPTION 'At least one valid branch assignment is required' USING ERRCODE = '22023';
  END IF;

  SELECT ru.* INTO v_actor
  FROM public.restaurant_users ru
  WHERE ru.user_id = p_actor_user_id
    AND ru.restaurant_id = p_restaurant_id
    AND ru.is_active = true
    AND lower(ru.role) IN ('owner','admin')
  ORDER BY CASE lower(ru.role) WHEN 'owner' THEN 1 ELSE 2 END
  LIMIT 1;

  IF v_actor.id IS NULL THEN
    RAISE EXCEPTION 'Active Owner or Admin access is required' USING ERRCODE = '42501';
  END IF;

  SELECT ru.* INTO v_manager
  FROM public.restaurant_users ru
  WHERE ru.id = p_manager_id
    AND ru.restaurant_id = p_restaurant_id
    AND ru.is_active = true
    AND lower(ru.role) = 'staff'
    AND lower(coalesce(ru.position,'')) = 'manager'
  FOR UPDATE;

  IF v_manager.id IS NULL THEN
    RAISE EXCEPTION 'Active Manager account not found in this restaurant' USING ERRCODE = '42501';
  END IF;

  FOR v_assignment IN SELECT value FROM jsonb_array_elements(p_assignments)
  LOOP
    IF jsonb_typeof(v_assignment) <> 'object'
       OR jsonb_typeof(v_assignment->'branch_id') <> 'string'
       OR jsonb_typeof(v_assignment->'permissions') <> 'object' THEN
      RAISE EXCEPTION 'Invalid branch permission assignment' USING ERRCODE = '22023';
    END IF;

    BEGIN
      v_branch_id := (v_assignment->>'branch_id')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'Invalid branch identifier' USING ERRCODE = '22023';
    END;

    IF v_branch_id = ANY(v_branch_ids) THEN
      RAISE EXCEPTION 'Duplicate branch assignment' USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.restaurant_branches b
      WHERE b.id = v_branch_id
        AND b.restaurant_id = p_restaurant_id
        AND b.is_active = true
    ) THEN
      RAISE EXCEPTION 'A selected branch is not active in this restaurant' USING ERRCODE = '22023';
    END IF;

    v_permissions := v_assignment->'permissions';

    IF EXISTS (
      SELECT 1 FROM jsonb_object_keys(v_permissions) AS k(key)
      WHERE key <> ALL (ARRAY['modules','staff_management','orders','tables','stocks','dispatcher','settings','void'])
    ) THEN
      RAISE EXCEPTION 'Unsupported permission field' USING ERRCODE = '22023';
    END IF;

    IF v_permissions ? 'staff_management'
       AND jsonb_typeof(v_permissions->'staff_management') <> 'boolean' THEN
      RAISE EXCEPTION 'Staff management authority must be boolean' USING ERRCODE = '22023';
    END IF;

    FOR v_entry IN
      SELECT key,value FROM jsonb_each(v_permissions)
      WHERE key = ANY(v_allowed_legacy)
    LOOP
      IF jsonb_typeof(v_entry.value) <> 'boolean' THEN
        RAISE EXCEPTION 'Legacy permission values must be boolean' USING ERRCODE = '22023';
      END IF;
    END LOOP;

    IF v_permissions ? 'modules' THEN
      v_modules := v_permissions->'modules';
      IF jsonb_typeof(v_modules) <> 'object' THEN
        RAISE EXCEPTION 'Module permissions must be an object' USING ERRCODE = '22023';
      END IF;

      FOR v_module IN SELECT key,value FROM jsonb_each(v_modules)
      LOOP
        IF NOT (v_module.key = ANY(v_allowed_modules))
           OR jsonb_typeof(v_module.value) <> 'object' THEN
          RAISE EXCEPTION 'Unsupported module permission' USING ERRCODE = '22023';
        END IF;

        FOR v_action IN SELECT key,value FROM jsonb_each(v_module.value)
        LOOP
          IF NOT (v_action.key = ANY(v_allowed_actions))
             OR jsonb_typeof(v_action.value) <> 'boolean' THEN
            RAISE EXCEPTION 'Unsupported module action' USING ERRCODE = '22023';
          END IF;
        END LOOP;
      END LOOP;
    END IF;

    v_branch_ids := array_append(v_branch_ids, v_branch_id);
    v_branch_count := v_branch_count + 1;
  END LOOP;

  v_actor_name := coalesce(nullif(btrim(v_actor.display_name),''),nullif(btrim(v_actor.full_name),''),nullif(btrim(v_actor.cashier_username),''),'Owner/Admin');
  v_manager_name := coalesce(nullif(btrim(v_manager.display_name),''),nullif(btrim(v_manager.full_name),''),nullif(btrim(v_manager.cashier_username),''),'Manager');

  UPDATE public.staff_branch_access sba
  SET is_active = false, updated_at = now()
  WHERE sba.restaurant_user_id = v_manager.id
    AND sba.restaurant_id = p_restaurant_id
    AND sba.is_active = true
    AND NOT (sba.branch_id = ANY(v_branch_ids));

  FOR v_assignment IN SELECT value FROM jsonb_array_elements(p_assignments)
  LOOP
    v_branch_id := (v_assignment->>'branch_id')::uuid;
    v_permissions := v_assignment->'permissions';

    INSERT INTO public.staff_branch_access (
      restaurant_user_id, restaurant_id, branch_id, permissions, is_active, created_by, updated_at
    )
    VALUES (
      v_manager.id, p_restaurant_id, v_branch_id, v_permissions, true, p_actor_user_id, now()
    )
    ON CONFLICT (restaurant_user_id, branch_id)
    DO UPDATE SET
      restaurant_id = EXCLUDED.restaurant_id,
      permissions = EXCLUDED.permissions,
      is_active = true,
      updated_at = now();

    SELECT b.name INTO v_branch_name
    FROM public.restaurant_branches b
    WHERE b.id = v_branch_id AND b.restaurant_id = p_restaurant_id;

    INSERT INTO public.audit_logs (
      restaurant_id, actor_user_id, actor_name, actor_role,
      action_category, action, record_type, record_id, result, details
    ) VALUES (
      p_restaurant_id, p_actor_user_id, v_actor_name, lower(v_actor.role),
      'Staff & Security', 'Updated Manager branch permissions',
      'staff_branch_access', v_manager.id::text, 'success',
      jsonb_build_object(
        'manager_name', v_manager_name,
        'manager_username', coalesce(v_manager.cashier_username,''),
        'branch_id', v_branch_id,
        'branch_name', coalesce(v_branch_name,'Assigned branch'),
        'permissions', v_permissions
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'manager_id', v_manager.id,
    'branches_saved', v_branch_count,
    'deactivated_unselected_assignments', true
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_admin_save_manager_branch_permissions(uuid,uuid,uuid,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.edmel_admin_save_manager_branch_permissions(uuid,uuid,uuid,jsonb) TO service_role;