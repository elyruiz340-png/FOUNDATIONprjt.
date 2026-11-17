-- EDMEL POS: security baseline and backward-compatible action permissions
-- Target: GitHub test branch only.
-- This migration is intentionally additive and does not alter existing restaurant data.
-- Do not apply to the active Supabase project until an isolated development database exists
-- and the complete migration history has been reconciled.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Remove anonymous inventory exposure.
-- Customer checkout uses SECURITY DEFINER RPCs for inventory validation and deduction;
-- the public customer page does not need direct access to PRODUCT_STOCK.
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS "Allow public to view product stock" ON public."PRODUCT_STOCK";
DROP POLICY IF EXISTS "Allow cashier to update product stock" ON public."PRODUCT_STOCK";

REVOKE ALL PRIVILEGES ON TABLE public."PRODUCT_STOCK" FROM anon;

-- ---------------------------------------------------------------------------
-- 2. Replace unrestricted public table reads with authenticated branch access.
-- QR checkout and shared-cart RPCs validate table_id + QR token server-side and
-- execute as SECURITY DEFINER, so anonymous clients do not need table SELECT.
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS "Public can view active restaurant tables"
  ON public.restaurant_tables;
REVOKE SELECT ON TABLE public.restaurant_tables FROM anon;

-- ---------------------------------------------------------------------------
-- 3. Backward-compatible granular permission evaluator.
--
-- Legacy format remains valid:
--   {"orders":true,"tables":true,"stocks":true,"void":true}
--
-- New format:
--   {"modules":{"orders":{"view":true,"approve":true,"void":false}}}
--
-- If a staff member has the new "modules" object, it is authoritative.
-- If not, a legacy module boolean grants the module's existing actions so that
-- current staff accounts do not unexpectedly lose access during migration.
-- ---------------------------------------------------------------------------

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
  v_restaurant_user_id uuid;
  v_role text;
  v_permissions jsonb;
  v_module_permissions jsonb;
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

  SELECT ru.id, lower(coalesce(ru.role,'')), sba.permissions
    INTO v_restaurant_user_id, v_role, v_permissions
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

  IF v_restaurant_user_id IS NULL THEN
    RETURN false;
  END IF;

  IF v_role IN ('owner','admin') THEN
    RETURN true;
  END IF;

  IF v_permissions IS NULL OR jsonb_typeof(v_permissions) <> 'object' THEN
    RETURN false;
  END IF;

  -- New action-level permission format takes precedence when present.
  IF v_permissions ? 'modules' THEN
    IF jsonb_typeof(v_permissions->'modules') <> 'object' THEN
      RETURN false;
    END IF;

    v_module_permissions := v_permissions->'modules'->p_module;
    IF v_module_permissions IS NULL
       OR jsonb_typeof(v_module_permissions) <> 'object' THEN
      RETURN false;
    END IF;

    RETURN coalesce((v_module_permissions->>p_action)::boolean, false);
  END IF;

  -- Legacy compatibility: a true module flag preserves existing access.
  IF p_module = 'orders' AND p_action = 'void' THEN
    RETURN coalesce((v_permissions->>'void')::boolean, false)
       OR coalesce((v_permissions->>'orders')::boolean, false);
  END IF;

  -- Historically, the single Orders permission covered the cashier payment workflow.
  -- Preserve that behavior for legacy accounts; new-format permissions separate Payments.
  IF p_module = 'payments' THEN
    RETURN coalesce((v_permissions->>'orders')::boolean, false);
  END IF;

  RETURN coalesce((v_permissions->>p_module)::boolean, false);
EXCEPTION
  WHEN invalid_text_representation THEN
    RETURN false;
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_has_branch_action_permission(uuid,text,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edmel_has_branch_action_permission(uuid,text,text)
  TO authenticated, service_role;

-- Authenticated owners/admins can view all tables in their own restaurant.
-- Staff and managers can view tables only in an assigned branch with table access.
-- Legacy single-branch tenants without branch records remain accessible within
-- their own restaurant. This fallback is disabled as soon as a tenant has an active
-- branch, so it cannot bypass branch membership in a branched tenant.
CREATE OR REPLACE FUNCTION public.edmel_has_legacy_restaurant_action_permission(
  p_restaurant_id uuid,
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
  v_role text;
  v_permissions jsonb;
  v_module_permissions jsonb;
BEGIN
  IF (SELECT auth.uid()) IS NULL
     OR p_restaurant_id IS NULL
     OR p_module IS NULL
     OR p_action IS NULL
     OR p_action NOT IN ('view','create','edit','delete','approve','manage','void') THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.restaurant_branches b
    WHERE b.restaurant_id = p_restaurant_id AND b.is_active = true
  ) THEN
    RETURN false;
  END IF;

  SELECT lower(coalesce(ru.role,'')), ru.permissions
    INTO v_role, v_permissions
  FROM public.restaurant_users ru
  WHERE ru.user_id = (SELECT auth.uid())
    AND ru.restaurant_id = p_restaurant_id
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

  IF v_permissions IS NULL OR jsonb_typeof(v_permissions) <> 'object' THEN
    RETURN false;
  END IF;

  IF v_permissions ? 'modules' THEN
    IF jsonb_typeof(v_permissions->'modules') <> 'object' THEN
      RETURN false;
    END IF;
    v_module_permissions := v_permissions->'modules'->p_module;
    IF v_module_permissions IS NULL OR jsonb_typeof(v_module_permissions) <> 'object' THEN
      RETURN false;
    END IF;
    RETURN coalesce((v_module_permissions->>p_action)::boolean, false);
  END IF;

  IF p_module = 'orders' AND p_action = 'void' THEN
    RETURN coalesce((v_permissions->>'void')::boolean, false)
       OR coalesce((v_permissions->>'orders')::boolean, false);
  END IF;
  IF p_module = 'payments' THEN
    RETURN coalesce((v_permissions->>'orders')::boolean, false);
  END IF;
  RETURN coalesce((v_permissions->>p_module)::boolean, false);
EXCEPTION
  WHEN invalid_text_representation THEN
    RETURN false;
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_has_legacy_restaurant_action_permission(uuid,text,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edmel_has_legacy_restaurant_action_permission(uuid,text,text)
  TO authenticated, service_role;

CREATE POLICY "EDMEL authenticated branch table visibility"
ON public.restaurant_tables
FOR SELECT
TO authenticated
USING (
  (
    branch_id IS NOT NULL
    AND public.edmel_has_branch_action_permission(branch_id, 'tables', 'view')
  )
  OR
  (
    branch_id IS NULL
    AND public.edmel_has_legacy_restaurant_action_permission(restaurant_id, 'tables', 'view')
  )
);

-- ---------------------------------------------------------------------------
-- 4. Restrict order visibility to the active restaurant/assigned branch.
-- The previous staff policy exposed all branch orders in the restaurant.
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS "Owners can view their restaurant orders" ON public.orders;
DROP POLICY IF EXISTS "Staff can view restaurant orders" ON public.orders;

CREATE POLICY "EDMEL authenticated branch order visibility"
ON public.orders
FOR SELECT
TO authenticated
USING (
  (
    branch_id IS NOT NULL
    AND public.edmel_has_branch_action_permission(branch_id, 'orders', 'view')
  )
  OR
  (
    branch_id IS NULL
    AND public.edmel_has_legacy_restaurant_action_permission(restaurant_id, 'orders', 'view')
  )
);

-- ---------------------------------------------------------------------------
-- 5. Enforce action permissions inside privileged order RPCs.
-- These checks are server-side; hiding UI controls is not an authorization layer.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cashier_accept_order(
  p_order_id uuid,
  p_session_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_restaurant_user_id uuid;
  v_restaurant_id uuid;
  v_actor_name text;
  v_session_branch_id uuid;
  v_session_found boolean := false;
  v_order public.orders%rowtype;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT ru.id, ru.restaurant_id,
         coalesce(nullif(btrim(ru.display_name), ''), nullif(btrim(ru.full_name), ''))
    INTO v_restaurant_user_id, v_restaurant_id, v_actor_name
  FROM public.restaurant_users ru
  WHERE ru.user_id = auth.uid()
    AND ru.is_active = true
    AND lower(ru.role) IN ('owner','admin','staff','cashier')
  ORDER BY CASE lower(ru.role) WHEN 'owner' THEN 1 WHEN 'admin' THEN 2 ELSE 3 END
  LIMIT 1;

  IF v_restaurant_user_id IS NULL THEN
    RAISE EXCEPTION 'Active staff account not found';
  END IF;

  SELECT true, ss.branch_id
    INTO v_session_found, v_session_branch_id
  FROM public.staff_sessions ss
  WHERE ss.id = p_session_id
    AND ss.user_id = auth.uid()
    AND ss.restaurant_user_id = v_restaurant_user_id
    AND ss.restaurant_id = v_restaurant_id
    AND ss.logout_at IS NULL;

  IF NOT v_session_found THEN
    RAISE EXCEPTION 'Active staff session required';
  END IF;

  SELECT o.* INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
    AND o.restaurant_id = v_restaurant_id
    AND (
      o.branch_id = v_session_branch_id
      OR (
        o.branch_id IS NULL
        AND v_session_branch_id IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM public.restaurant_branches b
          WHERE b.restaurant_id = v_restaurant_id AND b.is_active = true
        )
      )
    )
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found for this branch';
  END IF;

  IF NOT (
    CASE
      WHEN v_session_branch_id IS NULL THEN
        public.edmel_has_legacy_restaurant_action_permission(v_restaurant_id, 'orders', 'approve')
      ELSE
        public.edmel_has_branch_action_permission(v_session_branch_id, 'orders', 'approve')
    END
  ) THEN
    RAISE EXCEPTION 'You do not have permission to accept orders' USING ERRCODE = '42501';
  END IF;

  IF lower(coalesce(v_order.status, '')) = 'accepted'
     AND v_order.accepted_by_session_id = p_session_id THEN
    RETURN jsonb_build_object(
      'success', true,
      'already_accepted', true,
      'order_id', v_order.id,
      'accepted_at', v_order.accepted_at
    );
  END IF;

  UPDATE public.orders o
  SET status = 'accepted',
      accepted_by_user_id = auth.uid(),
      accepted_by_session_id = p_session_id,
      accepted_by_name = v_actor_name,
      accepted_at = now(),
      updated_at = now()
  WHERE o.id = p_order_id
    AND o.restaurant_id = v_restaurant_id
    AND (
      o.branch_id = v_session_branch_id
      OR (
        o.branch_id IS NULL
        AND v_session_branch_id IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM public.restaurant_branches b
          WHERE b.restaurant_id = v_restaurant_id AND b.is_active = true
        )
      )
    )
    AND lower(coalesce(o.status, 'new')) IN ('new','pending','confirmed')
    AND o.accepted_at IS NULL
  RETURNING o.* INTO v_order;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'already_accepted', true,
      'message', 'This order has already been accepted by another session or is no longer new.'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'order_id', v_order.id,
    'accepted_at', v_order.accepted_at
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.cashier_settle_order(
  p_order_id uuid,
  p_session_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_restaurant_user_id uuid;
  v_restaurant_id uuid;
  v_actor_name text;
  v_session_branch_id uuid;
  v_session_found boolean := false;
  v_order public.orders%rowtype;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT ru.id, ru.restaurant_id,
         coalesce(nullif(btrim(ru.display_name), ''), nullif(btrim(ru.full_name), ''))
    INTO v_restaurant_user_id, v_restaurant_id, v_actor_name
  FROM public.restaurant_users ru
  WHERE ru.user_id = auth.uid()
    AND ru.is_active = true
    AND lower(ru.role) IN ('owner','admin','staff','cashier')
  ORDER BY CASE lower(ru.role) WHEN 'owner' THEN 1 WHEN 'admin' THEN 2 ELSE 3 END
  LIMIT 1;

  IF v_restaurant_user_id IS NULL THEN
    RAISE EXCEPTION 'Active staff account not found';
  END IF;

  SELECT true, ss.branch_id
    INTO v_session_found, v_session_branch_id
  FROM public.staff_sessions ss
  WHERE ss.id = p_session_id
    AND ss.user_id = auth.uid()
    AND ss.restaurant_user_id = v_restaurant_user_id
    AND ss.restaurant_id = v_restaurant_id
    AND ss.logout_at IS NULL;

  IF NOT v_session_found THEN
    RAISE EXCEPTION 'Active staff session required';
  END IF;

  SELECT o.* INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
    AND o.restaurant_id = v_restaurant_id
    AND (
      o.branch_id = v_session_branch_id
      OR (
        o.branch_id IS NULL
        AND v_session_branch_id IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM public.restaurant_branches b
          WHERE b.restaurant_id = v_restaurant_id AND b.is_active = true
        )
      )
    )
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found for this branch';
  END IF;

  IF NOT (
    CASE
      WHEN v_session_branch_id IS NULL THEN
        public.edmel_has_legacy_restaurant_action_permission(v_restaurant_id, 'payments', 'approve')
      ELSE
        public.edmel_has_branch_action_permission(v_session_branch_id, 'payments', 'approve')
    END
  ) THEN
    RAISE EXCEPTION 'You do not have permission to settle payments' USING ERRCODE = '42501';
  END IF;

  IF lower(coalesce(v_order.payment_status, '')) IN ('paid','successful','succeeded','verified')
     AND v_order.settled_by_session_id = p_session_id THEN
    RETURN jsonb_build_object(
      'success', true,
      'already_settled', true,
      'order_id', v_order.id,
      'settled_at', v_order.settled_at
    );
  END IF;

  UPDATE public.orders o
  SET payment_status = 'paid',
      settled_by_user_id = auth.uid(),
      settled_by_session_id = p_session_id,
      settled_by_name = v_actor_name,
      settled_at = now(),
      updated_at = now()
  WHERE o.id = p_order_id
    AND o.restaurant_id = v_restaurant_id
    AND (
      o.branch_id = v_session_branch_id
      OR (
        o.branch_id IS NULL
        AND v_session_branch_id IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM public.restaurant_branches b
          WHERE b.restaurant_id = v_restaurant_id AND b.is_active = true
        )
      )
    )
    AND lower(coalesce(o.status, '')) IN ('served','completed')
    AND lower(coalesce(o.payment_status, 'pending')) IN ('pending','unpaid','')
    AND o.settled_at IS NULL
  RETURNING o.* INTO v_order;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'already_settled', true,
      'message', 'This order is already settled by another session or is not ready for payment.'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'order_id', v_order.id,
    'settled_at', v_order.settled_at
  );
END;
$function$;

-- Keep the existing function execution grants unchanged.
COMMIT;
