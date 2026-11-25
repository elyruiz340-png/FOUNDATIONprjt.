-- Allow Managers with Action-level Staff View to read subordinate staff records.
-- This function is used by SELECT policies only; staff writes remain Owner/Admin controlled.
CREATE OR REPLACE FUNCTION public.edmel_can_manage_branch_staff(p_branch_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 SELECT EXISTS (
  SELECT 1
  FROM public.restaurant_branches b
  JOIN public.restaurant_users ru
    ON ru.restaurant_id=b.restaurant_id
   AND ru.user_id=(SELECT auth.uid())
   AND coalesce(ru.is_active,true)=true
  WHERE b.id=p_branch_id
    AND b.is_active=true
    AND (
      lower(coalesce(ru.role,'')) IN ('owner','admin')
      OR EXISTS (
        SELECT 1
        FROM public.staff_branch_access sba
        WHERE sba.restaurant_user_id=ru.id
          AND sba.branch_id=b.id
          AND sba.restaurant_id=b.restaurant_id
          AND sba.is_active=true
          AND public.edmel_permission_json_allows(sba.permissions,'staff','view')
      )
    )
 );
$function$;
