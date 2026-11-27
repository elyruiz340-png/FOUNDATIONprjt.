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

    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      return json({ error: "Invalid request body" }, 400);
    }
    const password = typeof body.password === "string" ? body.password : "";
    if (password.length < 12 || password.length > 128) {
      return json({ error: "Use a password between 12 and 128 characters." }, 400);
    }

    // Verify the invitation lifecycle before changing the Auth password.
    const { data: profile, error: profileError } = await admin
      .from("restaurant_users")
      .select("id,user_id,restaurant_id,role,position,is_active,manager_auth_method,manager_email,manager_auth_setup_status,manager_invitation_expires_at")
      .eq("user_id", user.id)
      .eq("role", "staff")
      .eq("position", "Manager")
      .eq("is_active", true)
      .eq("manager_auth_method", "password")
      .eq("manager_auth_setup_status", "pending")
      .eq("manager_email", verifiedEmail)
      .maybeSingle();

    if (profileError) {
      console.error("manager-auth-setup: profile validation failed");
      return json({ error: "Unable to verify the Manager invitation." }, 500);
    }
    const expiry = profile?.manager_invitation_expires_at
      ? Date.parse(profile.manager_invitation_expires_at)
      : NaN;
    if (!profile || !Number.isFinite(expiry) || expiry <= Date.now()) {
      return json({ error: "This Manager invitation has expired or is no longer valid. Contact the Owner or Admin for a new setup email." }, 403);
    }

    // The invitation record is the authorization source; the Auth invitation
    // timestamp is not relied on because a renewed email may use signup or recovery.
    const { error: passwordError } = await admin.auth.admin.updateUserById(user.id, { password });
    if (passwordError) {
      console.error("manager-auth-setup: password update failed");
      return json({ error: "Unable to save the Manager password. Please try again." }, 400);
    }

    // Conditional update keeps activation one-time and prevents a stale setup
    // request from consuming a newer invitation issued concurrently.
    const { data: updatedRows, error: updateError } = await admin
      .from("restaurant_users")
      .update({
        manager_email_verified_at: user.email_confirmed_at,
        manager_auth_setup_status: "active",
        manager_invitation_expires_at: null,
      })
      .eq("id", profile.id)
      .eq("user_id", user.id)
      .eq("is_active", true)
      .eq("manager_auth_setup_status", "pending")
      .eq("manager_email", verifiedEmail)
      .eq("manager_invitation_expires_at", profile.manager_invitation_expires_at)
      .gt("manager_invitation_expires_at", new Date().toISOString())
      .select("id");

    if (updateError) {
      console.error("manager-auth-setup: profile activation failed");
      return json({ error: "The password was saved, but Manager activation could not be confirmed. Contact the Owner or Admin before signing in." }, 500);
    }
    if (!updatedRows?.length) {
      return json({ error: "The invitation changed or expired during setup. Contact the Owner or Admin to renew it." }, 409);
    }

    return json({ success: true, message: "Manager password setup completed." });
  } catch (_error) {
    console.error("manager-auth-setup: request failed");
    return json({ error: "Unable to complete Manager account setup." }, 500);
  }
});
