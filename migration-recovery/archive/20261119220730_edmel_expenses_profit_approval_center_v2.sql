
create table if not exists public.restaurant_expense_policies (
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  create_approval_mode text not null default 'admin'
    check (create_approval_mode in ('none','manager','admin')),
  edit_approval_mode text not null default 'admin'
    check (edit_approval_mode in ('none','manager','admin')),
  void_approval_mode text not null default 'admin'
    check (void_approval_mode in ('none','manager','admin')),
  emergency_authorization_limit numeric(14,2) not null default 0
    check (emergency_authorization_limit >= 0),
  updated_by_user_id uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (restaurant_id, branch_id),
  constraint restaurant_expense_policies_branch_fk
    foreign key (branch_id, restaurant_id)
    references public.restaurant_branches(id, restaurant_id) on delete cascade
);

alter table public.restaurant_expense_policies enable row level security;
revoke all on public.restaurant_expense_policies from anon;
grant select, insert, update on public.restaurant_expense_policies to authenticated;

drop policy if exists restaurant_expense_policies_admin_select on public.restaurant_expense_policies;
create policy restaurant_expense_policies_admin_select
  on public.restaurant_expense_policies for select to authenticated
  using (public.edmel_is_restaurant_owner_admin(restaurant_id));

drop policy if exists restaurant_expense_policies_admin_insert on public.restaurant_expense_policies;
create policy restaurant_expense_policies_admin_insert
  on public.restaurant_expense_policies for insert to authenticated
  with check (public.edmel_is_restaurant_owner_admin(restaurant_id));

drop policy if exists restaurant_expense_policies_admin_update on public.restaurant_expense_policies;
create policy restaurant_expense_policies_admin_update
  on public.restaurant_expense_policies for update to authenticated
  using (public.edmel_is_restaurant_owner_admin(restaurant_id))
  with check (public.edmel_is_restaurant_owner_admin(restaurant_id));

create table if not exists public.manager_emergency_authorization_requests (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  manager_restaurant_user_id uuid not null references public.restaurant_users(id),
  submitted_by_user_id uuid not null references auth.users(id),
  description text not null check (char_length(btrim(description)) between 3 and 500),
  purpose text not null check (char_length(btrim(purpose)) between 3 and 1000),
  requested_amount numeric(14,2) not null check (requested_amount > 0),
  currency_code text not null check (currency_code ~ '^[A-Z]{3}$'),
  emergency_reason text not null check (char_length(btrim(emergency_reason)) between 3 and 1000),
  authorization_limit numeric(14,2) not null default 0 check (authorization_limit >= 0),
  status text not null default 'pending_authorization'
    check (status in ('pending_authorization','authorized','authorized_under_limit','rejected','spent_pending_review','reconciled','reconciliation_rejected')),
  approved_amount numeric(14,2),
  approved_by_user_id uuid references auth.users(id),
  approved_at timestamptz,
  decision_reason text,
  actual_amount numeric(14,2),
  actual_receipt_reference text,
  actual_notes text,
  actual_submitted_at timestamptz,
  final_reviewed_by_user_id uuid references auth.users(id),
  final_reviewed_at timestamptz,
  final_review_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint manager_emergency_authorization_branch_fk
    foreign key (branch_id, restaurant_id)
    references public.restaurant_branches(id, restaurant_id) on delete cascade,
  constraint manager_emergency_authorization_amounts_check
    check (actual_amount is null or actual_amount > 0)
);

create index if not exists manager_emergency_authorization_branch_status_idx
  on public.manager_emergency_authorization_requests(restaurant_id, branch_id, status, created_at desc);

create table if not exists public.manager_emergency_authorization_notifications (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  request_id uuid not null references public.manager_emergency_authorization_requests(id) on delete cascade,
  recipient_role text not null check (recipient_role in ('admin','manager')),
  recipient_user_id uuid,
  notification_type text not null check (notification_type in ('authorization_requested','authorization_decided','actuals_submitted','actuals_reviewed')),
  title text not null,
  message text not null,
  is_read boolean not null default false,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  constraint manager_emergency_authorization_notifications_branch_fk
    foreign key (branch_id, restaurant_id)
    references public.restaurant_branches(id, restaurant_id) on delete cascade
);

create index if not exists manager_emergency_authorization_notifications_recipient_idx
  on public.manager_emergency_authorization_notifications(restaurant_id, recipient_role, recipient_user_id, is_read, created_at desc);

alter table public.manager_emergency_authorization_requests enable row level security;
alter table public.manager_emergency_authorization_notifications enable row level security;
revoke all on public.manager_emergency_authorization_requests from anon;
revoke all on public.manager_emergency_authorization_notifications from anon;
grant select on public.manager_emergency_authorization_requests to authenticated;
grant select, update(is_read, read_at) on public.manager_emergency_authorization_notifications to authenticated;

drop policy if exists manager_emergency_authorization_select_authorized on public.manager_emergency_authorization_requests;
create policy manager_emergency_authorization_select_authorized
  on public.manager_emergency_authorization_requests for select to authenticated
  using (
    public.edmel_is_restaurant_owner_admin(restaurant_id)
    or (
      submitted_by_user_id = (select auth.uid())
      and public.edmel_expense_has_access(restaurant_id, branch_id, 'view')
    )
  );

drop policy if exists manager_emergency_authorization_notifications_select_recipient on public.manager_emergency_authorization_notifications;
create policy manager_emergency_authorization_notifications_select_recipient
  on public.manager_emergency_authorization_notifications for select to authenticated
  using (
    (recipient_role = 'admin' and public.edmel_is_restaurant_owner_admin(restaurant_id))
    or (recipient_role = 'manager' and recipient_user_id = (select auth.uid())
        and public.edmel_expense_has_access(restaurant_id, branch_id, 'view'))
  );

drop policy if exists manager_emergency_authorization_notifications_update_recipient on public.manager_emergency_authorization_notifications;
create policy manager_emergency_authorization_notifications_update_recipient
  on public.manager_emergency_authorization_notifications for update to authenticated
  using (
    (recipient_role = 'admin' and public.edmel_is_restaurant_owner_admin(restaurant_id))
    or (recipient_role = 'manager' and recipient_user_id = (select auth.uid())
        and public.edmel_expense_has_access(restaurant_id, branch_id, 'view'))
  )
  with check (
    (recipient_role = 'admin' and public.edmel_is_restaurant_owner_admin(restaurant_id))
    or (recipient_role = 'manager' and recipient_user_id = (select auth.uid())
        and public.edmel_expense_has_access(restaurant_id, branch_id, 'view'))
  );

create or replace function public.edmel_submit_manager_emergency_authorization(
  p_restaurant_id uuid,
  p_branch_id uuid,
  p_description text,
  p_purpose text,
  p_requested_amount numeric,
  p_emergency_reason text
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_manager public.restaurant_users%rowtype;
  v_currency text;
  v_limit numeric(14,2) := 0;
  v_status text;
  v_id uuid;
  v_actor_name text;
begin
  if v_user_id is null then raise exception 'Authentication required.' using errcode='42501'; end if;
  if p_restaurant_id is null or p_branch_id is null
     or char_length(btrim(coalesce(p_description,''))) not between 3 and 500
     or char_length(btrim(coalesce(p_purpose,''))) not between 3 and 1000
     or char_length(btrim(coalesce(p_emergency_reason,''))) not between 3 and 1000
     or p_requested_amount is null or p_requested_amount <= 0
     or p_requested_amount::text in ('NaN','Infinity','-Infinity') then
    raise exception 'Complete the emergency details, purpose, amount and reason with valid values.' using errcode='22023';
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
    join public.staff_branch_access sba
      on sba.branch_id=b.id and sba.restaurant_id=b.restaurant_id
    where b.id=p_branch_id and b.restaurant_id=p_restaurant_id and b.is_active=true
      and sba.restaurant_user_id=v_manager.id and sba.is_active=true
  ) then raise exception 'This branch is not assigned to the Manager.' using errcode='42501'; end if;
  if not public.edmel_expense_has_access(p_restaurant_id,p_branch_id,'create') then
    raise exception 'Expense creation permission is required for this branch.' using errcode='42501';
  end if;

  select r.currency into v_currency from public.restaurants r where r.id=p_restaurant_id;
  if v_currency is null then raise exception 'Restaurant currency could not be verified.'; end if;
  select coalesce(p.emergency_authorization_limit,0) into v_limit
  from public.restaurant_expense_policies p
  where p.restaurant_id=p_restaurant_id and p.branch_id=p_branch_id;
  v_limit:=coalesce(v_limit,0);
  v_status:=case when p_requested_amount>v_limit then 'pending_authorization' else 'authorized_under_limit' end;

  insert into public.manager_emergency_authorization_requests(
    restaurant_id,branch_id,manager_restaurant_user_id,submitted_by_user_id,
    description,purpose,requested_amount,currency_code,emergency_reason,
    authorization_limit,status,approved_amount
  ) values (
    p_restaurant_id,p_branch_id,v_manager.id,v_user_id,btrim(p_description),
    btrim(p_purpose),p_requested_amount,upper(v_currency),btrim(p_emergency_reason),
    v_limit,v_status,
    case when v_status='authorized_under_limit' then p_requested_amount else null end
  ) returning id into v_id;

  v_actor_name:=coalesce(nullif(btrim(v_manager.display_name),''),nullif(btrim(v_manager.full_name),''),'Manager');
  if v_status='pending_authorization' then
    insert into public.manager_emergency_authorization_notifications(
      restaurant_id,branch_id,request_id,recipient_role,notification_type,title,message
    ) values (
      p_restaurant_id,p_branch_id,v_id,'admin','authorization_requested',
      'Emergency authorization requested',
      v_actor_name||' requested emergency authorization for '||btrim(p_description)||'.'
    );
  else
    insert into public.manager_emergency_authorization_notifications(
      restaurant_id,branch_id,request_id,recipient_role,recipient_user_id,notification_type,title,message
    ) values (
      p_restaurant_id,p_branch_id,v_id,'manager',v_user_id,'authorization_decided',
      'Emergency spending within branch limit',
      'Your request was recorded under the branch emergency spending limit. Submit the actual amount and receipt reference after spending.'
    );
  end if;

  insert into public.audit_logs(
    restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
    record_type,record_id,result,details
  ) values (
    p_restaurant_id,v_user_id,v_actor_name,'manager','Emergency Authorization',
    case when v_status='pending_authorization' then 'Requested emergency spending authorization' else 'Recorded emergency spending within branch limit' end,
    'manager_emergency_authorization',v_id::text,'success',
    jsonb_build_object('branch_id',p_branch_id,'requested_amount',p_requested_amount,
      'authorization_limit',v_limit,'status',v_status)
  );

  return jsonb_build_object('success',true,'request_id',v_id,'status',v_status,
    'authorization_limit',v_limit,'requires_admin_approval',v_status='pending_authorization');
end;
$function$;

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

  update public.manager_emergency_authorization_requests
  set status=p_decision,approved_amount=case when p_decision='approved' then requested_amount else null end,
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
    'manager_emergency_authorization',v_req.id::text,p_decision,
    jsonb_build_object('branch_id',v_req.branch_id,'requested_amount',v_req.requested_amount,
      'reason',btrim(p_reason))
  );
  return jsonb_build_object('success',true,'request_id',v_req.id,'status',p_decision);
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
     or char_length(coalesce(p_receipt_reference,''))>500
     or char_length(coalesce(p_notes,''))>2000 then
    raise exception 'Enter a valid actual amount and keep receipt reference and notes within their limits.' using errcode='22023';
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
  set actual_amount=p_actual_amount,actual_receipt_reference=nullif(btrim(p_receipt_reference),''),
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
      'actual_amount',p_actual_amount,'receipt_reference_present',nullif(btrim(p_receipt_reference),'') is not null)
  );
  return jsonb_build_object('success',true,'request_id',v_req.id,'status','spent_pending_review',
    'over_authorized_amount',p_actual_amount>coalesce(v_req.approved_amount,v_req.requested_amount));
end;
$function$;

create or replace function public.edmel_review_manager_emergency_actuals(
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
begin
  if v_user_id is null then raise exception 'Authentication required.' using errcode='42501'; end if;
  if p_decision not in ('reconciled','rejected')
     or char_length(btrim(coalesce(p_reason,''))) not between 3 and 500 then
    raise exception 'Choose a valid final decision and provide a reason between 3 and 500 characters.' using errcode='22023';
  end if;
  select * into v_req from public.manager_emergency_authorization_requests where id=p_request_id for update;
  if not found then raise exception 'Emergency authorization request not found.' using errcode='P0002'; end if;
  if v_req.status<>'spent_pending_review' then raise exception 'Actual spending is not awaiting final review.' using errcode='22023'; end if;
  if not public.edmel_is_restaurant_owner_admin(v_req.restaurant_id) then
    raise exception 'Owner or Admin final review is required.' using errcode='42501';
  end if;
  select ru.* into v_actor from public.restaurant_users ru
  where ru.user_id=v_user_id and ru.restaurant_id=v_req.restaurant_id
    and coalesce(ru.is_active,true)=true
  order by ru.created_at desc limit 1;
  update public.manager_emergency_authorization_requests
  set status=case when p_decision='reconciled' then 'reconciled' else 'reconciliation_rejected' end,
      final_reviewed_by_user_id=v_user_id,final_reviewed_at=now(),
      final_review_reason=btrim(p_reason),updated_at=now()
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
    'manager_emergency_authorization',v_req.id::text,p_decision,
    jsonb_build_object('branch_id',v_req.branch_id,'authorized_amount',v_req.approved_amount,
      'actual_amount',v_req.actual_amount,'reason',btrim(p_reason))
  );
  return jsonb_build_object('success',true,'request_id',v_req.id,'status',
    case when p_decision='reconciled' then 'reconciled' else 'reconciliation_rejected' end);
end;
$function$;

revoke all on function public.edmel_submit_manager_emergency_authorization(uuid,uuid,text,text,numeric,text) from public, anon;
revoke all on function public.edmel_review_manager_emergency_authorization(uuid,text,text) from public, anon;
revoke all on function public.edmel_submit_manager_emergency_actuals(uuid,numeric,text,text) from public, anon;
revoke all on function public.edmel_review_manager_emergency_actuals(uuid,text,text) from public, anon;
grant execute on function public.edmel_submit_manager_emergency_authorization(uuid,uuid,text,text,numeric,text) to authenticated;
grant execute on function public.edmel_review_manager_emergency_authorization(uuid,text,text) to authenticated;
grant execute on function public.edmel_submit_manager_emergency_actuals(uuid,numeric,text,text) to authenticated;
grant execute on function public.edmel_review_manager_emergency_actuals(uuid,text,text) to authenticated;
