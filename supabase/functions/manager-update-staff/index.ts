import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const legacyPermissionKeys = ["orders", "tables", "stocks", "dispatcher", "settings", "void"];
const requiredPermissionKeys = ["orders", "tables", "stocks", "dispatcher", "settings"];

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

    if (!permissions || typeof permissions !== "object" || Array.isArray(permissions)) {
      return json({ error: "Invalid staff permissions" }, 400);
    }
    const suppliedKeys = Object.keys(permissions);
    if (!requiredPermissionKeys.every((key) => typeof permissions[key] === "boolean") ||
        suppliedKeys.some((key) => !legacyPermissionKeys.includes(key)) ||
        (Object.prototype.hasOwnProperty.call(permissions, "void") && typeof permissions.void !== "boolean")) {
      return json({ error: "Invalid staff permissions" }, 400);
    }

    const { data, error } = await admin.rpc("edmel_manager_update_staff_branch_permissions", {
      p_actor_user_id: actor.id,
      p_restaurant_id: restaurantId,
      p_branch_id: branchId,
      p_target_restaurant_user_id: targetId,
      p_permissions: permissions,
    });

    if (error) {
      if (error.code === "42501") return json({ error: error.message || "You are not allowed to update these staff permissions." }, 403);
      if (error.code === "22023") return json({ error: error.message || "The submitted staff permissions are invalid." }, 400);
      if (error.code === "P0002") return json({ error: error.message || "The staff member is not assigned to this branch." }, 404);
      console.error("manager-update-staff: permission update failed", error.code || "unknown");
      return json({ error: "Unable to update staff permissions. The branch access was not changed." }, 500);
    }

    if (!data?.success) return json({ error: "Staff permission update was not confirmed." }, 500);
    return json(data);
  } catch (_error) {
    console.error("manager-update-staff: request failed");
    return json({ error: "Unable to update staff permissions." }, 500);
  }
});
