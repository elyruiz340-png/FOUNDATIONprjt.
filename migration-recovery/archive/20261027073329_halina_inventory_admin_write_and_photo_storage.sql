BEGIN;

-- Stock item creation and item-detail changes are reserved for signed-in owners/admins.
DROP POLICY IF EXISTS "Allow cashier to manage product stock" ON public."PRODUCT_STOCK";
DROP POLICY IF EXISTS "Owners and admins can insert product stock" ON public."PRODUCT_STOCK";
DROP POLICY IF EXISTS "Owners and admins can update product stock" ON public."PRODUCT_STOCK";

REVOKE INSERT, UPDATE ON TABLE public."PRODUCT_STOCK" FROM anon;
GRANT UPDATE (stock_total, stock_remaining) ON TABLE public."PRODUCT_STOCK" TO anon;

GRANT INSERT (product_id, product_name, stock_group, stock_total, stock_remaining, category, image_url)
ON TABLE public."PRODUCT_STOCK" TO authenticated;
GRANT UPDATE (product_id, product_name, stock_group, stock_total, stock_remaining, category, image_url)
ON TABLE public."PRODUCT_STOCK" TO authenticated;

CREATE POLICY "Owners and admins can insert product stock"
ON public."PRODUCT_STOCK"
FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND lower(coalesce(ru.role, '')) IN ('owner', 'admin')
  )
);

CREATE POLICY "Owners and admins can update product stock"
ON public."PRODUCT_STOCK"
FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND lower(coalesce(ru.role, '')) IN ('owner', 'admin')
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND lower(coalesce(ru.role, '')) IN ('owner', 'admin')
  )
);

-- Publicly readable images; uploads and management are restricted to authenticated owners/admins.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('halina-stock-images', 'halina-stock-images', true, 5242880, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "HALINA stock images public read" ON storage.objects;
DROP POLICY IF EXISTS "HALINA admins upload stock images" ON storage.objects;
DROP POLICY IF EXISTS "HALINA admins update stock images" ON storage.objects;
DROP POLICY IF EXISTS "HALINA admins delete stock images" ON storage.objects;

CREATE POLICY "HALINA stock images public read"
ON storage.objects FOR SELECT TO anon, authenticated
USING (bucket_id = 'halina-stock-images');

CREATE POLICY "HALINA admins upload stock images"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'halina-stock-images'
  AND EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND lower(coalesce(ru.role, '')) IN ('owner', 'admin')
  )
);

CREATE POLICY "HALINA admins update stock images"
ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id = 'halina-stock-images'
  AND EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND lower(coalesce(ru.role, '')) IN ('owner', 'admin')
  )
)
WITH CHECK (
  bucket_id = 'halina-stock-images'
  AND EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND lower(coalesce(ru.role, '')) IN ('owner', 'admin')
  )
);

CREATE POLICY "HALINA admins delete stock images"
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'halina-stock-images'
  AND EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND lower(coalesce(ru.role, '')) IN ('owner', 'admin')
  )
);

COMMIT;