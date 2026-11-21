CREATE TABLE IF NOT EXISTS public.staff_pin_reset_otp_challenges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  target_restaurant_user_id uuid NOT NULL,
  otp_hash text NOT NULL,
  expires_at timestamptz NOT NULL,
  attempts smallint NOT NULL DEFAULT 0 CHECK (attempts >= 0 AND attempts <= 5),
  verified_at timestamptz,
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_sent_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS staff_pin_reset_otp_owner_created_idx
  ON public.staff_pin_reset_otp_challenges (owner_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS staff_pin_reset_otp_target_idx
  ON public.staff_pin_reset_otp_challenges (target_restaurant_user_id, created_at DESC);

ALTER TABLE public.staff_pin_reset_otp_challenges ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.staff_pin_reset_otp_challenges FROM PUBLIC;
REVOKE ALL ON TABLE public.staff_pin_reset_otp_challenges FROM anon;
REVOKE ALL ON TABLE public.staff_pin_reset_otp_challenges FROM authenticated;
GRANT ALL ON TABLE public.staff_pin_reset_otp_challenges TO service_role;