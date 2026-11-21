ALTER TABLE public."PRODUCT_STOCK"
    ADD COLUMN IF NOT EXISTS is_available boolean NOT NULL DEFAULT true,
    ADD COLUMN IF NOT EXISTS is_archived boolean NOT NULL DEFAULT false;
  UPDATE public."PRODUCT_STOCK"
    SET is_available = COALESCE(is_available, true),
        is_archived = COALESCE(is_archived, false)
    WHERE is_available IS NULL OR is_archived IS NULL;