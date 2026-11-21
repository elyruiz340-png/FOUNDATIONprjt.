
create table if not exists public.manager_approval_batches (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete restrict,
  requested_by_user_id uuid not null,
  requested_by_staff_id uuid not null references public.restaurant_users(id) on delete restrict,
  status text not null default 'pending' check (status in ('pending','approved','rejected','failed')),
  summary text not null check (char_length(summary) between 3 and 240),
  actions jsonb not null check (jsonb_typeof(actions)='array' and jsonb_array_length(actions) between 1 and 50),
  decision_by_user_id uuid,
  decision_at timestamptz,
  decision_reason text,
  applied_at timestamptz,
  failure_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint manager_approval_batches_branch_restaurant_fk
    foreign key (branch_id, restaurant_id)
    references public.restaurant_branches(id, restaurant_id)
);
create index if not exists manager_approval_batches_restaurant_status_created_idx
  on public.manager_approval_batches (restaurant_id, status, created_at desc);
create index if not exists manager_approval_batches_requester_created_idx
  on public.manager_approval_batches (requested_by_user_id, created_at desc);

create table if not exists public.manager_approval_notifications (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  batch_id uuid not null references public.manager_approval_batches(id) on delete cascade,
  recipient_role text not null default 'admin' check (recipient_role in ('admin','manager')),
  recipient_user_id uuid,
  notification_type text not null check (notification_type in ('approval_requested','approval_decided')),
  title text not null,
  message text not null,
  is_read boolean not null default false,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists manager_approval_notifications_inbox_idx
  on public.manager_approval_notifications (restaurant_id, recipient_role, is_read, created_at desc);

create table if not exists public.manager_approval_policies (
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  action_type text not null check (action_type in ('edit_staff_permissions','remove_branch_access')),
  approval_required boolean not null default true,
  updated_by_user_id uuid,
  updated_at timestamptz not null default now(),
  primary key (restaurant_id, branch_id, action_type),
  foreign key (branch_id, restaurant_id)
    references public.restaurant_branches(id, restaurant_id)
);

alter table public.manager_approval_batches enable row level security;
alter table public.manager_approval_notifications enable row level security;
alter table public.manager_approval_policies enable row level security;

revoke all on public.manager_approval_batches from anon, authenticated;
revoke all on public.manager_approval_notifications from anon, authenticated;
revoke all on public.manager_approval_policies from anon, authenticated;
grant all on public.manager_approval_batches to service_role;
grant all on public.manager_approval_notifications to service_role;
grant all on public.manager_approval_policies to service_role;

create or replace function public.edmel_submit_manager_approval_batch(
  p_restaurant_id uuid,
  p_branch_id uuid,
  p_actions jsonb,
  p_summary text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor_id uuid := auth.uid();
  v_actor public.restaurant_users%rowtype;
  v_access jsonb;
  v_action jsonb;
  v_type text;
  v_batch_id uuid;
  v_count integer := 0;
  v_required boolean;
begin
  if v_actor_id is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_restaurant_id is null or p_branch_id is null
     or p_actions is null or jsonb_typeof(p_actions) <> 'array'
     or jsonb_array_length(p_actions) not between 1 and 50
     or p_summary is null or char_length(btrim(p_summary)) not between 3 and 240 then
    raise exception 'Invalid approval batch' using errcode='22023';
  end if;

  select ru.* into v_actor
  from public.restaurant_users ru
  where ru.user_id=v_actor_id and ru.restaurant_id=p_restaurant_id
    and ru.is_active=true and lower(ru.role)='staff'
    and lower(coalesce(ru.position,''))='manager'
  limit 1;
  if v_actor.id is null then raise exception 'Active Manager access required' using errcode='42501'; end if;

  select sba.permissions into v_access
  from public.staff_branch_access sba
  where sba.restaurant_user_id=v_actor.id and sba.restaurant_id=p_restaurant_id
    and sba.branch_id=p_branch_id and sba.is_active=true
  for share;
  if v_access is null then raise exception 'Manager branch access is unavailable' using errcode='42501'; end if;

  if not exists(select 1 from public.restaurant_branches b
    where b.id=p_branch_id and b.restaurant_id=p_restaurant_id and b.is_active=true) then
    raise exception 'Branch not found or inactive' using errcode='22023';
  end if;

  for v_action in select value from jsonb_array_elements(p_actions)
  loop
    if jsonb_typeof(v_action) <> 'object' then raise exception 'Invalid action item' using errcode='22023'; end if;
    v_type := v_action->>'type';
    if v_type not in ('edit_staff_permissions','remove_branch_access') then
      raise exception 'Unsupported approval action type' using errcode='22023';
    end if;
    if v_action ?| array['pin','pin_hash','password','password_hash','otp','token','secret','credential'] then
      raise exception 'Credential data is not permitted in approval requests' using errcode='22023';
    end if;
    if v_type='edit_staff_permissions' then
      if not public.edmel_permission_json_allows(v_access,'staff','manage')
         or jsonb_typeof(v_action->'permissions') <> 'object'
         or (v_action->>'staff_id') is null then
        raise exception 'Invalid staff permission request' using errcode='42501';
      end if;
      if exists(select 1 from jsonb_object_keys(v_action->'permissions') k
        where k not in ('orders','tables','stocks','dispatcher','settings','void')) then
        raise exception 'Unsupported staff permission field' using errcode='22023';
      end if;
      if not (v_action->'permissions' ?& array['orders','tables','stocks','dispatcher','settings']) then
        raise exception 'Required staff permission fields are missing' using errcode='22023';
      end if;
    else
      if not coalesce((v_access->>'staff_management')::boolean,false)
         or (v_action->>'staff_id') is null then
        raise exception 'Invalid branch access removal request' using errcode='42501';
      end if;
    end if;
    select coalesce(p.approval_required,true) into v_required
    from public.manager_approval_policies p
    where p.restaurant_id=p_restaurant_id and p.branch_id=p_branch_id and p.action_type=v_type;
    v_required := coalesce(v_required,true);
    if not v_required then
      raise exception 'This action is configured for direct execution and must use its authorized workflow' using errcode='22023';
    end if;
    v_count := v_count + 1;
  end loop;

  insert into public.manager_approval_batches(
    restaurant_id,branch_id,requested_by_user_id,requested_by_staff_id,summary,actions
  ) values (
    p_restaurant_id,p_branch_id,v_actor_id,v_actor.id,btrim(p_summary),p_actions
  ) returning id into v_batch_id;

  insert into public.manager_approval_notifications(
    restaurant_id,batch_id,recipient_role,notification_type,title,message
  ) values (
    p_restaurant_id,v_batch_id,'admin','approval_requested',
    'Manager approval requested',
    coalesce(nullif(btrim(v_actor.display_name),''),nullif(btrim(v_actor.full_name),''),'A Manager')
      || ' submitted ' || v_count::text || ' action(s) for review.'
  );

  insert into public.audit_logs(
    restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
    record_type,record_id,result,details
  ) values (
    p_restaurant_id,v_actor_id,
    coalesce(nullif(btrim(v_actor.display_name),''),nullif(btrim(v_actor.full_name),''),'Manager'),
    'manager','Approvals','Submitted approval batch',
    'manager_approval_batch',v_batch_id::text,'pending',
    jsonb_build_object('branch_id',p_branch_id,'action_count',v_count,'summary',btrim(p_summary))
  );

  return jsonb_build_object('success',true,'batch_id',v_batch_id,'action_count',v_count,'status','pending');
end;
$function$;

create or replace function public.edmel_review_manager_approval_batch(
  p_batch_id uuid,
  p_decision text,
  p_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor_id uuid := auth.uid();
  v_actor public.restaurant_users%rowtype;
  v_batch public.manager_approval_batches%rowtype;
  v_action jsonb;
  v_type text;
  v_target_id uuid;
  v_permissions jsonb;
  v_result jsonb;
  v_count integer := 0;
  v_target public.restaurant_users%rowtype;
  v_branch public.restaurant_branches%rowtype;
  v_now timestamptz := now();
begin
  if v_actor_id is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_decision not in ('approve','reject') then raise exception 'Decision must be approve or reject' using errcode='22023'; end if;
  if p_reason is not null and char_length(p_reason)>1000 then raise exception 'Decision note is too long' using errcode='22023'; end if;

  select * into v_batch from public.manager_approval_batches where id=p_batch_id for update;
  if v_batch.id is null then raise exception 'Approval batch not found' using errcode='P0002'; end if;
  if v_batch.status <> 'pending' then raise exception 'Approval batch has already been reviewed' using errcode='22023'; end if;
  if v_batch.requested_by_user_id = v_actor_id then raise exception 'You cannot approve your own request' using errcode='42501'; end if;

  select ru.* into v_actor from public.restaurant_users ru
  where ru.user_id=v_actor_id and ru.restaurant_id=v_batch.restaurant_id
    and ru.is_active=true and lower(ru.role) in ('owner','admin')
  order by case lower(ru.role) when 'owner' then 1 else 2 end limit 1;
  if v_actor.id is null then raise exception 'Owner or Admin access required' using errcode='42501'; end if;

  if p_decision='reject' then
    update public.manager_approval_batches set status='rejected',
      decision_by_user_id=v_actor_id,decision_at=v_now,
      decision_reason=nullif(btrim(p_reason),''),updated_at=v_now
    where id=p_batch_id and status='pending';
  else
    select * into v_branch from public.restaurant_branches
    where id=v_batch.branch_id and restaurant_id=v_batch.restaurant_id and is_active=true;
    if v_branch.id is null then raise exception 'Requested branch is no longer active' using errcode='22023'; end if;

    for v_action in select value from jsonb_array_elements(v_batch.actions)
    loop
      v_type := v_action->>'type';
      begin
        v_target_id := (v_action->>'staff_id')::uuid;
      exception when invalid_text_representation then
        raise exception 'Invalid target staff identifier' using errcode='22023';
      end;

      select * into v_target from public.restaurant_users
      where id=v_target_id and restaurant_id=v_batch.restaurant_id
        and lower(role)='staff' and lower(coalesce(position,''))<>'manager'
        and is_active=true for update;
      if v_target.id is null then raise exception 'A requested staff account is no longer eligible' using errcode='P0002'; end if;

      if v_type='edit_staff_permissions' then
        v_permissions := v_action->'permissions';
        v_result := public.edmel_manager_update_staff_branch_permissions(
          v_batch.requested_by_user_id,v_batch.restaurant_id,v_batch.branch_id,
          v_target_id,v_permissions
        );
        if coalesce((v_result->>'success')::boolean,false) is not true then
          raise exception 'Staff permission change was not confirmed' using errcode='P0001';
        end if;
      elsif v_type='remove_branch_access' then
        update public.staff_branch_access
        set is_active=false,updated_at=v_now
        where restaurant_user_id=v_target_id and restaurant_id=v_batch.restaurant_id
          and branch_id=v_batch.branch_id and is_active=true;
        if not found then raise exception 'Staff branch access is no longer active' using errcode='P0002'; end if;
        update public.staff_sessions
        set logout_at=v_now,last_seen_at=v_now,end_reason='branch_access_removed'
        where restaurant_user_id=v_target_id and branch_id=v_batch.branch_id and logout_at is null;
        insert into public.audit_logs(
          restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
          record_type,record_id,result,details
        ) values (
          v_batch.restaurant_id,v_batch.requested_by_user_id,
          coalesce(nullif(btrim((select display_name from public.restaurant_users where id=v_batch.requested_by_staff_id)),''),'Manager'),
          'manager','Staff & Security','Removed staff branch access',
          'staff_branch_access',v_target_id::text,'success',
          jsonb_build_object('branch_id',v_batch.branch_id,'approved_by',v_actor_id,'approval_batch_id',p_batch_id)
        );
      else
        raise exception 'Unsupported approval action type' using errcode='22023';
      end if;
      v_count := v_count + 1;
    end loop;

    update public.manager_approval_batches set status='approved',
      decision_by_user_id=v_actor_id,decision_at=v_now,
      decision_reason=nullif(btrim(p_reason),''),applied_at=v_now,updated_at=v_now
    where id=p_batch_id and status='pending';
  end if;

  insert into public.manager_approval_notifications(
    restaurant_id,batch_id,recipient_role,recipient_user_id,notification_type,title,message
  ) values (
    v_batch.restaurant_id,p_batch_id,'manager',v_batch.requested_by_user_id,
    'approval_decided',
    case when p_decision='approve' then 'Approval batch approved' else 'Approval batch rejected' end,
    'Your request "'||v_batch.summary||'" was '||case when p_decision='approve' then 'approved.' else 'rejected.' end
  );

  insert into public.audit_logs(
    restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
    record_type,record_id,result,details
  ) values (
    v_batch.restaurant_id,v_actor_id,
    coalesce(nullif(btrim(v_actor.display_name),''),nullif(btrim(v_actor.full_name),''),'Owner/Admin'),
    lower(v_actor.role),'Approvals',
    case when p_decision='approve' then 'Approved manager approval batch' else 'Rejected manager approval batch' end,
    'manager_approval_batch',p_batch_id::text,p_decision,
    jsonb_build_object('requester_user_id',v_batch.requested_by_user_id,'action_count',
      jsonb_array_length(v_batch.actions),'reason',nullif(btrim(p_reason),''),'applied_action_count',v_count)
  );
  return jsonb_build_object('success',true,'batch_id',p_batch_id,'status',
    case when p_decision='approve' then 'approved' else 'rejected' end,'applied_action_count',v_count);
end;
$function$;

revoke all on function public.edmel_submit_manager_approval_batch(uuid,uuid,jsonb,text) from public, anon;
revoke all on function public.edmel_review_manager_approval_batch(uuid,text,text) from public, anon;
grant execute on function public.edmel_submit_manager_approval_batch(uuid,uuid,jsonb,text) to authenticated;
grant execute on function public.edmel_review_manager_approval_batch(uuid,text,text) to authenticated;
