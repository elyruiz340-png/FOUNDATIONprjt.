-- Restrict direct API access to internal/security tables. Existing rows are preserved.
REVOKE ALL PRIVILEGES ON TABLE public.cashier_credentials, public.cashier_security, public.cashier_pin, public.daily_order_counters FROM anon, authenticated;
REVOKE ALL PRIVILEGES ON TABLE public.order_items, public.payments, public.reservations FROM anon, authenticated;
REVOKE ALL PRIVILEGES ON TABLE public."Orders" FROM anon, authenticated;
REVOKE ALL PRIVILEGES ON TABLE public.restaurants, public.restaurant_tables, public.menu_categories, public.menu_items FROM anon, authenticated;

-- Public ordering requires read-only access to active restaurant/menu/table data.
GRANT SELECT ON TABLE public.restaurants, public.restaurant_tables, public.menu_categories, public.menu_items TO anon;
GRANT SELECT ON TABLE public.restaurants, public.restaurant_tables, public.menu_categories, public.menu_items TO authenticated;

DROP POLICY IF EXISTS "Public can view restaurants" ON public.restaurants;
CREATE POLICY "Public can view restaurants" ON public.restaurants FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "Public can view active restaurant tables" ON public.restaurant_tables;
CREATE POLICY "Public can view active restaurant tables" ON public.restaurant_tables FOR SELECT TO anon, authenticated USING (is_active = true);

DROP POLICY IF EXISTS "Public can view active menu categories" ON public.menu_categories;
CREATE POLICY "Public can view active menu categories" ON public.menu_categories FOR SELECT TO anon, authenticated USING (is_active = true);

DROP POLICY IF EXISTS "Public can view available menu items" ON public.menu_items;
CREATE POLICY "Public can view available menu items" ON public.menu_items FOR SELECT TO anon, authenticated USING (is_available = true);

-- Restrict elevated API privileges on legacy cashier/order tables to only the operations currently
-- explicitly allowed by their RLS policies; do not remove the existing cashier/customer workflow.
REVOKE DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE public."PRODUCT_STOCK", public."T A B L E S", public.orders FROM anon, authenticated;
REVOKE INSERT, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE public."PRODUCT_STOCK", public."T A B L E S", public.orders FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE public."PRODUCT_STOCK", public."T A B L E S" FROM authenticated;

-- No direct API access to daily sequence counters; the SECURITY DEFINER trigger function owns updates.
