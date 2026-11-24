-- EDMEL branch activation lifecycle: Manager request -> Owner review -> Owner activation.
-- Existing branch records and transaction data are preserved.
ALTER TABLE public.restaurant_branches
  ADD COLUMN IF NOT EXISTS lifecycle_status text;

UPDATE public.restaurant_branches
SET lifecycle_status = CASE
  WHEN is_active THEN 'active'
  ELSE 'deactivated'
END
WHERE lifecycle_status IS NULL;

ALTER TABLE public.restaurant_branches
  ALTER COLUMN lifecycle_status SET DEFAULT 'active',
  ALTER COLUMN lifecycle_status SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.restaurant_branches'::regclass
      AND conname = 'restaurant_branches_lifecycle_status_check'
  ) THEN
    ALTER TABLE public.restaurant_branches
      ADD CONSTRAINT restaurant_branches_lifecycle_status_check
      CHECK (lifecycle_status IN ('active','pending_activation','deactivated'));
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.edmel_review_branch_creation_request(
  p_request_id uuid,
  p_decision text,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_request private.restaurant_branch_creation_requests%ROWTYPE;
  v_restaurant_slug text;
  v_actor_name text;
  v_actor_role text;
  v_create_result jsonb;
  v_branch_id uuid;
  v_manager_link_id uuid;
  v_reason text := nullif(btrim(p_reason), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_request_id IS NULL OR p_decision NOT IN ('approved','rejected')
     OR v_reason IS NULL OR length(v_reason) < 3 OR length(v_reason) > 500 THEN
    RAISE EXCEPTION 'A valid decision and reason are required' USING ERRCODE = '22023';
  END IF;

  SELECT r.* INTO v_request
  FROM private.restaurant_branch_creation_requests r
  WHERE r.id = p_request_id
    AND EXISTS (
      SELECT 1
      FROM public.restaurant_users ru
      WHERE ru.restaurant_id = r.restaurant_id
        AND ru.user_id = auth.uid()
        AND ru.is_active = true
        AND lower(ru.role) = 'owner'
    )
  FOR UPDATE;

  IF v_request.id IS NULL THEN
    RAISE EXCEPTION 'Pending request not found or Owner access required' USING ERRCODE = '42501';
  END IF;
  IF v_request.status <> 'pending' THEN
    RAISE EXCEPTION 'This branch request has already been reviewed' USING ERRCODE = '22023';
  END IF;
  IF v_request.requested_by = auth.uid() THEN
    RAISE EXCEPTION 'The requester cannot review their own branch request' USING ERRCODE = '42501';
  END IF;

  SELECT r.slug INTO v_restaurant_slug
  FROM public.restaurants r
  WHERE r.id = v_request.restaurant_id;

  SELECT coalesce(nullif(btrim(ru.display_name), ''), nullif(btrim(ru.full_name), ''), 'Owner'),
         lower(ru.role)
  INTO v_actor_name, v_actor_role
  FROM public.restaurant_users ru
  WHERE ru.restaurant_id = v_request.restaurant_id
    AND ru.user_id = auth.uid()
    AND ru.is_active = true
    AND lower(ru.role) = 'owner'
  LIMIT 1;

  IF p_decision = 'approved' THEN
    v_create_result := public.edmel_create_restaurant_branch_configured_with_hours(
      v_restaurant_slug,
      v_request.request_data->>'name',
      v_request.request_data->>'code',
      v_request.request_data->>'address',
      v_request.request_data->>'timezone',
      v_request.request_data->'operating_hours',
      coalesce(v_request.request_data->'settings_modes', '{}'::jsonb),
      coalesce(v_request.request_data->>'menu_catalog_mode', 'override')
    );
    v_branch_id := (v_create_result #>> '{branch,id}')::uuid;

    UPDATE public.restaurant_branches
    SET is_active = false,
        lifecycle_status = 'pending_activation',
        updated_at = now()
    WHERE id = v_branch_id
      AND restaurant_id = v_request.restaurant_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'The prepared branch could not be placed into pending activation';
    END IF;

    SELECT ru.id INTO v_manager_link_id
    FROM public.restaurant_users ru
    WHERE ru.restaurant_id = v_request.restaurant_id
      AND ru.user_id = v_request.requested_by
      AND ru.is_active = true
      AND lower(ru.role) = 'staff'
      AND lower(coalesce(ru.position,'')) = 'manager'
    LIMIT 1;

    IF v_manager_link_id IS NULL
       OR NOT private.edmel_manager_can_create_branch(v_request.restaurant_id,v_request.requested_by) THEN
      RAISE EXCEPTION 'The requesting Manager account is no longer eligible for branch assignment' USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.staff_branch_access(
      restaurant_user_id,restaurant_id,branch_id,permissions,is_active,created_by
    )
    VALUES (
      v_manager_link_id,v_request.restaurant_id,v_branch_id,
      jsonb_build_object('modules',jsonb_build_object('branches',jsonb_build_object('view',true,'create',true))),
      true,auth.uid()
    )
    ON CONFLICT (restaurant_user_id,branch_id) DO UPDATE
      SET permissions=EXCLUDED.permissions,
          is_active=true,
          created_by=EXCLUDED.created_by,
          updated_at=now();

    v_create_result := jsonb_set(
      jsonb_set(v_create_result,'{branch,is_active}','false'::jsonb,true),
      '{branch,lifecycle_status}','"pending_activation"'::jsonb,true
    );
  END IF;

  UPDATE private.restaurant_branch_creation_requests
  SET status = p_decision,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      decision_reason = v_reason,
      created_branch_id = v_branch_id,
      updated_at = now()
  WHERE id = v_request.id;

  INSERT INTO public.audit_logs (
    restaurant_id, actor_user_id, actor_name, actor_role,
    action_category, action, record_type, record_id, result, details
  ) VALUES (
    v_request.restaurant_id, auth.uid(), v_actor_name, v_actor_role,
    'Branch Management',
    CASE WHEN p_decision = 'approved' THEN 'Approved Manager branch request for setup'
         ELSE 'Rejected Manager branch creation request' END,
    'restaurant_branch_creation_request', v_request.id::text, 'success',
    jsonb_build_object(
      'requester_user_id', v_request.requested_by,
      'decision', p_decision,
      'reason', v_reason,
      'created_branch_id', v_branch_id,
      'branch_name', v_request.request_data->>'name',
      'branch_code', v_request.request_data->>'code',
      'lifecycle_status', CASE WHEN p_decision='approved' THEN 'pending_activation' ELSE null END
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'request_id', v_request.id,
    'status', p_decision,
    'branch_id', v_branch_id,
    'lifecycle_status', CASE WHEN p_decision='approved' THEN 'pending_activation' ELSE null END,
    'branch', v_create_result->'branch'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.edmel_activate_restaurant_branch(
  p_restaurant_id uuid,
  p_branch_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_branch public.restaurant_branches%ROWTYPE;
  v_readiness jsonb;
  v_blockers text[];
  v_actor_name text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_restaurant_id IS NULL OR p_branch_id IS NULL THEN
    RAISE EXCEPTION 'Restaurant and branch are required' USING ERRCODE = '22023';
  END IF;

  SELECT coalesce(nullif(btrim(ru.display_name),''),nullif(btrim(ru.full_name),''),'Owner')
  INTO v_actor_name
  FROM public.restaurant_users ru
  WHERE ru.restaurant_id=p_restaurant_id
    AND ru.user_id=auth.uid()
    AND ru.is_active=true
    AND lower(ru.role)='owner'
  LIMIT 1;
  IF v_actor_name IS NULL THEN
    RAISE EXCEPTION 'Active Owner access is required to activate a branch' USING ERRCODE = '42501';
  END IF;

  SELECT b.* INTO v_branch
  FROM public.restaurant_branches b
  WHERE b.id=p_branch_id AND b.restaurant_id=p_restaurant_id
  FOR UPDATE;
  IF v_branch.id IS NULL THEN
    RAISE EXCEPTION 'Branch was not found for this restaurant' USING ERRCODE = '22023';
  END IF;
  IF v_branch.is_default THEN
    RAISE EXCEPTION 'The default branch is already the primary active branch' USING ERRCODE = '22023';
  END IF;
  IF v_branch.is_active AND v_branch.lifecycle_status='active' THEN
    RETURN jsonb_build_object('success',true,'already_active',true,'branch_id',p_branch_id,'lifecycle_status','active');
  END IF;
  IF v_branch.is_active OR v_branch.lifecycle_status<>'pending_activation' THEN
    RAISE EXCEPTION 'Only a branch pending final activation can be activated' USING ERRCODE = '22023';
  END IF;

  v_readiness := public.edmel_get_branch_setup_readiness(p_restaurant_id,p_branch_id);
  SELECT array_agg(coalesce(item->>'label',item->>'key','Required setup'))
  INTO v_blockers
  FROM jsonb_array_elements(coalesce(v_readiness->'items','[]'::jsonb)) AS rows(item)
  WHERE item->>'status'='Needs Attention';

  IF coalesce(array_length(v_blockers,1),0)>0 THEN
    RAISE EXCEPTION 'Branch setup is incomplete: %', array_to_string(v_blockers, ', ')
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.restaurant_branches
  SET is_active=true,
      lifecycle_status='active',
      updated_at=now()
  WHERE id=p_branch_id AND restaurant_id=p_restaurant_id;

  INSERT INTO public.audit_logs(
    restaurant_id,actor_user_id,actor_name,actor_role,
    action_category,action,record_type,record_id,result,details
  ) VALUES (
    p_restaurant_id,auth.uid(),v_actor_name,'owner',
    'Branch Management','Branch activated',
    'restaurant_branch',p_branch_id::text,'success',
    jsonb_build_object('branch_name',v_branch.name,'branch_code',v_branch.code,'previous_status','pending_activation')
  );

  RETURN jsonb_build_object('success',true,'branch_id',p_branch_id,'is_active',true,'lifecycle_status','active');
END;
$function$;

CREATE OR REPLACE FUNCTION public.edmel_deactivate_restaurant_branch(
  p_restaurant_slug text,
  p_branch_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_restaurant_id uuid;
  v_actor_name text;
  v_branch public.restaurant_branches%rowtype;
  v_active_branch_count integer;
  v_now timestamptz := now();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT r.id,
         coalesce(nullif(btrim(ru.display_name), ''),
                  nullif(btrim(ru.full_name), ''),
                  'Owner')
  INTO v_restaurant_id, v_actor_name
  FROM public.restaurants r
  JOIN public.restaurant_users ru ON ru.restaurant_id = r.id
  WHERE lower(btrim(r.slug)) = lower(btrim(p_restaurant_slug))
    AND ru.user_id = auth.uid()
    AND ru.is_active = true
    AND lower(ru.role) = 'owner'
  LIMIT 1;

  IF v_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'Owner access required for this restaurant';
  END IF;

  SELECT *
  INTO v_branch
  FROM public.restaurant_branches b
  WHERE b.id = p_branch_id
    AND b.restaurant_id = v_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Branch not found for this restaurant';
  END IF;
  IF v_branch.is_default THEN
    RAISE EXCEPTION 'The default branch cannot be deactivated';
  END IF;
  IF NOT v_branch.is_active THEN
    RETURN jsonb_build_object('success', true, 'already_deactivated', true);
  END IF;

  SELECT count(*)
  INTO v_active_branch_count
  FROM public.restaurant_branches b
  WHERE b.restaurant_id = v_restaurant_id
    AND b.is_active = true;

  IF v_active_branch_count <= 1 THEN
    RAISE EXCEPTION 'The only active branch cannot be deactivated';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.restaurant_id = v_restaurant_id
      AND o.branch_id = p_branch_id
      AND (
        lower(coalesce(o.status, o.order_status, 'pending'))
          NOT IN ('served', 'completed', 'voided', 'cancelled')
        OR lower(coalesce(o.payment_status, 'pending'))
          NOT IN ('paid', 'refunded')
      )
  ) THEN
    RAISE EXCEPTION 'This branch has unfinished or unsettled orders';
  END IF;

  UPDATE public.restaurant_branches
  SET is_active = false,
      lifecycle_status = 'deactivated',
      updated_at = v_now
  WHERE id = p_branch_id
    AND restaurant_id = v_restaurant_id;

  UPDATE public.staff_sessions
  SET logout_at = v_now,
      last_seen_at = v_now,
      end_reason = 'branch_deactivated'
  WHERE restaurant_id = v_restaurant_id
    AND branch_id = p_branch_id
    AND logout_at IS NULL;

  INSERT INTO public.audit_logs (
    restaurant_id, actor_user_id, actor_name, actor_role,
    action_category, action, record_type, record_id, result, details
  )
  VALUES (
    v_restaurant_id, auth.uid(), v_actor_name, 'owner',
    'Branch Management', 'Branch deactivated', 'restaurant_branch',
    p_branch_id::text, 'success',
    jsonb_build_object(
      'branch_name', v_branch.name,
      'branch_code', v_branch.code
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'branch_id', p_branch_id,
    'is_active', false,
    'lifecycle_status','deactivated',
    'active_sessions_closed', true
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_activate_restaurant_branch(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edmel_activate_restaurant_branch(uuid,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.edmel_review_branch_creation_request(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edmel_review_branch_creation_request(uuid,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.edmel_deactivate_restaurant_branch(text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edmel_deactivate_restaurant_branch(text,uuid) TO authenticated;
