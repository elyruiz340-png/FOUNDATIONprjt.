-- Cover the composite branch/tenant foreign key used by branch-scoped order counters.
CREATE INDEX IF NOT EXISTS restaurant_daily_order_counters_branch_fk_idx
  ON public.restaurant_daily_order_counters (branch_id, restaurant_id);