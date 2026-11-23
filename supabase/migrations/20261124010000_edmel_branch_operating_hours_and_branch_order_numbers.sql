-- EDMEL: branch-owned operating hours and branch-scoped operating-day order numbers.
-- Existing orders and their historical order_number values are never rewritten.

CREATE OR REPLACE FUNCTION private.edmel_valid_branch_operating_hours(p_hours jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $function$
DECLARE
  v_day text;
  v_days text[] := ARRAY['sunday','monday','tuesday','wednesday','thursday','friday','saturday'];
BEGIN
  IF p_hours IS NULL OR jsonb_typeof(p_hours) <> 'object' THEN RETURN false; END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_object_keys(p_hours) AS keys(key)
    WHERE NOT (keys.key = ANY(v_days))
  ) THEN RETURN false; END IF;

  FOREACH v_day IN ARRAY v_days LOOP
    IF NOT (p_hours ? v_day)
       OR jsonb_typeof(p_hours->v_day) <> 'object'
       OR jsonb_typeof(p_hours->v_day->'is_open') <> 'boolean'
       OR jsonb_typeof(p_hours->v_day->'open_time') <> 'string'
       OR jsonb_typeof(p_hours->v_day->'close_time') <> 'string'
       OR (p_hours->v_day->>'open_time') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
       OR (p_hours->v_day->>'close_time') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
      RETURN false;
    END IF;
  END LOOP;
  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION private.edmel_valid_branch_operating_hours(jsonb) FROM PUBLIC, anon, authenticated;

ALTER TABLE public.restaurant_branches
  ADD COLUMN IF NOT EXISTS operating_hours jsonb NOT NULL DEFAULT '{}'::jsonb;

-- Each existing branch receives a one-time copy of the current restaurant schedule.
-- From this migration onward, branch schedules are stored and edited independently.
UPDATE public.restaurant_branches b
SET operating_hours = COALESCE(r.operating_hours, '{}'::jsonb)
FROM public.restaurants r
WHERE r.id = b.restaurant_id
  AND (b.operating_hours IS NULL OR b.operating_hours = '{}'::jsonb);

DO $constraint$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.restaurant_branches'::regclass
      AND conname = 'restaurant_branches_operating_hours_object'
  ) THEN
    ALTER TABLE public.restaurant_branches
      ADD CONSTRAINT restaurant_branches_operating_hours_object
      CHECK (jsonb_typeof(operating_hours) = 'object');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.restaurant_branches b
    WHERE NOT private.edmel_valid_branch_operating_hours(b.operating_hours)
  ) THEN
    RAISE EXCEPTION 'A branch has invalid operating_hours. Correct the restaurant schedule before applying this migration.';
  END IF;
END;
$constraint$;

COMMENT ON COLUMN public.restaurant_branches.operating_hours
IS 'Branch-owned weekly operating schedule. A new branch receives a one-time copy of the default branch schedule; subsequent changes are independent.';

CREATE OR REPLACE FUNCTION private.edmel_branch_operating_hours_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_hours jsonb;
  v_closed jsonb := jsonb_build_object(
    'sunday',jsonb_build_object('is_open',false,'open_time','09:00','close_time','17:00'),
    'monday',jsonb_build_object('is_open',false,'open_time','09:00','close_time','17:00'),
    'tuesday',jsonb_build_object('is_open',false,'open_time','09:00','close_time','17:00'),
    'wednesday',jsonb_build_object('is_open',false,'open_time','09:00','close_time','17:00'),
    'thursday',jsonb_build_object('is_open',false,'open_time','09:00','close_time','17:00'),
    'friday',jsonb_build_object('is_open',false,'open_time','09:00','close_time','17:00'),
    'saturday',jsonb_build_object('is_open',false,'open_time','09:00','close_time','17:00')
  );
BEGIN
  IF NEW.operating_hours IS NULL OR NEW.operating_hours = '{}'::jsonb THEN
    -- Additional branches copy the default branch once; the default branch
    -- itself starts from the restaurant's current schedule.
    SELECT b.operating_hours INTO v_hours
    FROM public.restaurant_branches b
    WHERE b.restaurant_id = NEW.restaurant_id
      AND b.is_default = true
      AND b.is_active = true
    ORDER BY b.created_at
    LIMIT 1;

    IF v_hours IS NULL THEN
      SELECT r.operating_hours INTO v_hours
      FROM public.restaurants r
      WHERE r.id = NEW.restaurant_id;
    END IF;

    NEW.operating_hours := COALESCE(v_hours, v_closed);
  END IF;

  IF NOT private.edmel_valid_branch_operating_hours(NEW.operating_hours) THEN
    NEW.operating_hours := v_closed;
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.edmel_branch_operating_hours_before_insert() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS edmel_branch_operating_hours_before_insert ON public.restaurant_branches;
CREATE TRIGGER edmel_branch_operating_hours_before_insert
BEFORE INSERT ON public.restaurant_branches
FOR EACH ROW
EXECUTE FUNCTION private.edmel_branch_operating_hours_before_insert();

-- Add branch_id to the counter while preserving any existing counter rows.
ALTER TABLE public.restaurant_daily_order_counters
  ADD COLUMN IF NOT EXISTS branch_id uuid;

UPDATE public.restaurant_daily_order_counters c
SET branch_id = COALESCE(
  (
    SELECT b.id FROM public.restaurant_branches b
    WHERE b.restaurant_id = c.restaurant_id AND b.is_default = true AND b.is_active = true
    ORDER BY b.created_at LIMIT 1
  ),
  (
    SELECT b.id FROM public.restaurant_branches b
    WHERE b.restaurant_id = c.restaurant_id AND b.is_active = true
    ORDER BY b.created_at LIMIT 1
  )
)
WHERE c.branch_id IS NULL;

DO $counter_check$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.restaurant_daily_order_counters
    WHERE branch_id IS NULL
  ) THEN
    RAISE EXCEPTION 'Cannot associate an existing daily order counter with an active branch.';
  END IF;
END;
$counter_check$;

ALTER TABLE public.restaurant_daily_order_counters
  ALTER COLUMN branch_id SET NOT NULL;

ALTER TABLE public.restaurant_daily_order_counters
  DROP CONSTRAINT IF EXISTS restaurant_daily_order_counters_pkey;

ALTER TABLE public.restaurant_daily_order_counters
  ADD CONSTRAINT restaurant_daily_order_counters_pkey
  PRIMARY KEY (restaurant_id, branch_id, operating_date);

ALTER TABLE public.restaurant_daily_order_counters
  DROP CONSTRAINT IF EXISTS restaurant_daily_order_counters_branch_restaurant_fkey;

ALTER TABLE public.restaurant_daily_order_counters
  ADD CONSTRAINT restaurant_daily_order_counters_branch_restaurant_fkey
  FOREIGN KEY (branch_id, restaurant_id)
  REFERENCES public.restaurant_branches(id, restaurant_id)
  ON DELETE RESTRICT;

-- Resolve business profile hours/timezone from the selected branch, not the tenant master.
DO $patch_branch_profile$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := pg_get_functiondef('public.edmel_get_branch_setting_config(uuid,uuid,text)'::regprocedure);
  v_old := $old$
    select jsonb_set(
      jsonb_set(v_effective,'{restaurant,address}',coalesce(to_jsonb(b.address),'null'::jsonb),true),
      '{restaurant,timezone}',to_jsonb(b.timezone),true
    ) into v_effective
    from public.restaurant_branches b
    where b.id=p_branch_id and b.restaurant_id=p_restaurant_id and b.is_active=true;
$old$;
  v_new := $new$
    select jsonb_set(
      jsonb_set(
        jsonb_set(v_effective,'{restaurant,address}',coalesce(to_jsonb(b.address),'null'::jsonb),true),
        '{restaurant,timezone}',to_jsonb(b.timezone),true
      ),
      '{restaurant,operating_hours}',coalesce(b.operating_hours,'{}'::jsonb),true
    ) into v_effective
    from public.restaurant_branches b
    where b.id=p_branch_id and b.restaurant_id=p_restaurant_id and b.is_active=true;
$new$;
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not safely patch branch settings resolver for branch-owned operating hours.';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;
END;
$patch_branch_profile$;

-- Validate weekly schedules centrally; allow overnight shifts where close_time is earlier than open_time.
CREATE OR REPLACE FUNCTION public.edmel_create_restaurant_branch_configured_with_hours(
  p_restaurant_slug text,
  p_name text,
  p_code text,
  p_address text,
  p_timezone text,
  p_operating_hours jsonb,
  p_settings_modes jsonb DEFAULT '{}'::jsonb,
  p_menu_catalog_mode text DEFAULT 'inherit'
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
  v_actor_name text;
BEGIN
  IF NOT private.edmel_valid_branch_operating_hours(p_operating_hours) THEN
    RAISE EXCEPTION 'Enter valid opening and closing times for all seven days.' USING errcode='22023';
  END IF;

  v_result := public.edmel_create_restaurant_branch_configured(
    p_restaurant_slug,p_name,p_code,p_address,p_timezone,p_settings_modes,p_menu_catalog_mode
  );
  v_branch_id := (v_result#>>'{branch,id}')::uuid;

  UPDATE public.restaurant_branches
  SET operating_hours = p_operating_hours, updated_at = now()
  WHERE id = v_branch_id
  RETURNING restaurant_id INTO v_restaurant_id;

  SELECT COALESCE(NULLIF(BTRIM(ru.display_name),''),NULLIF(BTRIM(ru.full_name),''),'Owner')
  INTO v_actor_name
  FROM public.restaurant_users ru
  WHERE ru.restaurant_id = v_restaurant_id
    AND ru.user_id = auth.uid()
    AND ru.is_active = true
    AND lower(ru.role) = 'owner'
  LIMIT 1;

  INSERT INTO public.audit_logs(
    restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
    record_type,record_id,result,details
  ) VALUES (
    v_restaurant_id,auth.uid(),COALESCE(v_actor_name,'Owner'),'owner',
    'Branch Management','Branch operating hours initialized',
    'restaurant_branch',v_branch_id::text,'success',
    jsonb_build_object('operating_hours',p_operating_hours)
  );

  RETURN v_result || jsonb_build_object('operating_hours',p_operating_hours);
END;
$function$;

CREATE OR REPLACE FUNCTION public.edmel_update_restaurant_branch_configured_with_hours(
  p_restaurant_slug text,
  p_branch_id uuid,
  p_name text,
  p_code text,
  p_address text,
  p_timezone text,
  p_operating_hours jsonb,
  p_settings_modes jsonb DEFAULT '{}'::jsonb,
  p_menu_catalog_mode text DEFAULT 'inherit'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_result jsonb;
  v_restaurant_id uuid;
  v_actor_name text;
BEGIN
  IF NOT private.edmel_valid_branch_operating_hours(p_operating_hours) THEN
    RAISE EXCEPTION 'Enter valid opening and closing times for all seven days.' USING errcode='22023';
  END IF;

  v_result := public.edmel_update_restaurant_branch_configured(
    p_restaurant_slug,p_branch_id,p_name,p_code,p_address,p_timezone,p_settings_modes,p_menu_catalog_mode
  );
  v_restaurant_id := (v_result#>>'{branch,restaurant_id}')::uuid;

  UPDATE public.restaurant_branches
  SET operating_hours = p_operating_hours, updated_at = now()
  WHERE id = p_branch_id AND restaurant_id = v_restaurant_id;

  SELECT COALESCE(NULLIF(BTRIM(ru.display_name),''),NULLIF(BTRIM(ru.full_name),''),'Owner')
  INTO v_actor_name
  FROM public.restaurant_users ru
  WHERE ru.restaurant_id = v_restaurant_id
    AND ru.user_id = auth.uid()
    AND ru.is_active = true
    AND lower(ru.role) = 'owner'
  LIMIT 1;

  INSERT INTO public.audit_logs(
    restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
    record_type,record_id,result,details
  ) VALUES (
    v_restaurant_id,auth.uid(),COALESCE(v_actor_name,'Owner'),'owner',
    'Branch Management','Branch operating hours updated',
    'restaurant_branch',p_branch_id::text,'success',
    jsonb_build_object('operating_hours',p_operating_hours)
  );

  RETURN v_result || jsonb_build_object('operating_hours',p_operating_hours);
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_create_restaurant_branch_configured_with_hours(text,text,text,text,text,jsonb,jsonb,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.edmel_create_restaurant_branch_configured_with_hours(text,text,text,text,text,jsonb,jsonb,text) TO authenticated;
REVOKE ALL ON FUNCTION public.edmel_update_restaurant_branch_configured_with_hours(text,uuid,text,text,text,text,jsonb,jsonb,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.edmel_update_restaurant_branch_configured_with_hours(text,uuid,text,text,text,text,jsonb,jsonb,text) TO authenticated;

-- Branch-aware order number generation. Historical orders are not renumbered.
CREATE OR REPLACE FUNCTION public.generate_daily_order_number()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
DECLARE
  v_timezone text;
  v_operating_hours jsonb;
  v_local_now timestamp;
  v_local_date date;
  v_candidate_date date;
  v_day_name text;
  v_day_config jsonb;
  v_open_time time;
  v_operating_date date;
  v_operating_start timestamptz;
  v_existing_max bigint;
  v_next_number bigint;
  v_offset integer;
BEGIN
  IF NEW.restaurant_id IS NULL THEN
    RAISE EXCEPTION 'A restaurant_id is required to generate an order number';
  END IF;
  IF NEW.branch_id IS NULL THEN
    RAISE EXCEPTION 'A branch_id is required to generate an order number';
  END IF;

  SELECT COALESCE(NULLIF(BTRIM(b.timezone),''),'UTC'),b.operating_hours
  INTO v_timezone,v_operating_hours
  FROM public.restaurant_branches b
  WHERE b.id = NEW.branch_id
    AND b.restaurant_id = NEW.restaurant_id
    AND b.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'The selected active branch was not found while generating the order number';
  END IF;
  IF NOT private.edmel_valid_branch_operating_hours(v_operating_hours) THEN
    RAISE EXCEPTION 'The selected branch has invalid operating hours';
  END IF;

  v_local_now := now() AT TIME ZONE v_timezone;
  v_local_date := v_local_now::date;

  -- The operating date is the local calendar date of the latest opening
  -- that has already occurred for this branch.
  FOR v_offset IN 0..7 LOOP
    v_candidate_date := v_local_date - v_offset;
    v_day_name := lower(to_char(v_candidate_date,'FMDay'));
    v_day_config := v_operating_hours -> v_day_name;

    IF COALESCE((v_day_config->>'is_open')::boolean,false) THEN
      v_open_time := (v_day_config->>'open_time')::time;
      IF (v_candidate_date + v_open_time) <= v_local_now THEN
        v_operating_date := v_candidate_date;
        v_operating_start := (v_candidate_date + v_open_time) AT TIME ZONE v_timezone;
        EXIT;
      END IF;
    END IF;
  END LOOP;

  -- A schedule with no opening in the previous seven days falls back to local midnight.
  IF v_operating_date IS NULL THEN
    v_operating_date := v_local_date;
    v_operating_start := v_local_date::timestamp AT TIME ZONE v_timezone;
  END IF;

  SELECT COALESCE(MAX(o.order_number),0)
  INTO v_existing_max
  FROM public.orders o
  WHERE o.restaurant_id = NEW.restaurant_id
    AND o.branch_id = NEW.branch_id
    AND o.created_at >= v_operating_start;

  INSERT INTO public.restaurant_daily_order_counters(
    restaurant_id,branch_id,operating_date,last_number,updated_at
  )
  VALUES(
    NEW.restaurant_id,NEW.branch_id,v_operating_date,v_existing_max+1,now()
  )
  ON CONFLICT (restaurant_id,branch_id,operating_date)
  DO UPDATE SET
    last_number = GREATEST(
      public.restaurant_daily_order_counters.last_number,
      EXCLUDED.last_number - 1
    ) + 1,
    updated_at = now()
  RETURNING last_number INTO v_next_number;

  NEW.order_number := v_next_number;
  RETURN NEW;
END;
$function$;

-- Identity columns are populated before BEFORE INSERT triggers, so the old
-- WHEN (NEW.order_number IS NULL) condition skipped the generator.
DROP TRIGGER IF EXISTS set_daily_order_number ON public.orders;
CREATE TRIGGER set_daily_order_number
BEFORE INSERT ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.generate_daily_order_number();

COMMENT ON FUNCTION public.generate_daily_order_number()
IS 'Generates a branch-scoped order number for the branch local operating date, using branch timezone and independently stored operating hours.';
