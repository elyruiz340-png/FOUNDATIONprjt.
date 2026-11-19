-- EDMEL Manager expense approval workflow.
-- Existing expense records and audit history are preserved.

ALTER TABLE public.staff_branch_access
  ALTER COLUMN permissions SET DEFAULT '{}'::jsonb;

CREATE TABLE IF NOT EXISTS public.manager_expense_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  branch_id uuid NOT NULL REFERENCES public.restaurant_branches(id) ON DELETE RESTRICT,
  manager_restaurant_user_id uuid NOT NULL REFERENCES public.restaurant_users(id) ON DELETE RESTRICT,
  submitted_by_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  request_type text NOT NULL CHECK (request_type IN ('create','edit','void')),
  expense_id uuid NULL REFERENCES public.restaurant_expenses(id) ON DELETE RESTRICT,
  request_data jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(request_data) = 'object'),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  submitted_at timestamptz NOT NULL DEFAULT now(),
  reviewed_by_user_id uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  reviewed_at timestamptz NULL,
  review_reason text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT manager_expense_request_expense_requirement CHECK (
    (request_type = 'create' AND expense_id IS NULL)
    OR (request_type IN ('edit','void') AND expense_id IS NOT NULL)
  ),
  CONSTRAINT manager_expense_request_review_state CHECK (
    (status = 'pending' AND reviewed_by_user_id IS NULL AND reviewed_at IS NULL)
    OR (status IN ('approved','rejected') AND reviewed_by_user_id IS NOT NULL AND reviewed_at IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_manager_expense_requests_branch_status
  ON public.manager_expense_requests (restaurant_id, branch_id, status, submitted_at DESC);
CREATE INDEX IF NOT EXISTS idx_manager_expense_requests_submitter
  ON public.manager_expense_requests (submitted_by_user_id, submitted_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS idx_manager_expense_requests_one_pending_per_expense
  ON public.manager_expense_requests (expense_id)
  WHERE expense_id IS NOT NULL AND status = 'pending';

ALTER TABLE public.manager_expense_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.manager_expense_requests FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.manager_expense_requests TO authenticated;

DROP POLICY IF EXISTS manager_expense_requests_select_authorized
  ON public.manager_expense_requests;
CREATE POLICY manager_expense_requests_select_authorized
  ON public.manager_expense_requests
  FOR SELECT TO authenticated
  USING (
    public.edmel_is_restaurant_owner_admin(restaurant_id)
    OR (
      submitted_by_user_id = (SELECT auth.uid())
      AND public.edmel_expense_has_access(restaurant_id, branch_id, 'view')
    )
    OR public.edmel_expense_has_access(restaurant_id, branch_id, 'approve')
  );

-- A Manager cannot bypass a branch's approval policy by calling the older
-- expense RPCs directly. Explicit approvers may still approve another
-- Manager's request through the dedicated review RPC below.
CREATE OR REPLACE FUNCTION public.edmel_guard_manager_expense_policy()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_manager_id uuid;
  v_approval_required boolean := true;
  v_permission text := coalesce(nullif(current_setting('edmel.expense_permission', true), ''), '');
BEGIN
  SELECT ru.id INTO v_manager_id
  FROM public.restaurant_users ru
  WHERE ru.user_id = (SELECT auth.uid())
    AND ru.restaurant_id = NEW.restaurant_id
    AND coalesce(ru.is_active, true) = true
    AND lower(coalesce(ru.role,'')) = 'staff'
    AND lower(coalesce(ru.position,'')) = 'manager'
  ORDER BY ru.created_at DESC
  LIMIT 1;

  IF v_manager_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT coalesce((sba.permissions->>'expense_approval_required')::boolean, true)
    INTO v_approval_required
  FROM public.staff_branch_access sba
  WHERE sba.restaurant_user_id = v_manager_id
    AND sba.restaurant_id = NEW.restaurant_id
    AND sba.branch_id = NEW.branch_id
    AND sba.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'This Manager is not assigned to the expense branch.';
  END IF;

  IF v_permission = 'approve'
     AND public.edmel_expense_has_access(NEW.restaurant_id, NEW.branch_id, 'approve') THEN
    RETURN NEW;
  END IF;

  IF v_approval_required THEN
    RAISE EXCEPTION 'Manager expense approval is required. Submit an expense request for review.';
  END IF;

  IF TG_OP = 'INSERT' THEN
    NEW.status := 'approved';
    NEW.approved_by_user_id := (SELECT auth.uid());
    NEW.approved_at := now();
    NEW.approval_note := 'Automatically approved under branch policy; approval is not required.';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS manager_expense_policy_guard
  ON public.restaurant_expenses;
CREATE TRIGGER manager_expense_policy_guard
  BEFORE INSERT OR UPDATE ON public.restaurant_expenses
  FOR EACH ROW
  EXECUTE FUNCTION public.edmel_guard_manager_expense_policy();

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
  IF p_restaurant_id IS NULL OR p_branch_id IS NULL
     OR p_request_type NOT IN ('create','edit','void')
     OR jsonb_typeof(coalesce(p_request_data,'{}'::jsonb)) <> 'object' THEN
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

    IF v_category_id IS NULL OR v_description NOT BETWEEN '' AND '' THEN
      NULL;
    END IF;
    IF v_category_id IS NULL OR char_length(v_description) NOT BETWEEN 3 AND 500
       OR v_amount IS NULL OR v_amount <= 0
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
    IF EXISTS (
      SELECT 1 FROM public.manager_expense_requests r
      WHERE r.expense_id=p_expense_id AND r.status='pending'
    ) THEN RAISE EXCEPTION 'This expense already has a pending Manager request.'; END IF;
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
  IF p_decision NOT IN ('approved','rejected')
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
         OR v_amount IS NULL OR v_amount<=0 THEN
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
         OR v_amount IS NULL OR v_amount<=0 THEN
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

REVOKE ALL ON FUNCTION public.edmel_submit_manager_expense_request(uuid,uuid,text,uuid,jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.edmel_review_manager_expense_request(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edmel_submit_manager_expense_request(uuid,uuid,text,uuid,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edmel_review_manager_expense_request(uuid,text,text) TO authenticated;

-- Extend the existing permission-save RPC to accept the branch-level expense policy.
CREATE OR REPLACE FUNCTION public.edmel_admin_save_manager_branch_permissions(
  p_actor_user_id uuid,
  p_restaurant_id uuid,
  p_manager_id uuid,
  p_assignments jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor public.restaurant_users%ROWTYPE;
  v_manager public.restaurant_users%ROWTYPE;
  v_assignment jsonb;
  v_branch_id uuid;
  v_permissions jsonb;
  v_modules jsonb;
  v_module record;
  v_action record;
  v_entry record;
  v_branch_ids uuid[] := ARRAY[]::uuid[];
  v_branch_count integer := 0;
  v_actor_name text;
  v_manager_name text;
  v_branch_name text;
  v_allowed_modules text[] := ARRAY[
    'overview','sales','settings','orders','expenses','staff','audit','branches','health','ai',
    'inventory','tables','dispatcher','payments','menu','discounts','vouchers','tax',
    'service_charge','receipts','printers','transactions'
  ];
  v_allowed_actions text[] := ARRAY['view','create','edit','delete','approve','manage'];
  v_allowed_legacy text[] := ARRAY['orders','tables','stocks','dispatcher','settings','void'];
BEGIN
  IF p_actor_user_id IS NULL OR p_restaurant_id IS NULL OR p_manager_id IS NULL THEN
    RAISE EXCEPTION 'Missing required account context' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_assignments) <> 'array' OR jsonb_array_length(p_assignments) < 1
     OR jsonb_array_length(p_assignments) > 100 THEN
    RAISE EXCEPTION 'At least one valid branch assignment is required' USING ERRCODE = '22023';
  END IF;

  SELECT ru.* INTO v_actor
  FROM public.restaurant_users ru
  WHERE ru.user_id = p_actor_user_id
    AND ru.restaurant_id = p_restaurant_id
    AND ru.is_active = true
    AND lower(ru.role) IN ('owner','admin')
  ORDER BY CASE lower(ru.role) WHEN 'owner' THEN 1 ELSE 2 END
  LIMIT 1;
  IF v_actor.id IS NULL THEN
    RAISE EXCEPTION 'Active Owner or Admin access is required' USING ERRCODE = '42501';
  END IF;

  SELECT ru.* INTO v_manager
  FROM public.restaurant_users ru
  WHERE ru.id = p_manager_id
    AND ru.restaurant_id = p_restaurant_id
    AND ru.is_active = true
    AND lower(ru.role) = 'staff'
    AND lower(coalesce(ru.position,'')) = 'manager'
  FOR UPDATE;
  IF v_manager.id IS NULL THEN
    RAISE EXCEPTION 'Active Manager account not found in this restaurant' USING ERRCODE = '42501';
  END IF;

  FOR v_assignment IN SELECT value FROM jsonb_array_elements(p_assignments)
  LOOP
    IF jsonb_typeof(v_assignment) <> 'object'
       OR jsonb_typeof(v_assignment->'branch_id') <> 'string'
       OR jsonb_typeof(v_assignment->'permissions') <> 'object' THEN
      RAISE EXCEPTION 'Invalid branch permission assignment' USING ERRCODE = '22023';
    END IF;
    BEGIN
      v_branch_id := (v_assignment->>'branch_id')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'Invalid branch identifier' USING ERRCODE = '22023';
    END;
    IF v_branch_id = ANY(v_branch_ids) THEN
      RAISE EXCEPTION 'Duplicate branch assignment' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.restaurant_branches b
      WHERE b.id = v_branch_id AND b.restaurant_id = p_restaurant_id AND b.is_active = true
    ) THEN
      RAISE EXCEPTION 'A selected branch is not active in this restaurant' USING ERRCODE = '22023';
    END IF;

    v_permissions := v_assignment->'permissions';
    IF EXISTS (
      SELECT 1 FROM jsonb_object_keys(v_permissions) AS k(key)
      WHERE key <> ALL (ARRAY['modules','staff_management','approval_request_access','expense_approval_required','orders','tables','stocks','dispatcher','settings','void'])
    ) THEN
      RAISE EXCEPTION 'Unsupported permission field' USING ERRCODE = '22023';
    END IF;
    IF v_permissions ? 'staff_management' AND jsonb_typeof(v_permissions->'staff_management') <> 'boolean' THEN
      RAISE EXCEPTION 'Staff management authority must be boolean' USING ERRCODE = '22023';
    END IF;
    IF v_permissions ? 'approval_request_access' AND jsonb_typeof(v_permissions->'approval_request_access') <> 'boolean' THEN
      RAISE EXCEPTION 'Approval request access must be boolean' USING ERRCODE = '22023';
    END IF;
    IF v_permissions ? 'expense_approval_required' AND jsonb_typeof(v_permissions->'expense_approval_required') <> 'boolean' THEN
      RAISE EXCEPTION 'Expense approval policy must be boolean' USING ERRCODE = '22023';
    END IF;

    FOR v_entry IN
      SELECT key,value FROM jsonb_each(v_permissions)
      WHERE key = ANY(ARRAY['orders','tables','stocks','dispatcher','settings','void'])
    LOOP
      IF jsonb_typeof(v_entry.value) <> 'boolean' THEN
        RAISE EXCEPTION 'Legacy permission values must be boolean' USING ERRCODE = '22023';
      END IF;
    END LOOP;

    IF v_permissions ? 'modules' THEN
      v_modules := v_permissions->'modules';
      IF jsonb_typeof(v_modules) <> 'object' THEN
        RAISE EXCEPTION 'Module permissions must be an object' USING ERRCODE = '22023';
      END IF;
      FOR v_module IN SELECT key,value FROM jsonb_each(v_modules)
      LOOP
        IF NOT (v_module.key = ANY(v_allowed_modules)) OR jsonb_typeof(v_module.value) <> 'object' THEN
          RAISE EXCEPTION 'Unsupported module permission' USING ERRCODE = '22023';
        END IF;
        FOR v_action IN SELECT key,value FROM jsonb_each(v_module.value)
        LOOP
          IF NOT (v_action.key = ANY(v_allowed_actions)) OR jsonb_typeof(v_action.value) <> 'boolean' THEN
            RAISE EXCEPTION 'Unsupported module action' USING ERRCODE = '22023';
          END IF;
        END LOOP;
      END LOOP;
    END IF;

    v_branch_ids := array_append(v_branch_ids,v_branch_id);
    v_branch_count := v_branch_count + 1;
  END LOOP;

  v_actor_name := coalesce(nullif(btrim(v_actor.display_name),''),nullif(btrim(v_actor.full_name),''),nullif(btrim(v_actor.cashier_username),''),'Owner/Admin');
  v_manager_name := coalesce(nullif(btrim(v_manager.display_name),''),nullif(btrim(v_manager.full_name),''),nullif(btrim(v_manager.cashier_username),''),'Manager');

  UPDATE public.staff_branch_access sba
  SET is_active=false,updated_at=now()
  WHERE sba.restaurant_user_id=v_manager.id
    AND sba.restaurant_id=p_restaurant_id
    AND sba.is_active=true
    AND NOT (sba.branch_id=ANY(v_branch_ids));

  FOR v_assignment IN SELECT value FROM jsonb_array_elements(p_assignments)
  LOOP
    v_branch_id := (v_assignment->>'branch_id')::uuid;
    v_permissions := v_assignment->'permissions';
    INSERT INTO public.staff_branch_access (
      restaurant_user_id,restaurant_id,branch_id,permissions,is_active,created_by,updated_at
    ) VALUES (
      v_manager.id,p_restaurant_id,v_branch_id,v_permissions,true,p_actor_user_id,now()
    )
    ON CONFLICT (restaurant_user_id,branch_id)
    DO UPDATE SET restaurant_id=EXCLUDED.restaurant_id,permissions=EXCLUDED.permissions,
      is_active=true,updated_at=now();

    SELECT b.name INTO v_branch_name
    FROM public.restaurant_branches b
    WHERE b.id=v_branch_id AND b.restaurant_id=p_restaurant_id;

    INSERT INTO public.audit_logs (
      restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
      record_type,record_id,result,details
    ) VALUES (
      p_restaurant_id,p_actor_user_id,v_actor_name,lower(v_actor.role),
      'Staff & Security','Updated Manager branch permissions',
      'staff_branch_access',v_manager.id::text,'success',
      jsonb_build_object('manager_name',v_manager_name,'manager_username',coalesce(v_manager.cashier_username,''),
        'branch_id',v_branch_id,'branch_name',coalesce(v_branch_name,'Assigned branch'),
        'permissions',v_permissions)
    );
  END LOOP;

  RETURN jsonb_build_object('success',true,'manager_id',v_manager.id,
    'branches_saved',v_branch_count,'deactivated_unselected_assignments',true);
END;
$function$;
