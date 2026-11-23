-- EDMEL Multi-Branch Add/Edit foundation
-- Additive and backward-compatible: existing branches and revisions are preserved.

ALTER TABLE private.restaurant_branch_setting_overrides
  DROP CONSTRAINT IF EXISTS restaurant_branch_setting_overrides_inheritance_mode_check;
ALTER TABLE private.restaurant_branch_setting_overrides
  ADD CONSTRAINT restaurant_branch_setting_overrides_inheritance_mode_check
  CHECK (inheritance_mode = ANY (ARRAY['inherit'::text,'override'::text,'independent'::text]));

ALTER TABLE private.restaurant_branch_setting_overrides
  DROP CONSTRAINT IF EXISTS restaurant_branch_setting_overrides_mode_data_check;
ALTER TABLE private.restaurant_branch_setting_overrides
  ADD CONSTRAINT restaurant_branch_setting_overrides_mode_data_check
  CHECK (
    (inheritance_mode='inherit' AND override_data='{}'::jsonb)
    OR (inheritance_mode='override' AND jsonb_typeof(override_data)='object')
    OR (inheritance_mode='independent' AND override_data<>'{}'::jsonb AND jsonb_typeof(override_data)='object')
  );

ALTER TABLE private.restaurant_branch_setting_revisions
  DROP CONSTRAINT IF EXISTS restaurant_branch_setting_revisions_inheritance_mode_check;
ALTER TABLE private.restaurant_branch_setting_revisions
  ADD CONSTRAINT restaurant_branch_setting_revisions_inheritance_mode_check
  CHECK (inheritance_mode = ANY (ARRAY['inherit'::text,'override'::text,'independent'::text]));

ALTER TABLE private.restaurant_branch_setting_revisions
  DROP CONSTRAINT IF EXISTS restaurant_branch_setting_revisions_mode_data_check;
ALTER TABLE private.restaurant_branch_setting_revisions
  ADD CONSTRAINT restaurant_branch_setting_revisions_mode_data_check
  CHECK (
    (inheritance_mode='inherit' AND override_data='{}'::jsonb)
    OR (inheritance_mode='override' AND jsonb_typeof(override_data)='object')
    OR (inheritance_mode='independent' AND override_data<>'{}'::jsonb AND jsonb_typeof(override_data)='object')
  );

CREATE OR REPLACE FUNCTION private.edmel_strip_branch_snapshot_metadata(p_value jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $function$
DECLARE v_result jsonb;
BEGIN
  CASE jsonb_typeof(p_value)
    WHEN 'object' THEN
      SELECT coalesce(jsonb_object_agg(e.key,private.edmel_strip_branch_snapshot_metadata(e.value)),'{}'::jsonb)
      INTO v_result FROM jsonb_each(p_value) e
      WHERE e.key NOT IN ('id','created_at','updated_at','created_by');
      RETURN v_result;
    WHEN 'array' THEN
      SELECT coalesce(jsonb_agg(private.edmel_strip_branch_snapshot_metadata(a.value)),'[]'::jsonb)
      INTO v_result FROM jsonb_array_elements(p_value) a;
      RETURN v_result;
    ELSE RETURN p_value;
  END CASE;
END;
$function$;
REVOKE ALL ON FUNCTION private.edmel_strip_branch_snapshot_metadata(jsonb) FROM PUBLIC,anon,authenticated;

-- Patch the existing private writer without replacing its concurrency, revision, or audit behavior.
DO $patch$
DECLARE v_def text;
BEGIN
  v_def:=pg_get_functiondef('private.edmel_apply_branch_setting_change(uuid,uuid,text,text,jsonb,integer,uuid,text)'::regprocedure);
  v_def:=replace(v_def,
    'p_inheritance_mode not in (''inherit'',''override'')',
    'p_inheritance_mode not in (''inherit'',''override'',''independent'')');
  v_def:=replace(v_def,
$old$
  if p_inheritance_mode='inherit' then
    v_override_data := '{}'::jsonb;
  elsif not private.edmel_validate_branch_setting_payload(p_setting_group,v_override_data)
        or v_override_data='{}'::jsonb then
    raise exception 'The branch setting payload is invalid or empty' using errcode='22023';
  end if;
$new$,
$new$
  if p_inheritance_mode='inherit' then
    v_override_data := '{}'::jsonb;
  elsif p_inheritance_mode='override' then
    if jsonb_typeof(v_override_data)<>'object'
       or (v_override_data<>'{}'::jsonb and not private.edmel_validate_branch_setting_payload(p_setting_group,v_override_data)) then
      raise exception 'The branch setting override payload is invalid' using errcode='22023';
    end if;
  elsif jsonb_typeof(v_override_data)<>'object'
        or v_override_data='{}'::jsonb
        or not private.edmel_validate_branch_setting_payload(p_setting_group,v_override_data) then
    raise exception 'The independent branch setting snapshot is invalid or empty' using errcode='22023';
  end if;
$new$);
  IF position('p_inheritance_mode not in (''inherit'',''override'',''independent'')' in v_def)=0
     OR position('The independent branch setting snapshot is invalid or empty' in v_def)=0 THEN
    RAISE EXCEPTION 'Could not safely patch the existing branch settings writer; no function change was applied';
  END IF;
  EXECUTE v_def;
END;
$patch$;

-- Extend the existing resolver: Independent uses its own snapshot; Override merges on top of master.
DO $patch$
DECLARE v_def text;
BEGIN
  v_def:=pg_get_functiondef('public.edmel_get_branch_setting_config(uuid,uuid,text)'::regprocedure);
  v_def:=replace(v_def,
$old$
  v_effective:=case when v_mode='override'
    then private.edmel_jsonb_deep_merge(coalesce(v_master,'{}'::jsonb),v_data)
    else coalesce(v_master,'{}'::jsonb) end;
$new$,
$new$
  v_effective:=case
    when v_mode='independent' then v_data
    when v_mode='override' then private.edmel_jsonb_deep_merge(coalesce(v_master,'{}'::jsonb),v_data)
    else coalesce(v_master,'{}'::jsonb) end;

  if p_setting_group='business_profile' then
    select jsonb_set(
      jsonb_set(v_effective,'{restaurant,address}',coalesce(to_jsonb(b.address),'null'::jsonb),true),
      '{restaurant,timezone}',to_jsonb(b.timezone),true
    ) into v_effective
    from public.restaurant_branches b
    where b.id=p_branch_id and b.restaurant_id=p_restaurant_id and b.is_active=true;
  end if;
$new$);
  IF position('when v_mode=''independent'' then v_data' in v_def)=0 THEN
    RAISE EXCEPTION 'Could not safely patch branch settings resolver; no resolver change was applied';
  END IF;
  EXECUTE v_def;
END;
$patch$;

CREATE OR REPLACE FUNCTION public.edmel_create_restaurant_branch_with_modes(
  p_restaurant_slug text,p_name text,p_code text,p_address text DEFAULT NULL,
  p_timezone text DEFAULT NULL,p_settings_modes jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_result jsonb;
  v_branch_id uuid;
  v_restaurant_id uuid;
  v_default_branch_id uuid;
  v_group text;
  v_mode text;
  v_config jsonb;
  v_snapshot jsonb;
  v_groups text[]:=ARRAY['business_profile','tax','service_charge','discounts_vouchers','payment_methods','receipt_settings'];
BEGIN
  IF p_settings_modes IS NULL OR jsonb_typeof(p_settings_modes)<>'object' OR pg_column_size(p_settings_modes)>8192 THEN
    RAISE EXCEPTION 'Invalid branch settings mode selection' USING errcode='22023';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_each(p_settings_modes) e
    WHERE NOT (e.key=ANY(v_groups)) OR jsonb_typeof(e.value)<>'string'
      OR e.value#>>'{}' NOT IN ('inherit','override','independent')) THEN
    RAISE EXCEPTION 'Unsupported branch settings mode selection' USING errcode='22023';
  END IF;

  -- Reuse the existing Owner-only creation function and its identity/audit validations.
  v_result:=public.edmel_create_restaurant_branch(p_restaurant_slug,p_name,p_code,p_address,p_timezone);
  v_branch_id:=(v_result#>>'{branch,id}')::uuid;
  SELECT b.restaurant_id INTO v_restaurant_id FROM public.restaurant_branches b WHERE b.id=v_branch_id;
  SELECT b.id INTO v_default_branch_id FROM public.restaurant_branches b
    WHERE b.restaurant_id=v_restaurant_id AND b.is_default=true AND b.is_active=true LIMIT 1;
  IF v_default_branch_id IS NULL THEN RAISE EXCEPTION 'An active default branch is required before adding another branch' USING errcode='22023'; END IF;

  FOREACH v_group IN ARRAY v_groups LOOP
    v_mode:=coalesce(p_settings_modes->>v_group,'inherit');
    IF v_mode='inherit' THEN CONTINUE; END IF;
    v_snapshot:='{}'::jsonb;
    IF v_mode='independent' THEN
      v_config:=public.edmel_get_branch_setting_config(v_restaurant_id,v_default_branch_id,v_group);
      v_snapshot:=private.edmel_strip_branch_snapshot_metadata(coalesce(v_config->'master_data','{}'::jsonb));
      IF v_group='receipt_settings' AND v_snapshot='{}'::jsonb THEN
        v_snapshot:=jsonb_build_object('settings','{}'::jsonb);
      END IF;
      IF NOT private.edmel_validate_branch_setting_payload(v_group,v_snapshot) THEN
        RAISE EXCEPTION 'The current master configuration for % cannot be copied as an independent snapshot yet',v_group USING errcode='22023';
      END IF;
    END IF;
    PERFORM private.edmel_apply_branch_setting_change(
      v_restaurant_id,v_branch_id,v_group,v_mode,v_snapshot,0,auth.uid(),
      CASE WHEN v_mode='independent'
        THEN 'Initial independent snapshot copied from master settings'
        ELSE 'Branch override enabled; master values remain the fallback' END
    );
  END LOOP;
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.edmel_update_restaurant_branch(
  p_restaurant_slug text,p_branch_id uuid,p_name text,p_code text,
  p_address text,p_timezone text,p_settings_modes jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_restaurant_id uuid;
  v_restaurant_timezone text;
  v_actor_name text;
  v_branch public.restaurant_branches%rowtype;
  v_name text:=nullif(btrim(p_name),'');
  v_code text:=upper(btrim(coalesce(p_code,'')));
  v_timezone text;
  v_group text;
  v_mode text;
  v_current_mode text;
  v_current_data jsonb;
  v_current_version integer;
  v_config jsonb;
  v_default_branch_id uuid;
  v_snapshot jsonb;
  v_groups text[]:=ARRAY['business_profile','tax','service_charge','discounts_vouchers','payment_methods','receipt_settings'];
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING errcode='42501'; END IF;
  IF p_settings_modes IS NULL OR jsonb_typeof(p_settings_modes)<>'object' OR pg_column_size(p_settings_modes)>8192 THEN
    RAISE EXCEPTION 'Invalid branch settings mode selection' USING errcode='22023';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_each(p_settings_modes) e
    WHERE NOT (e.key=ANY(v_groups)) OR jsonb_typeof(e.value)<>'string'
      OR e.value#>>'{}' NOT IN ('inherit','override','independent')) THEN
    RAISE EXCEPTION 'Unsupported branch settings mode selection' USING errcode='22023';
  END IF;

  SELECT r.id,r.timezone,
    coalesce(nullif(btrim(ru.display_name),''),nullif(btrim(ru.full_name),''),'Owner')
  INTO v_restaurant_id,v_restaurant_timezone,v_actor_name
  FROM public.restaurants r JOIN public.restaurant_users ru ON ru.restaurant_id=r.id
  WHERE lower(btrim(r.slug))=lower(btrim(p_restaurant_slug))
    AND ru.user_id=auth.uid() AND ru.is_active=true AND lower(ru.role)='owner'
  LIMIT 1;
  IF v_restaurant_id IS NULL THEN RAISE EXCEPTION 'Owner access required for this restaurant' USING errcode='42501'; END IF;
  IF p_branch_id IS NULL OR v_name IS NULL OR length(v_name)>80 THEN RAISE EXCEPTION 'Branch name must contain 1 to 80 characters' USING errcode='22023'; END IF;
  IF v_code !~ '^[A-Z0-9][A-Z0-9_-]{1,19}$' THEN RAISE EXCEPTION 'Branch code must contain 2 to 20 characters and start with a letter or number' USING errcode='22023'; END IF;
  v_timezone:=coalesce(nullif(btrim(p_timezone),''),nullif(btrim(v_restaurant_timezone),''),'America/Chicago');
  IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_timezone_names z WHERE z.name=v_timezone) THEN RAISE EXCEPTION 'Invalid branch timezone' USING errcode='22023'; END IF;

  SELECT * INTO v_branch FROM public.restaurant_branches b
  WHERE b.id=p_branch_id AND b.restaurant_id=v_restaurant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Branch not found for this restaurant' USING errcode='P0002'; END IF;
  IF NOT v_branch.is_active THEN RAISE EXCEPTION 'Inactive branches cannot be edited' USING errcode='22023'; END IF;

  UPDATE public.restaurant_branches SET name=v_name,code=v_code,address=nullif(btrim(p_address),''),
    timezone=v_timezone,updated_at=now()
  WHERE id=p_branch_id AND restaurant_id=v_restaurant_id RETURNING * INTO v_branch;

  FOREACH v_group IN ARRAY v_groups LOOP
    IF NOT (p_settings_modes ? v_group) THEN CONTINUE; END IF;
    v_mode:=p_settings_modes->>v_group;
    SELECT o.inheritance_mode,o.override_data,o.version
    INTO v_current_mode,v_current_data,v_current_version
    FROM private.restaurant_branch_setting_overrides o
    WHERE o.restaurant_id=v_restaurant_id AND o.branch_id=p_branch_id AND o.setting_group=v_group;
    v_current_mode:=coalesce(v_current_mode,'inherit');
    v_current_data:=coalesce(v_current_data,'{}'::jsonb);
    v_current_version:=coalesce(v_current_version,0);
    IF v_mode=v_current_mode THEN CONTINUE; END IF;

    v_snapshot:='{}'::jsonb;
    IF v_mode='independent' THEN
      IF v_current_mode IN ('override','independent') AND v_current_data<>'{}'::jsonb THEN
        v_config:=public.edmel_get_branch_setting_config(v_restaurant_id,p_branch_id,v_group);
        v_snapshot:=private.edmel_strip_branch_snapshot_metadata(coalesce(v_config->'effective_data','{}'::jsonb));
      ELSE
        SELECT b.id INTO v_default_branch_id FROM public.restaurant_branches b
        WHERE b.restaurant_id=v_restaurant_id AND b.is_default=true AND b.is_active=true LIMIT 1;
        IF v_default_branch_id IS NULL THEN RAISE EXCEPTION 'An active default branch is required to create an independent snapshot' USING errcode='22023'; END IF;
        v_config:=public.edmel_get_branch_setting_config(v_restaurant_id,v_default_branch_id,v_group);
        v_snapshot:=private.edmel_strip_branch_snapshot_metadata(coalesce(v_config->'master_data','{}'::jsonb));
      END IF;
      IF v_group='receipt_settings' AND v_snapshot='{}'::jsonb THEN
        v_snapshot:=jsonb_build_object('settings','{}'::jsonb);
      END IF;
    ELSIF v_mode='override' AND v_current_mode IN ('override','independent') THEN
      v_snapshot:=v_current_data;
    END IF;

    PERFORM private.edmel_apply_branch_setting_change(
      v_restaurant_id,p_branch_id,v_group,v_mode,v_snapshot,v_current_version,auth.uid(),
      CASE v_mode
        WHEN 'inherit' THEN 'Reset branch settings to inherit master configuration'
        WHEN 'independent' THEN 'Copied current effective settings into an independent branch snapshot'
        ELSE 'Enabled branch override mode; master values remain the fallback'
      END
    );
  END LOOP;

  INSERT INTO public.audit_logs(
    restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
    record_type,record_id,result,details
  ) VALUES (
    v_restaurant_id,auth.uid(),v_actor_name,'owner','Branch Management','Branch information updated',
    'restaurant_branch',p_branch_id::text,'success',
    jsonb_build_object('branch_name',v_branch.name,'branch_code',v_branch.code,
      'timezone',v_branch.timezone,'address',v_branch.address)
  );

  RETURN jsonb_build_object('success',true,'branch',jsonb_build_object(
    'id',v_branch.id,'restaurant_id',v_branch.restaurant_id,'name',v_branch.name,
    'code',v_branch.code,'timezone',v_branch.timezone,'address',v_branch.address,
    'is_default',v_branch.is_default,'is_active',v_branch.is_active
  ));
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_create_restaurant_branch_with_modes(text,text,text,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.edmel_create_restaurant_branch_with_modes(text,text,text,text,text,jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.edmel_update_restaurant_branch(text,uuid,text,text,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.edmel_update_restaurant_branch(text,uuid,text,text,text,text,jsonb) TO authenticated;

COMMENT ON FUNCTION public.edmel_create_restaurant_branch_with_modes(text,text,text,text,text,jsonb)
IS 'Owner-only atomic branch creation with initial Inherit, Override, or Independent settings modes. Menu, stock, tables, and printer provisioning are separate branch setup steps.';
COMMENT ON FUNCTION public.edmel_update_restaurant_branch(text,uuid,text,text,text,text,jsonb)
IS 'Owner-only branch identity and settings inheritance update. Preserves existing branch operational records.';
