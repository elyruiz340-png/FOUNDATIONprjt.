CREATE OR REPLACE FUNCTION public.edmel_permission_json_allows(
  p_permissions jsonb,
  p_module text,
  p_action text
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $function$
DECLARE
  v_module_permissions jsonb;
BEGIN
  IF p_permissions IS NULL
     OR jsonb_typeof(p_permissions) <> 'object'
     OR p_module IS NULL
     OR p_action IS NULL
     OR p_action NOT IN ('view','create','edit','delete','approve','manage','void') THEN
    RETURN false;
  END IF;

  IF p_permissions ? 'modules' THEN
    IF jsonb_typeof(p_permissions->'modules') <> 'object' THEN
      RETURN false;
    END IF;

    v_module_permissions := p_permissions->'modules'->p_module;
    IF v_module_permissions IS NULL
       OR jsonb_typeof(v_module_permissions) <> 'object' THEN
      RETURN false;
    END IF;

    -- A module-level Manage grant intentionally includes every supported
    -- action in that module. Granular grants remain independent otherwise.
    RETURN coalesce((v_module_permissions->>'manage')::boolean, false)
        OR coalesce((v_module_permissions->>p_action)::boolean, false);
  END IF;

  IF p_module = 'orders' AND p_action = 'void' THEN
    RETURN coalesce((p_permissions->>'void')::boolean, false)
       OR coalesce((p_permissions->>'orders')::boolean, false);
  END IF;
  IF p_module = 'payments' OR p_module = 'transactions' THEN
    RETURN coalesce((p_permissions->>'orders')::boolean, false);
  END IF;
  IF p_module = 'inventory' THEN
    RETURN coalesce((p_permissions->>'stocks')::boolean, false);
  END IF;
  IF p_module = 'staff' THEN
    RETURN coalesce((p_permissions->>'staff_management')::boolean, false);
  END IF;

  RETURN coalesce((p_permissions->>p_module)::boolean, false);
EXCEPTION
  WHEN invalid_text_representation THEN
    RETURN false;
END;
$function$;
