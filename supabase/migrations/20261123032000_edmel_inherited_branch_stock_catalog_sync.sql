-- Keep the inventory catalog synchronized for branches that inherit the Main Branch menu.
-- This copies/updates metadata only. Branch stock balances remain independent.
CREATE OR REPLACE FUNCTION private.edmel_sync_inherited_branch_stock_catalog()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF NEW.restaurant_id IS NULL OR NEW.branch_id IS NULL OR NEW.product_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM public.restaurant_branches b
    WHERE b.id=NEW.branch_id AND b.restaurant_id=NEW.restaurant_id AND b.is_default=true
  ) THEN
    RETURN NEW;
  END IF;

  IF TG_OP='INSERT' THEN
    INSERT INTO public."PRODUCT_STOCK"(
      product_name,stock_total,stock_remaining,product_id,stock_group,category,image_url,
      is_available,is_archived,restaurant_id,branch_id
    )
    SELECT NEW.product_name,0,0,NEW.product_id,NEW.stock_group,NEW.category,NEW.image_url,
      NEW.is_available,NEW.is_archived,NEW.restaurant_id,b.id
    FROM public.restaurant_branches b
    WHERE b.restaurant_id=NEW.restaurant_id
      AND b.is_active=true AND b.is_default=false
      AND b.menu_catalog_mode='inherit'
    ON CONFLICT (restaurant_id,branch_id,product_id) DO NOTHING;
  ELSE
    IF OLD.product_id IS DISTINCT FROM NEW.product_id THEN
      UPDATE public."PRODUCT_STOCK" target
      SET product_id=NEW.product_id
      FROM public.restaurant_branches b
      WHERE b.id=target.branch_id AND b.restaurant_id=target.restaurant_id
        AND b.restaurant_id=NEW.restaurant_id AND b.is_active=true
        AND b.is_default=false AND b.menu_catalog_mode='inherit'
        AND target.product_id=OLD.product_id;
    END IF;
    UPDATE public."PRODUCT_STOCK" target
    SET product_name=NEW.product_name,
        stock_group=NEW.stock_group,
        category=NEW.category,
        image_url=NEW.image_url,
        is_available=NEW.is_available,
        is_archived=NEW.is_archived
    FROM public.restaurant_branches b
    WHERE b.id=target.branch_id AND b.restaurant_id=target.restaurant_id
      AND b.restaurant_id=NEW.restaurant_id AND b.is_active=true
      AND b.is_default=false AND b.menu_catalog_mode='inherit'
      AND target.product_id=NEW.product_id;
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.edmel_sync_inherited_branch_stock_catalog() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS edmel_sync_inherited_branch_stock_catalog ON public."PRODUCT_STOCK";
CREATE TRIGGER edmel_sync_inherited_branch_stock_catalog
AFTER INSERT OR UPDATE OF product_name,stock_group,category,image_url,is_available,is_archived,product_id
ON public."PRODUCT_STOCK"
FOR EACH ROW
EXECUTE FUNCTION private.edmel_sync_inherited_branch_stock_catalog();
