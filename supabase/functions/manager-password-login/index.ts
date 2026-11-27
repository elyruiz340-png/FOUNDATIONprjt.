import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const invalidCredentials = "Invalid username/email or password.";

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
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !serviceRoleKey || !anonKey) {
    console.error("manager-password-login: required Supabase configuration is missing");
    return json({ error: "Login service is temporarily unavailable." }, 500);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid login request." }, 400);
  }

  const identifier = typeof body.identifier === "string" ? body.identifier.trim() : "";
  const password = typeof body.password === "string" ? body.password : "";
  const isEmail = identifier.includes("@");

  if (
    !identifier ||
    identifier.length > 254 ||
    (isEmail ? !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(identifier) : !/^[a-zA-Z0-9._-]{1,80}$/.test(identifier)) ||
    password.length < 1 ||
    password.length > 128
  ) {
    return json({ error: invalidCredentials }, 401);
  }

  const admin = createClient(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const authClient = createClient(url, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    let profileQuery = admin
      .from("restaurant_users")
      .select("user_id,manager_email")
      .eq("role", "staff")
      .ilike("position", "manager")
      .eq("is_active", true)
      .eq("manager_auth_method", "password")
      .eq("manager_auth_setup_status", "active")
      .not("manager_email_verified_at", "is", null)
      .not("manager_email", "is", null);

    profileQuery = isEmail
      ? profileQuery.ilike("manager_email", identifier.toLowerCase())
      : profileQuery.ilike("cashier_username", identifier);

    const { data: profiles, error: profileError } = await profileQuery.limit(100);
    if (profileError) {
      console.error("manager-password-login: Manager profile lookup failed");
      return json({ error: "Login service is temporarily unavailable." }, 500);
    }

    const userIds = [...new Set((profiles || []).map((profile) => profile.user_id).filter(Boolean))];
    if (userIds.length !== 1) return json({ error: invalidCredentials }, 401);

    const { data: authUserData, error: authUserError } = await admin.auth.admin.getUserById(userIds[0]);
    const authUser = authUserData?.user;
    const authEmail = String(authUser?.email || "").trim().toLowerCase();
    const assignedEmails = [...new Set((profiles || [])
      .filter((profile) => profile.user_id === userIds[0])
      .map((profile) => String(profile.manager_email || "").trim().toLowerCase())
      .filter(Boolean))];

    if (
      authUserError ||
      !authUser ||
      !authEmail ||
      !authUser.email_confirmed_at ||
      assignedEmails.length !== 1 ||
      assignedEmails[0] !== authEmail
    ) {
      return json({ error: invalidCredentials }, 401);
    }

    const { data: signInData, error: signInError } = await authClient.auth.signInWithPassword({
      email: authEmail,
      password,
    });

    if (signInError || !signInData?.session) {
      return json({ error: invalidCredentials }, 401);
    }

    return json({
      access_token: signInData.session.access_token,
      refresh_token: signInData.session.refresh_token,
    });
  } catch (_error) {
    console.error("manager-password-login: request failed");
    return json({ error: "Login service is temporarily unavailable." }, 500);
  }
});
