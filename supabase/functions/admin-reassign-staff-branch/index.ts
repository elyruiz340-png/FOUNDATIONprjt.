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

  const url = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceRoleKey) {
    console.error("admin-reassign-staff-branch: missing server configuration");
    return json({ error: "Server configuration error" }, 500);
  }

  const tokenMatch = (req.headers.get("Authorization") || "").match(/^Bearer\s+(.+)$/i);
  if (!tokenMatch) return json({ error: "Authentication required" }, 401);

  const admin = createClient(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    const { data: authData, error: authError } = await admin.auth.getUser(tokenMatch[1]);
    const actor = authData?.user;
    if (authError || !actor) return json({ error: "Invalid or expired session" }, 401);

    const body = await req.json();
    const restaurantId = typeof body.restaurant_id === "string" ? body.restaurant_id : "";
    const staffId = typeof body.restaurant_user_id === "string" ? body.restaurant_user_id : "";
    const branchId = typeof body.branch_id === "string" ? body.branch_id : "";
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    if (!uuid.test(restaurantId) || !uuid.test(staffId) || !uuid.test(branchId)) {
      return json({ error: "Invalid restaurant, staff, or branch identifier" }, 400);
    }

    const { data, error } = await admin.rpc("edmel_admin_reassign_staff_branch", {
      p_actor_user_id: actor.id,
      p_restaurant_id: restaurantId,
      p_staff_id: staffId,
      p_new_branch_id: branchId,
    });

    if (error) {
      if (error.code === "42501") return json({ error: error.message || "Owner/Admin access is required." }, 403);
      if (error.code === "22023") return json({ error: error.message || "The staff member or branch assignment is invalid." }, 400);
      console.error("admin-reassign-staff-branch: database operation failed", error.code || "unknown");
      return json({ error: "Unable to reassign this staff member. No branch change was confirmed." }, 500);
    }

    if (!data?.success) return json({ error: "Branch reassignment was not confirmed." }, 500);
    return json({ success: true, result: data });
  } catch (_error) {
    console.error("admin-reassign-staff-branch: request failed");
    return json({ error: "Unable to reassign this staff member." }, 500);
  }
});