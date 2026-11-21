do $$
declare v text;
begin
  select pg_get_functiondef('public.edmel_submit_manager_approval_batch(uuid,uuid,jsonb,text)'::regprocedure) into v;
  if position('v_access is null or not public.edmel_permission_json_allows(v_access,''staff'',''manage'')' in v)=0 then
    raise exception 'Submit function permission guard not found; migration aborted';
  end if;
  v := replace(v,
    'v_access is null or not public.edmel_permission_json_allows(v_access,''staff'',''manage'')',
    'v_access is null or not public.edmel_permission_json_allows(v_access,''staff'',''manage'') or coalesce((v_access->>''approval_request_access'')::boolean,false) is not true');
  execute v;

  select pg_get_functiondef('public.edmel_review_manager_approval_batch(uuid,text,text)'::regprocedure) into v;
  if position('v_requester_access is null or not public.edmel_permission_json_allows(v_requester_access,''staff'',''manage'')' in v)=0 then
    raise exception 'Review function permission guard not found; migration aborted';
  end if;
  v := replace(v,
    'v_requester_access is null or not public.edmel_permission_json_allows(v_requester_access,''staff'',''manage'')',
    'v_requester_access is null or not public.edmel_permission_json_allows(v_requester_access,''staff'',''manage'') or coalesce((v_requester_access->>''approval_request_access'')::boolean,false) is not true');
  execute v;

  select pg_get_functiondef('public.edmel_admin_save_manager_branch_permissions(uuid,uuid,uuid,jsonb)'::regprocedure) into v;
  if position('''modules'',''staff_management'',''orders''' in v)=0 then
    raise exception 'Admin permission whitelist not found; migration aborted';
  end if;
  v := replace(v,
    '''modules'',''staff_management'',''orders''',
    '''modules'',''staff_management'',''approval_request_access'',''orders''');
  if position('v_permissions ? ''staff_management''' in v)=0 then
    raise exception 'Admin permission boolean validation anchor not found; migration aborted';
  end if;
  v := replace(v,
    'IF v_permissions ? ''staff_management''\n       AND jsonb_typeof(v_permissions->''staff_management'') <> ''boolean'' THEN\n      RAISE EXCEPTION ''Staff management authority must be boolean'' USING ERRCODE = ''22023'';\n    END IF;',
    'IF v_permissions ? ''staff_management''\n       AND jsonb_typeof(v_permissions->''staff_management'') <> ''boolean'' THEN\n      RAISE EXCEPTION ''Staff management authority must be boolean'' USING ERRCODE = ''22023'';\n    END IF;\n\n    IF v_permissions ? ''approval_request_access''\n       AND jsonb_typeof(v_permissions->''approval_request_access'') <> ''boolean'' THEN\n      RAISE EXCEPTION ''Approval request access must be boolean'' USING ERRCODE = ''22023'';\n    END IF;');
  execute v;
end $$;