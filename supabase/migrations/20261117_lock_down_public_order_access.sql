-- EDMEL POS: close legacy anonymous order access after customer page moved to secure RPC.
-- Authenticated staff dashboards retain their existing policies and privileges.

DROP POLICY IF EXISTS "Customers can submit orders" ON public.orders;
DROP POLICY IF EXISTS "Customers can view submitted orders" ON public.orders;

REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLE public.orders FROM PUBLIC, anon;

REVOKE ALL ON FUNCTION public.place_order_with_stock(uuid,text,text,jsonb,numeric,text,text,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.place_order_with_stock(uuid,text,text,jsonb,numeric,text,text,text,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.place_order_with_stock(uuid,text,text,jsonb,numeric,text,text,text,text,uuid) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.halina_finish_shared_cart_checkout(uuid,text,boolean) FROM PUBLIC, anon, authenticated;

DROP POLICY IF EXISTS "Allow cashier to update tables" ON public."T A B L E S";
REVOKE UPDATE ON TABLE public."T A B L E S" FROM PUBLIC, anon;
