ALTER TABLE public."PRODUCT_STOCK"
ADD CONSTRAINT product_stock_product_id_key UNIQUE (product_id);

ALTER TABLE public.menu_items
ADD COLUMN IF NOT EXISTS stock_product_id text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'menu_items_stock_product_id_fkey'
      AND conrelid = 'public.menu_items'::regclass
  ) THEN
    ALTER TABLE public.menu_items
    ADD CONSTRAINT menu_items_stock_product_id_fkey
    FOREIGN KEY (stock_product_id)
    REFERENCES public."PRODUCT_STOCK" (product_id)
    ON UPDATE CASCADE
    ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS menu_items_restaurant_stock_product_idx
ON public.menu_items (restaurant_id, stock_product_id);