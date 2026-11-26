-- Password-capable Manager profile creation.
-- Reuses the existing, fully validated Manager branch-permission transaction,
-- then removes its temporary PIN credential and records password onboarding state
-- in the same database transaction.
CREATE OR REPLACE FUNCTION public.edmel_create_password_manager_profile_with_branch_permissions(
  p_actor_user_id uuid,
  p_staff_user_id uuid,
  p_restaurant_id uuid,
  p_full_name text,
  p_display_name text,
  p_username text,
  p_manager_email text,
  p_assignments jsonb,
  p_can_change_pin boolean DEFAULT false,
  p_can_change_password boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_staff_id uuid;
BEGIN
  IF p_manager_email IS NULL
    OR length(btrim(p_manager_email)) > 254
    OR btrim(p_manager_email) !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
  THEN
    RAISE EXCEPTION 'A valid Manager email address is required' USING ERRCODE='22023';
  END IF;

  -- The existing RPC remains the single source of truth for Owner/Admin
  -- authorization, branch validation, permission validation, assignments,
  -- and audit logging. The temporary credential never leaves this transaction.
  v_staff_id := public.edmel_create_staff_profile_with_branch_permissions(
    p_actor_user_id,
    p_staff_user_id,
    p_restaurant_id,
    p_full_name,
    p_display_name,
    p_username,
    '000000',
    p_assignments
  );

  DELETE FROM public.cashier_credentials
  WHERE restaurant_user_id = v_staff_id;

  UPDATE public.restaurant_users
  SET manager_auth_method = 'password',
      manager_email = lower(btrim(p_manager_email)),
      manager_email_verified_at = NULL,
      manager_can_change_pin = coalesce(p_can_change_pin, false),
      manager_can_change_password = coalesce(p_can_change_password, false),
      manager_auth_setup_status = 'pending'
  WHERE id = v_staff_id
    AND user_id = p_staff_user_id
    AND restaurant_id = p_restaurant_id
    AND lower(role) = 'staff'
    AND lower(position) = 'manager';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unable to finalize Manager password profile' USING ERRCODE='P0001';
  END IF;

  RETURN v_staff_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_create_password_manager_profile_with_branch_permissions(
  uuid, uuid, uuid, text, text, text, text, jsonb, boolean, boolean
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.edmel_create_password_manager_profile_with_branch_permissions(
  uuid, uuid, uuid, text, text, text, text, jsonb, boolean, boolean
) TO service_role;

COMMENT ON FUNCTION public.edmel_create_password_manager_profile_with_branch_permissions(
  uuid, uuid, uuid, text, text, text, text, jsonb, boolean, boolean
) IS 'Creates a password-based Manager profile while reusing the existing branch permission validation and audit transaction.';
