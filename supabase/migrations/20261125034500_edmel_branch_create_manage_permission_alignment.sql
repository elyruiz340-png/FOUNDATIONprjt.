-- Align Manager branch-creation authorization with shared module permissions.
-- Manage includes Create; Manager identity and at least one active branch assignment remain required.
CREATE OR REPLACE FUNCTION private.edmel_manager_can_create_branch(
  p_restaurant_id uuid,
  p_user_id uuid
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
    JOIN public.staff_branch_access sba
      ON sba.restaurant_user_id = ru.id
     AND sba.restaurant_id = ru.restaurant_id
     AND sba.is_active = true
    JOIN public.restaurant_branches b
      ON b.id = sba.branch_id
     AND b.restaurant_id = ru.restaurant_id
     AND b.is_active = true
    WHERE ru.restaurant_id = p_restaurant_id
      AND ru.user_id = p_user_id
      AND ru.is_active = true
      AND lower(ru.role) = 'staff'
      AND lower(coalesce(ru.position, '')) = 'manager'
      AND public.edmel_permission_json_allows(
        sba.permissions,
        'branches',
        'create'
      )
  );
$function$;
