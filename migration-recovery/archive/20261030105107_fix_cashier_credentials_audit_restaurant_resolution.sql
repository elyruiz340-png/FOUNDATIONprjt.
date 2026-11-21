DO $migration$
DECLARE
  v_def text;
  v_old text := $old$  v_restaurant_id := nullif(v_row->>'restaurant_id','')::uuid;
$old$;
  v_new text := $new$  v_restaurant_id := nullif(v_row->>'restaurant_id','')::uuid;
  IF v_restaurant_id IS NULL AND TG_TABLE_NAME = 'cashier_credentials' THEN
    SELECT ru.restaurant_id INTO v_restaurant_id
    FROM public.restaurant_users ru
    WHERE ru.id = coalesce(v_new_row->>'restaurant_user_id',v_old_row->>'restaurant_user_id')::uuid;
  END IF;
$new$;
BEGIN
  SELECT pg_get_functiondef('public.write_audit_log_for_row()'::regprocedure) INTO v_def;
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Expected audit trigger function section was not found; migration aborted';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;
END
$migration$;