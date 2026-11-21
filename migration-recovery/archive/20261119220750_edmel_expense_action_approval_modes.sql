
create or replace function public.edmel_submit_manager_expense_request(
  p_restaurant_id uuid,
  p_branch_id uuid,
  p_request_type text,
  p_expense_id uuid,
  p_request_data jsonb
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_manager public.restaurant_users%rowtype;
  v_expense public.restaurant_expenses%rowtype;
  v_approval_mode text := 'admin';
  v_legacy_approval_required boolean := true;
  v_action text;
  v_manage boolean := false;
  v_category_id uuid;
  v_expense_date date;
  v_description text;
  v_amount numeric;
  v_payee text;
  v_reference text;
  v_notes text;
  v_reason text;
  v_expense_id uuid;
  v_request_id uuid;
  v_currency text;
  v_actor_name text;
begin
  if v_user_id is null then raise exception 'Authentication required.' using errcode='42501'; end if;
  p_request_data := coalesce(p_request_data,'{}'::jsonb);
  if p_restaurant_id is null or p_branch_id is null
     or p_request_type is null or p_request_type not in ('create','edit','void')
     or jsonb_typeof(p_request_data) <> 'object' or pg_column_size(p_request_data)>16384 then
    raise exception 'Invalid expense request.' using errcode='22023';
  end if;

  select ru.* into v_manager
  from public.restaurant_users ru
  where ru.user_id=v_user_id and ru.restaurant_id=p_restaurant_id
    and lower(coalesce(ru.role,''))='staff'
    and lower(coalesce(ru.position,''))='manager'
    and coalesce(ru.is_active,true)=true
  order by ru.created_at desc limit 1;
  if v_manager.id is null then raise exception 'Active Manager access is required.' using errcode='42501'; end if;
  if not exists (
    select 1 from public.restaurant_branches b
    where b.id=p_branch_id and b.restaurant_id=p_restaurant_id and b.is_active=true
  ) then raise exception 'The selected branch is not active in this restaurant.' using errcode='22023'; end if;

  v_action:=case p_request_type when 'create' then 'create' when 'edit' then 'edit' else 'delete' end;
  if not public.edmel_expense_has_access(p_restaurant_id,p_branch_id,v_action) then
    raise exception 'You do not have permission for this expense action in the selected branch.' using errcode='42501';
  end if;
  v_manage:=public.edmel_expense_has_access(p_restaurant_id,p_branch_id,'manage');

  select case p_request_type
    when 'create' then p.create_approval_mode
    when 'edit' then p.edit_approval_mode
    else p.void_approval_mode
  end
  into v_approval_mode
  from public.restaurant_expense_policies p
  where p.restaurant_id=p_restaurant_id and p.branch_id=p_branch_id;

  if not found then
    select coalesce((sba.permissions->>'expense_approval_required')::boolean,true)
      into v_legacy_approval_required
    from public.staff_branch_access sba
    where sba.restaurant_user_id=v_manager.id
      and sba.restaurant_id=p_restaurant_id
      and sba.branch_id=p_branch_id
      and sba.is_active=true;
    if not found then raise exception 'This branch is not assigned to the Manager.' using errcode='42501'; end if;
    v_approval_mode:=case when v_legacy_approval_required then 'admin' else 'none' end;
  end if;
  v_approval_mode:=coalesce(v_approval_mode,'admin');

  -- Manage permission allows direct creation and editing. Void remains governed by its branch policy.
  if v_manage and p_request_type in ('create','edit') then
    v_approval_mode:='none';
  end if;

  if p_request_type in ('create','edit') then
    begin
      v_category_id:=nullif(p_request_data->>'category_id','')::uuid;
      v_expense_date:=coalesce(nullif(p_request_data->>'expense_date','')::date,current_date);
      v_amount:=nullif(p_request_data->>'amount','')::numeric;
    exception when others then
      raise exception 'Expense category, date or amount is invalid.';
    end;
    v_description:=btrim(coalesce(p_request_data->>'description',''));
    v_payee:=nullif(btrim(coalesce(p_request_data->>'payee','')),'');
    v_reference:=nullif(btrim(coalesce(p_request_data->>'reference_number','')),'');
    v_notes:=nullif(btrim(coalesce(p_request_data->>'notes','')),'');
    v_reason:=nullif(btrim(coalesce(p_request_data->>'reason','')),'');
    if v_category_id is null or char_length(v_description) not between 3 and 500
       or v_amount is null or v_amount::text in ('NaN','Infinity','-Infinity') or v_amount<=0
       or (v_notes is not null and char_length(v_notes)>2000)
       or (p_request_type='edit' and (v_reason is null or char_length(v_reason)<3 or char_length(v_reason)>500)) then
      raise exception 'Complete the required expense fields with valid values.';
    end if;
    if not exists (
      select 1 from public.restaurant_expense_categories c
      where c.id=v_category_id and c.restaurant_id=p_restaurant_id and c.is_active=true
    ) then raise exception 'The selected expense category is unavailable.'; end if;
  else
    v_reason:=nullif(btrim(coalesce(p_request_data->>'reason','')),'');
    if v_reason is null or char_length(v_reason)<3 or char_length(v_reason)>500 then
      raise exception 'A reason between 3 and 500 characters is required.';
    end if;
  end if;

  if p_request_type in ('edit','void') then
    if p_expense_id is null then raise exception 'An expense record is required.'; end if;
    select * into v_expense from public.restaurant_expenses e
    where e.id=p_expense_id and e.restaurant_id=p_restaurant_id and e.branch_id=p_branch_id
    for update;
    if not found then raise exception 'Expense record was not found in this branch.'; end if;
    if v_expense.status in ('rejected','voided') then raise exception 'Rejected or voided expenses cannot be changed.'; end if;
    if p_request_type='edit' and v_expense.status='pending'
       and v_expense.created_by_user_id<>v_user_id and not v_manage then
      raise exception 'You may only edit your own pending expense submission unless Manage permission is granted.';
    end if;
    if exists(select 1 from public.manager_expense_requests r where r.expense_id=p_expense_id and r.status='pending') then
      raise exception 'This expense already has a pending Manager request.';
    end if;
    if v_approval_mode<>'none' then
      p_request_data:=p_request_data||jsonb_build_object('expected_updated_at',v_expense.updated_at);
    end if;
  elsif p_expense_id is not null then
    raise exception 'A new expense request must not include an existing expense ID.';
  end if;

  if v_approval_mode='none' then
    if p_request_type='create' then
      select r.currency into v_currency from public.restaurants r where r.id=p_restaurant_id;
      if v_currency is null then raise exception 'Restaurant currency could not be verified.'; end if;
      perform set_config('edmel.expense_permission','create',true);
      insert into public.restaurant_expenses(
        restaurant_id,branch_id,category_id,expense_date,description,payee,
        reference_number,notes,amount,currency_code,status,created_by_user_id,
        created_by_staff_id,approved_by_user_id,approved_at,approval_note
      ) values (
        p_restaurant_id,p_branch_id,v_category_id,v_expense_date,v_description,v_payee,
        v_reference,v_notes,v_amount,upper(v_currency),'approved',v_user_id,
        v_manager.id,v_user_id,now(),'Automatically approved under branch approval policy.'
      ) returning id into v_expense_id;
    elsif p_request_type='edit' then
      perform set_config('edmel.expense_permission','edit',true);
      update public.restaurant_expenses
      set category_id=v_category_id,expense_date=v_expense_date,description=v_description,
          payee=v_payee,reference_number=v_reference,notes=v_notes,amount=v_amount,
          last_change_reason=v_reason,updated_by_user_id=v_user_id,updated_at=now()
      where id=p_expense_id;
      v_expense_id:=p_expense_id;
    else
      perform set_config('edmel.expense_permission','delete',true);
      update public.restaurant_expenses
      set status='voided',voided_by_user_id=v_user_id,voided_at=now(),
          void_reason=v_reason,last_change_reason=v_reason,
          updated_by_user_id=v_user_id,updated_at=now()
      where id=p_expense_id;
      v_expense_id:=p_expense_id;
    end if;
    return jsonb_build_object('success',true,'status','saved','direct_save',true,
      'approval_mode',v_approval_mode,'expense_id',v_expense_id);
  end if;

  p_request_data:=p_request_data||jsonb_build_object('approval_mode',v_approval_mode);
  insert into public.manager_expense_requests(
    restaurant_id,branch_id,manager_restaurant_user_id,submitted_by_user_id,
    request_type,expense_id,request_data
  ) values (
    p_restaurant_id,p_branch_id,v_manager.id,v_user_id,p_request_type,p_expense_id,p_request_data
  ) returning id into v_request_id;

  v_actor_name:=coalesce(nullif(btrim(v_manager.display_name),''),nullif(btrim(v_manager.full_name),''),nullif(btrim(v_manager.cashier_username),''),'Manager');
  insert into public.audit_logs(
    restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
    record_type,record_id,result,details
  ) values (
    p_restaurant_id,v_user_id,v_actor_name,'staff (Manager)','Expenses & Profit',
    'Submitted expense approval request','manager_expense_request',v_request_id::text,'success',
    jsonb_build_object('branch_id',p_branch_id,'request_type',p_request_type,
      'expense_id',p_expense_id,'approval_mode',v_approval_mode)
  );
  return jsonb_build_object('success',true,'status','pending','direct_save',false,
    'approval_mode',v_approval_mode,'request_id',v_request_id);
end;
$function$;

create or replace function public.edmel_review_manager_expense_request(
  p_request_id uuid,
  p_decision text,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_request public.manager_expense_requests%rowtype;
  v_expense public.restaurant_expenses%rowtype;
  v_manager public.restaurant_users%rowtype;
  v_owner_admin boolean;
  v_approval_mode text;
  v_category_id uuid;
  v_expense_date date;
  v_description text;
  v_amount numeric;
  v_currency text;
  v_payee text;
  v_reference text;
  v_notes text;
  v_expense_id uuid;
  v_actor_name text;
  v_actor_role text;
begin
  if v_user_id is null then raise exception 'Authentication required.'; end if;
  if p_decision is null or p_decision not in ('approved','rejected')
     or p_reason is null or char_length(btrim(p_reason)) not between 3 and 500 then
    raise exception 'Choose approve or reject and provide a reason between 3 and 500 characters.';
  end if;

  select * into v_request from public.manager_expense_requests r
  where r.id=p_request_id for update;
  if not found then raise exception 'Expense approval request was not found.'; end if;
  if v_request.status<>'pending' then raise exception 'This request has already been reviewed.'; end if;
  if v_request.submitted_by_user_id=v_user_id then raise exception 'You cannot approve or reject your own expense request.'; end if;

  v_owner_admin:=public.edmel_is_restaurant_owner_admin(v_request.restaurant_id);
  v_approval_mode:=coalesce(v_request.request_data->>'approval_mode','admin');
  if v_approval_mode='admin' and not v_owner_admin then
    raise exception 'Owner or Admin approval is required for this request.' using errcode='42501';
  end if;
  if v_approval_mode='manager' and not v_owner_admin
     and not public.edmel_expense_has_access(v_request.restaurant_id,v_request.branch_id,'approve') then
    raise exception 'You do not have Manager approval permission for this branch.' using errcode='42501';
  end if;
  if v_approval_mode not in ('admin','manager') then
    raise exception 'This request has an invalid approval policy.' using errcode='22023';
  end if;

  select ru.* into v_manager from public.restaurant_users ru
  where ru.id=v_request.manager_restaurant_user_id and ru.restaurant_id=v_request.restaurant_id;
  if v_manager.id is null then raise exception 'The submitting Manager account could not be verified.'; end if;
  if not exists(select 1 from public.restaurant_branches b
    where b.id=v_request.branch_id and b.restaurant_id=v_request.restaurant_id and b.is_active=true) then
    raise exception 'The request branch is no longer active.';
  end if;

  if p_decision='approved' then
    perform set_config('edmel.expense_permission','approve',true);
    if v_request.request_type='create' then
      begin
        v_category_id:=nullif(v_request.request_data->>'category_id','')::uuid;
        v_expense_date:=coalesce(nullif(v_request.request_data->>'expense_date','')::date,current_date);
        v_amount:=nullif(v_request.request_data->>'amount','')::numeric;
      exception when others then raise exception 'The submitted expense data is invalid.'; end;
      v_description:=btrim(coalesce(v_request.request_data->>'description',''));
      v_payee:=nullif(btrim(coalesce(v_request.request_data->>'payee','')),'');
      v_reference:=nullif(btrim(coalesce(v_request.request_data->>'reference_number','')),'');
      v_notes:=nullif(btrim(coalesce(v_request.request_data->>'notes','')),'');
      if v_category_id is null or char_length(v_description) not between 3 and 500
         or v_amount is null or v_amount::text in ('NaN','Infinity','-Infinity') or v_amount<=0 then
        raise exception 'The submitted expense data is incomplete or invalid.';
      end if;
      if not exists(select 1 from public.restaurant_expense_categories c
        where c.id=v_category_id and c.restaurant_id=v_request.restaurant_id and c.is_active=true) then
        raise exception 'The submitted expense category is no longer active.';
      end if;
      select r.currency into v_currency from public.restaurants r where r.id=v_request.restaurant_id;
      if v_currency is null then raise exception 'Restaurant currency could not be verified.'; end if;
      insert into public.restaurant_expenses(
        restaurant_id,branch_id,category_id,expense_date,description,payee,
        reference_number,notes,amount,currency_code,status,created_by_user_id,
        created_by_staff_id,approved_by_user_id,approved_at,approval_note
      ) values (
        v_request.restaurant_id,v_request.branch_id,v_category_id,v_expense_date,v_description,
        v_payee,v_reference,v_notes,v_amount,upper(v_currency),'approved',
        v_request.submitted_by_user_id,v_request.manager_restaurant_user_id,
        v_user_id,now(),btrim(p_reason)
      ) returning id into v_expense_id;
    elsif v_request.request_type='edit' then
      select * into v_expense from public.restaurant_expenses e
      where e.id=v_request.expense_id and e.restaurant_id=v_request.restaurant_id
        and e.branch_id=v_request.branch_id for update;
      if not found or v_expense.status in ('rejected','voided') then raise exception 'The expense can no longer be edited.'; end if;
      if nullif(v_request.request_data->>'expected_updated_at','') is null
         or (v_request.request_data->>'expected_updated_at')::timestamptz is distinct from v_expense.updated_at then
        raise exception 'This expense changed after the request was submitted. Refresh and submit the change again.';
      end if;
      begin
        v_category_id:=nullif(v_request.request_data->>'category_id','')::uuid;
        v_expense_date:=coalesce(nullif(v_request.request_data->>'expense_date','')::date,v_expense.expense_date);
        v_amount:=nullif(v_request.request_data->>'amount','')::numeric;
      exception when others then raise exception 'The submitted expense changes are invalid.'; end;
      v_description:=btrim(coalesce(v_request.request_data->>'description',''));
      v_payee:=nullif(btrim(coalesce(v_request.request_data->>'payee','')),'');
      v_reference:=nullif(btrim(coalesce(v_request.request_data->>'reference_number','')),'');
      v_notes:=nullif(btrim(coalesce(v_request.request_data->>'notes','')),'');
      if v_category_id is null or char_length(v_description) not between 3 and 500
         or v_amount is null or v_amount::text in ('NaN','Infinity','-Infinity') or v_amount<=0 then
        raise exception 'The submitted expense changes are incomplete or invalid.';
      end if;
      if not exists(select 1 from public.restaurant_expense_categories c
        where c.id=v_category_id and c.restaurant_id=v_request.restaurant_id and c.is_active=true) then
        raise exception 'The requested expense category is no longer active.';
      end if;
      update public.restaurant_expenses
      set category_id=v_category_id,expense_date=v_expense_date,description=v_description,
          payee=v_payee,reference_number=v_reference,notes=v_notes,amount=v_amount,
          last_change_reason='Manager change request approved: '||btrim(p_reason),
          updated_by_user_id=v_user_id,updated_at=now()
      where id=v_request.expense_id;
      v_expense_id:=v_request.expense_id;
    else
      select * into v_expense from public.restaurant_expenses e
      where e.id=v_request.expense_id and e.restaurant_id=v_request.restaurant_id
        and e.branch_id=v_request.branch_id for update;
      if not found or v_expense.status='voided' then raise exception 'The expense can no longer be voided.'; end if;
      if nullif(v_request.request_data->>'expected_updated_at','') is null
         or (v_request.request_data->>'expected_updated_at')::timestamptz is distinct from v_expense.updated_at then
        raise exception 'This expense changed after the request was submitted. Refresh and submit the void again.';
      end if;
      update public.restaurant_expenses
      set status='voided',voided_by_user_id=v_user_id,voided_at=now(),
          void_reason=btrim(p_reason),last_change_reason='Manager void request approved: '||btrim(p_reason),
          updated_by_user_id=v_user_id,updated_at=now()
      where id=v_request.expense_id;
      v_expense_id:=v_request.expense_id;
    end if;
  end if;

  update public.manager_expense_requests
  set status=p_decision,reviewed_by_user_id=v_user_id,reviewed_at=now(),
      review_reason=btrim(p_reason),updated_at=now()
  where id=p_request_id;

  select coalesce(nullif(ru.display_name,''),nullif(ru.full_name,''),nullif(ru.cashier_username,''),'Approver'),
         lower(coalesce(ru.role,'staff'))
    into v_actor_name,v_actor_role
  from public.restaurant_users ru
  where ru.user_id=v_user_id and ru.restaurant_id=v_request.restaurant_id
    and coalesce(ru.is_active,true)=true
  order by ru.created_at desc limit 1;

  insert into public.audit_logs(
    restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
    record_type,record_id,result,details
  ) values (
    v_request.restaurant_id,v_user_id,coalesce(v_actor_name,'Approver'),coalesce(v_actor_role,'staff'),
    'Expenses & Profit',
    case p_decision when 'approved' then 'Approved Manager expense request' else 'Rejected Manager expense request' end,
    'manager_expense_request',p_request_id::text,'success',
    jsonb_build_object('branch_id',v_request.branch_id,'request_type',v_request.request_type,
      'expense_id',v_expense_id,'submitted_by_user_id',v_request.submitted_by_user_id,
      'approval_mode',v_approval_mode,'reason',btrim(p_reason))
  );
  return jsonb_build_object('success',true,'status',p_decision,'request_id',p_request_id,'expense_id',v_expense_id);
end;
$function$;

revoke all on function public.edmel_submit_manager_expense_request(uuid,uuid,text,uuid,jsonb) from public, anon;
revoke all on function public.edmel_review_manager_expense_request(uuid,text,text) from public, anon;
grant execute on function public.edmel_submit_manager_expense_request(uuid,uuid,text,uuid,jsonb) to authenticated;
grant execute on function public.edmel_review_manager_expense_request(uuid,text,text) to authenticated;
