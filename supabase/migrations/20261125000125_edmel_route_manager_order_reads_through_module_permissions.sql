-- Keep ordinary staff/cashier reads intact, but route Manager reads through
-- the explicit branch + Orders permission helper.

DROP POLICY IF EXISTS "EDMEL staff view assigned branch orders" ON public.orders;
CREATE POLICY "EDMEL staff view assigned branch orders"
ON public.orders
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = orders.restaurant_id
      AND ru.is_active = true
      AND lower(coalesce(ru.role, '')) IN ('staff', 'cashier')
      AND lower(coalesce(ru.position, '')) <> 'manager'
      AND (
        lower(coalesce(ru.role, '')) IN ('owner', 'admin')
        OR public.edmel_has_branch_permission(orders.branch_id, NULL)
      )
  )
);

DROP POLICY IF EXISTS "EDMEL staff view assigned branch order items" ON public.order_items;
CREATE POLICY "EDMEL staff view assigned branch order items"
ON public.order_items
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.orders o
    JOIN public.restaurant_users ru
      ON ru.restaurant_id = o.restaurant_id
    WHERE o.id = order_items.order_id
      AND ru.user_id = (SELECT auth.uid())
      AND ru.is_active = true
      AND lower(coalesce(ru.role, '')) IN ('staff', 'cashier', 'owner', 'admin')
      AND lower(coalesce(ru.position, '')) <> 'manager'
      AND (
        lower(coalesce(ru.role, '')) IN ('owner', 'admin')
        OR public.edmel_has_branch_permission(o.branch_id, NULL)
      )
  )
);
