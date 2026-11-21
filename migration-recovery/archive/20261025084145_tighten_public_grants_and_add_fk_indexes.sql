-- Remove implicit PUBLIC execute grants from authorization helpers.
REVOKE ALL ON FUNCTION public.current_user_restaurant_id() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_system_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_restaurant_id() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_system_admin() TO authenticated, service_role;

-- Prevent browser roles from destructive table-level operations.
-- Keep SELECT/INSERT/UPDATE where existing policies may support current customer/cashier flows.
REVOKE DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE
  public."Orders", public."PRODUCT_STOCK", public."T A B L E S",
  public.cashier_pin, public.cashier_security, public.cashier_credentials,
  public.daily_order_counters, public.menu_categories, public.menu_items,
  public.order_items, public.orders, public.payments, public.reservations,
  public.restaurant_tables, public.restaurants
FROM anon, authenticated;

-- Index foreign-key columns flagged by Supabase performance advisor.
CREATE INDEX IF NOT EXISTS idx_order_items_menu_item_id ON public.order_items(menu_item_id);
CREATE INDEX IF NOT EXISTS idx_orders_table_id ON public.orders(table_id);
CREATE INDEX IF NOT EXISTS idx_payments_restaurant_id ON public.payments(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_users_restaurant_id ON public.restaurant_users(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_users_user_id ON public.restaurant_users(user_id);

-- Avoid per-row re-evaluation of auth identity in existing policies.
DROP POLICY IF EXISTS "Users can view own restaurant link" ON public.restaurant_users;
CREATE POLICY "Users can view own restaurant link" ON public.restaurant_users
FOR SELECT TO authenticated
USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Owner can manage cashier PIN" ON public.cashier_pin;
CREATE POLICY "Owner can manage cashier PIN" ON public.cashier_pin
FOR ALL TO authenticated
USING ((select auth.email()) = 'halinabistrocafe101@gmail.com')
WITH CHECK ((select auth.email()) = 'halinabistrocafe101@gmail.com');