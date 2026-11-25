-- Manager branch visibility and read-only Orders access.
-- Existing Owner/Admin and Cashier/Staff policies remain unchanged.

CREATE OR REPLACE FUNCTION public.edmel_manager_has_module_access(
  p_restaurant_id uuid,
  p_branch_id uuid,
  p_module text,
  p_action text DEFAULT 'view'
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT
    p_restaurant_id IS NOT NULL
    AND p_branch_id IS NOT NULL
    AND p_module IN ('orders', 'transactions')
    AND p_action IN ('view')
    AND EXISTS (
      SELECT 1
      FROM public.restaurant_users ru
      JOIN public.staff_branch_access sba
        ON sba.restaurant_user_id = ru.id
       AND sba.restaurant_id = ru.restaurant_id
      JOIN public.restaurant_branches b
        ON b.id = sba.branch_id
       AND b.restaurant_id = sba.restaurant_id
      WHERE ru.user_id = (SELECT auth.uid())
        AND ru.restaurant_id = p_restaurant_id
        AND ru.is_active = true
        AND lower(coalesce(ru.role, '')) = 'staff'
        AND lower(coalesce(ru.position, '')) = 'manager'
        AND sba.branch_id = p_branch_id
        AND sba.is_active = true
        AND b.is_active = true
        AND (
          sba.permissions #>> ARRAY['modules', p_module, p_action] = 'true'
          OR (
            p_module IN ('orders', 'transactions')
            AND sba.permissions #>> ARRAY['modules', 'orders', p_action] = 'true'
          )
          OR (
            p_module IN ('orders', 'transactions')
            AND sba.permissions ->> 'orders' = 'true'
          )
        )
    );
$function$;

REVOKE ALL ON FUNCTION public.edmel_manager_has_module_access(uuid, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.edmel_manager_has_module_access(uuid, uuid, text, text) TO authenticated;

DROP POLICY IF EXISTS "EDMEL manager view assigned branch orders" ON public.orders;
CREATE POLICY "EDMEL manager view assigned branch orders"
ON public.orders
FOR SELECT
TO authenticated
USING (public.edmel_manager_has_module_access(restaurant_id, branch_id, 'orders', 'view'));

DROP POLICY IF EXISTS "EDMEL manager view assigned branch order items" ON public.order_items;
CREATE POLICY "EDMEL manager view assigned branch order items"
ON public.order_items
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = order_items.order_id
      AND public.edmel_manager_has_module_access(o.restaurant_id, o.branch_id, 'orders', 'view')
  )
);
