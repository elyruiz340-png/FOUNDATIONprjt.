-- Full Action-level Manager staff permissions with legacy compatibility.
-- Managers submit requests; only Owner/Admin can review and apply them.
CREATE OR REPLACE FUNCTION public.edmel_manager_update_staff_branch_permissions(p_actor_user_id uuid, p_restaurant_id uuid, p_branch_id uuid, p_target_restaurant_user_id uuid, p_permissions jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
 v_actor public.restaurant_users%ROWTYPE;
 v_target public.restaurant_users%ROWTYPE;
 v_manager_permissions jsonb;
 v_target_permissions jsonb;
 v_target_access_id uuid;
 v_new_permissions jsonb;
 v_entry record;
 v_actor_name text;
 v_target_name text;
 v_branch_name text;
 v_manager_module text;
 v_action_entry record;
 v_allowed_legacy text[] := ARRAY['orders','tables','stocks','dispatcher','settings','void','staff_management','modules'];
 v_allowed_modules text[] := ARRAY['overview','sales','settings','orders','expenses','staff','audit','branches','health','ai','inventory','tables','dispatcher','payments','menu','discounts','vouchers','tax','service_charge','receipts','printers','transactions'];
 v_allowed_actions text[] := ARRAY['view','create','edit','delete','approve','manage'];
BEGIN
 IF p_actor_user_id IS NULL OR p_restaurant_id IS NULL OR p_branch_id IS NULL OR p_target_restaurant_user_id IS NULL THEN
  RAISE EXCEPTION 'Missing required account or branch context' USING ERRCODE='22023';
 END IF;
 IF p_permissions IS NULL OR jsonb_typeof(p_permissions)<>'object' THEN
  RAISE EXCEPTION 'Invalid staff permissions' USING ERRCODE='22023';
 END IF;
 IF EXISTS(SELECT 1 FROM jsonb_each(p_permissions) e WHERE NOT(e.key=ANY(v_allowed_legacy))) THEN
  RAISE EXCEPTION 'Unsupported staff permission field' USING ERRCODE='22023';
 END IF;
 IF p_permissions ? 'staff_management' AND jsonb_typeof(p_permissions->'staff_management')<>'boolean' THEN
  RAISE EXCEPTION 'Legacy staff_management permission must be boolean' USING ERRCODE='22023';
 END IF;
 IF coalesce((p_permissions->>'staff_management')::boolean,false) THEN
  RAISE EXCEPTION 'Managers cannot grant legacy staff management access' USING ERRCODE='42501';
 END IF;

 SELECT ru.* INTO v_actor FROM public.restaurant_users ru
 WHERE ru.user_id=p_actor_user_id AND ru.restaurant_id=p_restaurant_id AND ru.is_active=true
 ORDER BY CASE lower(coalesce(ru.role,'')) WHEN 'owner' THEN 1 WHEN 'admin' THEN 2 ELSE 3 END LIMIT 1;
 IF v_actor.id IS NULL OR lower(coalesce(v_actor.role,''))<>'staff' OR lower(coalesce(v_actor.position,''))<>'manager' THEN
  RAISE EXCEPTION 'Manager access required' USING ERRCODE='42501';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.restaurant_branches b WHERE b.id=p_branch_id AND b.restaurant_id=p_restaurant_id AND b.is_active=true) THEN
  RAISE EXCEPTION 'Branch not found or inactive' USING ERRCODE='22023';
 END IF;

 SELECT sba.permissions INTO v_manager_permissions FROM public.staff_branch_access sba
 WHERE sba.restaurant_user_id=v_actor.id AND sba.restaurant_id=p_restaurant_id AND sba.branch_id=p_branch_id AND sba.is_active=true FOR SHARE;
 IF v_manager_permissions IS NULL OR NOT public.edmel_permission_json_allows(v_manager_permissions,'staff','manage') THEN
  RAISE EXCEPTION 'Staff management access is not enabled for this branch' USING ERRCODE='42501';
 END IF;
 IF p_target_restaurant_user_id=v_actor.id THEN
  RAISE EXCEPTION 'Managers cannot edit their own staff permissions' USING ERRCODE='42501';
 END IF;

 SELECT ru.* INTO v_target FROM public.restaurant_users ru
 WHERE ru.id=p_target_restaurant_user_id AND ru.restaurant_id=p_restaurant_id FOR UPDATE;
 IF v_target.id IS NULL OR lower(coalesce(v_target.role,''))<>'staff'
    OR lower(coalesce(v_target.position,''))='manager' OR v_target.user_id=p_actor_user_id THEN
  RAISE EXCEPTION 'Only subordinate staff accounts in this restaurant can be edited' USING ERRCODE='42501';
 END IF;

 SELECT sba.id,sba.permissions INTO v_target_access_id,v_target_permissions
 FROM public.staff_branch_access sba
 WHERE sba.restaurant_user_id=v_target.id AND sba.restaurant_id=p_restaurant_id
   AND sba.branch_id=p_branch_id AND sba.is_active=true FOR UPDATE;
 IF v_target_access_id IS NULL THEN
  RAISE EXCEPTION 'Staff account is not assigned to this branch' USING ERRCODE='P0002';
 END IF;
 v_target_permissions:=coalesce(v_target_permissions,'{}'::jsonb);

 IF p_permissions ? 'modules' THEN
  IF jsonb_typeof(p_permissions->'modules')<>'object' THEN
   RAISE EXCEPTION 'Action-level modules must be an object' USING ERRCODE='22023';
  END IF;
  FOR v_entry IN SELECT key,value FROM jsonb_each(p_permissions->'modules') LOOP
   IF NOT(v_entry.key=ANY(v_allowed_modules)) OR jsonb_typeof(v_entry.value)<>'object' THEN
    RAISE EXCEPTION 'Unsupported action-level module' USING ERRCODE='22023';
   END IF;
   FOR v_action_entry IN SELECT key,value FROM jsonb_each(v_entry.value) LOOP
    IF NOT(v_action_entry.key=ANY(v_allowed_actions)) OR jsonb_typeof(v_action_entry.value)<>'boolean' THEN
     RAISE EXCEPTION 'Unsupported or non-boolean module action' USING ERRCODE='22023';
    END IF;
   END LOOP;
  END LOOP;
 ELSE
  IF NOT(p_permissions ?& ARRAY['orders','tables','stocks','dispatcher','settings']) THEN
   RAISE EXCEPTION 'Required legacy permissions are missing' USING ERRCODE='22023';
  END IF;
 END IF;

 IF p_permissions ? 'modules' THEN
  FOR v_entry IN SELECT key,value FROM jsonb_each(p_permissions->'modules') LOOP
   FOR v_action_entry IN SELECT key,value FROM jsonb_each(v_entry.value) LOOP
    IF v_action_entry.value='true'::jsonb THEN
     IF v_entry.key='staff' AND v_action_entry.key='approve'
        AND NOT public.edmel_permission_json_allows(v_target_permissions,'staff','approve') THEN
      RAISE EXCEPTION 'Only Owner/Admin can grant staff approval authority' USING ERRCODE='42501';
     END IF;
     IF NOT public.edmel_permission_json_allows(v_target_permissions,v_entry.key,v_action_entry.key)
        AND NOT public.edmel_permission_json_allows(v_manager_permissions,v_entry.key,v_action_entry.key) THEN
      RAISE EXCEPTION 'You cannot grant permissions beyond your own branch access' USING ERRCODE='42501';
     END IF;
    END IF;
   END LOOP;
  END LOOP;
  v_new_permissions:=v_target_permissions||p_permissions;
 ELSE
  FOR v_entry IN SELECT key,value FROM jsonb_each(p_permissions) WHERE key<>'staff_management' LOOP
   IF jsonb_typeof(v_entry.value)<>'boolean' THEN
    RAISE EXCEPTION 'Legacy permissions must be boolean values' USING ERRCODE='22023';
   END IF;
   v_manager_module:=CASE v_entry.key WHEN 'stocks' THEN 'inventory' ELSE v_entry.key END;
   IF v_entry.value='true'::jsonb
      AND NOT public.edmel_permission_json_allows(v_target_permissions,v_entry.key,'view')
      AND NOT public.edmel_permission_json_allows(v_manager_permissions,v_manager_module,'view') THEN
    RAISE EXCEPTION 'You cannot grant permissions beyond your own branch access' USING ERRCODE='42501';
   END IF;
  END LOOP;
  v_new_permissions:=(v_target_permissions-ARRAY['orders','tables','stocks','dispatcher','settings','void'])||p_permissions;
 END IF;
 UPDATE public.staff_branch_access SET permissions=v_new_permissions,updated_at=now()
 WHERE id=v_target_access_id AND restaurant_user_id=v_target.id AND branch_id=p_branch_id
   AND restaurant_id=p_restaurant_id AND is_active=true;
 IF NOT FOUND THEN
  RAISE EXCEPTION 'Staff branch access could not be updated' USING ERRCODE='P0002';
 END IF;

 v_actor_name:=coalesce(nullif(btrim(v_actor.display_name),''),nullif(btrim(v_actor.full_name),''),nullif(btrim(v_actor.cashier_username),''),'Manager');
 v_target_name:=coalesce(nullif(btrim(v_target.display_name),''),nullif(btrim(v_target.full_name),''),nullif(btrim(v_target.cashier_username),''),'Staff');
 SELECT b.name INTO v_branch_name FROM public.restaurant_branches b WHERE b.id=p_branch_id;
 INSERT INTO public.audit_logs(restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,record_type,record_id,result,details)
 VALUES(p_restaurant_id,p_actor_user_id,v_actor_name,'manager','Staff & Security','Updated staff branch permissions',
 'staff_branch_access',v_target.id::text,'success',
 jsonb_build_object('branch_id',p_branch_id,'branch_name',coalesce(v_branch_name,'Assigned branch'),
 'staff_name',v_target_name,'username',coalesce(v_target.cashier_username,''),'permissions',p_permissions));
 RETURN jsonb_build_object('success',true,'branch_id',p_branch_id,'staff_id',v_target.id,'permissions',v_new_permissions,'audit_logged',true);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.edmel_submit_manager_approval_batch(p_restaurant_id uuid, p_branch_id uuid, p_actions jsonb, p_summary text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_actor_id uuid := auth.uid();
  v_actor public.restaurant_users%rowtype;
  v_access jsonb;
  v_action jsonb;
  v_type text;
  v_target_id uuid;
  v_permissions jsonb;
  v_required boolean;
  v_module_entry record;
  v_permission_entry record;
  v_allowed_modules text[] := ARRAY['overview','sales','settings','orders','expenses','staff','audit','branches','health','ai','inventory','tables','dispatcher','payments','menu','discounts','vouchers','tax','service_charge','receipts','printers','transactions'];
  v_allowed_actions text[] := ARRAY['view','create','edit','delete','approve','manage'];
  v_batch_id uuid;
  v_count integer := 0;
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
  if v_access is null or not public.edmel_permission_json_allows(v_access,'staff','manage') or coalesce((v_access->>'approval_request_access')::boolean,false) is not true then
    raise exception 'Manager staff management access is unavailable' using errcode='42501';
  end if;

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
    if exists(select 1 from jsonb_object_keys(v_action) as keys(key)
      where (v_type='edit_staff_permissions' and key not in ('type','staff_id','permissions'))
         or (v_type='remove_branch_access' and key not in ('type','staff_id'))) then
      raise exception 'Unsupported approval action field' using errcode='22023';
    end if;
    if v_action ?| array['pin','pin_hash','password','password_hash','otp','token','secret','credential'] then
      raise exception 'Credential data is not permitted in approval requests' using errcode='22023';
    end if;
    begin
      v_target_id := (v_action->>'staff_id')::uuid;
    exception when invalid_text_representation then
      raise exception 'Invalid target staff identifier' using errcode='22023';
    end;
    if not exists(select 1 from public.restaurant_users ru
      join public.staff_branch_access sba on sba.restaurant_user_id=ru.id
      where ru.id=v_target_id and ru.restaurant_id=p_restaurant_id and ru.is_active=true
        and lower(ru.role)='staff' and lower(coalesce(ru.position,''))<>'manager'
        and sba.branch_id=p_branch_id and sba.restaurant_id=p_restaurant_id and sba.is_active=true) then
      raise exception 'Target staff account is not active in this branch' using errcode='P0002';
    end if;
    if v_type='edit_staff_permissions' then
      v_permissions := v_action->'permissions';
      if v_permissions is null or jsonb_typeof(v_permissions) <> 'object' then
        raise exception 'Invalid staff permission request' using errcode='22023';
      end if;
      if v_permissions ? 'modules' then
        if (select count(*) from jsonb_object_keys(v_permissions))<>1
           or jsonb_typeof(v_permissions->'modules')<>'object' then
          raise exception 'Invalid action-level staff permission request' using errcode='22023';
        end if;
        for v_module_entry in select key,value from jsonb_each(v_permissions->'modules') loop
          if not(v_module_entry.key=any(v_allowed_modules)) or jsonb_typeof(v_module_entry.value)<>'object' then
            raise exception 'Unsupported action-level permission module' using errcode='22023';
          end if;
          for v_permission_entry in select key,value from jsonb_each(v_module_entry.value) loop
            if not(v_permission_entry.key=any(v_allowed_actions)) or jsonb_typeof(v_permission_entry.value)<>'boolean' then
              raise exception 'Unsupported or non-boolean module action' using errcode='22023';
            end if;
          end loop;
        end loop;
      else
        if exists(select 1 from jsonb_object_keys(v_permissions) as keys(key)
          where key not in ('orders','tables','stocks','dispatcher','settings','void')) then
          raise exception 'Invalid legacy staff permission request' using errcode='22023';
        end if;
        if not (v_permissions ?& array['orders','tables','stocks','dispatcher','settings'])
           or exists(select 1 from jsonb_each(v_permissions) e where jsonb_typeof(e.value)<>'boolean') then
          raise exception 'Staff permissions must contain the required boolean fields' using errcode='22023';
        end if;
      end if;
    end if;
    select p.approval_required into v_required
    from public.manager_approval_policies p
    where p.restaurant_id=p_restaurant_id and p.branch_id=p_branch_id and p.action_type=v_type;
    if coalesce(v_required,true)=false then
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
$function$
;

CREATE OR REPLACE FUNCTION public.edmel_review_manager_approval_batch(p_batch_id uuid, p_decision text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_actor_id uuid := auth.uid();
  v_actor public.restaurant_users%rowtype;
  v_requester public.restaurant_users%rowtype;
  v_batch public.manager_approval_batches%rowtype;
  v_action jsonb;
  v_type text;
  v_target_id uuid;
  v_permissions jsonb;
  v_result jsonb;
  v_count integer := 0;
  v_now timestamptz := now();
  v_requester_access jsonb;
begin
  if v_actor_id is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_decision is null or p_decision not in ('approve','reject') then raise exception 'Decision must be approve or reject' using errcode='22023'; end if;
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
    select * into v_requester from public.restaurant_users
    where id=v_batch.requested_by_staff_id and user_id=v_batch.requested_by_user_id
      and restaurant_id=v_batch.restaurant_id and is_active=true
      and lower(role)='staff' and lower(coalesce(position,''))='manager';
    if v_requester.id is null then raise exception 'Requesting Manager is no longer active' using errcode='42501'; end if;

    select sba.permissions into v_requester_access from public.staff_branch_access sba
    where sba.restaurant_user_id=v_requester.id and sba.restaurant_id=v_batch.restaurant_id
      and sba.branch_id=v_batch.branch_id and sba.is_active=true for share;
    if v_requester_access is null or not public.edmel_permission_json_allows(v_requester_access,'staff','manage') or coalesce((v_requester_access->>'approval_request_access')::boolean,false) is not true then
      raise exception 'Requesting Manager no longer has staff management access' using errcode='42501';
    end if;
    if not exists(select 1 from public.restaurant_branches b
      where b.id=v_batch.branch_id and b.restaurant_id=v_batch.restaurant_id and b.is_active=true) then
      raise exception 'Requested branch is no longer active' using errcode='22023';
    end if;

    for v_action in select value from jsonb_array_elements(v_batch.actions)
    loop
      v_type := v_action->>'type';
      v_target_id := (v_action->>'staff_id')::uuid;
      if not exists(select 1 from public.manager_approval_policies p
        where p.restaurant_id=v_batch.restaurant_id and p.branch_id=v_batch.branch_id
          and p.action_type=v_type and p.approval_required=true)
        and exists(select 1 from public.manager_approval_policies p
          where p.restaurant_id=v_batch.restaurant_id and p.branch_id=v_batch.branch_id
            and p.action_type=v_type and p.approval_required=false) then
        raise exception 'Approval policy changed after this request was submitted' using errcode='42501';
      end if;

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
        if not exists(select 1 from public.restaurant_users ru
          join public.staff_branch_access sba on sba.restaurant_user_id=ru.id
          where ru.id=v_target_id and ru.restaurant_id=v_batch.restaurant_id
            and ru.is_active=true and lower(ru.role)='staff'
            and lower(coalesce(ru.position,''))<>'manager'
            and sba.branch_id=v_batch.branch_id and sba.restaurant_id=v_batch.restaurant_id
            and sba.is_active=true) then
          raise exception 'A requested staff branch access is no longer active' using errcode='P0002';
        end if;
        update public.staff_branch_access set is_active=false,updated_at=v_now
        where restaurant_user_id=v_target_id and restaurant_id=v_batch.restaurant_id
          and branch_id=v_batch.branch_id and is_active=true;
        update public.staff_sessions set logout_at=v_now,last_seen_at=v_now,end_reason='branch_access_removed'
        where restaurant_user_id=v_target_id and branch_id=v_batch.branch_id and logout_at is null;
        insert into public.audit_logs(
          restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
          record_type,record_id,result,details
        ) values (
          v_batch.restaurant_id,v_batch.requested_by_user_id,
          coalesce(nullif(btrim(v_requester.display_name),''),nullif(btrim(v_requester.full_name),''),'Manager'),
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
$function$
;
