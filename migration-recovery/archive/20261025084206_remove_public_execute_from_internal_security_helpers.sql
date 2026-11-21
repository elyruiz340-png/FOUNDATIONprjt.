REVOKE EXECUTE ON FUNCTION public.current_user_restaurant_id() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.is_system_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_user_restaurant_id() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_system_admin() TO authenticated, service_role;

-- Keep order submission RPC callable by anon for the existing public QR ordering page.
-- Remove only the implicit PUBLIC grant, then explicitly grant the roles required by current clients.
REVOKE EXECUTE ON FUNCTION public.place_order_with_stock(uuid,text,text,jsonb,numeric,text,text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.place_order_with_stock(uuid,text,text,jsonb,numeric,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.place_order_with_stock(uuid,text,text,jsonb,numeric,text,text,text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.place_order_with_stock(uuid,text,text,jsonb,numeric,text,text,text,text) TO anon, authenticated, service_role;
