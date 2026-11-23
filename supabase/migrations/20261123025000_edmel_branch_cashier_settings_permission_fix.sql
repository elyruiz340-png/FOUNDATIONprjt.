-- Correct the read-only branch settings permission check to use the declared p_action argument.
DO $patch$
DECLARE v_def text;
BEGIN
  v_def:=pg_get_functiondef('public.edmel_has_branch_setting_permission(uuid,uuid,text,text)'::regprocedure);
  v_def:=replace(v_def,
    'if v_action=''view'' and public.edmel_has_branch_permission(p_branch_id,''orders'') then return true; end if;',
    'if p_action=''view'' and public.edmel_has_branch_permission(p_branch_id,''orders'') then return true; end if;');
  IF position('if p_action=''view'' and public.edmel_has_branch_permission(p_branch_id,''orders'')' in v_def)=0 THEN
    RAISE EXCEPTION 'Could not correct branch settings view permission check';
  END IF;
  EXECUTE v_def;
END;
$patch$;
