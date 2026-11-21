GRANT INSERT ON TABLE public.audit_logs TO authenticated;

CREATE POLICY "Owners and admins can append audit logs"
ON public.audit_logs
FOR INSERT
TO authenticated
WITH CHECK (
  actor_user_id = (SELECT auth.uid())
  AND EXISTS (
    SELECT 1
    FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = audit_logs.restaurant_id
      AND lower(COALESCE(ru.role, '')) IN ('owner', 'admin')
      AND COALESCE(ru.is_active, true) = true
      AND lower(COALESCE(ru.role, '')) = lower(COALESCE(audit_logs.actor_role, ''))
  )
);