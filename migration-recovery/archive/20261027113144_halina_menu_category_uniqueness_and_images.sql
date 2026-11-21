CREATE UNIQUE INDEX IF NOT EXISTS menu_categories_restaurant_name_ci_uidx ON public.menu_categories (restaurant_id, lower(btrim(name)));

INSERT INTO storage.buckets (id, name, public)
VALUES ('halina-menu-images', 'halina-menu-images', true)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "HALINA menu images public read" ON storage.objects;
CREATE POLICY "HALINA menu images public read"
ON storage.objects FOR SELECT TO anon, authenticated
USING (bucket_id = 'halina-menu-images');

DROP POLICY IF EXISTS "HALINA owners upload menu images" ON storage.objects;
CREATE POLICY "HALINA owners upload menu images"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'halina-menu-images'
  AND (storage.foldername(name))[1] = '5e562ca7-38aa-4894-8265-ddca2f4e61b6'
  AND EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = '5e562ca7-38aa-4894-8265-ddca2f4e61b6'::uuid
      AND ru.role IN ('owner','admin')
  )
);

DROP POLICY IF EXISTS "HALINA owners update menu images" ON storage.objects;
CREATE POLICY "HALINA owners update menu images"
ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id = 'halina-menu-images'
  AND (storage.foldername(name))[1] = '5e562ca7-38aa-4894-8265-ddca2f4e61b6'
  AND EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = '5e562ca7-38aa-4894-8265-ddca2f4e61b6'::uuid
      AND ru.role IN ('owner','admin')
  )
)
WITH CHECK (
  bucket_id = 'halina-menu-images'
  AND (storage.foldername(name))[1] = '5e562ca7-38aa-4894-8265-ddca2f4e61b6'
  AND EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = '5e562ca7-38aa-4894-8265-ddca2f4e61b6'::uuid
      AND ru.role IN ('owner','admin')
  )
);

DROP POLICY IF EXISTS "HALINA owners delete menu images" ON storage.objects;
CREATE POLICY "HALINA owners delete menu images"
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'halina-menu-images'
  AND (storage.foldername(name))[1] = '5e562ca7-38aa-4894-8265-ddca2f4e61b6'
  AND EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = '5e562ca7-38aa-4894-8265-ddca2f4e61b6'::uuid
      AND ru.role IN ('owner','admin')
  )
);