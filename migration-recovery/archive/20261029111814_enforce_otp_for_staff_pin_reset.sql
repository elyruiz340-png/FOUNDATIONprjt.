
CREATE OR REPLACE FUNCTION public.verify_staff_pin_reset_otp(
  p_challenge_id uuid,
  p_owner_user_id uuid,
  p_otp_hash text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_challenge public.staff_pin_reset_otp_challenges%ROWTYPE;
BEGIN
  SELECT * INTO v_challenge
  FROM public.staff_pin_reset_otp_challenges
  WHERE id = p_challenge_id
    AND owner_user_id = p_owner_user_id
  FOR UPDATE;

  IF NOT FOUND THEN RETURN 'invalid'; END IF;
  IF v_challenge.consumed_at IS NOT NULL THEN RETURN 'used'; END IF;
  IF v_challenge.expires_at <= now() THEN RETURN 'expired'; END IF;
  IF v_challenge.attempts >= 5 THEN RETURN 'locked'; END IF;
  IF v_challenge.verified_at IS NOT NULL THEN RETURN 'verified'; END IF;

  IF v_challenge.otp_hash = p_otp_hash THEN
    UPDATE public.staff_pin_reset_otp_challenges
      SET verified_at = now()
      WHERE id = p_challenge_id;
    RETURN 'verified';
  END IF;

  UPDATE public.staff_pin_reset_otp_challenges
    SET attempts = attempts + 1
    WHERE id = p_challenge_id;
  RETURN 'invalid';
END;
$function$;

REVOKE ALL ON FUNCTION public.verify_staff_pin_reset_otp(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.verify_staff_pin_reset_otp(uuid, uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.reset_cashier_pin_with_otp(
  p_challenge_id uuid,
  p_new_pin text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_owner uuid;
  v_owner_restaurant uuid;
  v_target_restaurant uuid;
  v_target_role text;
  v_challenge public.staff_pin_reset_otp_challenges%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_new_pin IS NULL OR p_new_pin !~ '^[0-9]{6}$' THEN
    RAISE EXCEPTION 'PIN must be exactly 6 digits';
  END IF;

  SELECT user_id, restaurant_id
    INTO v_owner, v_owner_restaurant
  FROM public.restaurant_users
  WHERE user_id = auth.uid()
    AND lower(role) IN ('owner', 'admin')
  LIMIT 1;

  IF v_owner IS NULL OR v_owner_restaurant IS NULL THEN
    RAISE EXCEPTION 'Owner/Admin permission required';
  END IF;

  SELECT * INTO v_challenge
  FROM public.staff_pin_reset_otp_challenges
  WHERE id = p_challenge_id
    AND owner_user_id = auth.uid()
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'OTP verification required'; END IF;
  IF v_challenge.verified_at IS NULL THEN RAISE EXCEPTION 'OTP verification required'; END IF;
  IF v_challenge.consumed_at IS NOT NULL THEN RAISE EXCEPTION 'OTP has already been used'; END IF;
  IF v_challenge.expires_at <= now() THEN RAISE EXCEPTION 'OTP has expired'; END IF;
  IF v_challenge.restaurant_id <> v_owner_restaurant THEN
    RAISE EXCEPTION 'OTP belongs to a different restaurant';
  END IF;

  SELECT restaurant_id, lower(role)
    INTO v_target_restaurant, v_target_role
  FROM public.restaurant_users
  WHERE id = v_challenge.target_restaurant_user_id;

  IF v_target_role IS DISTINCT FROM 'staff' THEN
    RAISE EXCEPTION 'Staff account not found';
  END IF;
  IF v_target_restaurant IS DISTINCT FROM v_owner_restaurant THEN
    RAISE EXCEPTION 'Staff belongs to a different restaurant';
  END IF;

  UPDATE public.cashier_credentials
    SET pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf')),
        failed_attempts = 0,
        locked_at = NULL,
        updated_at = now()
  WHERE restaurant_user_id = v_challenge.target_restaurant_user_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'Staff PIN record not found'; END IF;

  UPDATE public.staff_pin_reset_otp_challenges
    SET consumed_at = now()
  WHERE id = p_challenge_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.reset_cashier_pin_with_otp(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reset_cashier_pin_with_otp(uuid, text) TO authenticated, service_role;

-- Close the old authenticated paths so OTP cannot be bypassed with direct RPC calls.
REVOKE EXECUTE ON FUNCTION public.reset_cashier_pin_for_user(uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.set_cashier_pin_for_user(uuid, text) FROM authenticated;
