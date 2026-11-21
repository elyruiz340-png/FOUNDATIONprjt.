CREATE OR REPLACE FUNCTION public.edmel_review_manager_emergency_actuals(
  p_request_id uuid,
  p_decision text,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_req public.manager_emergency_authorization_requests%rowtype;
  v_actor public.restaurant_users%rowtype;
begin
  if v_user_id is null then
    raise exception 'Authentication required.' using errcode='42501';
  end if;

  if p_decision not in ('reconciled','rejected')
     or char_length(btrim(coalesce(p_reason,''))) not between 3 and 500 then
    raise exception 'Choose a valid final decision and provide a reason between 3 and 500 characters.' using errcode='22023';
  end if;

  select * into v_req
  from public.manager_emergency_authorization_requests
  where id=p_request_id
  for update;

  if not found then
    raise exception 'Emergency authorization request not found.' using errcode='P0002';
  end if;

  if v_req.status<>'spent_pending_review' then
    raise exception 'Actual spending is not awaiting final review.' using errcode='22023';
  end if;

  if not public.edmel_is_restaurant_owner_admin(v_req.restaurant_id) then
    raise exception 'Owner or Admin final review is required.' using errcode='42501';
  end if;

  select ru.* into v_actor
  from public.restaurant_users ru
  where ru.user_id=v_user_id
    and ru.restaurant_id=v_req.restaurant_id
    and coalesce(ru.is_active,true)=true
  order by ru.created_at desc
  limit 1;

  update public.manager_emergency_authorization_requests
  set status=case when p_decision='reconciled' then 'reconciled' else 'reconciliation_rejected' end,
      final_reviewed_by_user_id=v_user_id,
      final_reviewed_at=now(),
      final_review_reason=btrim(p_reason),
      updated_at=now()
  where id=p_request_id;

  insert into public.manager_emergency_authorization_notifications(
    restaurant_id,branch_id,request_id,recipient_role,recipient_user_id,notification_type,title,message
  ) values (
    v_req.restaurant_id,v_req.branch_id,v_req.id,'manager',v_req.submitted_by_user_id,'actuals_reviewed',
    case when p_decision='reconciled' then 'Emergency spending reconciled' else 'Emergency spending needs correction' end,
    'Final review for '||v_req.description||': '||p_decision||'. Reason: '||btrim(p_reason)
  );

  insert into public.audit_logs(
    restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
    record_type,record_id,result,details
  ) values (
    v_req.restaurant_id,v_user_id,
    coalesce(nullif(btrim(v_actor.display_name),''),nullif(btrim(v_actor.full_name),''),'Owner/Admin'),
    lower(coalesce(v_actor.role,'admin')),'Emergency Authorization',
    case when p_decision='reconciled' then 'Reviewed emergency spending actuals' else 'Rejected emergency spending actuals' end,
    'manager_emergency_authorization',v_req.id::text,'success',
    jsonb_build_object('branch_id',v_req.branch_id,'authorized_amount',v_req.approved_amount,
      'actual_amount',v_req.actual_amount,'decision',p_decision,'reason',btrim(p_reason))
  );

  return jsonb_build_object(
    'success',true,
    'request_id',v_req.id,
    'status',case when p_decision='reconciled' then 'reconciled' else 'reconciliation_rejected' end
  );
end;
$function$;