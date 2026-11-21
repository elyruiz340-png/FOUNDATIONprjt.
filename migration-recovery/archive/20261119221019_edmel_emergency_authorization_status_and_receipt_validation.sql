
create or replace function public.edmel_review_manager_emergency_authorization(
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
  v_req public.manager_emergency_authorization_requests%rowtype;
  v_actor public.restaurant_users%rowtype;
  v_new_status text;
begin
  if v_user_id is null then raise exception 'Authentication required.' using errcode='42501'; end if;
  if p_decision not in ('approved','rejected')
     or char_length(btrim(coalesce(p_reason,''))) not between 3 and 500 then
    raise exception 'Choose approve or reject and provide a reason between 3 and 500 characters.' using errcode='22023';
  end if;
  select * into v_req from public.manager_emergency_authorization_requests where id=p_request_id for update;
  if not found then raise exception 'Emergency authorization request not found.' using errcode='P0002'; end if;
  if v_req.status<>'pending_authorization' then raise exception 'This authorization request has already been reviewed.' using errcode='22023'; end if;
  if not public.edmel_is_restaurant_owner_admin(v_req.restaurant_id) then
    raise exception 'Owner or Admin approval is required.' using errcode='42501';
  end if;
  select ru.* into v_actor from public.restaurant_users ru
  where ru.user_id=v_user_id and ru.restaurant_id=v_req.restaurant_id
    and coalesce(ru.is_active,true)=true
  order by ru.created_at desc limit 1;

  v_new_status:=case when p_decision='approved' then 'authorized' else 'rejected' end;
  update public.manager_emergency_authorization_requests
  set status=v_new_status,approved_amount=case when p_decision='approved' then requested_amount else null end,
      approved_by_user_id=v_user_id,approved_at=now(),decision_reason=btrim(p_reason),updated_at=now()
  where id=p_request_id;

  insert into public.manager_emergency_authorization_notifications(
    restaurant_id,branch_id,request_id,recipient_role,recipient_user_id,notification_type,title,message
  ) values (
    v_req.restaurant_id,v_req.branch_id,v_req.id,'manager',v_req.submitted_by_user_id,
    'authorization_decided',
    case when p_decision='approved' then 'Emergency spending authorized' else 'Emergency authorization rejected' end,
    'Your emergency request for '||v_req.description||' was '||p_decision||'. Reason: '||btrim(p_reason)
  );

  insert into public.audit_logs(
    restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
    record_type,record_id,result,details
  ) values (
    v_req.restaurant_id,v_user_id,
    coalesce(nullif(btrim(v_actor.display_name),''),nullif(btrim(v_actor.full_name),''),'Owner/Admin'),
    lower(coalesce(v_actor.role,'admin')),'Emergency Authorization',
    case when p_decision='approved' then 'Approved emergency spending authorization' else 'Rejected emergency spending authorization' end,
    'manager_emergency_authorization',v_req.id::text,'success',
    jsonb_build_object('branch_id',v_req.branch_id,'requested_amount',v_req.requested_amount,
      'reason',btrim(p_reason))
  );
  return jsonb_build_object('success',true,'request_id',v_req.id,'status',v_new_status);
end;
$function$;

create or replace function public.edmel_submit_manager_emergency_actuals(
  p_request_id uuid,
  p_actual_amount numeric,
  p_receipt_reference text,
  p_notes text
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_req public.manager_emergency_authorization_requests%rowtype;
  v_manager public.restaurant_users%rowtype;
begin
  if v_user_id is null then raise exception 'Authentication required.' using errcode='42501'; end if;
  if p_actual_amount is null or p_actual_amount<=0 or p_actual_amount::text in ('NaN','Infinity','-Infinity')
     or char_length(btrim(coalesce(p_receipt_reference,''))) not between 3 and 500
     or char_length(coalesce(p_notes,''))>2000 then
    raise exception 'Enter a valid actual amount and a receipt reference or link between 3 and 500 characters. Notes cannot exceed 2000 characters.' using errcode='22023';
  end if;
  select * into v_req from public.manager_emergency_authorization_requests where id=p_request_id for update;
  if not found then raise exception 'Emergency authorization request not found.' using errcode='P0002'; end if;
  if v_req.submitted_by_user_id<>v_user_id then raise exception 'Only the submitting Manager may submit actual spending details.' using errcode='42501'; end if;
  if v_req.status not in ('authorized','authorized_under_limit','reconciliation_rejected') then
    raise exception 'This request is not ready for actual spending review.' using errcode='22023';
  end if;
  if not public.edmel_expense_has_access(v_req.restaurant_id,v_req.branch_id,'create') then
    raise exception 'You no longer have expense access for this branch.' using errcode='42501';
  end if;
  update public.manager_emergency_authorization_requests
  set actual_amount=p_actual_amount,actual_receipt_reference=btrim(p_receipt_reference),
      actual_notes=nullif(btrim(p_notes),''),actual_submitted_at=now(),
      status='spent_pending_review',updated_at=now()
  where id=p_request_id;

  select ru.* into v_manager from public.restaurant_users ru
  where ru.user_id=v_user_id and ru.restaurant_id=v_req.restaurant_id
  order by ru.created_at desc limit 1;
  insert into public.manager_emergency_authorization_notifications(
    restaurant_id,branch_id,request_id,recipient_role,notification_type,title,message
  ) values (
    v_req.restaurant_id,v_req.branch_id,v_req.id,'admin','actuals_submitted',
    'Emergency spending actuals submitted',
    coalesce(nullif(btrim(v_manager.display_name),''),nullif(btrim(v_manager.full_name),''),'Manager')||
    ' submitted actual spending details for '||v_req.description||'.'
  );
  insert into public.audit_logs(
    restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
    record_type,record_id,result,details
  ) values (
    v_req.restaurant_id,v_user_id,
    coalesce(nullif(btrim(v_manager.display_name),''),nullif(btrim(v_manager.full_name),''),'Manager'),
    'manager','Emergency Authorization','Submitted emergency spending actuals',
    'manager_emergency_authorization',v_req.id::text,'success',
    jsonb_build_object('branch_id',v_req.branch_id,'authorized_amount',v_req.approved_amount,
      'actual_amount',p_actual_amount,'receipt_reference_present',true)
  );
  return jsonb_build_object('success',true,'request_id',v_req.id,'status','spent_pending_review',
    'over_authorized_amount',p_actual_amount>coalesce(v_req.approved_amount,v_req.requested_amount));
end;
$function$;

revoke all on function public.edmel_review_manager_emergency_authorization(uuid,text,text) from public, anon;
revoke all on function public.edmel_submit_manager_emergency_actuals(uuid,numeric,text,text) from public, anon;
grant execute on function public.edmel_review_manager_emergency_authorization(uuid,text,text) to authenticated;
grant execute on function public.edmel_submit_manager_emergency_actuals(uuid,numeric,text,text) to authenticated;
