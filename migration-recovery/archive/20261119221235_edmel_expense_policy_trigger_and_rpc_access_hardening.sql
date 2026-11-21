
create or replace function public.edmel_guard_manager_expense_policy()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_manager_id uuid;
  v_approval_mode text := 'admin';
  v_legacy_approval_required boolean := true;
  v_permission text := coalesce(nullif(current_setting('edmel.expense_permission', true), ''), '');
  v_action text;
  v_manage boolean := false;
begin
  select ru.id into v_manager_id
  from public.restaurant_users ru
  where ru.user_id=(select auth.uid())
    and ru.restaurant_id=new.restaurant_id
    and coalesce(ru.is_active,true)=true
    and lower(coalesce(ru.role,''))='staff'
    and lower(coalesce(ru.position,''))='manager'
  order by ru.created_at desc
  limit 1;

  if v_manager_id is null then return new; end if;

  if v_permission='approve'
     and public.edmel_expense_has_access(new.restaurant_id,new.branch_id,'approve') then
    return new;
  end if;

  v_action:=case
    when v_permission='create' then 'create'
    when v_permission='edit' then 'edit'
    when v_permission='delete' then 'void'
    when tg_op='INSERT' then 'create'
    when new.status='voided' and old.status is distinct from new.status then 'void'
    else 'edit'
  end;

  select case v_action
    when 'create' then p.create_approval_mode
    when 'edit' then p.edit_approval_mode
    else p.void_approval_mode
  end
  into v_approval_mode
  from public.restaurant_expense_policies p
  where p.restaurant_id=new.restaurant_id and p.branch_id=new.branch_id;

  if not found then
    select coalesce((sba.permissions->>'expense_approval_required')::boolean,true)
      into v_legacy_approval_required
    from public.staff_branch_access sba
    where sba.restaurant_user_id=v_manager_id
      and sba.restaurant_id=new.restaurant_id
      and sba.branch_id=new.branch_id
      and sba.is_active=true;
    if not found then raise exception 'This Manager is not assigned to the expense branch.'; end if;
    v_approval_mode:=case when v_legacy_approval_required then 'admin' else 'none' end;
  end if;

  v_manage:=public.edmel_expense_has_access(new.restaurant_id,new.branch_id,'manage');
  if v_manage and v_action in ('create','edit') then
    v_approval_mode:='none';
  end if;

  if coalesce(v_approval_mode,'admin')<>'none' then
    raise exception 'Manager expense approval is required. Submit an expense request for review.';
  end if;

  if tg_op='INSERT' then
    new.status:='approved';
    new.approved_by_user_id:=(select auth.uid());
    new.approved_at:=now();
    new.approval_note:='Automatically approved under branch approval policy; approval is not required.';
  end if;
  return new;
end;
$function$;

-- Internal trigger functions are invoked by PostgreSQL triggers, not by the REST API.
revoke all on function public.edmel_block_expense_audit_mutation() from public, anon, authenticated;
revoke all on function public.edmel_capture_expense_audit() from public, anon, authenticated;
revoke all on function public.edmel_capture_manager_expense_request_notification() from public, anon, authenticated;
revoke all on function public.edmel_guard_expense_category() from public, anon, authenticated;
revoke all on function public.edmel_guard_manager_expense_policy() from public, anon, authenticated;

-- Expense helpers and business RPCs are available only to signed-in users.
revoke all on function public.edmel_expense_can_view_categories(uuid) from public, anon;
revoke all on function public.edmel_expense_has_access(uuid,uuid,text) from public, anon;
revoke all on function public.edmel_create_operating_expense(uuid,uuid,uuid,date,text,numeric,text,text,text) from public, anon;
revoke all on function public.edmel_review_operating_expense(uuid,text,text) from public, anon;
revoke all on function public.edmel_update_operating_expense(uuid,uuid,date,text,numeric,text,text,text,text) from public, anon;
revoke all on function public.edmel_void_operating_expense(uuid,text) from public, anon;
grant execute on function public.edmel_expense_can_view_categories(uuid) to authenticated;
grant execute on function public.edmel_expense_has_access(uuid,uuid,text) to authenticated;
grant execute on function public.edmel_create_operating_expense(uuid,uuid,uuid,date,text,numeric,text,text,text) to authenticated;
grant execute on function public.edmel_review_operating_expense(uuid,text,text) to authenticated;
grant execute on function public.edmel_update_operating_expense(uuid,uuid,date,text,numeric,text,text,text,text) to authenticated;
grant execute on function public.edmel_void_operating_expense(uuid,text) to authenticated;
