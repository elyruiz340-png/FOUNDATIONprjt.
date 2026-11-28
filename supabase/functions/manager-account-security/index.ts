import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function digest(code: string, secret: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(code));
  return Array.from(new Uint8Array(sig), b => b.toString(16).padStart(2, "0")).join("");
}
function escapeHtml(value: string) {
  return value.replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch] || ch));
}
async function notifyAdmins(db: ReturnType<typeof createClient>, restaurantId: string, actorUserId: string, eventType: string, title: string, message: string, resend?: string, recipient?: string) {
  const { data: admins, error } = await db.from("restaurant_users")
    .select("user_id,role").eq("restaurant_id", restaurantId).eq("is_active", true).in("role", ["owner", "admin"]);
  if (error) { console.error("manager-account-security: admin recipient lookup failed"); return; }
  const ids = [...new Set((admins || []).map((row: any) => row.user_id).filter(Boolean))];
  if (!ids.length) return;
  const rows = ids.map(userId => ({ restaurant_id: restaurantId, actor_user_id: actorUserId, recipient_user_id: userId, event_type: eventType, title, message }));
  const inserted = await db.from("manager_security_notifications").insert(rows);
  if (inserted.error) { console.error("manager-account-security: notification insert failed"); return; }
  if (!resend || !recipient) return;
  const emailHtml = `<h2>${escapeHtml(title)}</h2><p>${escapeHtml(message)}</p><p style="color:#777">EDMEL test notification. This message was sent to the configured Resend test inbox, not to the Owner/Admin login email.</p>`;
  try {
    const sent = await fetch("https://api.resend.com/emails", {
      method: "POST", headers: { Authorization: "Bearer " + resend, "Content-Type": "application/json" },
      body: JSON.stringify({ from: "EDMEL POS Test <onboarding@resend.dev>", to: [recipient], subject: "EDMEL Security Alert — " + title, html: emailHtml }),
    });
    if (!sent.ok) console.error("manager-account-security: Resend test notification failed", sent.status);
  } catch { console.error("manager-account-security: Resend test notification request failed"); }
}

Deno.serve(async req => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL"), serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY"), resend = Deno.env.get("RESEND_API_KEY"), testRecipient = Deno.env.get("RESEND_TEST_EMAIL");
  if (!url || !serviceKey || !anonKey) return reply({ error: "Security service configuration is incomplete." }, 500);
  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return reply({ error: "Invalid request body." }, 400); }
  const action = typeof body.action === "string" ? body.action : "";

  try {
    if (action === "password_reset_request") {
      const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) {
        return reply({ success: true, message: "If the Manager account is eligible, a recovery email will be sent." });
      }
      const { data: matches, error } = await db.from("restaurant_users").select("id,user_id,manager_email")
        .eq("manager_email", email).eq("role", "staff").ilike("position", "manager")
        .eq("is_active", true).eq("manager_can_change_password", true)
        .eq("manager_auth_method", "password").eq("manager_auth_setup_status", "active")
        .not("manager_email_verified_at", "is", null).limit(2);
      if (error) return reply({ error: "Unable to process password recovery." }, 500);
      const matchedUserIds = [...new Set((matches || []).map((row: any) => row.user_id).filter(Boolean))];
      if (matchedUserIds.length === 1) {
        const redirectTo = typeof body.redirect_to === "string" && body.redirect_to.length < 1000 ? body.redirect_to : undefined;
        const authClient = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
        const result = await authClient.auth.resetPasswordForEmail(email, redirectTo ? { redirectTo } : undefined);
        if (result.error) console.error("manager-account-security: Supabase recovery email request failed");
      }
      return reply({ success: true, message: "If the Manager account is eligible, a recovery email will be sent." });
    }

    if (action === "pin_reset_request") {
      if (!resend || !testRecipient) return reply({ error: "PIN recovery test email is not configured." }, 503);
      const username = typeof body.username === "string" ? body.username.trim() : "";
      if (!/^[a-zA-Z0-9._-]{1,80}$/.test(username)) return reply({ success: true, message: "If the account is eligible, a verification code will be sent to the configured test inbox." });
      const { data: matches, error } = await db.from("restaurant_users")
        .select("id,user_id,restaurant_id,manager_email,manager_email_verified_at")
        .eq("cashier_username", username).eq("role", "staff").ilike("position", "manager")
        .eq("is_active", true).eq("manager_can_change_pin", true)
        .not("manager_email", "is", null).not("manager_email_verified_at", "is", null).limit(2);
      if (error) return reply({ error: "Unable to process PIN recovery." }, 500);
      if (!matches || matches.length !== 1) return reply({ success: true, message: "If the account is eligible, a verification code will be sent to the configured test inbox." });
      const target = matches[0];
      const { data: pinCredential, error: credentialError } = await db.from("cashier_credentials").select("id").eq("restaurant_user_id", target.id).maybeSingle();
      if (credentialError) return reply({ error: "Unable to verify Manager PIN record." }, 500);
      if (!pinCredential) return reply({ success: true, message: "If the account is eligible, a verification code will be sent to the configured test inbox." });
      const { data: recent, error: recentError } = await db.from("manager_pin_reset_challenges")
        .select("last_sent_at").eq("manager_restaurant_user_id", target.id).is("consumed_at", null)
        .order("created_at", { ascending: false }).limit(1);
      if (recentError) return reply({ error: "Unable to check the recovery request limit." }, 500);
      if (recent?.[0] && Date.now() - new Date(recent[0].last_sent_at).getTime() < 60000) return reply({ error: "Wait 60 seconds before requesting another code." }, 429);
      const invalidated = await db.from("manager_pin_reset_challenges").update({ consumed_at: new Date().toISOString(), verification_token_hash: null }).eq("manager_restaurant_user_id", target.id).is("consumed_at", null);
      if (invalidated.error) return reply({ error: "Unable to renew the PIN recovery request." }, 500);
      const otp = String(crypto.getRandomValues(new Uint32Array(1))[0] % 1000000).padStart(6, "0");
      const otpHash = await digest(otp, resend);
      const { data: challenge, error: insertError } = await db.from("manager_pin_reset_challenges")
        .insert({ manager_restaurant_user_id: target.id, manager_user_id: target.user_id, restaurant_id: target.restaurant_id, otp_hash: otpHash, expires_at: new Date(Date.now() + 600000).toISOString(), attempts: 0 })
        .select("id").single();
      if (insertError || !challenge) return reply({ error: "Unable to create PIN recovery request." }, 500);
      const sent = await fetch("https://api.resend.com/emails", {
        method: "POST", headers: { Authorization: "Bearer " + resend, "Content-Type": "application/json" },
        body: JSON.stringify({ from: "EDMEL POS Test <onboarding@resend.dev>", to: [testRecipient], subject: "EDMEL POS — Manager PIN recovery code",
          html: "<h2>Manager PIN recovery</h2><p>Your test verification code is:</p><p style='font-size:30px;font-weight:bold;letter-spacing:8px'>" + otp + "</p><p>Expires in 10 minutes. Five attempts maximum. One use only.</p><p><strong>Testing mode:</strong> this code was sent to the configured Resend test inbox, not the Manager's assigned email address.</p>" })
      });
      if (!sent.ok) {
        await db.from("manager_pin_reset_challenges").delete().eq("id", challenge.id);
        return reply({ error: "Resend could not send the test verification code.", provider_status: sent.status }, 502);
      }
      return reply({ success: true, challenge_id: challenge.id, expires_in_seconds: 600, message: "Verification code sent to the configured test inbox." });
    }

    if (action === "pin_reset_verify") {
      if (!resend) return reply({ error: "PIN recovery test email is not configured." }, 503);
      const challengeId = typeof body.challenge_id === "string" ? body.challenge_id : "";
      const otp = typeof body.otp === "string" ? body.otp : "";
      if (!/^[0-9a-f-]{36}$/i.test(challengeId) || !/^\d{6}$/.test(otp)) return reply({ error: "Enter the six-digit verification code." }, 400);
      const status = await db.rpc("verify_manager_pin_reset_otp", { p_challenge_id: challengeId, p_otp_hash: await digest(otp, resend) });
      if (status.error) return reply({ error: "Unable to verify the code." }, 500);
      if (status.data !== "verified") return reply({ error: status.data === "expired" ? "Code expired. Request another." : status.data === "locked" ? "Too many attempts. Request another code." : status.data === "used" ? "Code already used." : "Incorrect code." }, 400);
      const verificationToken = Array.from(crypto.getRandomValues(new Uint8Array(32)), b => b.toString(16).padStart(2, "0")).join("");
      const tokenHash = await digest(verificationToken, resend);
      const tokenSaved = await db.from("manager_pin_reset_challenges").update({ verification_token_hash: tokenHash })
        .eq("id", challengeId).not("verified_at", "is", null).is("consumed_at", null);
      if (tokenSaved.error) return reply({ error: "Unable to secure the verified recovery session." }, 500);
      return reply({ success: true, challenge_id: challengeId, verification_token: verificationToken, message: "Verification code confirmed." });
    }

    if (action === "pin_reset_complete") {
      if (!resend || !testRecipient) return reply({ error: "PIN recovery test email is not configured." }, 503);
      const challengeId = typeof body.challenge_id === "string" ? body.challenge_id : "";
      const newPin = typeof body.new_pin === "string" ? body.new_pin : "";
      const verificationToken = typeof body.verification_token === "string" ? body.verification_token : "";
      if (!/^[0-9a-f-]{36}$/i.test(challengeId) || !/^\d{6}$/.test(newPin) || !/^[0-9a-f]{64}$/.test(verificationToken)) return reply({ error: "Enter a valid recovery token and six-digit new PIN." }, 400);
      const result = await db.rpc("reset_manager_pin_with_otp", { p_challenge_id: challengeId, p_new_pin: newPin, p_verification_token_hash: await digest(verificationToken, resend) });
      if (result.error) return reply({ error: result.error.message || "Unable to reset Manager PIN." }, 400);
      const target = Array.isArray(result.data) ? result.data[0] : result.data;
      if (!target?.manager_user_id || !target?.restaurant_id) return reply({ error: "PIN reset was not confirmed." }, 500);
      await notifyAdmins(db, target.restaurant_id, target.manager_user_id, "pin_reset", "Manager PIN reset", "A Manager PIN was reset using the test recovery flow.", resend, testRecipient);
      return reply({ success: true, message: "Manager PIN reset completed." });
    }

    const bearer = (req.headers.get("Authorization") || "").match(/^Bearer\s+(.+)$/i);
    if (!bearer) return reply({ error: "Authentication required." }, 401);
    const token = bearer[1];
    const { data: authData, error: authError } = await db.auth.getUser(token);
    const user = authData?.user;
    if (authError || !user) return reply({ error: "Invalid or expired session." }, 401);

    if (action === "change_pin") {
      const currentPin = typeof body.current_pin === "string" ? body.current_pin : "";
      const newPin = typeof body.new_pin === "string" ? body.new_pin : "";
      if (!/^\d{6}$/.test(currentPin) || !/^\d{6}$/.test(newPin)) return reply({ error: "PIN must be exactly six digits." }, 400);
      const restaurantId = typeof body.restaurant_id === "string" ? body.restaurant_id : "";
      if (!/^[0-9a-f-]{36}$/i.test(restaurantId)) return reply({ error: "Invalid Manager restaurant." }, 400);
      const userClient = createClient(url, anonKey, { global: { headers: { Authorization: "Bearer " + token } }, auth: { persistSession: false, autoRefreshToken: false } });
      const changed = await userClient.rpc("manager_change_own_pin", { p_restaurant_id: restaurantId, p_current_pin: currentPin, p_new_pin: newPin });
      if (changed.error) return reply({ error: changed.error.message || "Unable to change Manager PIN." }, 400);
      const changeStatus = changed.data;
      if (changeStatus !== "success") return reply({ error: changeStatus === "incorrect" ? "Current PIN is incorrect." : changeStatus === "locked" ? "PIN is locked. Contact the Owner or Admin for assistance." : changeStatus === "same_pin" ? "Choose a new PIN different from the current PIN." : changeStatus === "disabled" ? "Manager PIN changes are not enabled for this account." : "Invalid PIN change request." }, 400);
      const { data: manager } = await db.from("restaurant_users").select("id,restaurant_id").eq("user_id", user.id).eq("restaurant_id", restaurantId).eq("role", "staff").ilike("position", "manager").eq("is_active", true).maybeSingle();
      if (manager) await notifyAdmins(db, restaurantId, user.id, "pin_changed", "Manager PIN changed", "A Manager changed their own PIN.", resend, testRecipient);
      return reply({ success: true, message: "Manager PIN changed." });
    }

    if (action === "change_password" || action === "password_reset_completed") {
      const restaurantId = typeof body.restaurant_id === "string" ? body.restaurant_id : "";
      const { data: manager, error: managerError } = await db.from("restaurant_users")
        .select("id,restaurant_id,manager_email,manager_auth_method,manager_can_change_password,manager_auth_setup_status,is_active")
        .eq("user_id", user.id).eq("restaurant_id", restaurantId).eq("role", "staff").ilike("position", "manager").eq("is_active", true).maybeSingle();
      if (managerError || !manager || manager.manager_can_change_password !== true) return reply({ error: "Manager password changes are not enabled for this account." }, 403);
      if (manager.manager_auth_method !== "password" || manager.manager_auth_setup_status !== "active") return reply({ error: "Password sign-in is not active for this Manager account." }, 403);
      if (action === "change_password") {
        const currentPassword = typeof body.current_password === "string" ? body.current_password : "";
        const newPassword = typeof body.new_password === "string" ? body.new_password : "";
        if (newPassword.length < 12 || newPassword.length > 128) return reply({ error: "Use a password between 12 and 128 characters." }, 400);
        if (!currentPassword || currentPassword.length > 128) return reply({ error: "Enter your current password." }, 400);
        const authClient = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
        const verified = await authClient.auth.signInWithPassword({ email: String(manager.manager_email || ""), password: currentPassword });
        if (verified.error || verified.data?.user?.id !== user.id) return reply({ error: "Current password is incorrect." }, 401);
        const updated = await db.auth.admin.updateUserById(user.id, { password: newPassword });
        if (updated.error) return reply({ error: "Unable to update Manager password." }, 400);
      }
      await notifyAdmins(db, restaurantId, user.id, action === "change_password" ? "password_changed" : "password_reset", action === "change_password" ? "Manager password changed" : "Manager password reset", action === "change_password" ? "A Manager changed their account password." : "A Manager completed a password recovery.", resend, testRecipient);
      return reply({ success: true, message: action === "change_password" ? "Manager password changed." : "Password recovery completed." });
    }
    return reply({ error: "Unsupported security action." }, 400);
  } catch (error) {
    console.error("manager-account-security: request failed", error instanceof Error ? error.message : "unknown error");
    return reply({ error: "Unable to process Manager security request." }, 500);
  }
});