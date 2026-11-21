
ALTER TABLE public.restaurant_users
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS deactivated_at timestamptz,
  ADD COLUMN IF NOT EXISTS deactivated_by uuid;

CREATE TABLE IF NOT EXISTS public.staff_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  restaurant_user_id uuid NOT NULL REFERENCES public.restaurant_users(id) ON DELETE RESTRICT,
  user_id uuid NOT NULL,
  login_at timestamptz NOT NULL DEFAULT now(),
  logout_at timestamptz,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  end_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT staff_sessions_end_reason_check
    CHECK (end_reason IS NULL OR end_reason IN ('logout','session_expired','deactivated','unknown'))
);

CREATE INDEX IF NOT EXISTS staff_sessions_restaurant_login_idx
  ON public.staff_sessions (restaurant_id, login_at DESC);
CREATE INDEX IF NOT EXISTS staff_sessions_staff_login_idx
  ON public.staff_sessions (restaurant_user_id, login_at DESC);
CREATE INDEX IF NOT EXISTS staff_sessions_active_idx
  ON public.staff_sessions (restaurant_id, last_seen_at DESC)
  WHERE logout_at IS NULL;

ALTER TABLE public.staff_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Owners and admins can view staff session history" ON public.staff_sessions;
CREATE POLICY "Owners and admins can view staff session history"
  ON public.staff_sessions FOR SELECT
  USING (public.can_view_restaurant_users(restaurant_id));

REVOKE ALL ON TABLE public.staff_sessions FROM anon, authenticated;
GRANT SELECT ON TABLE public.staff_sessions TO authenticated;

CREATE OR REPLACE FUNCTION public.verify_cashier_login_credentials(p_username text, p_pin text)
RETURNS TABLE(cashier_user_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id UUID;
  v_restaurant_user_id UUID;
  v_pin_hash TEXT;
  v_failed_attempts INTEGER;
  v_locked_at TIMESTAMPTZ;
BEGIN
  IF p_username IS NULL
     OR LENGTH(TRIM(p_username)) = 0
     OR p_pin IS NULL
     OR p_pin !~ '^[0-9]{6}$'
  THEN
    RETURN;
  END IF;

  SELECT ru.id, ru.user_id, cc.pin_hash, cc.failed_attempts, cc.locked_at
  INTO v_restaurant_user_id, v_user_id, v_pin_hash, v_failed_attempts, v_locked_at
  FROM public.restaurant_users AS ru
  JOIN public.cashier_credentials AS cc ON cc.restaurant_user_id = ru.id
  WHERE LOWER(ru.cashier_username) = LOWER(TRIM(p_username))
    AND LOWER(ru.role) = 'staff'
    AND ru.is_active = true
  FOR UPDATE OF cc;

  IF NOT FOUND OR v_locked_at IS NOT NULL OR v_pin_hash IS NULL THEN
    RETURN;
  END IF;

  IF extensions.crypt(p_pin, v_pin_hash) = v_pin_hash THEN
    UPDATE public.cashier_credentials
    SET failed_attempts = 0, locked_at = NULL, updated_at = NOW()
    WHERE restaurant_user_id = v_restaurant_user_id;
    RETURN QUERY SELECT v_user_id;
    RETURN;
  END IF;

  UPDATE public.cashier_credentials
  SET failed_attempts = LEAST(COALESCE(v_failed_attempts, 0) + 1, 5),
      locked_at = CASE WHEN COALESCE(v_failed_attempts, 0) + 1 >= 5 THEN NOW() ELSE NULL END,
      updated_at = NOW()
  WHERE restaurant_user_id = v_restaurant_user_id;

  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public.verify_cashier_login_credentials(text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.verify_cashier_login_credentials(text,text) TO service_role;
