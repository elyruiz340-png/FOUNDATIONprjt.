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
    const username = typeof body.username === "string" ? body.username.trim() : "";
    const pin = typeof body.pin === "string" ? body.pin : "";
    const expectedPosition = typeof body.expected_position === "string"
      ? body.expected_position.trim().toLowerCase()
      : "cashier";

    if (username.length === 0 || username.length > 80 ||
        !/^[a-zA-Z0-9._-]+$/.test(username) ||
        !/^\d{6}$/.test(pin) ||
        expectedPosition !== "cashier") {
      return json({ error: "Invalid username, PIN, or cashier access" }, 400);
    }

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Resolve the tenant from the globally unique staff username. If legacy
    // duplicate usernames exist, fail closed rather than selecting a tenant.
    const { data: staffRows, error: staffError } = await admin
      .from("restaurant_users")
      .select("id,restaurant_id,cashier_username,role,position,is_active")
      .eq("is_active", true)
      .ilike("cashier_username", username);

    if (staffError) {
      console.error("Cashier staff lookup failed:", staffError.message);
      return json({ error: "Unable to verify login" }, 500);
    }

    const matches = (staffRows || []).filter((row: any) =>
      String(row.role || "").trim().toLowerCase() === "staff" &&
      String(row.position || "").trim().toLowerCase() === expectedPosition &&
      String(row.cashier_username || "").trim().toLowerCase() === username.toLowerCase()
    );
    if (matches.length !== 1) return json({ error: "Invalid username or PIN" }, 401);

    const staff = matches[0];
    const { data: restaurant, error: restaurantError } = await admin
      .from("restaurants")
      .select("id,slug")
      .eq("id", staff.restaurant_id)
      .maybeSingle();

    if (restaurantError || !restaurant?.slug) {
      console.error("Cashier restaurant lookup failed:", restaurantError?.message || "Restaurant not found");
      return json({ error: "Unable to resolve cashier workspace" }, 500);
    }

    const { data, error } = await admin.rpc("edmel_verify_staff_login_credentials", {
      p_restaurant_slug: restaurant.slug,
      p_username: username,
      p_pin: pin,
    });

    if (error) {
      console.error("Tenant-scoped cashier verification failed:", error.message);
      return json({ error: "Unable to verify login" }, 500);
    }

    const verified = Array.isArray(data) ? data[0] : data;
    if (!verified?.cashier_user_id ||
        !verified?.restaurant_id ||
        !verified?.restaurant_user_id ||
        verified.restaurant_user_id !== staff.id ||
        verified.restaurant_id !== staff.restaurant_id ||
        String(verified.staff_position || "").trim().toLowerCase() !== expectedPosition) {
      return json({ error: "Invalid username or PIN" }, 401);
    }

    const { data: userResult, error: userError } =
      await admin.auth.admin.getUserById(verified.cashier_user_id);
    const email = userResult?.user?.email;

    if (userError || !email) {
      console.error("Cashier Auth user lookup failed");
      return json({ error: "Unable to complete login" }, 500);
    }

    const { data: linkData, error: linkError } = await admin.auth.admin.generateLink({
      type: "magiclink",
      email,
    });
    const tokenHash = linkData?.properties?.hashed_token;

    if (linkError || !tokenHash) {
      console.error("Unable to create cashier Auth token");
      return json({ error: "Unable to complete login" }, 500);
    }

    return json({ token_hash: tokenHash, type: "magiclink", restaurant_slug: restaurant.slug });
  } catch (error) {
    console.error("Cashier login failed:", error);
    return json({ error: "Unable to complete login" }, 500);
  }
});
