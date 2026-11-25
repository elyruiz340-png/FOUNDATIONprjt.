-- Authenticated users need table-level SELECT before RLS can evaluate policies.
-- Row visibility remains controlled by the existing and Manager-specific RLS policies.
GRANT SELECT ON TABLE public.order_items TO authenticated;
