CREATE POLICY "Owners and admins can view product stock"
ON public."PRODUCT_STOCK"
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND lower(coalesce(ru.role, '')) IN ('owner', 'admin')
  )
);