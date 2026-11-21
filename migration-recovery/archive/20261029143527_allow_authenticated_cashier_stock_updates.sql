CREATE POLICY "Active demo restaurant staff can update product stock"
ON public."PRODUCT_STOCK"
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = '5e562ca7-38aa-4894-8265-ddca2f4e61b6'::uuid
      AND COALESCE(ru.is_active, true) = true
      AND lower(COALESCE(ru.role, '')) IN ('owner', 'admin', 'cashier')
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = '5e562ca7-38aa-4894-8265-ddca2f4e61b6'::uuid
      AND COALESCE(ru.is_active, true) = true
      AND lower(COALESCE(ru.role, '')) IN ('owner', 'admin', 'cashier')
  )
);