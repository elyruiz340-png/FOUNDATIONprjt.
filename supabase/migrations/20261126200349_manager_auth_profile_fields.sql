-- EDMEL Manager Authentication foundation
-- Additive only: legacy staff and Manager accounts remain PIN-based.
ALTER TABLE public.restaurant_users
  ADD COLUMN IF NOT EXISTS manager_auth_method text NOT NULL DEFAULT 'pin',
  ADD COLUMN IF NOT EXISTS manager_email text,
  ADD COLUMN IF NOT EXISTS manager_email_verified_at timestamptz,
  ADD COLUMN IF NOT EXISTS manager_can_change_pin boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS manager_can_change_password boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS manager_auth_setup_status text NOT NULL DEFAULT 'not_required';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.restaurant_users'::regclass
      AND conname = 'restaurant_users_manager_auth_method_check'
  ) THEN
    ALTER TABLE public.restaurant_users
      ADD CONSTRAINT restaurant_users_manager_auth_method_check
      CHECK (manager_auth_method IN ('pin', 'password'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.restaurant_users'::regclass
      AND conname = 'restaurant_users_manager_auth_setup_status_check'
  ) THEN
    ALTER TABLE public.restaurant_users
      ADD CONSTRAINT restaurant_users_manager_auth_setup_status_check
      CHECK (manager_auth_setup_status IN ('not_required', 'pending', 'active', 'failed'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.restaurant_users'::regclass
      AND conname = 'restaurant_users_manager_email_format_check'
  ) THEN
    ALTER TABLE public.restaurant_users
      ADD CONSTRAINT restaurant_users_manager_email_format_check
      CHECK (
        manager_email IS NULL OR
        (length(manager_email) <= 254 AND manager_email = btrim(manager_email)
         AND manager_email ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$')
      );
  END IF;
END
$$;

COMMENT ON COLUMN public.restaurant_users.manager_auth_method IS
  'Assigned Manager login method. Legacy accounts default to PIN.';
COMMENT ON COLUMN public.restaurant_users.manager_email IS
  'Verified contact/login email for Manager authentication and recovery; nullable for legacy accounts.';
COMMENT ON COLUMN public.restaurant_users.manager_email_verified_at IS
  'Timestamp when the Manager email was verified.';
COMMENT ON COLUMN public.restaurant_users.manager_can_change_pin IS
  'Owner/Admin-controlled permission for Manager self-service PIN changes.';
COMMENT ON COLUMN public.restaurant_users.manager_can_change_password IS
  'Owner/Admin-controlled permission for Manager self-service password changes.';
COMMENT ON COLUMN public.restaurant_users.manager_auth_setup_status IS
  'Manager password onboarding state; legacy PIN accounts use not_required.';
