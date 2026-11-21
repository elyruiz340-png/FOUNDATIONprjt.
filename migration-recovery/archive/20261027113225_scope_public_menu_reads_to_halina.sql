DROP POLICY IF EXISTS "Public can view active menu categories" ON public.menu_categories;
CREATE POLICY "Public can view active menu categories"
ON public.menu_categories FOR SELECT TO anon, authenticated
USING (
  is_active = true
  AND restaurant_id = '5e562ca7-38aa-4894-8265-ddca2f4e61b6'::uuid
);

DROP POLICY IF EXISTS "Public can view available menu items" ON public.menu_items;
CREATE POLICY "Public can view available menu items"
ON public.menu_items FOR SELECT TO anon, authenticated
USING (
  is_available = true
  AND restaurant_id = '5e562ca7-38aa-4894-8265-ddca2f4e61b6'::uuid
);