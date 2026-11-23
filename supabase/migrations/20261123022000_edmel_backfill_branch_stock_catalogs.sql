-- Backfill branch-local inventory catalog definitions for existing branches.
-- Quantities are deliberately initialized to zero; no existing stock balances are copied or changed.

INSERT INTO public."PRODUCT_STOCK"(
  product_name,stock_total,stock_remaining,product_id,stock_group,category,image_url,
  is_available,is_archived,restaurant_id,branch_id
)
SELECT source.product_name,0,0,source.product_id,source.stock_group,source.category,
       source.image_url,source.is_available,source.is_archived,
       target.restaurant_id,target.id
FROM public.restaurant_branches target
JOIN public.restaurant_branches master
  ON master.restaurant_id=target.restaurant_id
 AND master.is_default=true
 AND master.is_active=true
JOIN public."PRODUCT_STOCK" source
  ON source.restaurant_id=master.restaurant_id
 AND source.branch_id=master.id
WHERE target.is_active=true
  AND target.is_default=false
  AND NOT EXISTS(
    SELECT 1 FROM public."PRODUCT_STOCK" existing
    WHERE existing.restaurant_id=target.restaurant_id
      AND existing.branch_id=target.id
      AND existing.product_id=source.product_id
  );

CREATE INDEX IF NOT EXISTS restaurant_branches_menu_source_idx
ON public.restaurant_branches(restaurant_id,menu_source_branch_id,menu_catalog_mode);
