-- Expose read-only effective branch settings to staff who can process branch orders.
-- Keep manage/request/approve permissions restricted to the existing Manager workflow.
DO $patch$
DECLARE v_def text; v_old text; v_new text;
BEGIN
  v_def:=pg_get_functiondef('public.edmel_has_branch_setting_permission(uuid,uuid,text,text)'::regprocedure);
  v_old:='  if v_role in (''owner'',''admin'') then return true; end if;';
  v_new:=v_old||chr(10)||'  if v_action=''view'' and public.edmel_has_branch_permission(p_branch_id,''orders'') then return true; end if;';
  v_def:=replace(v_def,v_old,v_new);
  IF position('v_action=''view'' and public.edmel_has_branch_permission(p_branch_id,''orders'')' in v_def)=0 THEN
    RAISE EXCEPTION 'Could not safely extend read-only branch settings access';
  END IF;
  EXECUTE v_def;
END;
$patch$;

-- Preserve stable rule/method IDs in Independent snapshots so cashier discount
-- selection and voucher lookup continue to reference the correct item.
DO $patch$
DECLARE v_def text; v_old text; v_new text;
BEGIN
  v_def:=pg_get_functiondef('private.edmel_strip_branch_snapshot_metadata(jsonb)'::regprocedure);
  v_old:='e.key NOT IN (''id'',''created_at'',''updated_at'',''created_by'')';
  v_new:='e.key NOT IN (''created_at'',''updated_at'',''created_by'')';
  v_def:=replace(v_def,v_old,v_new);
  IF position(v_new in v_def)=0 THEN RAISE EXCEPTION 'Could not preserve stable setting item identifiers'; END IF;
  EXECUTE v_def;
END;
$patch$;

DO $patch$
DECLARE v_def text;
BEGIN
  v_def:=pg_get_functiondef('private.edmel_validate_branch_setting_payload(text,jsonb)'::regprocedure);
  v_def:=replace(v_def,'v_allowed:=array[''rule_name'',''tax_type''','v_allowed:=array[''id'',''rule_name'',''tax_type''');
  v_def:=replace(v_def,'v_allowed:=array[''rule_name'',''display_label''','v_allowed:=array[''id'',''rule_name'',''display_label''');
  v_def:=replace(v_def,'v_allowed:=array[''rule_name'',''discount_category''','v_allowed:=array[''id'',''rule_name'',''discount_category''');
  v_def:=replace(v_def,'v_allowed:=array[''code'',''description''','v_allowed:=array[''id'',''code'',''description''');
  v_def:=replace(v_def,'v_allowed:=array[''method_key''','v_allowed:=array[''id'',''method_key''');
  IF position('v_allowed:=array[''id'',''rule_name'',''tax_type''' in v_def)=0
     OR position('v_allowed:=array[''id'',''rule_name'',''display_label''' in v_def)=0
     OR position('v_allowed:=array[''id'',''rule_name'',''discount_category''' in v_def)=0
     OR position('v_allowed:=array[''id'',''code'',''description''' in v_def)=0
     OR position('v_allowed:=array[''id'',''method_key''' in v_def)=0 THEN
    RAISE EXCEPTION 'Could not safely extend branch setting payload validation for stable identifiers';
  END IF;
  v_def:=replace(v_def,
    'if jsonb_typeof(v_item)<>''object'' then return false; end if;',
    'if jsonb_typeof(v_item)<>''object'' then return false; end if;'||chr(10)||
    '        if v_item ? ''id'' and (jsonb_typeof(v_item->''id'')<>''string'' or length(v_item->>''id'')>100) then return false; end if;');
  EXECUTE v_def;
END;
$patch$;
