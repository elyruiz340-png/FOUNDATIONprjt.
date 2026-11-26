-- Fix the email validation expression in the Manager authentication foundation.
ALTER TABLE public.restaurant_users
  DROP CONSTRAINT IF EXISTS restaurant_users_manager_email_format_check;

ALTER TABLE public.restaurant_users
  ADD CONSTRAINT restaurant_users_manager_email_format_check
  CHECK (
    manager_email IS NULL OR
    (length(manager_email) <= 254 AND manager_email = btrim(manager_email)
     AND manager_email ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$')
  );
