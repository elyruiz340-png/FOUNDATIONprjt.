
ALTER TABLE public.restaurant_branches
  ADD COLUMN IF NOT EXISTS country_code text,
  ADD COLUMN IF NOT EXISTS state_province text,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS district text,
  ADD COLUMN IF NOT EXISTS postal_code text,
  ADD COLUMN IF NOT EXISTS contact_number text,
  ADD COLUMN IF NOT EXISTS email text,
  ADD COLUMN IF NOT EXISTS website text,
  ADD COLUMN IF NOT EXISTS locale text,
  ADD COLUMN IF NOT EXISTS date_format text,
  ADD COLUMN IF NOT EXISTS time_format text,
  ADD COLUMN IF NOT EXISTS number_format text;

CREATE OR REPLACE FUNCTION public.edmel_set_branch_regional_profile(p_branch_id uuid, p_profile jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_restaurant_id uuid;
  v_key text;
  v_value text;
  v_max_length integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';
  END IF;
  IF p_branch_id IS NULL OR jsonb_typeof(p_profile) <> 'object' OR pg_column_size(p_profile) > 12000 THEN
    RAISE EXCEPTION 'Invalid branch regional profile' USING ERRCODE='22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_object_keys(p_profile) AS k(key)
    WHERE k.key <> ALL (ARRAY['country_code','state_province','city','district','postal_code','contact_number','email','website','locale','date_format','time_format','number_format'])
  ) THEN
    RAISE EXCEPTION 'Unsupported branch regional profile field' USING ERRCODE='22023';
  END IF;

  SELECT b.restaurant_id INTO v_restaurant_id
  FROM public.restaurant_branches b WHERE b.id=p_branch_id FOR UPDATE;
  IF v_restaurant_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.restaurant_id=v_restaurant_id AND ru.user_id=auth.uid()
      AND ru.is_active=true AND lower(ru.role)='owner'
  ) THEN
    RAISE EXCEPTION 'Owner access to this branch is required' USING ERRCODE='42501';
  END IF;

  FOR v_key,v_value IN
    SELECT key,nullif(btrim(value #>> '{}'),'') FROM jsonb_each(p_profile)
  LOOP
    v_max_length := CASE v_key
      WHEN 'country_code' THEN 2 WHEN 'state_province' THEN 120 WHEN 'city' THEN 120
      WHEN 'district' THEN 120 WHEN 'postal_code' THEN 24 WHEN 'contact_number' THEN 40
      WHEN 'email' THEN 254 WHEN 'website' THEN 500 WHEN 'locale' THEN 35
      WHEN 'date_format' THEN 40 WHEN 'time_format' THEN 20 WHEN 'number_format' THEN 40
      ELSE 0 END;
    IF v_value IS NOT NULL AND length(v_value)>v_max_length THEN
      RAISE EXCEPTION 'Branch regional profile field is too long: %',v_key USING ERRCODE='22023';
    END IF;
  END LOOP;

  IF nullif(btrim(p_profile->>'country_code'),'') IS NOT NULL
     AND upper(btrim(p_profile->>'country_code')) !~ '^[A-Z]{2}$' THEN
    RAISE EXCEPTION 'Country must use a two-letter ISO code' USING ERRCODE='22023';
  END IF;
  IF nullif(btrim(p_profile->>'email'),'') IS NOT NULL
     AND btrim(p_profile->>'email') !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' THEN
    RAISE EXCEPTION 'Enter a valid email address' USING ERRCODE='22023';
  END IF;
  IF nullif(btrim(p_profile->>'website'),'') IS NOT NULL
     AND btrim(p_profile->>'website') !~* '^https?://' THEN
    RAISE EXCEPTION 'Website must begin with http:// or https://' USING ERRCODE='22023';
  END IF;

  UPDATE public.restaurant_branches
  SET country_code=upper(nullif(btrim(p_profile->>'country_code'),'')),
      state_province=nullif(btrim(p_profile->>'state_province'),''),
      city=nullif(btrim(p_profile->>'city'),''),
      district=nullif(btrim(p_profile->>'district'),''),
      postal_code=nullif(btrim(p_profile->>'postal_code'),''),
      contact_number=nullif(btrim(p_profile->>'contact_number'),''),
      email=lower(nullif(btrim(p_profile->>'email'),'')),
      website=nullif(btrim(p_profile->>'website'),''),
      locale=nullif(btrim(p_profile->>'locale'),''),
      date_format=nullif(btrim(p_profile->>'date_format'),''),
      time_format=nullif(btrim(p_profile->>'time_format'),''),
      number_format=nullif(btrim(p_profile->>'number_format'),''),
      updated_at=now()
  WHERE id=p_branch_id AND restaurant_id=v_restaurant_id;

  RETURN jsonb_build_object('success',true,'branch_id',p_branch_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_set_branch_regional_profile(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.edmel_set_branch_regional_profile(uuid,jsonb) TO authenticated,service_role;



CREATE OR REPLACE FUNCTION public.edmel_create_restaurant_branch_regional_configured_with_hours(
  p_restaurant_slug text,p_name text,p_code text,p_address text,p_timezone text,
  p_operating_hours jsonb,p_settings_modes jsonb,p_menu_catalog_mode text,p_regional_profile jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_result jsonb; v_branch_id uuid;
BEGIN
  v_result:=public.edmel_create_restaurant_branch_configured_with_hours(
    p_restaurant_slug,p_name,p_code,p_address,p_timezone,p_operating_hours,p_settings_modes,p_menu_catalog_mode
  );
  v_branch_id:=(v_result#>>'{branch,id}')::uuid;
  PERFORM public.edmel_set_branch_regional_profile(v_branch_id,p_regional_profile);
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.edmel_update_restaurant_branch_regional_configured_with_hours(
  p_restaurant_slug text,p_branch_id uuid,p_name text,p_code text,p_address text,p_timezone text,
  p_operating_hours jsonb,p_settings_modes jsonb,p_menu_catalog_mode text,p_regional_profile jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_result jsonb;
BEGIN
  v_result:=public.edmel_update_restaurant_branch_configured_with_hours(
    p_restaurant_slug,p_branch_id,p_name,p_code,p_address,p_timezone,p_operating_hours,p_settings_modes,p_menu_catalog_mode
  );
  PERFORM public.edmel_set_branch_regional_profile(p_branch_id,p_regional_profile);
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_create_restaurant_branch_regional_configured_with_hours(text,text,text,text,text,jsonb,jsonb,text,jsonb) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.edmel_update_restaurant_branch_regional_configured_with_hours(text,uuid,text,text,text,text,jsonb,jsonb,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.edmel_create_restaurant_branch_regional_configured_with_hours(text,text,text,text,text,jsonb,jsonb,text,jsonb) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.edmel_update_restaurant_branch_regional_configured_with_hours(text,uuid,text,text,text,text,jsonb,jsonb,text,jsonb) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.edmel_submit_branch_creation_request(p_restaurant_id uuid,p_request_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_manager public.restaurant_users%ROWTYPE;
  v_mode text;
  v_request_id uuid;
  v_name text;
  v_code text;
  v_setting_group text;
  v_setting_mode text;
  v_allowed_groups text[]:=ARRAY['business_profile','tax','service_charge','discounts_vouchers','payment_methods','receipt_settings'];
  v_profile jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
  IF p_restaurant_id IS NULL OR jsonb_typeof(p_request_data)<>'object' OR pg_column_size(p_request_data)>32768 THEN
    RAISE EXCEPTION 'Invalid branch request data' USING ERRCODE='22023';
  END IF;
  SELECT ru.* INTO v_manager FROM public.restaurant_users ru
  WHERE ru.restaurant_id=p_restaurant_id AND ru.user_id=auth.uid() AND ru.is_active=true
    AND lower(ru.role)='staff' AND lower(coalesce(ru.position,''))='manager' LIMIT 1;
  IF v_manager.id IS NULL OR NOT private.edmel_manager_can_create_branch(p_restaurant_id,auth.uid()) THEN
    RAISE EXCEPTION 'Manager branch creation permission is required' USING ERRCODE='42501';
  END IF;
  SELECT p.manager_creation_mode INTO v_mode FROM private.restaurant_branch_creation_policies p WHERE p.restaurant_id=p_restaurant_id;
  v_mode:=coalesce(v_mode,'not_allowed');
  IF v_mode='not_allowed' THEN RAISE EXCEPTION 'Branch creation is disabled by the Owner/Admin' USING ERRCODE='42501';
  ELSIF v_mode='allowed' THEN RAISE EXCEPTION 'Direct branch creation is enabled. Use the configured branch creation workflow.' USING ERRCODE='22023'; END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_object_keys(p_request_data) AS k(key)
    WHERE k.key<>ALL(ARRAY['name','code','address','timezone','operating_hours','settings_modes','menu_catalog_mode',
      'country_code','state_province','city','district','postal_code','contact_number','email','website',
      'locale','date_format','time_format','number_format'])
  ) THEN RAISE EXCEPTION 'Unsupported branch request field' USING ERRCODE='22023'; END IF;

  v_name:=nullif(btrim(p_request_data->>'name'),'');
  v_code:=upper(btrim(coalesce(p_request_data->>'code','')));
  IF v_name IS NULL OR length(v_name)>80 THEN RAISE EXCEPTION 'Branch name must contain 1 to 80 characters' USING ERRCODE='22023'; END IF;
  IF v_code !~ '^[A-Z0-9][A-Z0-9_-]{0,19}$' THEN RAISE EXCEPTION 'Branch code must contain 1 to 20 letters, numbers, hyphens, or underscores' USING ERRCODE='22023'; END IF;
  IF coalesce(p_request_data->>'timezone','')='' OR NOT EXISTS(SELECT 1 FROM pg_catalog.pg_timezone_names z WHERE z.name=p_request_data->>'timezone') THEN
    RAISE EXCEPTION 'Choose a valid branch timezone' USING ERRCODE='22023';
  END IF;
  IF NOT private.edmel_valid_branch_operating_hours(p_request_data->'operating_hours') THEN
    RAISE EXCEPTION 'Valid operating hours for all seven days are required' USING ERRCODE='22023';
  END IF;
  IF p_request_data ? 'settings_modes' THEN
    IF jsonb_typeof(p_request_data->'settings_modes')<>'object' OR pg_column_size(p_request_data->'settings_modes')>8192 THEN
      RAISE EXCEPTION 'Invalid branch settings mode selection' USING ERRCODE='22023';
    END IF;
    FOR v_setting_group,v_setting_mode IN SELECT key,value#>>'{}' FROM jsonb_each(p_request_data->'settings_modes') LOOP
      IF NOT(v_setting_group=ANY(v_allowed_groups)) OR v_setting_mode NOT IN('inherit','override','independent') THEN
        RAISE EXCEPTION 'Unsupported branch settings mode selection' USING ERRCODE='22023';
      END IF;
    END LOOP;
  END IF;
  IF p_request_data ? 'menu_catalog_mode' AND p_request_data->>'menu_catalog_mode' NOT IN('inherit','override','independent') THEN
    RAISE EXCEPTION 'Unsupported menu catalog mode' USING ERRCODE='22023';
  END IF;

  v_profile:=jsonb_build_object(
    'country_code',nullif(btrim(p_request_data->>'country_code'),''),
    'state_province',nullif(btrim(p_request_data->>'state_province'),''),
    'city',nullif(btrim(p_request_data->>'city'),''),
    'district',nullif(btrim(p_request_data->>'district'),''),
    'postal_code',nullif(btrim(p_request_data->>'postal_code'),''),
    'contact_number',nullif(btrim(p_request_data->>'contact_number'),''),
    'email',nullif(btrim(p_request_data->>'email'),''),
    'website',nullif(btrim(p_request_data->>'website'),''),
    'locale',nullif(btrim(p_request_data->>'locale'),''),
    'date_format',nullif(btrim(p_request_data->>'date_format'),''),
    'time_format',nullif(btrim(p_request_data->>'time_format'),''),
    'number_format',nullif(btrim(p_request_data->>'number_format'),'')
  );
  INSERT INTO private.restaurant_branch_creation_requests(restaurant_id,requested_by,request_data)
  VALUES(p_restaurant_id,auth.uid(),jsonb_build_object(
    'name',v_name,'code',v_code,'address',nullif(btrim(p_request_data->>'address'),''),'timezone',p_request_data->>'timezone',
    'operating_hours',p_request_data->'operating_hours','settings_modes',coalesce(p_request_data->'settings_modes','{}'::jsonb),
    'menu_catalog_mode',coalesce(p_request_data->>'menu_catalog_mode','inherit'),'regional_profile',v_profile
  )) RETURNING id INTO v_request_id;
  RETURN jsonb_build_object('success',true,'request_id',v_request_id,'status','pending');
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_submit_branch_creation_request(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.edmel_submit_branch_creation_request(uuid,jsonb) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.edmel_review_branch_creation_request(p_request_id uuid,p_decision text,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_request private.restaurant_branch_creation_requests%ROWTYPE;
  v_restaurant_slug text;
  v_actor_name text;
  v_actor_role text;
  v_create_result jsonb;
  v_branch_id uuid;
  v_manager_link_id uuid;
  v_reason text:=nullif(btrim(p_reason),'');
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
  IF p_request_id IS NULL OR p_decision NOT IN('approved','rejected') OR v_reason IS NULL OR length(v_reason)<3 OR length(v_reason)>500 THEN
    RAISE EXCEPTION 'A valid decision and reason are required' USING ERRCODE='22023';
  END IF;
  SELECT r.* INTO v_request FROM private.restaurant_branch_creation_requests r
  WHERE r.id=p_request_id AND EXISTS(
    SELECT 1 FROM public.restaurant_users ru WHERE ru.restaurant_id=r.restaurant_id AND ru.user_id=auth.uid()
      AND ru.is_active=true AND lower(ru.role)='owner'
  ) FOR UPDATE;
  IF v_request.id IS NULL THEN RAISE EXCEPTION 'Pending request not found or Owner access required' USING ERRCODE='42501'; END IF;
  IF v_request.status<>'pending' THEN RAISE EXCEPTION 'This branch request has already been reviewed' USING ERRCODE='22023'; END IF;
  IF v_request.requested_by=auth.uid() THEN RAISE EXCEPTION 'The requester cannot review their own branch request' USING ERRCODE='42501'; END IF;
  SELECT r.slug INTO v_restaurant_slug FROM public.restaurants r WHERE r.id=v_request.restaurant_id;
  SELECT coalesce(nullif(btrim(ru.display_name),''),nullif(btrim(ru.full_name),''),'Owner'),lower(ru.role)
  INTO v_actor_name,v_actor_role FROM public.restaurant_users ru
  WHERE ru.restaurant_id=v_request.restaurant_id AND ru.user_id=auth.uid() AND ru.is_active=true AND lower(ru.role)='owner' LIMIT 1;

  IF p_decision='approved' THEN
    v_create_result:=public.edmel_create_restaurant_branch_configured_with_hours(
      v_restaurant_slug,v_request.request_data->>'name',v_request.request_data->>'code',
      v_request.request_data->>'address',v_request.request_data->>'timezone',
      v_request.request_data->'operating_hours',coalesce(v_request.request_data->'settings_modes','{}'::jsonb),
      coalesce(v_request.request_data->>'menu_catalog_mode','override')
    );
    v_branch_id:=(v_create_result#>>'{branch,id}')::uuid;
    PERFORM public.edmel_set_branch_regional_profile(v_branch_id,coalesce(v_request.request_data->'regional_profile','{}'::jsonb));
    UPDATE public.restaurant_branches SET is_active=false,lifecycle_status='pending_activation',updated_at=now()
    WHERE id=v_branch_id AND restaurant_id=v_request.restaurant_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'The prepared branch could not be placed into pending activation'; END IF;
    SELECT ru.id INTO v_manager_link_id FROM public.restaurant_users ru
    WHERE ru.restaurant_id=v_request.restaurant_id AND ru.user_id=v_request.requested_by AND ru.is_active=true
      AND lower(ru.role)='staff' AND lower(coalesce(ru.position,''))='manager' LIMIT 1;
    IF v_manager_link_id IS NULL OR NOT private.edmel_manager_can_create_branch(v_request.restaurant_id,v_request.requested_by) THEN
      RAISE EXCEPTION 'The requesting Manager account is no longer eligible for branch assignment' USING ERRCODE='42501';
    END IF;
    INSERT INTO public.staff_branch_access(restaurant_user_id,restaurant_id,branch_id,permissions,is_active,created_by)
    VALUES(v_manager_link_id,v_request.restaurant_id,v_branch_id,
      jsonb_build_object('modules',jsonb_build_object('branches',jsonb_build_object('view',true,'create',true))),true,auth.uid())
    ON CONFLICT(restaurant_user_id,branch_id) DO UPDATE SET permissions=EXCLUDED.permissions,is_active=true,created_by=EXCLUDED.created_by,updated_at=now();
    v_create_result:=jsonb_set(jsonb_set(v_create_result,'{branch,is_active}','false'::jsonb,true),
      '{branch,lifecycle_status}','"pending_activation"'::jsonb,true);
  END IF;

  UPDATE private.restaurant_branch_creation_requests SET status=p_decision,reviewed_by=auth.uid(),reviewed_at=now(),
    decision_reason=v_reason,created_branch_id=v_branch_id,updated_at=now() WHERE id=v_request.id;
  INSERT INTO public.audit_logs(restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,record_type,record_id,result,details)
  VALUES(v_request.restaurant_id,auth.uid(),v_actor_name,v_actor_role,'Branch Management',
    CASE WHEN p_decision='approved' THEN 'Approved Manager branch request for setup' ELSE 'Rejected Manager branch creation request' END,
    'restaurant_branch_creation_request',v_request.id::text,'success',
    jsonb_build_object('requester_user_id',v_request.requested_by,'decision',p_decision,'reason',v_reason,
      'created_branch_id',v_branch_id,'branch_name',v_request.request_data->>'name','branch_code',v_request.request_data->>'code',
      'lifecycle_status',CASE WHEN p_decision='approved' THEN 'pending_activation' ELSE null END));
  RETURN jsonb_build_object('success',true,'request_id',v_request.id,'status',p_decision,'branch_id',v_branch_id,
    'lifecycle_status',CASE WHEN p_decision='approved' THEN 'pending_activation' ELSE null END,'branch',v_create_result->'branch');
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_review_branch_creation_request(uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.edmel_review_branch_creation_request(uuid,text,text) TO authenticated,service_role;



CREATE OR REPLACE FUNCTION private.edmel_validate_branch_request_regional_profile()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
DECLARE
  v_key text;
  v_value text;
  v_max_length integer;
  v_profile jsonb;
BEGIN
  v_profile:=coalesce(NEW.request_data->'regional_profile','{}'::jsonb);
  IF jsonb_typeof(v_profile)<>'object' OR pg_column_size(v_profile)>12000 THEN
    RAISE EXCEPTION 'Invalid branch regional profile' USING ERRCODE='22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_object_keys(v_profile) AS k(key)
    WHERE k.key<>ALL(ARRAY['country_code','state_province','city','district','postal_code','contact_number','email','website','locale','date_format','time_format','number_format'])
  ) THEN
    RAISE EXCEPTION 'Unsupported branch regional profile field' USING ERRCODE='22023';
  END IF;
  FOR v_key,v_value IN SELECT key,nullif(btrim(value#>>'{}'),'') FROM jsonb_each(v_profile) LOOP
    v_max_length:=CASE v_key
      WHEN 'country_code' THEN 2 WHEN 'state_province' THEN 120 WHEN 'city' THEN 120
      WHEN 'district' THEN 120 WHEN 'postal_code' THEN 24 WHEN 'contact_number' THEN 40
      WHEN 'email' THEN 254 WHEN 'website' THEN 500 WHEN 'locale' THEN 35
      WHEN 'date_format' THEN 40 WHEN 'time_format' THEN 20 WHEN 'number_format' THEN 40
      ELSE 0 END;
    IF v_value IS NOT NULL AND length(v_value)>v_max_length THEN
      RAISE EXCEPTION 'Branch regional profile field is too long: %',v_key USING ERRCODE='22023';
    END IF;
  END LOOP;
  IF nullif(btrim(v_profile->>'country_code'),'') IS NOT NULL AND upper(btrim(v_profile->>'country_code')) !~ '^[A-Z]{2}$' THEN
    RAISE EXCEPTION 'Country must use a two-letter ISO code' USING ERRCODE='22023';
  END IF;
  IF nullif(btrim(v_profile->>'email'),'') IS NOT NULL AND btrim(v_profile->>'email') !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' THEN
    RAISE EXCEPTION 'Enter a valid email address' USING ERRCODE='22023';
  END IF;
  IF nullif(btrim(v_profile->>'website'),'') IS NOT NULL AND btrim(v_profile->>'website') !~* '^https?://' THEN
    RAISE EXCEPTION 'Website must begin with http:// or https://' USING ERRCODE='22023';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS edmel_validate_branch_request_regional_profile ON private.restaurant_branch_creation_requests;
CREATE TRIGGER edmel_validate_branch_request_regional_profile
BEFORE INSERT OR UPDATE OF request_data ON private.restaurant_branch_creation_requests
FOR EACH ROW EXECUTE FUNCTION private.edmel_validate_branch_request_regional_profile();

REVOKE ALL ON FUNCTION private.edmel_validate_branch_request_regional_profile() FROM PUBLIC,anon,authenticated;
