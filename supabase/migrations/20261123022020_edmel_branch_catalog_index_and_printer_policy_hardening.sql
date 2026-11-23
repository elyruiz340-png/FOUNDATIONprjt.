-- Add covering indexes for branch foreign keys and remove redundant printer SELECT policy overlap.
DROP INDEX IF EXISTS public.restaurant_branches_menu_source_idx;
CREATE INDEX IF NOT EXISTS restaurant_branches_menu_source_fk_idx
ON public.restaurant_branches(menu_source_branch_id,restaurant_id);

CREATE INDEX IF NOT EXISTS product_stock_branch_restaurant_fk_idx
ON public."PRODUCT_STOCK"(branch_id,restaurant_id);

CREATE INDEX IF NOT EXISTS menu_categories_branch_restaurant_fk_idx
ON public.menu_categories(branch_id,restaurant_id);

CREATE INDEX IF NOT EXISTS menu_items_branch_restaurant_fk_idx
ON public.menu_items(branch_id,restaurant_id);

CREATE INDEX IF NOT EXISTS menu_items_stock_product_branch_fk_idx
ON public.menu_items(restaurant_id,branch_id,stock_product_id);

DROP INDEX IF EXISTS public.idx_printer_devices_branch;
CREATE INDEX IF NOT EXISTS printer_devices_branch_restaurant_fk_idx
ON public.restaurant_printer_devices(branch_id,restaurant_id);

CREATE INDEX IF NOT EXISTS printer_devices_updated_by_fk_idx
ON public.restaurant_printer_devices(updated_by);

DROP POLICY IF EXISTS "Restaurant owners admins manage printer devices" ON public.restaurant_printer_devices;
CREATE POLICY "Restaurant owners admins insert printer devices"
ON public.restaurant_printer_devices
FOR INSERT TO authenticated
WITH CHECK (
  EXISTS(
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id=(SELECT auth.uid())
      AND ru.restaurant_id=restaurant_printer_devices.restaurant_id
      AND ru.is_active=true
      AND lower(coalesce(ru.role,'')) IN ('owner','admin')
  )
);
CREATE POLICY "Restaurant owners admins update printer devices"
ON public.restaurant_printer_devices
FOR UPDATE TO authenticated
USING (
  EXISTS(
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id=(SELECT auth.uid())
      AND ru.restaurant_id=restaurant_printer_devices.restaurant_id
      AND ru.is_active=true
      AND lower(coalesce(ru.role,'')) IN ('owner','admin')
  )
)
WITH CHECK (
  EXISTS(
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id=(SELECT auth.uid())
      AND ru.restaurant_id=restaurant_printer_devices.restaurant_id
      AND ru.is_active=true
      AND lower(coalesce(ru.role,'')) IN ('owner','admin')
  )
);
CREATE POLICY "Restaurant owners admins delete printer devices"
ON public.restaurant_printer_devices
FOR DELETE TO authenticated
USING (
  EXISTS(
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id=(SELECT auth.uid())
      AND ru.restaurant_id=restaurant_printer_devices.restaurant_id
      AND ru.is_active=true
      AND lower(coalesce(ru.role,'')) IN ('owner','admin')
  )
);
