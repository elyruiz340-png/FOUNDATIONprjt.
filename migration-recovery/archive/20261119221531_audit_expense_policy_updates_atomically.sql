
create or replace function public.edmel_save_restaurant_expense_policy(
  p_restaurant_id uuid,
  p_branch_id uuid,
  p_create_approval_mode text,
  p_edit_approval_mode text,
  p_void_approval_mode text,
  p_emergency_authorization_limit numeric
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_actor public.restaurant_users%rowtype;
begin
  if v_user_id is null then raise exception 'Authentication required.' using errcode='42501'; end if;
  if not public.edmel_is_restaurant_owner_admin(p_restaurant_id) then
    raise exception 'Owner or Admin access is required to change expense approval policies.' using errcode='42501';
  end if;
  if p_create_approval_mode not in ('none','manager','admin')
     or p_edit_approval_mode not in ('none','manager','admin')
     or p_void_approval_mode not in ('none','manager','admin')
     or p_emergency_authorization_limit is null
     or p_emergency_authorization_limit<0
     or p_emergency_authorization_limit::text in ('NaN','Infinity','-Infinity') then
    raise exception 'Enter valid approval modes and a non-negative emergency spending limit.' using errcode='22023';
  end if;
  if not exists(select 1 from public.restaurant_branches b
    where b.id=p_branch_id and b.restaurant_id=p_restaurant_id and b.is_active=true) then
    raise exception 'The selected branch is invalid or inactive.' using errcode='22023';
  end if;

  insert into public.restaurant_expense_policies(
    restaurant_id,branch_id,create_approval_mode,edit_approval_mode,
    void_approval_mode,emergency_authorization_limit,updated_by_user_id,updated_at
  ) values (
    p_restaurant_id,p_branch_id,p_create_approval_mode,p_edit_approval_mode,
    p_void_approval_mode,p_emergency_authorization_limit,v_user_id,now()
  )
  on conflict(restaurant_id,branch_id) do update
  set create_approval_mode=excluded.create_approval_mode,
      edit_approval_mode=excluded.edit_approval_mode,
      void_approval_mode=excluded.void_approval_mode,
      emergency_authorization_limit=excluded.emergency_authorization_limit,
      updated_by_user_id=excluded.updated_by_user_id,
      updated_at=now();

  select ru.* into v_actor from public.restaurant_users ru
  where ru.user_id=v_user_id and ru.restaurant_id=p_restaurant_id
    and coalesce(ru.is_active,true)=true
  order by ru.created_at desc limit 1;

  insert into public.audit_logs(
    restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
    record_type,record_id,result,details
  ) values (
    p_restaurant_id,v_user_id,
    coalesce(nullif(btrim(v_actor.display_name),''),nullif(btrim(v_actor.full_name),''),'Owner/Admin'),
    lower(coalesce(v_actor.role,'admin')),'Expenses & Profit',
    'Updated branch expense approval policy','restaurant_expense_policy',p_branch_id::text,'success',
    jsonb_build_object('create_approval_mode',p_create_approval_mode,
      'edit_approval_mode',p_edit_approval_mode,'void_approval_mode',p_void_approval_mode,
      'emergency_authorization_limit',p_emergency_authorization_limit)
  );
  return jsonb_build_object('success',true,'branch_id',p_branch_id);
end;
$function$;

revoke all on function public.edmel_save_restaurant_expense_policy(uuid,uuid,text,text,text,numeric) from public, anon;
grant execute on function public.edmel_save_restaurant_expense_policy(uuid,uuid,text,text,text,numeric) to authenticated;

drop policy if exists restaurant_expense_policies_admin_insert on public.restaurant_expense_policies;
drop policy if exists restaurant_expense_policies_admin_update on public.restaurant_expense_policies;
revoke insert, update, delete on public.restaurant_expense_policies from authenticated;
grant select on public.restaurant_expense_policies to authenticated;
