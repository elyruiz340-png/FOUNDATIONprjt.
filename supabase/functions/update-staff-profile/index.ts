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

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("update-staff-profile: missing server configuration");
    return json({ error: "Server configuration error" }, 500);
  }

  const authHeader = req.headers.get("Authorization") || "";
  const tokenMatch = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!tokenMatch) return json({ error: "Authentication required" }, 401);

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    const { data: authData, error: authError } =
      await admin.auth.getUser(tokenMatch[1]);
    const actor = authData?.user;
    if (authError || !actor) {
      return json({ error: "Invalid or expired session" }, 401);
    }

    const body = await req.json();
    const staffId =
      typeof body.restaurant_user_id === "string"
        ? body.restaurant_user_id.trim()
        : "";
    const fullName =
      typeof body.full_name === "string" ? body.full_name.trim() : "";
    const displayName =
      typeof body.display_name === "string" ? body.display_name.trim() : "";

    if (!/^[0-9a-f-]{36}$/i.test(staffId)) {
      return json({ error: "Invalid staff account" }, 400);
    }
    if (!fullName || fullName.length > 100 || displayName.length > 60) {
      return json({ error: "Full Name is required (maximum 100 characters); Display Name must be 60 characters or fewer." }, 400);
    }

    const { data: target, error: targetError } = await admin
      .from("restaurant_users")
      .select("id, restaurant_id, role")
      .eq("id", staffId)
      .maybeSingle();

    if (targetError) {
      console.error("update-staff-profile: target lookup failed");
      return json({ error: "Unable to verify staff account" }, 500);
    }
    if (!target || String(target.role).toLowerCase() !== "staff") {
      return json({ error: "Staff account not found" }, 404);
    }

    const { data: actorLinks, error: actorError } = await admin
      .from("restaurant_users")
      .select("id")
      .eq("user_id", actor.id)
      .eq("restaurant_id", target.restaurant_id)
      .eq("is_active", true)
      .in("role", ["owner", "admin"])
      .limit(1);

    if (actorError) {
      console.error("update-staff-profile: authorization lookup failed");
      return json({ error: "Unable to verify permissions" }, 500);
    }
    if (!actorLinks || actorLinks.length !== 1) {
      return json({ error: "Owner/Admin access required for this restaurant" }, 403);
    }

    const { data: updated, error: updateError } = await admin
      .from("restaurant_users")
      .update({
        full_name: fullName,
        display_name: displayName || null,
      })
      .eq("id", target.id)
      .eq("restaurant_id", target.restaurant_id)
      .eq("role", "staff")
      .select("id, full_name, display_name")
      .maybeSingle();

    if (updateError || !updated) {
      console.error("update-staff-profile: profile update failed");
      return json({ error: "Unable to save staff profile" }, 500);
    }

    return json({
      success: true,
      staff_id: updated.id,
      full_name: updated.full_name,
      display_name: updated.display_name,
    });
  } catch (_error) {
    console.error("update-staff-profile: request failed");
    return json({ error: "Unable to update staff profile" }, 500);
  }
});