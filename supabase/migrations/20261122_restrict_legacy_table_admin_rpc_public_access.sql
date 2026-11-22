-- Legacy table-management RPCs are not public customer APIs.
-- They remain callable by authenticated users, with Owner/Admin authorization enforced internally.

REVOKE EXECUTE ON FUNCTION public.can_view_restaurant_users(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.halina_can_manage_tables(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.halina_create_restaurant_table(uuid, text, integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.halina_list_restaurant_tables(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.halina_rotate_table_qr(uuid, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.halina_update_restaurant_table(uuid, uuid, text, integer, boolean, boolean) FROM anon;
