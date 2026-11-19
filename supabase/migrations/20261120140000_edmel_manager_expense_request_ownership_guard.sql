CREATE OR REPLACE FUNCTION public.edmel_submit_manager_expense_request(
  p_restaurant_id uuid,
  p_branch_id uuid,
  p_request_type text,
  p_expense_id uuid,
  p_request_data jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
  v_manager public.restaurant_users%ROWTYPE;
  v_expense public.restaurant_expenses%ROWTYPE;
  v_approval_required boolean := true;
  v_action text;
  v_category_id uuid;
  v_expense_date date;
  v_description text;
  v_amount numeric;
  v_payee text;
  v_reference text;
  v_notes text;
  v_reason text;
  v_expense_id uuid;
  v_request_id uuid;
  v_currency text;
  v_actor_name text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required.'; END IF;
  p_request_data := coalesce(p_request_data,'{}'::jsonb);
  IF p_restaurant_id IS NULL OR p_branch_id IS NULL
     OR p_request_type IS NULL OR p_request_type NOT IN ('create','edit','void')
     OR jsonb_typeof(p_request_data) <> 'object' OR pg_column_size(p_request_data)>16384 THEN
    RAISE EXCEPTION 'Invalid expense request.';
  END IF;

  SELECT ru.* INTO v_manager
  FROM public.restaurant_users ru
  WHERE ru.user_id = v_user_id
    AND ru.restaurant_id = p_restaurant_id
    AND lower(coalesce(ru.role,'')) = 'staff'
    AND lower(coalesce(ru.position,'')) = 'manager'
    AND coalesce(ru.is_active,true) = true
  ORDER BY ru.created_at DESC
  LIMIT 1;

  IF v_manager.id IS NULL THEN RAISE EXCEPTION 'Active Manager access is required.'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.restaurant_branches b
    WHERE b.id = p_branch_id AND b.restaurant_id = p_restaurant_id AND b.is_active = true
  ) THEN RAISE EXCEPTION 'The selected branch is not active in this restaurant.'; END IF;

  v_action := CASE p_request_type WHEN 'create' THEN 'create' WHEN 'edit' THEN 'edit' ELSE 'delete' END;
  IF NOT public.edmel_expense_has_access(p_restaurant_id,p_branch_id,v_action) THEN
    RAISE EXCEPTION 'You do not have permission for this expense action in the selected branch.';
  END IF;

  SELECT coalesce((sba.permissions->>'expense_approval_required')::boolean,true)
    INTO v_approval_required
  FROM public.staff_branch_access sba
  WHERE sba.restaurant_user_id=v_manager.id
    AND sba.restaurant_id=p_restaurant_id
    AND sba.branch_id=p_branch_id
    AND sba.is_active=true;
  IF NOT FOUND THEN RAISE EXCEPTION 'This branch is not assigned to the Manager.'; END IF;

  IF p_request_type IN ('create','edit') THEN
    BEGIN
      v_category_id := nullif(p_request_data->>'category_id','')::uuid;
      v_expense_date := coalesce(nullif(p_request_data->>'expense_date','')::date,current_date);
      v_amount := nullif(p_request_data->>'amount','')::numeric;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Expense category, date or amount is invalid.';
    END;
    v_description := btrim(coalesce(p_request_data->>'description',''));
    v_payee := nullif(btrim(coalesce(p_request_data->>'payee','')),'');
    v_reference := nullif(btrim(coalesce(p_request_data->>'reference_number','')),'');
    v_notes := nullif(btrim(coalesce(p_request_data->>'notes','')),'');
    v_reason := nullif(btrim(coalesce(p_request_data->>'reason','')),'');

    IF v_category_id IS NULL OR char_length(v_description) NOT BETWEEN 3 AND 500
       OR v_amount IS NULL OR v_amount::text IN ('NaN','Infinity','-Infinity') OR v_amount <= 0
       OR (v_notes IS NOT NULL AND char_length(v_notes)>2000)
       OR (p_request_type='edit' AND (v_reason IS NULL OR char_length(v_reason)<3 OR char_length(v_reason)>500)) THEN
      RAISE EXCEPTION 'Complete the required expense fields with valid values.';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.restaurant_expense_categories c
      WHERE c.id=v_category_id AND c.restaurant_id=p_restaurant_id AND c.is_active=true
    ) THEN RAISE EXCEPTION 'The selected expense category is unavailable.'; END IF;
  ELSE
    v_reason := nullif(btrim(coalesce(p_request_data->>'reason','')),'');
    IF v_reason IS NULL OR char_length(v_reason)<3 OR char_length(v_reason)>500 THEN
      RAISE EXCEPTION 'A reason between 3 and 500 characters is required.';
    END IF;
  END IF;

  IF p_request_type IN ('edit','void') THEN
    IF p_expense_id IS NULL THEN RAISE EXCEPTION 'An expense record is required.'; END IF;
    SELECT * INTO v_expense
    FROM public.restaurant_expenses e
    WHERE e.id=p_expense_id
      AND e.restaurant_id=p_restaurant_id
      AND e.branch_id=p_branch_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Expense record was not found in this branch.'; END IF;
    IF v_expense.status IN ('rejected','voided') THEN
      RAISE EXCEPTION 'Rejected or voided expenses cannot be changed.';
    END IF;
    IF p_request_type='edit' AND v_expense.status='pending'
       AND v_expense.created_by_user_id<>v_user_id
       AND NOT public.edmel_expense_has_access(p_restaurant_id,p_branch_id,'manage') THEN
      RAISE EXCEPTION 'You may only edit your own pending expense submission unless Manage permission is granted.';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.manager_expense_requests r
      WHERE r.expense_id=p_expense_id AND r.status='pending'
    ) THEN RAISE EXCEPTION 'This expense already has a pending Manager request.'; END IF;
    IF v_approval_required THEN
      p_request_data := p_request_data || jsonb_build_object('expected_updated_at',v_expense.updated_at);
    END IF;
  ELSIF p_expense_id IS NOT NULL THEN
    RAISE EXCEPTION 'A new expense request must not include an existing expense ID.';
  END IF;

  -- Direct-save policy: still requires the matching action permission.
  IF NOT v_approval_required THEN
    IF p_request_type='create' THEN
      SELECT r.currency INTO v_currency FROM public.restaurants r WHERE r.id=p_restaurant_id;
      IF v_currency IS NULL THEN RAISE EXCEPTION 'Restaurant currency could not be verified.'; END IF;
      PERFORM set_config('edmel.expense_permission','create',true);
      INSERT INTO public.restaurant_expenses (
        restaurant_id,branch_id,category_id,expense_date,description,payee,
        reference_number,notes,amount,currency_code,status,created_by_user_id,
        created_by_staff_id,approved_by_user_id,approved_at,approval_note
      ) VALUES (
        p_restaurant_id,p_branch_id,v_category_id,v_expense_date,v_description,v_payee,
        v_reference,v_notes,v_amount,upper(v_currency),'approved',v_user_id,
        v_manager.id,v_user_id,now(),'Automatically approved under branch policy; approval is not required.'
      ) RETURNING id INTO v_expense_id;
    ELSIF p_request_type='edit' THEN
      PERFORM set_config('edmel.expense_permission','edit',true);
      UPDATE public.restaurant_expenses
      SET category_id=v_category_id,expense_date=v_expense_date,description=v_description,
          payee=v_payee,reference_number=v_reference,notes=v_notes,amount=v_amount,
          last_change_reason=v_reason,updated_by_user_id=v_user_id,updated_at=now()
      WHERE id=p_expense_id;
      v_expense_id:=p_expense_id;
    ELSE
      PERFORM set_config('edmel.expense_permission','delete',true);
      UPDATE public.restaurant_expenses
      SET status='voided',voided_by_user_id=v_user_id,voided_at=now(),
          void_reason=v_reason,last_change_reason=v_reason,
          updated_by_user_id=v_user_id,updated_at=now()
      WHERE id=p_expense_id;
      v_expense_id:=p_expense_id;
    END IF;
    RETURN jsonb_build_object('success',true,'status','saved','direct_save',true,'expense_id',v_expense_id);
  END IF;

  INSERT INTO public.manager_expense_requests (
    restaurant_id,branch_id,manager_restaurant_user_id,submitted_by_user_id,
    request_type,expense_id,request_data
  ) VALUES (
    p_restaurant_id,p_branch_id,v_manager.id,v_user_id,
    p_request_type,p_expense_id,p_request_data
  ) RETURNING id INTO v_request_id;

  SELECT coalesce(nullif(v_manager.display_name,''),nullif(v_manager.full_name,''),nullif(v_manager.cashier_username,''),'Manager')
    INTO v_actor_name;
  INSERT INTO public.audit_logs (
    restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
    record_type,record_id,result,details
  ) VALUES (
    p_restaurant_id,v_user_id,coalesce(v_actor_name,'Manager'),'staff (Manager)',
    'Expenses & Profit','Submitted expense approval request',
    'manager_expense_request',v_request_id::text,'success',
    jsonb_build_object('branch_id',p_branch_id,'request_type',p_request_type,'expense_id',p_expense_id)
  );

  RETURN jsonb_build_object('success',true,'status','pending','direct_save',false,'request_id',v_request_id);
END;
$function$;


CREATE OR REPLACE FUNCTION public.edmel_review_manager_expense_request(
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
  v_user_id uuid := (SELECT auth.uid());
  v_request public.manager_expense_requests%ROWTYPE;
  v_expense public.restaurant_expenses%ROWTYPE;
  v_manager public.restaurant_users%ROWTYPE;
  v_owner_admin boolean;
  v_category_id uuid;
  v_expense_date date;
  v_description text;
  v_amount numeric;
  v_currency text;
  v_payee text;
  v_reference text;
  v_notes text;
  v_expense_id uuid;
  v_actor_name text;
  v_actor_role text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required.'; END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('approved','rejected')
     OR p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 3 AND 500 THEN
    RAISE EXCEPTION 'Choose approve or reject and provide a reason between 3 and 500 characters.';
  END IF;

  SELECT * INTO v_request
  FROM public.manager_expense_requests r
  WHERE r.id=p_request_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Expense approval request was not found.'; END IF;
  IF v_request.status<>'pending' THEN RAISE EXCEPTION 'This request has already been reviewed.'; END IF;
  IF v_request.submitted_by_user_id=v_user_id THEN RAISE EXCEPTION 'You cannot approve or reject your own expense request.'; END IF;

  v_owner_admin := public.edmel_is_restaurant_owner_admin(v_request.restaurant_id);
  IF NOT v_owner_admin AND NOT public.edmel_expense_has_access(v_request.restaurant_id,v_request.branch_id,'approve') THEN
    RAISE EXCEPTION 'You do not have approval permission for this branch.';
  END IF;

  SELECT ru.* INTO v_manager
  FROM public.restaurant_users ru
  WHERE ru.id=v_request.manager_restaurant_user_id
    AND ru.restaurant_id=v_request.restaurant_id;
  IF v_manager.id IS NULL THEN RAISE EXCEPTION 'The submitting Manager account could not be verified.'; END IF;

  IF NOT EXISTS (SELECT 1 FROM public.restaurant_branches b WHERE b.id=v_request.branch_id AND b.restaurant_id=v_request.restaurant_id AND b.is_active=true) THEN
    RAISE EXCEPTION 'The request branch is no longer active.';
  END IF;

  IF p_decision='approved' THEN
    PERFORM set_config('edmel.expense_permission','approve',true);
    IF v_request.request_type='create' THEN
      BEGIN
        v_category_id:=nullif(v_request.request_data->>'category_id','')::uuid;
        v_expense_date:=coalesce(nullif(v_request.request_data->>'expense_date','')::date,current_date);
        v_amount:=nullif(v_request.request_data->>'amount','')::numeric;
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'The submitted expense data is invalid.';
      END;
      v_description:=btrim(coalesce(v_request.request_data->>'description',''));
      v_payee:=nullif(btrim(coalesce(v_request.request_data->>'payee','')),'');
      v_reference:=nullif(btrim(coalesce(v_request.request_data->>'reference_number','')),'');
      v_notes:=nullif(btrim(coalesce(v_request.request_data->>'notes','')),'');
      IF v_category_id IS NULL OR char_length(v_description) NOT BETWEEN 3 AND 500
         OR v_amount IS NULL OR v_amount::text IN ('NaN','Infinity','-Infinity') OR v_amount<=0 THEN
        RAISE EXCEPTION 'The submitted expense data is incomplete or invalid.';
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM public.restaurant_expense_categories c
        WHERE c.id=v_category_id AND c.restaurant_id=v_request.restaurant_id AND c.is_active=true
      ) THEN RAISE EXCEPTION 'The submitted expense category is no longer active.'; END IF;
      SELECT r.currency INTO v_currency FROM public.restaurants r WHERE r.id=v_request.restaurant_id;
      IF v_currency IS NULL THEN RAISE EXCEPTION 'Restaurant currency could not be verified.'; END IF;
      INSERT INTO public.restaurant_expenses (
        restaurant_id,branch_id,category_id,expense_date,description,payee,
        reference_number,notes,amount,currency_code,status,created_by_user_id,
        created_by_staff_id,approved_by_user_id,approved_at,approval_note
      ) VALUES (
        v_request.restaurant_id,v_request.branch_id,v_category_id,v_expense_date,v_description,
        v_payee,v_reference,v_notes,v_amount,upper(v_currency),'approved',
        v_request.submitted_by_user_id,v_request.manager_restaurant_user_id,
        v_user_id,now(),btrim(p_reason)
      ) RETURNING id INTO v_expense_id;
    ELSIF v_request.request_type='edit' THEN
      SELECT * INTO v_expense
      FROM public.restaurant_expenses e
      WHERE e.id=v_request.expense_id
        AND e.restaurant_id=v_request.restaurant_id
        AND e.branch_id=v_request.branch_id
      FOR UPDATE;
      IF NOT FOUND OR v_expense.status IN ('rejected','voided') THEN
        RAISE EXCEPTION 'The expense can no longer be edited.';
      END IF;
      IF nullif(v_request.request_data->>'expected_updated_at','') IS NULL
         OR (v_request.request_data->>'expected_updated_at')::timestamptz IS DISTINCT FROM v_expense.updated_at THEN
        RAISE EXCEPTION 'This expense changed after the request was submitted. Refresh and submit the change again.';
      END IF;
      BEGIN
        v_category_id:=nullif(v_request.request_data->>'category_id','')::uuid;
        v_expense_date:=coalesce(nullif(v_request.request_data->>'expense_date','')::date,v_expense.expense_date);
        v_amount:=nullif(v_request.request_data->>'amount','')::numeric;
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'The submitted expense changes are invalid.';
      END;
      v_description:=btrim(coalesce(v_request.request_data->>'description',''));
      v_payee:=nullif(btrim(coalesce(v_request.request_data->>'payee','')),'');
      v_reference:=nullif(btrim(coalesce(v_request.request_data->>'reference_number','')),'');
      v_notes:=nullif(btrim(coalesce(v_request.request_data->>'notes','')),'');
      IF v_category_id IS NULL OR char_length(v_description) NOT BETWEEN 3 AND 500
         OR v_amount IS NULL OR v_amount::text IN ('NaN','Infinity','-Infinity') OR v_amount<=0 THEN
        RAISE EXCEPTION 'The submitted expense changes are incomplete or invalid.';
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM public.restaurant_expense_categories c
        WHERE c.id=v_category_id AND c.restaurant_id=v_request.restaurant_id AND c.is_active=true
      ) THEN RAISE EXCEPTION 'The requested expense category is no longer active.'; END IF;
      UPDATE public.restaurant_expenses
      SET category_id=v_category_id,expense_date=v_expense_date,description=v_description,
          payee=v_payee,reference_number=v_reference,notes=v_notes,amount=v_amount,
          last_change_reason='Manager change request approved: '||btrim(p_reason),
          updated_by_user_id=v_user_id,updated_at=now()
      WHERE id=v_request.expense_id;
      v_expense_id:=v_request.expense_id;
    ELSE
      SELECT * INTO v_expense
      FROM public.restaurant_expenses e
      WHERE e.id=v_request.expense_id
        AND e.restaurant_id=v_request.restaurant_id
        AND e.branch_id=v_request.branch_id
      FOR UPDATE;
      IF NOT FOUND OR v_expense.status='voided' THEN RAISE EXCEPTION 'The expense can no longer be voided.'; END IF;
      IF nullif(v_request.request_data->>'expected_updated_at','') IS NULL
         OR (v_request.request_data->>'expected_updated_at')::timestamptz IS DISTINCT FROM v_expense.updated_at THEN
        RAISE EXCEPTION 'This expense changed after the request was submitted. Refresh and submit the void again.';
      END IF;
      UPDATE public.restaurant_expenses
      SET status='voided',voided_by_user_id=v_user_id,voided_at=now(),
          void_reason=btrim(p_reason),last_change_reason='Manager void request approved: '||btrim(p_reason),
          updated_by_user_id=v_user_id,updated_at=now()
      WHERE id=v_request.expense_id;
      v_expense_id:=v_request.expense_id;
    END IF;
  END IF;

  UPDATE public.manager_expense_requests
  SET status=p_decision,reviewed_by_user_id=v_user_id,reviewed_at=now(),
      review_reason=btrim(p_reason),updated_at=now()
  WHERE id=p_request_id;

  SELECT coalesce(nullif(ru.display_name,''),nullif(ru.full_name,''),nullif(ru.cashier_username,''),'Approver'),
         lower(coalesce(ru.role,'staff'))
    INTO v_actor_name,v_actor_role
  FROM public.restaurant_users ru
  WHERE ru.user_id=v_user_id AND ru.restaurant_id=v_request.restaurant_id
    AND coalesce(ru.is_active,true)=true
  ORDER BY ru.created_at DESC LIMIT 1;

  INSERT INTO public.audit_logs (
    restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
    record_type,record_id,result,details
  ) VALUES (
    v_request.restaurant_id,v_user_id,coalesce(v_actor_name,'Approver'),coalesce(v_actor_role,'staff'),
    'Expenses & Profit',
    CASE p_decision WHEN 'approved' THEN 'Approved Manager expense request' ELSE 'Rejected Manager expense request' END,
    'manager_expense_request',p_request_id::text,'success',
    jsonb_build_object('branch_id',v_request.branch_id,'request_type',v_request.request_type,
      'expense_id',v_expense_id,'submitted_by_user_id',v_request.submitted_by_user_id,
      'reason',btrim(p_reason))
  );

  RETURN jsonb_build_object('success',true,'status',p_decision,'request_id',p_request_id,'expense_id',v_expense_id);
END;
$function$;

