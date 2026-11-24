-- Phase 4: keep restaurant branch authority on the single Owner account.
-- The Admin Dashboard is the Owner's dashboard; this does not create an Admin account/role.
-- Managers retain only their existing policy-controlled branch request/direct-create paths.
DO $$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  -- Branch creation policy: Owner may view/set; eligible Managers may view their own policy context.
  v_def := pg_get_functiondef('public.edmel_get_branch_creation_policy(uuid)'::regprocedure);
  v_old := 'lower(ru.role) IN (''owner'', ''admin'')';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Expected Owner/Admin check not found in edmel_get_branch_creation_policy'; END IF;
  v_def := replace(v_def,v_old,'lower(ru.role) = ''owner''');
  EXECUTE v_def;

  -- Branch request list: Owner sees all; eligible Manager sees their own requests.
  v_def := pg_get_functiondef('public.edmel_list_branch_creation_requests(uuid,text)'::regprocedure);
  v_old := 'bool_or(lower(ru.role) IN (''owner'',''admin''))';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Expected Owner/Admin check not found in edmel_list_branch_creation_requests'; END IF;
  v_def := replace(v_def,v_old,'bool_or(lower(ru.role) = ''owner'')');
  EXECUTE v_def;

  -- Only the Owner account can change the Manager branch-creation policy.
  v_def := pg_get_functiondef('public.edmel_set_branch_creation_policy(uuid,text)'::regprocedure);
  v_old := 'lower(ru.role) IN (''owner'', ''admin'')';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Expected Owner/Admin check not found in edmel_set_branch_creation_policy'; END IF;
  v_def := replace(v_def,v_old,'lower(ru.role) = ''owner''');
  v_def := replace(v_def,'''Owner/Admin''','''Owner''');
  v_def := replace(v_def,'Active Owner or Admin access is required','Active Owner access is required');
  EXECUTE v_def;

  -- Only the Owner account can approve or reject a Manager branch request.
  v_def := pg_get_functiondef('public.edmel_review_branch_creation_request(uuid,text,text)'::regprocedure);
  v_old := 'lower(ru.role) IN (''owner'',''admin'')';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Expected Owner/Admin check not found in edmel_review_branch_creation_request'; END IF;
  v_def := replace(v_def,v_old,'lower(ru.role) = ''owner''');
  v_def := replace(v_def,'''Owner/Admin''','''Owner''');
  v_def := replace(v_def,'Owner/Admin access required','Owner access required');
  EXECUTE v_def;

  -- Direct branch creation: Owner or policy-authorized Manager; no separate Admin role.
  v_def := pg_get_functiondef('public.edmel_create_restaurant_branch(text,text,text,text,text)'::regprocedure);
  v_old := 'lower(ru.role) IN (''owner'',''admin'',''staff'')';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Expected role check not found in edmel_create_restaurant_branch'; END IF;
  v_def := replace(v_def,v_old,'lower(ru.role) IN (''owner'',''staff'')');
  v_def := replace(v_def,'ORDER BY CASE lower(ru.role) WHEN ''owner'' THEN 1 WHEN ''admin'' THEN 2 ELSE 3 END','ORDER BY CASE lower(ru.role) WHEN ''owner'' THEN 1 ELSE 2 END');
  v_def := replace(v_def,'''Owner/Admin''','''Owner''');
  v_def := replace(v_def,'Owner/Admin policy','Owner policy');
  EXECUTE v_def;

  -- Configured create wrapper attributes Owner or Manager only.
  v_def := pg_get_functiondef('public.edmel_create_restaurant_branch_configured_with_hours(text,text,text,text,text,jsonb,jsonb,text)'::regprocedure);
  v_old := 'lower(ru.role) IN (''owner'',''admin'')';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Expected Owner/Admin check not found in configured branch create wrapper'; END IF;
  v_def := replace(v_def,v_old,'lower(ru.role) = ''owner''');
  v_def := replace(v_def,'ORDER BY CASE lower(ru.role) WHEN ''owner'' THEN 1 ELSE 2 END','ORDER BY CASE lower(ru.role) WHEN ''owner'' THEN 1 ELSE 2 END');
  v_def := replace(v_def,'''Owner/Admin''','''Owner''');
  EXECUTE v_def;

  -- Branch-level authorization helpers: Owner remains the only unrestricted restaurant account.
  v_def := pg_get_functiondef('public.edmel_has_branch_action_permission(uuid,text,text)'::regprocedure);
  v_old := 'IF v_role IN (''owner'',''admin'') THEN';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Expected role check not found in edmel_has_branch_action_permission'; END IF;
  v_def := replace(v_def,v_old,'IF v_role = ''owner'' THEN');
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.edmel_has_branch_permission(uuid,text)'::regprocedure);
  v_old := 'lower(ru.role) in (''owner'',''admin'')';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Expected role check not found in edmel_has_branch_permission'; END IF;
  v_def := replace(v_def,v_old,'lower(ru.role) = ''owner''');
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.edmel_has_branch_setting_permission(uuid,uuid,text,text)'::regprocedure);
  v_old := 'if v_role in (''owner'',''admin'') then return true; end if;';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Expected role check not found in edmel_has_branch_setting_permission'; END IF;
  v_def := replace(v_def,v_old,'if v_role = ''owner'' then return true; end if;');
  EXECUTE v_def;
END;
$$;