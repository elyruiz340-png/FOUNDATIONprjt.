import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const legacyPermissionKeys = ["orders", "tables", "stocks", "dispatcher", "settings", "void"];
const requiredLegacyPermissionKeys = ["orders", "tables", "stocks", "dispatcher", "settings"];
const allowedModules = new Set([
  "overview", "sales", "settings", "orders", "expenses", "staff", "audit", "branches", "health", "ai",
  "inventory", "tables", "dispatcher", "payments", "menu", "discounts", "vouchers", "tax",
  "service_charge", "receipts", "printers", "transactions",
]);
const allowedActions = new Set(["view", "create", "edit", "delete", "approve", "manage", "void"]);
const allowedTopLevelKeys = new Set([...legacyPermissionKeys, "staff_management", "modules"]);

function isBooleanRecord(value: unknown): value is Record<string, boolean> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function validatePermissions(value: unknown): value is Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const permissions = value as Record<string, unknown>;
  const keys = Object.keys(permissions);
  if (keys.some((key) => !allowedTopLevelKeys.has(key))) return false;

  if (permissions.staff_management !== undefined && typeof permissions.staff_management !== "boolean") {
    return false;
  }

  if (permissions.modules !== undefined) {
    if (!permissions.modules || typeof permissions.modules !== "object" || Array.isArray(permissions.modules)) {
      return false;
    }
    const modules = permissions.modules as Record<string, unknown>;
    if (Object.keys(modules).length > allowedModules.size) return false;
    for (const [moduleName, actionValue] of Object.entries(modules)) {
      if (!allowedModules.has(moduleName) || !isBooleanRecord(actionValue)) return false;
      for (const [actionName, enabled] of Object.entries(actionValue)) {
        if (!allowedActions.has(actionName) || typeof enabled !== "boolean") return false;
        if (actionName === "void" && moduleName !== "orders") return false;
      }
    }
    return Object.keys(modules).length > 0;
  }

  if (!requiredLegacyPermissionKeys.every((key) => typeof permissions[key] === "boolean")) return false;
  return keys.every((key) => key === "staff_management" || legacyPermissionKeys.includes(key));
}

Deno.serve(async (req: Request) => {
  const json = (body: Record<string, unknown>, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("manager-update-staff: missing server configuration");
    return json({ error: "Server configuration error" }, 500);
  }

  const tokenMatch = (req.headers.get("Authorization") || "").match(/^Bearer\s+(.+)$/i);
  if (!tokenMatch) return json({ error: "Authentication required" }, 401);

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    const { data: authData, error: authError } = await admin.auth.getUser(tokenMatch[1]);
    const actor = authData?.user;
    if (authError || !actor) return json({ error: "Invalid or expired session" }, 401);

    const body = await req.json();
    const restaurantId = typeof body.restaurant_id === "string" ? body.restaurant_id : "";
    const branchId = typeof body.branch_id === "string" ? body.branch_id : "";
    const targetId = typeof body.restaurant_user_id === "string" ? body.restaurant_user_id : "";
    const permissions = body.permissions;

    const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!uuidPattern.test(restaurantId) || !uuidPattern.test(branchId) || !uuidPattern.test(targetId)) {
      return json({ error: "Invalid restaurant, branch, or staff account" }, 400);
    }

    if (!validatePermissions(permissions)) {
      return json({ error: "Invalid staff permissions" }, 400);
    }

    return json({
      error: "Manager permission changes must be submitted through an Admin approval batch.",
    }, 409);

  } catch (_error) {
    console.error("manager-update-staff: request failed");
    return json({ error: "Unable to update staff permissions." }, 500);
  }
});
