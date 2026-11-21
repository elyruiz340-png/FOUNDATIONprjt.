do $$
declare v text; old_text text; new_text text;
begin
  select pg_get_functiondef('public.edmel_admin_save_manager_branch_permissions(uuid,uuid,uuid,jsonb)'::regprocedure) into v;
  old_text := 'IF v_permissions ? ''staff_management'''||chr(10)||
    '       AND jsonb_typeof(v_permissions->''staff_management'') <> ''boolean'' THEN'||chr(10)||
    '      RAISE EXCEPTION ''Staff management authority must be boolean'' USING ERRCODE = ''22023'';'||chr(10)||
    '    END IF;';
  new_text := old_text||chr(10)||chr(10)||
    '    IF v_permissions ? ''approval_request_access'''||chr(10)||
    '       AND jsonb_typeof(v_permissions->''approval_request_access'') <> ''boolean'' THEN'||chr(10)||
    '      RAISE EXCEPTION ''Approval request access must be boolean'' USING ERRCODE = ''22023'';'||chr(10)||
    '    END IF;';
  if position(old_text in v)=0 then raise exception 'Boolean validation insertion anchor not found'; end if;
  v:=replace(v,old_text,new_text);
  execute v;
end $$;