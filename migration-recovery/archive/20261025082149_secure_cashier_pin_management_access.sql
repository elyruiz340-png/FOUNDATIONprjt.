CREATE OR REPLACE FUNCTION public.set_cashier_pin(new_pin text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  IF auth.uid() IS NULL
     OR auth.email() IS DISTINCT FROM 'halinabistrocafe101@gmail.com' THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF new_pin !~ '^[0-9]{6}$' THEN
    RAISE EXCEPTION 'PIN must be exactly 6 digits';
  END IF;

  DELETE FROM public.cashier_pin WHERE true;

  INSERT INTO public.cashier_pin (pin_hash)
  VALUES (
    extensions.crypt(
      new_pin,
      extensions.gen_salt('bf')
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.set_cashier_pin(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_cashier_pin(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_cashier_pin(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_cashier_pin(text) TO service_role;