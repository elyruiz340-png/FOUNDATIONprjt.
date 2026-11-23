-- Scope printer device registrations to a restaurant branch.
ALTER TABLE public.restaurant_printer_devices
  ADD COLUMN IF NOT EXISTS branch_id uuid;

UPDATE public.restaurant_printer_devices d
SET branch_id=b.id
FROM public.restaurant_branches b
WHERE b.restaurant_id=d.restaurant_id
  AND b.is_default=true
  AND b.is_active=true
  AND d.branch_id IS NULL;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM public.restaurant_printer_devices WHERE branch_id IS NULL) THEN
    RAISE EXCEPTION 'Printer devices could not be assigned to an active default branch. Resolve those rows before enabling branch-scoped printer profiles.';
  END IF;
END;
$guard$;

ALTER TABLE public.restaurant_printer_devices
  ALTER COLUMN branch_id SET NOT NULL;
ALTER TABLE public.restaurant_printer_devices
  DROP CONSTRAINT IF EXISTS restaurant_printer_devices_branch_fk;
ALTER TABLE public.restaurant_printer_devices
  ADD CONSTRAINT restaurant_printer_devices_branch_fk
  FOREIGN KEY (branch_id,restaurant_id)
  REFERENCES public.restaurant_branches(id,restaurant_id)
  ON DELETE RESTRICT;

DROP INDEX IF EXISTS public.unique_restaurant_device;
CREATE UNIQUE INDEX IF NOT EXISTS unique_restaurant_branch_device
ON public.restaurant_printer_devices(restaurant_id,branch_id,device_id);
CREATE INDEX IF NOT EXISTS idx_printer_devices_branch
ON public.restaurant_printer_devices(restaurant_id,branch_id);

DROP POLICY IF EXISTS "Active order staff view receipt and printer devices" ON public.restaurant_printer_devices;
CREATE POLICY "Active branch order staff view branch printer devices"
ON public.restaurant_printer_devices
FOR SELECT TO authenticated
USING (
  EXISTS(
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id=(SELECT auth.uid())
      AND ru.restaurant_id=restaurant_printer_devices.restaurant_id
      AND ru.is_active=true
      AND (
        lower(coalesce(ru.role,'')) IN ('owner','admin')
        OR public.edmel_has_branch_permission(restaurant_printer_devices.branch_id,'orders')
      )
  )
);

COMMENT ON COLUMN public.restaurant_printer_devices.branch_id
IS 'Branch that owns this physical/browser printer registration. Device identifiers may be reused by another branch.';
