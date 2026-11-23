-- Prevent direct calls to legacy branch writers that bypass catalog/inventory provisioning.
-- The configured owner-only wrappers call these functions as their SECURITY DEFINER owner.
REVOKE ALL ON FUNCTION public.edmel_create_restaurant_branch(text,text,text,text,text)
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.edmel_create_restaurant_branch_with_modes(text,text,text,text,text,jsonb)
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.edmel_update_restaurant_branch(text,uuid,text,text,text,text,jsonb)
  FROM PUBLIC,anon,authenticated;
