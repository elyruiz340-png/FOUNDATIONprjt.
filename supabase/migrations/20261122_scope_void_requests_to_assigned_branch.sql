DROP POLICY IF EXISTS "Staff can view restaurant void requests" ON public.order_void_requests;

CREATE POLICY "EDMEL staff view assigned branch void requests"
ON public.order_void_requests FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = order_void_requests.restaurant_id
      AND ru.is_active = true
      AND lower(ru.role) IN ('staff','cashier','owner','admin')
      AND (
        lower(ru.role) IN ('owner','admin')
        OR public.edmel_has_branch_permission(order_void_requests.branch_id, NULL)
      )
  )
);
