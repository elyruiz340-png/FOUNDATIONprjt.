CREATE OR REPLACE FUNCTION public.sync_order_status_legacy()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.order_status := CASE lower(coalesce(NEW.status, ''))
    WHEN 'new' THEN 'pending'
    WHEN 'pending' THEN 'pending'
    WHEN 'accepted' THEN 'confirmed'
    WHEN 'confirmed' THEN 'confirmed'
    WHEN 'preparing' THEN 'preparing'
    WHEN 'ready' THEN 'ready'
    WHEN 'served' THEN 'served'
    WHEN 'completed' THEN 'completed'
    WHEN 'cancelled' THEN 'cancelled'
    ELSE NEW.order_status
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_legacy_order_status ON public.orders;
CREATE TRIGGER trg_sync_legacy_order_status
BEFORE INSERT OR UPDATE ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.sync_order_status_legacy();

UPDATE public.orders
SET order_status = CASE lower(coalesce(status, ''))
  WHEN 'new' THEN 'pending'
  WHEN 'pending' THEN 'pending'
  WHEN 'accepted' THEN 'confirmed'
  WHEN 'confirmed' THEN 'confirmed'
  WHEN 'preparing' THEN 'preparing'
  WHEN 'ready' THEN 'ready'
  WHEN 'served' THEN 'served'
  WHEN 'completed' THEN 'completed'
  WHEN 'cancelled' THEN 'cancelled'
  ELSE order_status
END
WHERE lower(coalesce(status, '')) IN (
  'new','pending','accepted','confirmed','preparing','ready','served','completed','cancelled'
)
AND order_status IS DISTINCT FROM CASE lower(coalesce(status, ''))
  WHEN 'new' THEN 'pending'
  WHEN 'pending' THEN 'pending'
  WHEN 'accepted' THEN 'confirmed'
  WHEN 'confirmed' THEN 'confirmed'
  WHEN 'preparing' THEN 'preparing'
  WHEN 'ready' THEN 'ready'
  WHEN 'served' THEN 'served'
  WHEN 'completed' THEN 'completed'
  WHEN 'cancelled' THEN 'cancelled'
  ELSE order_status
END;