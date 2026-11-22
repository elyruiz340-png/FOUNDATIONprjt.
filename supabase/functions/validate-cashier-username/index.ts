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
  if (!supabaseUrl || !serviceRoleKey) return json({ error: "Server configuration error" }, 500);

  try {
    const body = await req.json();
    const restaurantSlug = typeof body.restaurant_slug === "string" ? body.restaurant_slug.trim().toLowerCase() : "";
    const username = typeof body.username === "string" ? body.username.trim() : "";

    if (!/^[a-z0-9][a-z0-9-]{1,99}$/.test(restaurantSlug) ||
        !/^[a-zA-Z0-9._-]{1,80}$/.test(username)) {
      return json({ valid: false });
    }

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: restaurant, error: restaurantError } = await admin
      .from("restaurants")
      .select("id")
      .eq("slug", restaurantSlug)
      .maybeSingle();

    if (restaurantError) {
      console.error("Tenant lookup failed:", restaurantError.message);
      return json({ error: "Unable to validate username" }, 500);
    }
    if (!restaurant) return json({ valid: false });

    const { data: staffRows, error: staffError } = await admin
      .from("restaurant_users")
      .select("id,cashier_username,role")
      .eq("restaurant_id", restaurant.id)
      .eq("is_active", true);

    if (staffError) {
      console.error("Tenant staff lookup failed:", staffError.message);
      return json({ error: "Unable to validate username" }, 500);
    }

    const staff = (staffRows || []).find((row: any) =>
      String(row.role || "").toLowerCase() === "staff" &&
      String(row.cashier_username || "").trim().toLowerCase() === username.toLowerCase()
    );
    if (!staff) return json({ valid: false });

    const { data: credentials, error: credentialsError } = await admin
      .from("cashier_credentials")
      .select("locked_at,pin_hash")
      .eq("restaurant_user_id", staff.id)
      .maybeSingle();

    if (credentialsError) {
      console.error("Credential lookup failed:", credentialsError.message);
      return json({ error: "Unable to validate username" }, 500);
    }
    if (!credentials?.pin_hash || credentials.locked_at !== null) return json({ valid: false });

    const { data: accessRows, error: accessError } = await admin
      .from("staff_branch_access")
      .select("branch_id")
      .eq("restaurant_user_id", staff.id)
      .eq("restaurant_id", restaurant.id)
      .eq("is_active", true);

    if (accessError) {
      console.error("Branch access lookup failed:", accessError.message);
      return json({ error: "Unable to validate username" }, 500);
    }

    const branchIds = (accessRows || []).map((row: any) => row.branch_id).filter(Boolean);
    if (!branchIds.length) return json({ valid: false });

    const { data: activeBranches, error: branchError } = await admin
      .from("restaurant_branches")
      .select("id")
      .eq("restaurant_id", restaurant.id)
      .eq("is_active", true)
      .in("id", branchIds);

    if (branchError) {
      console.error("Active branch lookup failed:", branchError.message);
      return json({ error: "Unable to validate username" }, 500);
    }

    return json({ valid: Array.isArray(activeBranches) && activeBranches.length > 0 });
  } catch (error) {
    console.error("Username validation failed:", error);
    return json({ error: "Unable to validate username" }, 500);
  }
});