-- EDMEL tenant-scoped staff login and Owner-only branch management.
-- Additive migration: preserves existing records and legacy login RPCs.

CREATE UNIQUE INDEX IF NOT EXISTS restaurant_users_cashier_username_tenant_uidx
ON public.restaurant_users (restaurant_id, lower(btrim(cashier_username)))
WHERE restaurant_id IS NOT NULL
  AND cashier_username IS NOT NULL
  AND btrim(cashier_username) <> '';

CREATE OR REPLACE FUNCTION public.edmel_verify_staff_login_credentials(
  p_restaurant_slug text,
  p_username text,
  p_pin text
)
RETURNS TABLE (
  cashier_user_id uuid,
  restaurant_user_id uuid,
  restaurant_id uuid,
  role text,
  position text,
  permissions jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid;
  v_restaurant_user_id uuid;
  v_restaurant_id uuid;
  v_role text;
  v_position text;
  v_permissions jsonb;
  v_pin_hash text;
  v_failed_attempts integer;
  v_locked_at timestamptz;
BEGIN
  IF p_restaurant_slug IS NULL
     OR length(btrim(p_restaurant_slug)) = 0
     OR length(btrim(p_restaurant_slug)) > 100
     OR p_username IS NULL
     OR length(btrim(p_username)) = 0
     OR length(btrim(p_username)) > 80
     OR p_pin IS NULL
     OR p_pin !~ '^[0-9]{6}$' THEN
    RETURN;
  END IF;

  SELECT
    ru.id,
    ru.user_id,
    ru.restaurant_id,
    ru.role,
    ru.position,
    ru.permissions,
    cc.pin_hash,
    cc.failed_attempts,
    cc.locked_at
  INTO
    v_restaurant_user_id,
    v_user_id,
    v_restaurant_id,
    v_role,
    v_position,
    v_permissions,
    v_pin_hash,
    v_failed_attempts,
    v_locked_at
  FROM public.restaurants r
  JOIN public.restaurant_users ru
    ON ru.restaurant_id = r.id
  JOIN public.cashier_credentials cc
    ON cc.restaurant_user_id = ru.id
  WHERE lower(btrim(r.slug)) = lower(btrim(p_restaurant_slug))
    AND lower(btrim(ru.cashier_username)) = lower(btrim(p_username))
    AND lower(coalesce(ru.role, '')) = 'staff'
    AND ru.is_active = true
    AND EXISTS (
      SELECT 1
      FROM public.staff_branch_access sba
      JOIN public.restaurant_branches b
        ON b.id = sba.branch_id
       AND b.restaurant_id = sba.restaurant_id
      WHERE sba.restaurant_user_id = ru.id
        AND sba.restaurant_id = ru.restaurant_id
        AND sba.is_active = true
        AND b.is_active = true
    )
  ORDER BY ru.created_at DESC
  LIMIT 1
  FOR UPDATE OF cc;

  IF NOT FOUND OR v_locked_at IS NOT NULL OR v_pin_hash IS NULL THEN
    RETURN;
  END IF;

  IF extensions.crypt(p_pin, v_pin_hash) = v_pin_hash THEN
    UPDATE public.cashier_credentials
    SET failed_attempts = 0,
        locked_at = NULL,
        updated_at = now()
    WHERE restaurant_user_id = v_restaurant_user_id;

    RETURN QUERY
    SELECT v_user_id, v_restaurant_user_id, v_restaurant_id,
           v_role, v_position, v_permissions;
    RETURN;
  END IF;

  UPDATE public.cashier_credentials
  SET failed_attempts = least(coalesce(v_failed_attempts, 0) + 1, 5),
      locked_at = CASE
        WHEN coalesce(v_failed_attempts, 0) + 1 >= 5 THEN now()
        ELSE NULL
      END,
      updated_at = now()
  WHERE restaurant_user_id = v_restaurant_user_id;

  RETURN;
END;
$function$;

CREATE OR REPLACE FUNCTION public.edmel_list_my_restaurants()
RETURNS TABLE (
  restaurant_id uuid,
  restaurant_slug text,
  restaurant_name text,
  role text,
  position text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT r.id, r.slug, r.name, ru.role, ru.position
  FROM public.restaurant_users ru
  JOIN public.restaurants r ON r.id = ru.restaurant_id
  WHERE ru.user_id = (SELECT auth.uid())
    AND ru.is_active = true
  ORDER BY
    CASE lower(ru.role)
      WHEN 'owner' THEN 1
      WHEN 'admin' THEN 2
      ELSE 3
    END,
    r.name;
$function$;

CREATE OR REPLACE FUNCTION public.edmel_create_restaurant_branch(
  p_restaurant_slug text,
  p_name text,
  p_code text,
  p_address text DEFAULT NULL,
  p_timezone text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_restaurant_id uuid;
  v_restaurant_timezone text;
  v_actor_name text;
  v_name text := nullif(btrim(p_name), '');
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_timezone text;
  v_branch public.restaurant_branches%rowtype;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_restaurant_slug IS NULL OR length(btrim(p_restaurant_slug)) = 0 THEN
    RAISE EXCEPTION 'Restaurant slug is required';
  END IF;

  SELECT r.id, r.timezone,
         coalesce(nullif(btrim(ru.display_name), ''),
                  nullif(btrim(ru.full_name), ''),
                  'Owner')
  INTO v_restaurant_id, v_restaurant_timezone, v_actor_name
  FROM public.restaurants r
  JOIN public.restaurant_users ru ON ru.restaurant_id = r.id
  WHERE lower(btrim(r.slug)) = lower(btrim(p_restaurant_slug))
    AND ru.user_id = auth.uid()
    AND ru.is_active = true
    AND lower(ru.role) = 'owner'
  LIMIT 1;

  IF v_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'Owner access required for this restaurant';
  END IF;

  IF v_name IS NULL OR length(v_name) > 80 THEN
    RAISE EXCEPTION 'Branch name must contain 1 to 80 characters';
  END IF;

  IF v_code !~ '^[A-Z0-9][A-Z0-9_-]{0,19}$' THEN
    RAISE EXCEPTION 'Branch code must contain 1 to 20 letters, numbers, hyphens, or underscores';
  END IF;

  v_timezone := coalesce(nullif(btrim(p_timezone), ''),
                         nullif(btrim(v_restaurant_timezone), ''),
                         'America/Chicago');

  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names z WHERE z.name = v_timezone) THEN
    RAISE EXCEPTION 'Invalid branch timezone';
  END IF;

  INSERT INTO public.restaurant_branches (
    restaurant_id, name, code, timezone, address, is_default, is_active
  )
  VALUES (
    v_restaurant_id, v_name, v_code, v_timezone,
    nullif(btrim(p_address), ''), false, true
  )
  RETURNING * INTO v_branch;

  INSERT INTO public.audit_logs (
    restaurant_id, actor_user_id, actor_name, actor_role,
    action_category, action, record_type, record_id, result, details
  )
  VALUES (
    v_restaurant_id, auth.uid(), v_actor_name, 'owner',
    'Branch Management', 'Branch created', 'restaurant_branch',
    v_branch.id::text, 'success',
    jsonb_build_object(
      'branch_name', v_branch.name,
      'branch_code', v_branch.code,
      'timezone', v_branch.timezone
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'branch', jsonb_build_object(
      'id', v_branch.id,
      'restaurant_id', v_branch.restaurant_id,
      'name', v_branch.name,
      'code', v_branch.code,
      'timezone', v_branch.timezone,
      'address', v_branch.address,
      'is_default', v_branch.is_default,
      'is_active', v_branch.is_active
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.edmel_deactivate_restaurant_branch(
  p_restaurant_slug text,
  p_branch_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_restaurant_id uuid;
  v_actor_name text;
  v_branch public.restaurant_branches%rowtype;
  v_active_branch_count integer;
  v_now timestamptz := now();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT r.id,
         coalesce(nullif(btrim(ru.display_name), ''),
                  nullif(btrim(ru.full_name), ''),
                  'Owner')
  INTO v_restaurant_id, v_actor_name
  FROM public.restaurants r
  JOIN public.restaurant_users ru ON ru.restaurant_id = r.id
  WHERE lower(btrim(r.slug)) = lower(btrim(p_restaurant_slug))
    AND ru.user_id = auth.uid()
    AND ru.is_active = true
    AND lower(ru.role) = 'owner'
  LIMIT 1;

  IF v_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'Owner access required for this restaurant';
  END IF;

  SELECT *
  INTO v_branch
  FROM public.restaurant_branches b
  WHERE b.id = p_branch_id
    AND b.restaurant_id = v_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Branch not found for this restaurant';
  END IF;

  IF v_branch.is_default THEN
    RAISE EXCEPTION 'The default branch cannot be deactivated';
  END IF;

  IF NOT v_branch.is_active THEN
    RETURN jsonb_build_object('success', true, 'already_deactivated', true);
  END IF;

  SELECT count(*)
  INTO v_active_branch_count
  FROM public.restaurant_branches b
  WHERE b.restaurant_id = v_restaurant_id
    AND b.is_active = true;

  IF v_active_branch_count <= 1 THEN
    RAISE EXCEPTION 'The only active branch cannot be deactivated';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.restaurant_id = v_restaurant_id
      AND o.branch_id = p_branch_id
      AND (
        lower(coalesce(o.status, o.order_status, 'pending'))
          NOT IN ('served', 'completed', 'voided', 'cancelled')
        OR lower(coalesce(o.payment_status, 'pending'))
          NOT IN ('paid', 'refunded')
      )
  ) THEN
    RAISE EXCEPTION 'This branch has unfinished or unsettled orders';
  END IF;

  UPDATE public.restaurant_branches
  SET is_active = false,
      updated_at = v_now
  WHERE id = p_branch_id
    AND restaurant_id = v_restaurant_id;

  UPDATE public.staff_sessions
  SET logout_at = v_now,
      last_seen_at = v_now,
      end_reason = 'branch_deactivated'
  WHERE restaurant_id = v_restaurant_id
    AND branch_id = p_branch_id
    AND logout_at IS NULL;

  INSERT INTO public.audit_logs (
    restaurant_id, actor_user_id, actor_name, actor_role,
    action_category, action, record_type, record_id, result, details
  )
  VALUES (
    v_restaurant_id, auth.uid(), v_actor_name, 'owner',
    'Branch Management', 'Branch deactivated', 'restaurant_branch',
    p_branch_id::text, 'success',
    jsonb_build_object(
      'branch_name', v_branch.name,
      'branch_code', v_branch.code
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'branch_id', p_branch_id,
    'is_active', false,
    'active_sessions_closed', true
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_verify_staff_login_credentials(text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.edmel_verify_staff_login_credentials(text, text, text)
  TO service_role;

REVOKE ALL ON FUNCTION public.edmel_list_my_restaurants()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edmel_list_my_restaurants()
  TO authenticated;

REVOKE ALL ON FUNCTION public.edmel_create_restaurant_branch(text, text, text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edmel_create_restaurant_branch(text, text, text, text, text)
  TO authenticated;

REVOKE ALL ON FUNCTION public.edmel_deactivate_restaurant_branch(text, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edmel_deactivate_restaurant_branch(text, uuid)
  TO authenticated;
