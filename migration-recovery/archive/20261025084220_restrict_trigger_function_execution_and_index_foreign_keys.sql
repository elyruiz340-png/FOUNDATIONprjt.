-- Trigger functions are invoked by PostgreSQL triggers; API roles do not need direct EXECUTE access.
REVOKE EXECUTE ON FUNCTION public.update_updated_at_column() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.generate_daily_order_number() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM PUBLIC, anon, authenticated;

-- Cover foreign-key columns flagged by the Supabase performance advisor.
CREATE INDEX IF NOT EXISTS idx_order_items_menu_item_id_fk ON public.order_items(menu_item_id);
CREATE INDEX IF NOT EXISTS idx_orders_table_id_fk ON public.orders(table_id);
CREATE INDEX IF NOT EXISTS idx_payments_restaurant_id_fk ON public.payments(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_users_restaurant_id_fk ON public.restaurant_users(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_users_user_id_fk ON public.restaurant_users(user_id);

-- Optimize existing RLS policy expressions.
DROP POLICY IF EXISTS "Users can view own restaurant link" ON public.restaurant_users;
CREATE POLICY "Users can view own restaurant link" ON public.restaurant_users
FOR SELECT TO authenticated USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Owner can manage cashier PIN" ON public.cashier_pin;
CREATE POLICY "Owner can manage cashier PIN" ON public.cashier_pin
FOR ALL TO authenticated
USING ((select auth.email()) = 'halinabistrocafe101@gmail.com')
WITH CHECK ((select auth.email()) = 'halinabistrocafe101@gmail.com');
