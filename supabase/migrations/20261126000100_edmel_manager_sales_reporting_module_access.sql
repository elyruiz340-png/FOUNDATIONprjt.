-- Allow branch-scoped Manager reporting checks for explicit Overview and Sales action permissions.
-- Keep the existing Orders / Transactions read compatibility unchanged.
CREATE OR REPLACE FUNCTION public.edmel_manager_has_module_access(p_restaurant_id uuid, p_branch_id uuid, p_module text, p_action text DEFAULT 'view'::text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT
    p_restaurant_id IS NOT NULL
    AND p_branch_id IS NOT NULL
    AND (
      (
        p_module IN ('overview', 'sales')
        AND p_action = 'view'
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
              sba.permissions #>> ARRAY['modules', p_module, 'view'] = 'true'
              OR sba.permissions #>> ARRAY['modules', p_module, 'manage'] = 'true'
            )
        )
      )
      OR
      (
        p_module IN ('orders', 'transactions')
        AND p_action = 'view'
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
              sba.permissions #>> ARRAY['modules', p_module, 'view'] = 'true'
              OR sba.permissions #>> ARRAY['modules', p_module, 'manage'] = 'true'
              OR sba.permissions #>> ARRAY['modules', 'orders', 'view'] = 'true'
              OR sba.permissions #>> ARRAY['modules', 'orders', 'manage'] = 'true'
              OR sba.permissions #>> ARRAY['modules', 'transactions', 'view'] = 'true'
              OR sba.permissions #>> ARRAY['modules', 'transactions', 'manage'] = 'true'
              OR sba.permissions ->> 'orders' = 'true'
            )
        )
      )
    );
$function$
;

COMMENT ON FUNCTION public.edmel_manager_has_module_access(uuid, uuid, text, text)
 IS 'Checks branch-scoped Manager access for explicit Overview and Sales reporting permissions and preserves Orders/Transactions read compatibility.';
