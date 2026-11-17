import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

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
    console.error("admin-save-manager-permissions: missing server configuration");
    return json({ error: "Server configuration error" }, 500);
  }

  const authHeader = req.headers.get("Authorization") || "";
  const tokenMatch = authHeader.match(/^Bearer\s+(.+)$/i);
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
    const managerId = typeof body.manager_id === "string" ? body.manager_id : "";
    const assignments = body.assignments;

    if (!/^[0-9a-f-]{36}$/i.test(restaurantId) || !/^[0-9a-f-]{36}$/i.test(managerId)) {
      return json({ error: "Invalid restaurant or Manager account" }, 400);
    }
    if (!Array.isArray(assignments) || assignments.length < 1 || assignments.length > 100) {
      return json({ error: "Select at least one active branch" }, 400);
    }

    const { data, error } = await admin.rpc("edmel_admin_save_manager_branch_permissions", {
      p_actor_user_id: actor.id,
      p_restaurant_id: restaurantId,
      p_manager_id: managerId,
      p_assignments: assignments,
    });

    if (error || !data?.success) {
      const status = error?.code === "42501" ? 403 : error?.code === "22023" ? 400 : 500;
      if (status === 500) console.error("admin-save-manager-permissions: database operation failed", error?.code);
      return json({ error: error?.message || "Unable to save Manager permissions" }, status);
    }

    return json({ success: true, result: data, message: "Manager permissions saved successfully." });
  } catch (_error) {
    console.error("admin-save-manager-permissions: request failed");
    return json({ error: "Unable to save Manager permissions" }, 500);
  }
});
