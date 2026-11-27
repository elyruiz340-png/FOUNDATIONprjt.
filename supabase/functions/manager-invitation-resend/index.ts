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
    const actor = authData?.user;
    if (authError || !actor) return json({ error: "Invalid or expired session" }, 401);

    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      return json({ error: "Invalid request body" }, 400);
    }

    const restaurantId = typeof body.restaurant_id === "string" ? body.restaurant_id : "";
    const staffId = typeof body.staff_id === "string" ? body.staff_id : "";
    const redirectTo = typeof body.redirect_to === "string" ? body.redirect_to.trim() : "";
    if (!/^[0-9a-f-]{36}$/i.test(restaurantId) || !/^[0-9a-f-]{36}$/i.test(staffId)) {
      return json({ error: "Invalid Manager account" }, 400);
    }
    if (!redirectTo) return json({ error: "Manager invitation redirect is missing. Refresh Admin and try again." }, 400);

    const originHeader = req.headers.get("origin") || "";
    let redirectUrl: URL;
    try {
      const originUrl = new URL(originHeader);
      redirectUrl = new URL(redirectTo);
      const localDevelopment = originUrl.hostname === "localhost" || originUrl.hostname === "127.0.0.1";
      if ((!localDevelopment && originUrl.protocol !== "https:") ||
          redirectUrl.origin !== originUrl.origin ||
          !redirectUrl.pathname.endsWith("/manager.html") ||
          redirectUrl.username || redirectUrl.password || redirectUrl.search || redirectUrl.hash) {
        throw new Error("Invalid redirect");
      }
    } catch {
      return json({ error: "The Manager setup URL is invalid. Open Admin from the HTTPS application and try again." }, 400);
    }

    const { data: actorLinks, error: actorError } = await admin
      .from("restaurant_users")
      .select("id,role,is_active")
      .eq("user_id", actor.id)
      .eq("restaurant_id", restaurantId)
      .eq("is_active", true);
    if (actorError) {
      console.error("manager-invitation-resend: actor authorization lookup failed");
      return json({ error: "Unable to verify permissions." }, 500);
    }
    const isOwnerAdmin = (actorLinks || []).some((link: any) =>
      ["owner", "admin"].includes(String(link.role || "").toLowerCase())
    );
    if (!isOwnerAdmin) return json({ error: "Active Owner/Admin access is required." }, 403);

    const { data: manager, error: managerError } = await admin
      .from("restaurant_users")
      .select("id,user_id,restaurant_id,role,position,is_active,manager_auth_method,manager_email,manager_auth_setup_status,manager_invitation_expires_at")
      .eq("id", staffId)
      .eq("restaurant_id", restaurantId)
      .eq("role", "staff")
      .eq("position", "Manager")
      .eq("is_active", true)
      .eq("manager_auth_method", "password")
      .maybeSingle();

    if (managerError) {
      console.error("manager-invitation-resend: Manager lookup failed");
      return json({ error: "Unable to verify this Manager account." }, 500);
    }
    if (!manager || !manager.manager_email || !manager.user_id) {
      return json({ error: "An active password-based Manager account could not be verified." }, 404);
    }
    if (manager.manager_auth_setup_status === "active") {
      return json({ error: "This Manager account is already active. No new setup email is needed." }, 409);
    }
    if (!["pending", "failed"].includes(String(manager.manager_auth_setup_status || ""))) {
      return json({ error: "This Manager account is not eligible for invitation renewal." }, 409);
    }

    const email = String(manager.manager_email).trim().toLowerCase();
    const { data: authUserData, error: authUserError } = await admin.auth.admin.getUserById(manager.user_id);
    const authUser = authUserData?.user;
    if (authUserError || !authUser || String(authUser.email || "").trim().toLowerCase() !== email) {
      console.error("manager-invitation-resend: linked Auth identity could not be verified");
      return json({ error: "The linked Manager sign-in account could not be verified." }, 409);
    }

    const previousStatus = String(manager.manager_auth_setup_status);
    const previousExpiry = manager.manager_invitation_expires_at;
    const newExpiry = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();

    let claimQuery = admin
      .from("restaurant_users")
      .update({
        manager_auth_setup_status: "pending",
        manager_invitation_expires_at: newExpiry,
      })
      .eq("id", manager.id)
      .eq("user_id", manager.user_id)
      .eq("is_active", true)
      .eq("manager_auth_setup_status", previousStatus);
    claimQuery = previousExpiry
      ? claimQuery.eq("manager_invitation_expires_at", previousExpiry)
      : claimQuery.is("manager_invitation_expires_at", null);

    const { data: claimedRows, error: claimError } = await claimQuery.select("id");
    if (claimError) {
      console.error("manager-invitation-resend: invitation renewal claim failed");
      return json({ error: "Unable to renew this Manager invitation." }, 500);
    }
    if (!claimedRows?.length) {
      return json({ error: "This Manager invitation changed. Refresh the staff record and try again." }, 409);
    }

    let emailError: any = null;
    if (authUser.email_confirmed_at) {
      const result = await admin.auth.resetPasswordForEmail(email, {
        redirectTo: redirectUrl.toString(),
      });
      emailError = result.error;
    } else {
      const inviteResult = await admin.auth.admin.inviteUserByEmail(email, {
        redirectTo: redirectUrl.toString(),
        data: { account_type: "edmel_staff", staff_position: "Manager" },
      });
      if (!inviteResult.error) {
        emailError = null;
      } else {
        // Existing unconfirmed Auth users cannot always be invited again through
        // /invite; resend their signup confirmation without creating a new user.
        const resendResult = await admin.auth.resend({
          type: "signup",
          email,
          options: { emailRedirectTo: redirectUrl.toString() },
        });
        emailError = resendResult.error;
      }
    }

    if (emailError) {
      await admin
        .from("restaurant_users")
        .update({
          manager_auth_setup_status: "failed",
          manager_invitation_expires_at: null,
        })
        .eq("id", manager.id)
        .eq("user_id", manager.user_id)
        .eq("manager_auth_setup_status", "pending")
        .eq("manager_invitation_expires_at", newExpiry);
      console.error("manager-invitation-resend: email delivery request failed", emailError.status || "unknown");
      return json({ error: "Unable to send the Manager setup email. Check Auth email delivery and try again." }, 502);
    }

    return json({
      success: true,
      message: "A new Manager setup email has been sent.",
      invitation_expires_at: newExpiry,
    });
  } catch (_error) {
    console.error("manager-invitation-resend: request failed");
    return json({ error: "Unable to renew the Manager invitation." }, 500);
  }
});
