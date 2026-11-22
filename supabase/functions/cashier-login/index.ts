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
    const pin = typeof body.pin === "string" ? body.pin : "";

    if (!/^[a-z0-9][a-z0-9-]{1,99}$/.test(restaurantSlug) ||
        username.length === 0 || username.length > 80 ||
        !/^[a-zA-Z0-9._-]+$/.test(username) ||
        !/^\d{6}$/.test(pin)) {
      return json({ error: "Invalid restaurant, username, or PIN" }, 400);
    }

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data, error } = await admin.rpc("edmel_verify_staff_login_credentials", {
      p_restaurant_slug: restaurantSlug,
      p_username: username,
      p_pin: pin,
    });

    if (error) {
      console.error("Tenant-scoped cashier verification failed:", error.message);
      return json({ error: "Unable to verify login" }, 500);
    }

    const verified = Array.isArray(data) ? data[0] : data;
    if (!verified?.cashier_user_id || !verified?.restaurant_id || !verified?.restaurant_user_id) {
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

    return json({ token_hash: tokenHash, type: "magiclink" });
  } catch (error) {
    console.error("Cashier login failed:", error);
    return json({ error: "Unable to complete login" }, 500);
  }
});