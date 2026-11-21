create or replace function public.halina_can_manage_tables(p_restaurant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $function$
  select exists (
    select 1
    from public.restaurant_users ru
    where ru.user_id = auth.uid()
      and ru.restaurant_id = p_restaurant_id
      and ru.is_active = true
      and (
        ru.role in ('owner', 'admin')
        or (
          ru.role = 'staff'
          and coalesce(ru.permissions->'tables', 'false'::jsonb) = 'true'::jsonb
        )
      )
  );
$function$;