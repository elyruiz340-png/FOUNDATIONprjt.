
CREATE OR REPLACE FUNCTION public.write_audit_log_for_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_row jsonb;
  v_old_row jsonb := '{}'::jsonb;
  v_new_row jsonb := '{}'::jsonb;
  v_restaurant_id uuid;
  v_actor uuid := auth.uid();
  v_actor_name text := 'System / customer';
  v_actor_role text := 'system';
  v_category text;
  v_action text;
  v_record_id text;
  v_before jsonb := '{}'::jsonb;
  v_after jsonb := '{}'::jsonb;
  v_details jsonb;
BEGIN
  IF TG_OP <> 'INSERT' THEN v_old_row := to_jsonb(OLD); END IF;
  IF TG_OP <> 'DELETE' THEN v_new_row := to_jsonb(NEW); END IF;
  v_row := CASE WHEN TG_OP = 'DELETE' THEN v_old_row ELSE v_new_row END;

  v_restaurant_id := nullif(v_row->>'restaurant_id','')::uuid;
  IF v_restaurant_id IS NULL AND TG_TABLE_NAME = 'PRODUCT_STOCK' THEN
    v_restaurant_id := '5e562ca7-38aa-4894-8265-ddca2f4e61b6'::uuid;
  END IF;
  IF v_restaurant_id IS NULL AND TG_TABLE_NAME = 'restaurant_users' THEN
    v_restaurant_id := nullif(coalesce(v_new_row->>'restaurant_id',v_old_row->>'restaurant_id'),'')::uuid;
  END IF;
  IF v_restaurant_id IS NULL THEN RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END; END IF;

  v_record_id := coalesce(v_row->>'id',v_row->>'product_id');

  IF TG_TABLE_NAME = 'PRODUCT_STOCK' THEN
    v_category := 'Inventory';
    v_before := CASE WHEN TG_OP='INSERT' THEN '{}'::jsonb ELSE jsonb_build_object(
      'product_name',v_old_row->'product_name','stock_total',v_old_row->'stock_total',
      'stock_remaining',v_old_row->'stock_remaining','is_available',v_old_row->'is_available',
      'is_archived',v_old_row->'is_archived') END;
    v_after := CASE WHEN TG_OP='DELETE' THEN '{}'::jsonb ELSE jsonb_build_object(
      'product_name',v_new_row->'product_name','stock_total',v_new_row->'stock_total',
      'stock_remaining',v_new_row->'stock_remaining','is_available',v_new_row->'is_available',
      'is_archived',v_new_row->'is_archived') END;
    v_action := CASE WHEN TG_OP='UPDATE' AND v_old_row->>'stock_remaining' IS DISTINCT FROM v_new_row->>'stock_remaining'
      THEN 'Stock quantity changed'
      WHEN TG_OP='UPDATE' AND v_old_row->>'is_archived' IS DISTINCT FROM v_new_row->>'is_archived'
      THEN CASE WHEN v_new_row->>'is_archived'='true' THEN 'Stock item archived' ELSE 'Stock item restored' END
      WHEN TG_OP='UPDATE' AND v_old_row->>'is_available' IS DISTINCT FROM v_new_row->>'is_available'
      THEN 'Stock availability changed'
      ELSE CASE TG_OP WHEN 'INSERT' THEN 'Stock item created' WHEN 'UPDATE' THEN 'Stock item updated' ELSE 'Stock item deleted' END END;

  ELSIF TG_TABLE_NAME = 'orders' THEN
    v_category := 'Orders';
    v_before := CASE WHEN TG_OP='INSERT' THEN '{}'::jsonb ELSE jsonb_build_object(
      'order_number',v_old_row->'order_number','order_status',v_old_row->'order_status',
      'status',v_old_row->'status','payment_status',v_old_row->'payment_status',
      'payment_method',v_old_row->'payment_method','total',v_old_row->'total') END;
    v_after := CASE WHEN TG_OP='DELETE' THEN '{}'::jsonb ELSE jsonb_build_object(
      'order_number',v_new_row->'order_number','order_status',v_new_row->'order_status',
      'status',v_new_row->'status','payment_status',v_new_row->'payment_status',
      'payment_method',v_new_row->'payment_method','total',v_new_row->'total') END;
    v_action := CASE
      WHEN TG_OP='UPDATE' AND v_old_row->>'order_status' IS DISTINCT FROM v_new_row->>'order_status' THEN 'Order status changed'
      WHEN TG_OP='UPDATE' AND v_old_row->>'status' IS DISTINCT FROM v_new_row->>'status' THEN 'Order status changed'
      WHEN TG_OP='UPDATE' AND v_old_row->>'payment_status' IS DISTINCT FROM v_new_row->>'payment_status' THEN 'Payment status changed'
      ELSE CASE TG_OP WHEN 'INSERT' THEN 'Order created' WHEN 'UPDATE' THEN 'Order updated' ELSE 'Order deleted' END END;

  ELSIF TG_TABLE_NAME = 'menu_items' THEN
    v_category := 'Menu';
    v_before := CASE WHEN TG_OP='INSERT' THEN '{}'::jsonb ELSE jsonb_build_object(
      'name',v_old_row->'name','price',v_old_row->'price','is_available',v_old_row->'is_available','category_id',v_old_row->'category_id') END;
    v_after := CASE WHEN TG_OP='DELETE' THEN '{}'::jsonb ELSE jsonb_build_object(
      'name',v_new_row->'name','price',v_new_row->'price','is_available',v_new_row->'is_available','category_id',v_new_row->'category_id') END;
    v_action := CASE WHEN TG_OP='UPDATE' AND v_old_row->>'price' IS DISTINCT FROM v_new_row->>'price' THEN 'Menu price changed'
      ELSE CASE TG_OP WHEN 'INSERT' THEN 'Menu item created' WHEN 'UPDATE' THEN 'Menu item updated' ELSE 'Menu item deleted' END END;

  ELSIF TG_TABLE_NAME = 'menu_categories' THEN
    v_category := 'Menu';
    v_before := CASE WHEN TG_OP='INSERT' THEN '{}'::jsonb ELSE jsonb_build_object(
      'name',v_old_row->'name','is_active',v_old_row->'is_active','sort_order',v_old_row->'sort_order') END;
    v_after := CASE WHEN TG_OP='DELETE' THEN '{}'::jsonb ELSE jsonb_build_object(
      'name',v_new_row->'name','is_active',v_new_row->'is_active','sort_order',v_new_row->'sort_order') END;
    v_action := CASE TG_OP WHEN 'INSERT' THEN 'Menu category created' WHEN 'UPDATE' THEN 'Menu category updated' ELSE 'Menu category deleted' END;

  ELSIF TG_TABLE_NAME = 'restaurant_users' THEN
    v_category := 'Staff & Security';
    v_before := CASE WHEN TG_OP='INSERT' THEN '{}'::jsonb ELSE jsonb_build_object(
      'display_name',v_old_row->'display_name','full_name',v_old_row->'full_name',
      'cashier_username',v_old_row->'cashier_username','role',v_old_row->'role',
      'position',v_old_row->'position','permissions',v_old_row->'permissions','is_active',v_old_row->'is_active') END;
    v_after := CASE WHEN TG_OP='DELETE' THEN '{}'::jsonb ELSE jsonb_build_object(
      'display_name',v_new_row->'display_name','full_name',v_new_row->'full_name',
      'cashier_username',v_new_row->'cashier_username','role',v_new_row->'role',
      'position',v_new_row->'position','permissions',v_new_row->'permissions','is_active',v_new_row->'is_active') END;
    v_action := CASE WHEN TG_OP='UPDATE' AND v_old_row->>'is_active' IS DISTINCT FROM v_new_row->>'is_active'
      THEN CASE WHEN v_new_row->>'is_active'='false' THEN 'Staff account deactivated' ELSE 'Staff account reactivated' END
      WHEN TG_OP='UPDATE' AND v_old_row->'permissions' IS DISTINCT FROM v_new_row->'permissions' THEN 'Staff permissions changed'
      ELSE CASE TG_OP WHEN 'INSERT' THEN 'Staff account created' WHEN 'UPDATE' THEN 'Staff account updated' ELSE 'Staff account deleted' END END;

  ELSIF TG_TABLE_NAME = 'payments' THEN
    v_category := 'Payments';
    v_before := CASE WHEN TG_OP='INSERT' THEN '{}'::jsonb ELSE jsonb_build_object(
      'status',v_old_row->'status','amount',v_old_row->'amount','provider',v_old_row->'provider','order_id',v_old_row->'order_id') END;
    v_after := CASE WHEN TG_OP='DELETE' THEN '{}'::jsonb ELSE jsonb_build_object(
      'status',v_new_row->'status','amount',v_new_row->'amount','provider',v_new_row->'provider','order_id',v_new_row->'order_id') END;
    v_action := CASE WHEN TG_OP='UPDATE' AND v_old_row->>'status' IS DISTINCT FROM v_new_row->>'status'
      THEN 'Payment status changed' ELSE CASE TG_OP WHEN 'INSERT' THEN 'Payment created' WHEN 'UPDATE' THEN 'Payment updated' ELSE 'Payment deleted' END END;

  ELSIF TG_TABLE_NAME = 'cashier_credentials' THEN
    SELECT ru.restaurant_id INTO v_restaurant_id
    FROM public.restaurant_users ru
    WHERE ru.id = coalesce(v_new_row->>'restaurant_user_id',v_old_row->>'restaurant_user_id')::uuid;
    IF v_restaurant_id IS NULL THEN RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END; END IF;
    v_category := 'Staff & Security';
    v_record_id := coalesce(v_new_row->>'restaurant_user_id',v_old_row->>'restaurant_user_id');
    v_before := CASE WHEN TG_OP='INSERT' THEN '{}'::jsonb ELSE jsonb_build_object(
      'failed_attempts',v_old_row->'failed_attempts','locked_at',v_old_row->'locked_at') END;
    v_after := CASE WHEN TG_OP='DELETE' THEN '{}'::jsonb ELSE jsonb_build_object(
      'failed_attempts',v_new_row->'failed_attempts','locked_at',v_new_row->'locked_at') END;
    v_action := CASE
      WHEN TG_OP='UPDATE' AND v_old_row->>'pin_hash' IS DISTINCT FROM v_new_row->>'pin_hash' THEN 'Staff PIN reset'
      WHEN TG_OP='UPDATE' AND v_old_row->>'locked_at' IS DISTINCT FROM v_new_row->>'locked_at' AND v_new_row->>'locked_at' IS NOT NULL THEN 'Staff PIN locked'
      WHEN TG_OP='UPDATE' AND v_old_row->>'locked_at' IS DISTINCT FROM v_new_row->>'locked_at' AND v_new_row->>'locked_at' IS NULL THEN 'Staff PIN unlocked'
      ELSE CASE TG_OP WHEN 'INSERT' THEN 'Staff PIN created' WHEN 'UPDATE' THEN 'Staff security updated' ELSE 'Staff credentials deleted' END END;

  ELSIF TG_TABLE_NAME = 'staff_sessions' THEN
    v_category := 'Staff & Security';
    v_record_id := v_new_row->>'id';
    v_before := CASE WHEN TG_OP='INSERT' THEN '{}'::jsonb ELSE jsonb_build_object(
      'login_at',v_old_row->'login_at','logout_at',v_old_row->'logout_at','end_reason',v_old_row->'end_reason') END;
    v_after := CASE WHEN TG_OP='DELETE' THEN '{}'::jsonb ELSE jsonb_build_object(
      'login_at',v_new_row->'login_at','logout_at',v_new_row->'logout_at','end_reason',v_new_row->'end_reason') END;
    IF TG_OP='UPDATE' AND v_old_row->>'last_seen_at' IS DISTINCT FROM v_new_row->>'last_seen_at'
       AND v_old_row->>'logout_at' IS NOT DISTINCT FROM v_new_row->>'logout_at'
       AND v_old_row->>'end_reason' IS NOT DISTINCT FROM v_new_row->>'end_reason' THEN
      RETURN NEW;
    END IF;
    v_action := CASE WHEN TG_OP='INSERT' THEN 'Staff login'
      WHEN TG_OP='UPDATE' AND v_old_row->>'logout_at' IS DISTINCT FROM v_new_row->>'logout_at' THEN 'Staff logout'
      ELSE CASE TG_OP WHEN 'UPDATE' THEN 'Staff session updated' ELSE 'Staff session deleted' END END;
    SELECT coalesce(nullif(ru.display_name,''),nullif(ru.full_name,''),nullif(ru.cashier_username,''))
      INTO v_actor_name
    FROM public.restaurant_users ru
    WHERE ru.id = coalesce(v_new_row->>'restaurant_user_id',v_old_row->>'restaurant_user_id')::uuid;
    IF v_actor IS NULL THEN
      v_actor := nullif(coalesce(v_new_row->>'user_id',v_old_row->>'user_id'),'')::uuid;
      v_actor_role := 'staff';
    END IF;

  ELSIF TG_TABLE_NAME = 'restaurant_tables' THEN
    v_category := 'Tables';
    v_before := CASE WHEN TG_OP='INSERT' THEN '{}'::jsonb ELSE jsonb_build_object(
      'table_number',v_old_row->'table_number','is_active',v_old_row->'is_active') END;
    v_after := CASE WHEN TG_OP='DELETE' THEN '{}'::jsonb ELSE jsonb_build_object(
      'table_number',v_new_row->'table_number','is_active',v_new_row->'is_active') END;
    v_action := CASE TG_OP WHEN 'INSERT' THEN 'Table created' WHEN 'UPDATE' THEN 'Table updated' ELSE 'Table deleted' END;

  ELSE
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
  END IF;

  IF v_actor IS NOT NULL AND TG_TABLE_NAME <> 'staff_sessions' THEN
    SELECT coalesce(nullif(ru.display_name,''),nullif(ru.full_name,''),nullif(ru.cashier_username,''),au.email,'Authenticated user'),
           coalesce(ru.role,'authenticated')
      INTO v_actor_name,v_actor_role
    FROM auth.users au
    LEFT JOIN public.restaurant_users ru ON ru.user_id=au.id AND ru.restaurant_id=v_restaurant_id
    WHERE au.id=v_actor LIMIT 1;
    v_actor_name := coalesce(v_actor_name,'Authenticated user');
    v_actor_role := coalesce(v_actor_role,'authenticated');
  END IF;

  v_details := jsonb_build_object('before',v_before,'after',v_after,'operation',TG_OP,'source_table',TG_TABLE_NAME);
  INSERT INTO public.audit_logs(restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,record_type,record_id,details)
  VALUES(v_restaurant_id,v_actor,v_actor_name,v_actor_role,v_category,v_action,TG_TABLE_NAME,v_record_id,v_details);

  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END;
$function$;

DROP TRIGGER IF EXISTS audit_cashier_credentials_changes ON public.cashier_credentials;
CREATE TRIGGER audit_cashier_credentials_changes
AFTER INSERT OR UPDATE OR DELETE ON public.cashier_credentials
FOR EACH ROW EXECUTE FUNCTION public.write_audit_log_for_row();

DROP TRIGGER IF EXISTS audit_staff_sessions_changes ON public.staff_sessions;
CREATE TRIGGER audit_staff_sessions_changes
AFTER INSERT OR UPDATE OR DELETE ON public.staff_sessions
FOR EACH ROW EXECUTE FUNCTION public.write_audit_log_for_row();

DROP TRIGGER IF EXISTS audit_restaurant_tables_changes ON public.restaurant_tables;
CREATE TRIGGER audit_restaurant_tables_changes
AFTER INSERT OR UPDATE OR DELETE ON public.restaurant_tables
FOR EACH ROW EXECUTE FUNCTION public.write_audit_log_for_row();
