-- EDMEL: branch-scoped Manager permission updates.
-- Source-only migration for the GitHub test branch.
-- Do not apply to the active Supabase project without an isolated database review.

BEGIN;

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
  v_actor_name text;
  v_target_name text;
  v_branch_name text;
BEGIN
  IF p_actor_user_id IS NULL OR p_restaurant_id IS NULL
     OR p_branch_id IS NULL OR p_target_restaurant_user_id IS NULL THEN
    RAISE EXCEPTION 'Missing required account or branch context'
      USING ERRCODE = '22023';
  END IF;

  IF p_permissions IS NULL OR jsonb_typeof(p_permissions) <> 'object' THEN
    RAISE EXCEPTION 'Invalid staff permissions' USING ERRCODE = '22023';
  END IF;

  IF NOT (p_permissions ?& ARRAY['orders','tables','stocks','dispatcher','settings']) THEN
    RAISE EXCEPTION 'Required legacy permissions are missing' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_each(p_permissions) e
    WHERE e.key NOT IN ('orders','tables','stocks','dispatcher','settings','void')
       OR jsonb_typeof(e.value) <> 'boolean'
  ) THEN
    RAISE EXCEPTION 'Only supported legacy boolean permissions can be changed'
      USING ERRCODE = '22023';
  END IF;

  SELECT ru.*
    INTO v_actor
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
    WHERE b.id = p_branch_id
      AND b.restaurant_id = p_restaurant_id
      AND b.is_active = true
  ) THEN
    RAISE EXCEPTION 'Branch not found or inactive' USING ERRCODE = '22023';
  END IF;

  SELECT sba.permissions
    INTO v_manager_permissions
  FROM public.staff_branch_access sba
  WHERE sba.restaurant_user_id = v_actor.id
    AND sba.restaurant_id = p_restaurant_id
    AND sba.branch_id = p_branch_id
    AND sba.is_active = true
  FOR SHARE;

  IF v_manager_permissions IS NULL
     OR coalesce(v_manager_permissions->'staff_management', 'false'::jsonb) <> 'true'::jsonb THEN
    RAISE EXCEPTION 'Staff management access is not enabled for this branch'
      USING ERRCODE = '42501';
  END IF;

  IF p_target_restaurant_user_id = v_actor.id THEN
    RAISE EXCEPTION 'Managers cannot edit their own staff permissions'
      USING ERRCODE = '42501';
  END IF;

  SELECT ru.*
    INTO v_target
  FROM public.restaurant_users ru
  WHERE ru.id = p_target_restaurant_user_id
    AND ru.restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF v_target.id IS NULL
     OR lower(coalesce(v_target.role,'')) <> 'staff'
     OR lower(coalesce(v_target.position,'')) = 'manager'
     OR v_target.user_id = p_actor_user_id THEN
    RAISE EXCEPTION 'Only subordinate staff accounts in this restaurant can be edited'
      USING ERRCODE = '42501';
  END IF;

  SELECT sba.id, sba.permissions
    INTO v_target_access_id, v_target_permissions
  FROM public.staff_branch_access sba
  WHERE sba.restaurant_user_id = v_target.id
    AND sba.restaurant_id = p_restaurant_id
    AND sba.branch_id = p_branch_id
    AND sba.is_active = true
  FOR UPDATE;

  IF v_target_access_id IS NULL THEN
    RAISE EXCEPTION 'Staff account is not actively assigned to this branch'
      USING ERRCODE = 'P0002';
  END IF;

  v_target_permissions := coalesce(v_target_permissions, '{}'::jsonb);

  -- Managers may retain an existing grant they do not personally hold, but
  -- cannot newly grant any permission beyond their own access in this branch.
  IF EXISTS (
    SELECT 1
    FROM jsonb_each(p_permissions) e
    WHERE e.value = 'true'::jsonb
      AND coalesce(v_target_permissions->e.key, 'false'::jsonb) <> 'true'::jsonb
      AND coalesce(v_manager_permissions->e.key, 'false'::jsonb) <> 'true'::jsonb
  ) THEN
    RAISE EXCEPTION 'You cannot grant permissions beyond your own branch access'
      USING ERRCODE = '42501';
  END IF;

  -- Replace only the legacy permission keys. Preserve action-level modules,
  -- staff_management metadata, and any other existing non-legacy fields.
  v_new_permissions :=
    (v_target_permissions - ARRAY['orders','tables','stocks','dispatcher','settings','void'])
    || p_permissions;

  UPDATE public.staff_branch_access
  SET permissions = v_new_permissions,
      updated_at = now()
  WHERE id = v_target_access_id;

  v_actor_name := coalesce(
    nullif(btrim(v_actor.display_name), ''),
    nullif(btrim(v_actor.full_name), ''),
    nullif(btrim(v_actor.cashier_username), ''),
    'Manager'
  );
  v_target_name := coalesce(
    nullif(btrim(v_target.display_name), ''),
    nullif(btrim(v_target.full_name), ''),
    nullif(btrim(v_target.cashier_username), ''),
    'Staff'
  );

  SELECT b.name INTO v_branch_name
  FROM public.restaurant_branches b
  WHERE b.id = p_branch_id;

  INSERT INTO public.audit_logs (
    restaurant_id, actor_user_id, actor_name, actor_role,
    action_category, action, record_type, record_id, result, details
  ) VALUES (
    p_restaurant_id, p_actor_user_id, v_actor_name, 'manager',
    'Staff & Security', 'Updated staff branch permissions',
    'staff_branch_access', v_target.id, 'success',
    jsonb_build_object(
      'branch_id', p_branch_id,
      'branch_name', coalesce(v_branch_name, 'Assigned branch'),
      'staff_name', v_target_name,
      'username', coalesce(v_target.cashier_username, ''),
      'permissions', p_permissions
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'branch_id', p_branch_id,
    'staff_id', v_target.id,
    'permissions', v_new_permissions,
    'audit_logged', true
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_manager_update_staff_branch_permissions(uuid,uuid,uuid,uuid,jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.edmel_manager_update_staff_branch_permissions(uuid,uuid,uuid,uuid,jsonb)
  TO service_role;

COMMIT;
