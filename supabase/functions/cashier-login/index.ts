import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  const json = (body: Record<string, unknown>, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return json({ error: "Server configuration error" }, 500);

  try {
    const body = await req.json();
    const username = typeof body.username === "string" ? body.username.trim() : "";
    const pin = typeof body.pin === "string" ? body.pin : "";
    const expectedPosition = typeof body.expected_position === "string"
      ? body.expected_position.trim().toLowerCase()
      : "cashier";

    if (!/^[a-zA-Z0-9._-]{1,80}$/.test(username) ||
        !/^\d{6}$/.test(pin) ||
        !["cashier", "manager"].includes(expectedPosition)) {
      return json({ error: "Invalid username, PIN, or access type" }, 400);
    }

    const admin = createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });
    const { data, error } = await admin.rpc("edmel_verify_staff_login_credentials_global", {
      p_username: username,
      p_pin: pin,
      p_expected_position: expectedPosition,
    });

    if (error) {
      console.error("Global staff credential verification failed:", error.message);
      return json({ error: "Unable to verify login" }, 500);
    }

    const verified = Array.isArray(data) ? data[0] : data;
    if (!verified?.cashier_user_id || !verified?.restaurant_id ||
        !verified?.restaurant_user_id || !verified?.restaurant_slug) {
      return json({ error: "Invalid username or PIN" }, 401);
    }

    // A locked cashier must resume and unlock the existing session, not create a new login.
    const { data: activeSessions, error: activeSessionError } = await admin.from("staff_sessions")
      .select("id,last_activity_at,login_at")
      .eq("user_id", verified.cashier_user_id)
      .eq("restaurant_id", verified.restaurant_id)
      .eq("restaurant_user_id", verified.restaurant_user_id)
      .is("logout_at", null)
      .order("login_at", { ascending: false })
      .limit(1);
    if (activeSessionError) {
      console.error("Unable to check active cashier session:", activeSessionError.message);
      return json({ error: "Unable to verify the current cashier session." }, 500);
    }
    const activeSession = activeSessions?.[0];
    if (activeSession) {
      const lastActivityAt = new Date(activeSession.last_activity_at || activeSession.login_at || 0).getTime();
      const isLocked = !Number.isFinite(lastActivityAt) || Date.now() - lastActivityAt >= 30 * 60 * 1000;
      if (isLocked) {
        return json({
          error: "This cashier screen is locked. Return to the existing session and enter the current cashier PIN to unlock it.",
          locked: true,
        }, 423);
      }
    }

    const { data: userResult, error: userError } =
      await admin.auth.admin.getUserById(verified.cashier_user_id);
    const email = userResult?.user?.email;
    if (userError || !email) return json({ error: "Unable to complete login" }, 500);

    const { data: linkData, error: linkError } =
      await admin.auth.admin.generateLink({ type: "magiclink", email });
    const tokenHash = linkData?.properties?.hashed_token;
    if (linkError || !tokenHash) return json({ error: "Unable to complete login" }, 500);

    return json({
      token_hash: tokenHash,
      type: "magiclink",
      restaurant_id: verified.restaurant_id,
      restaurant_slug: verified.restaurant_slug,
      restaurant_user_id: verified.restaurant_user_id,
      staff_position: verified.staff_position,
    });
  } catch (error) {
    console.error("Staff login failed:", error);
    return json({ error: "Unable to complete login" }, 500);
  }
});