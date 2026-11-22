-- Remove anonymous access to private tenant/branch administration and table records.
-- Customer QR workflows use narrowly-scoped SECURITY DEFINER RPCs instead.

REVOKE ALL ON TABLE public.restaurant_branches FROM anon;
REVOKE ALL ON TABLE public.restaurant_users FROM anon;
REVOKE ALL ON TABLE public.staff_branch_access FROM anon;
REVOKE ALL ON TABLE public.restaurant_tables FROM anon;
REVOKE ALL ON TABLE public.restaurant_table_qr_tokens FROM anon;

DROP POLICY IF EXISTS "Public can view active restaurant tables" ON public.restaurant_tables;

CREATE POLICY "EDMEL tenant branch table select"
ON public.restaurant_tables FOR SELECT TO authenticated
USING (
  restaurant_id IS NOT NULL
  AND branch_id IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = restaurant_tables.restaurant_id
      AND ru.is_active = true
      AND lower(ru.role) IN ('owner','admin','staff','cashier')
      AND (
        lower(ru.role) IN ('owner','admin')
        OR public.edmel_has_branch_permission(restaurant_tables.branch_id, 'tables')
      )
  )
);
