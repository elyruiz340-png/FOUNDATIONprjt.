-- Keep Manager expense authorization consistent with the shared module permission model.
-- A module-level Manage grant includes create, edit, delete, approve and view.
-- Branch assignment and active branch checks remain mandatory for Managers.
CREATE OR REPLACE FUNCTION public.edmel_expense_has_access(
  p_restaurant_id uuid,
  p_branch_id uuid,
  p_action text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = p_restaurant_id
      AND COALESCE(ru.is_active, true) = true
      AND (
        lower(COALESCE(ru.role, '')) IN ('owner', 'admin')
        OR (
          p_branch_id IS NOT NULL
          AND EXISTS (
            SELECT 1
            FROM public.restaurant_branches b
            JOIN public.staff_branch_access sba
              ON sba.branch_id = b.id
             AND sba.restaurant_id = b.restaurant_id
            WHERE b.id = p_branch_id
              AND b.restaurant_id = p_restaurant_id
              AND b.is_active = true
              AND sba.restaurant_user_id = ru.id
              AND sba.is_active = true
              AND lower(COALESCE(ru.role, '')) = 'staff'
              AND lower(COALESCE(ru.position, '')) = 'manager'
              AND public.edmel_permission_json_allows(
                sba.permissions,
                'expenses',
                p_action
              )
          )
        )
      )
  );
$function$;
