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
  if (!url || !serviceRoleKey) return json({ error: "Server configuration error" }, 500);

  const authHeader = req.headers.get("Authorization") || "";
  const tokenMatch = authHeader.match(/^Bearer\\s+(.+)$/i);
  if (!tokenMatch) return json({ error: "Authentication required" }, 401);

  const admin = createClient(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    const { data: authData, error: authError } = await admin.auth.getUser(tokenMatch[1]);
    const user = authData?.user;
    if (authError || !user) return json({ error: "Invalid or expired session" }, 401);

    const verifiedEmail = String(user.email || "").trim().toLowerCase();
    if (!verifiedEmail || !user.email_confirmed_at) {
      return json({ error: "Verify your Manager email address before completing password setup." }, 403);
    }

    const { data: updatedRows, error: updateError } = await admin
      .from("restaurant_users")
      .update({
        manager_email_verified_at: user.email_confirmed_at,
        manager_auth_setup_status: "active",
      })
      .eq("user_id", user.id)
      .eq("role", "staff")
      .eq("position", "Manager")
      .eq("is_active", true)
      .eq("manager_auth_method", "password")
      .eq("manager_email", verifiedEmail)
      .select("id");

    if (updateError) {
      console.error("manager-auth-setup: profile activation failed");
      return json({ error: "Unable to complete Manager account setup." }, 500);
    }
    if (!updatedRows?.length) {
      return json({ error: "No active password-based Manager profile matches this verified email." }, 403);
    }

    return json({ success: true, message: "Manager password setup completed." });
  } catch (_error) {
    console.error("manager-auth-setup: request failed");
    return json({ error: "Unable to complete Manager account setup." }, 500);
  }
});
