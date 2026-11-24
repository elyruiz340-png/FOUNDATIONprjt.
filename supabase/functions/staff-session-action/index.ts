import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const INACTIVITY_TIMEOUT_MS = 30 * 60 * 1000;

Deno.serve(async (req: Request) => {
  const json = (body: Record<string, unknown>, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !serviceKey || !anonKey) return json({ error: "Server configuration error" }, 500);

  try {
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (!token) return json({ error: "Authentication required" }, 401);
    const caller = createClient(url, anonKey, { auth: { autoRefreshToken: false, persistSession: false } });
    const { data: authData, error: authError } = await caller.auth.getUser(token);
    if (authError || !authData.user) return json({ error: "Invalid session" }, 401);
    const actorId = authData.user.id;
    const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
    const body = await req.json();
    const action = typeof body.action === "string" ? body.action : "";

    if (["start", "heartbeat", "end", "list_branches", "switch_branch", "resume", "unlock"].includes(action)) {
      const sessionId = typeof body.session_id === "string" ? body.session_id : "";
      const { data: links, error: linkError } = await admin.from("restaurant_users")
        .select("id,user_id,restaurant_id,role,position,is_active,cashier_username")
        .eq("user_id", actorId).eq("is_active", true);
      if (linkError) return json({ error: "Unable to verify staff access" }, 500);
      const linkRows = (links || []).filter((r: any) =>
        r.restaurant_id && ["staff", "cashier", "dispatcher", "kitchen"].includes(String(r.role).trim().toLowerCase()));
      if (!linkRows.length) return json({ error: "Active staff account not found" }, 403);

      if (action === "list_branches") {
        const restaurantSlug = typeof body.restaurant_slug === "string" ? body.restaurant_slug.trim().toLowerCase() : "";
        if (!/^[a-z0-9][a-z0-9-]{1,99}$/.test(restaurantSlug)) {
          return json({ error: "A valid restaurant slug is required" }, 400);
        }
        const { data: restaurant, error: restaurantError } = await admin.from("restaurants")
          .select("id,slug").eq("slug", restaurantSlug).maybeSingle();
        if (restaurantError) return json({ error: "Unable to verify restaurant" }, 500);
        if (!restaurant) return json({ error: "Restaurant access not found" }, 403);
        const tenantLinks = linkRows.filter((row: any) => row.restaurant_id === restaurant.id);
        if (!tenantLinks.length) return json({ error: "No active staff access exists for this restaurant" }, 403);
        const assignedIds = new Set<string>();
        for (const candidate of tenantLinks) {
          const { data: accessRows, error: accessError } = await admin.from("staff_branch_access")
            .select("branch_id")
            .eq("restaurant_user_id", candidate.id)
            .eq("restaurant_id", restaurant.id)
            .eq("is_active", true);
          if (accessError) return json({ error: "Unable to load assigned branches" }, 500);
          for (const row of accessRows || []) if (row.branch_id) assignedIds.add(row.branch_id);
        }
        if (!assignedIds.size) return json({ error: "No active branch assignments were found" }, 403);
        const { data: branches, error: branchError } = await admin.from("restaurant_branches")
          .select("id,name,code,is_default")
          .eq("restaurant_id", restaurant.id)
          .eq("is_active", true)
          .in("id", [...assignedIds]);
        if (branchError) return json({ error: "Unable to load assigned branches" }, 500);
        return json({ success: true, restaurant_id: restaurant.id, branches: branches || [] });
      }

      if (action === "start") {
        const restaurantSlug = typeof body.restaurant_slug === "string" ? body.restaurant_slug.trim().toLowerCase() : "";
        const branchIdInput = typeof body.branch_id === "string" ? body.branch_id : "";
        if (!/^[a-z0-9][a-z0-9-]{1,99}$/.test(restaurantSlug)) {
          return json({ error: "A valid restaurant slug is required" }, 400);
        }

        const { data: restaurant, error: restaurantError } = await admin.from("restaurants")
          .select("id,slug").eq("slug", restaurantSlug).maybeSingle();
        if (restaurantError) return json({ error: "Unable to verify restaurant" }, 500);
        if (!restaurant) return json({ error: "Restaurant access not found" }, 403);

        const tenantLinks = linkRows.filter((row: any) => row.restaurant_id === restaurant.id);
        if (!tenantLinks.length) return json({ error: "No active staff account exists for this restaurant" }, 403);

        let selectedLink: any = null;
        let selectedBranchId = "";
        for (const candidate of tenantLinks) {
          const { data: memberships, error: membershipError } = await admin.from("staff_branch_access")
            .select("branch_id,permissions,is_active")
            .eq("restaurant_user_id", candidate.id)
            .eq("restaurant_id", restaurant.id)
            .eq("is_active", true);
          if (membershipError) return json({ error: "Unable to verify branch access" }, 500);
          const activeMemberships = memberships || [];
          if (!activeMemberships.length) continue;

          const ids = activeMemberships.map((m: any) => m.branch_id);
          const { data: branches, error: branchError } = await admin.from("restaurant_branches")
            .select("id,is_default")
            .eq("restaurant_id", restaurant.id)
            .eq("is_active", true)
            .in("id", ids);
          if (branchError) return json({ error: "Unable to load assigned branches" }, 500);

          const activeBranchIds = new Set((branches || []).map((b: any) => b.id));
          if (branchIdInput) {
            const match = activeMemberships.find((m: any) =>
              m.branch_id === branchIdInput && activeBranchIds.has(m.branch_id)
            );
            if (match) { selectedLink = candidate; selectedBranchId = match.branch_id; break; }
          } else {
            const chosen = (branches || []).find((b: any) => b.is_default) || (branches || [])[0];
            if (chosen) { selectedLink = candidate; selectedBranchId = chosen.id; break; }
          }
        }

        if (!selectedLink || !selectedBranchId) {
          return json({ error: "No active branch access is assigned to this staff account in the selected restaurant" }, 403);
        }

        const now = new Date().toISOString();
        const { data: session, error } = await admin.from("staff_sessions").insert({
          restaurant_id: selectedLink.restaurant_id,
          restaurant_user_id: selectedLink.id,
          user_id: actorId,
          branch_id: selectedBranchId,
          login_at: now,
          last_seen_at: now,
          last_activity_at: now,
        }).select("id,login_at,restaurant_id,restaurant_user_id,branch_id").single();
        if (error) {
          console.error("Session start failed", error.message);
          return json({ error: "Unable to record login" }, 500);
        }
        return json({
          success: true,
          session_id: session.id,
          login_at: session.login_at,
          restaurant_id: session.restaurant_id,
          restaurant_user_id: session.restaurant_user_id,
          branch_id: session.branch_id,
          inactivity_timeout_minutes: (String(selectedLink.position || "").trim().toLowerCase() === "dispatcher" || String(selectedLink.role || "").trim().toLowerCase() === "dispatcher") ? null : 30
        });
      }

      if (!sessionId) return json({ error: "Session ID required" }, 400);
      const { data: session, error: sessionError } = await admin.from("staff_sessions")
        .select("id,restaurant_user_id,restaurant_id,branch_id,user_id,login_at,logout_at,last_seen_at,last_activity_at")
        .eq("id", sessionId).eq("user_id", actorId).maybeSingle();
      if (sessionError || !session) return json({ error: "Session not found" }, 404);
      const linkedActor = linkRows.find((r: any) => r.id === session.restaurant_user_id);
      if (!linkedActor || linkedActor.restaurant_id !== session.restaurant_id) return json({ error: "Staff account is no longer active" }, 403);

      const staffPosition = String(linkedActor.position || "").trim().toLowerCase();
      const staffRole = String(linkedActor.role || "").trim().toLowerCase();
      const isDispatcherSession = staffPosition === "dispatcher" || staffRole === "dispatcher";
      const isCashierSession = staffPosition === "cashier" || staffRole === "cashier";

      if (action === "unlock") {
        const pin = typeof body.pin === "string" ? body.pin : "";
        if (!/^\d{6}$/.test(pin)) return json({ error: "Enter your six-digit PIN." }, 400);
        if (session.logout_at) return json({ error: "Session already ended", expired: true }, 401);
        if (!isCashierSession) return json({ error: "PIN unlock is available only for Cashier sessions." }, 403);

        const restaurantSlugResult = await admin.from("restaurants")
          .select("slug").eq("id", session.restaurant_id).maybeSingle();
        if (restaurantSlugResult.error || !restaurantSlugResult.data?.slug) {
          return json({ error: "Unable to verify the restaurant workspace" }, 500);
        }
        const username = String(linkedActor.cashier_username || "").trim();
        if (!username) return json({ error: "Cashier username is unavailable. Please sign in again." }, 403);

        const { data: verifiedData, error: verifyError } = await admin.rpc("edmel_verify_staff_login_credentials", {
          p_restaurant_slug: restaurantSlugResult.data.slug,
          p_username: username,
          p_pin: pin,
        });
        if (verifyError) {
          console.error("Cashier PIN unlock verification failed:", verifyError.message);
          return json({ error: "Unable to verify your PIN. Please try again." }, 500);
        }
        const verified = Array.isArray(verifiedData) ? verifiedData[0] : verifiedData;
        if (!verified?.cashier_user_id ||
            verified.cashier_user_id !== actorId ||
            verified.restaurant_user_id !== session.restaurant_user_id ||
            verified.restaurant_id !== session.restaurant_id) {
          return json({ error: "Incorrect PIN. Check your PIN and try again. After five failed attempts, ask your Owner/Admin to reset it." }, 401);
        }

        const { data: membership, error: membershipError } = await admin.from("staff_branch_access")
          .select("is_active").eq("restaurant_user_id", session.restaurant_user_id)
          .eq("restaurant_id", session.restaurant_id).eq("branch_id", session.branch_id).maybeSingle();
        if (membershipError) return json({ error: "Unable to verify branch assignment" }, 500);
        if (!membership?.is_active) return json({ error: "Your access to this branch has ended.", expired: true }, 403);

        const { data: branch, error: branchError } = await admin.from("restaurant_branches")
          .select("id").eq("id", session.branch_id)
          .eq("restaurant_id", session.restaurant_id).eq("is_active", true).maybeSingle();
        if (branchError) return json({ error: "Unable to verify branch status" }, 500);
        if (!branch) return json({ error: "This branch is inactive or unavailable.", expired: true }, 403);

        const now = new Date().toISOString();
        const { data: updatedSession, error: updateError } = await admin.from("staff_sessions").update({
          last_seen_at: now,
          last_activity_at: now,
        }).eq("id", sessionId).eq("user_id", actorId).is("logout_at", null)
          .select("id").maybeSingle();
        if (updateError) return json({ error: "Unable to resume your cashier session" }, 500);
        if (!updatedSession) return json({ error: "Session already ended", expired: true }, 401);
        return json({ success: true, unlocked: true, last_activity_at: now });
      }

      if (action === "resume") {
        if (session.logout_at) return json({ success: false, expired: true, error: "Session already ended" }, 401);
        const { data: membership, error: membershipError } = await admin.from("staff_branch_access")
          .select("is_active").eq("restaurant_user_id", session.restaurant_user_id)
          .eq("restaurant_id", session.restaurant_id).eq("branch_id", session.branch_id).maybeSingle();
        if (membershipError) return json({ error: "Unable to verify branch assignment" }, 500);
        if (!membership?.is_active) return json({ success: false, expired: true, error: "Your access to this branch has ended." }, 403);
        const { data: branch, error: branchError } = await admin.from("restaurant_branches")
          .select("id,name").eq("id", session.branch_id)
          .eq("restaurant_id", session.restaurant_id).eq("is_active", true).maybeSingle();
        if (branchError) return json({ error: "Unable to verify branch status" }, 500);
        if (!branch) return json({ success: false, expired: true, error: "This branch is inactive or unavailable." }, 403);
        const { data: restaurant, error: restaurantError } = await admin.from("restaurants")
          .select("slug").eq("id", session.restaurant_id).maybeSingle();
        if (restaurantError) return json({ error: "Unable to verify restaurant" }, 500);
        if (!restaurant?.slug) return json({ success: false, expired: true, error: "Restaurant access is unavailable." }, 403);
        const nowMs = Date.now();
        const lastActivity = new Date(session.last_activity_at || session.login_at || 0).getTime();
        const locked = isCashierSession && (!Number.isFinite(lastActivity) || nowMs - lastActivity >= INACTIVITY_TIMEOUT_MS);
        const remaining = locked ? 0 : Math.max(0, INACTIVITY_TIMEOUT_MS - (nowMs - lastActivity));
        await admin.from("staff_sessions").update({ last_seen_at: new Date(nowMs).toISOString() })
          .eq("id", sessionId).eq("user_id", actorId).is("logout_at", null);
        return json({ success: true, session_id: session.id, restaurant_id: session.restaurant_id,
          branch_id: session.branch_id, restaurant_slug: restaurant.slug, branch_name: branch.name || "",
          locked, inactivity_remaining_ms: remaining, last_activity_at: session.last_activity_at || session.login_at });
      }

      if (action === "switch_branch") {
        const restaurantSlug = typeof body.restaurant_slug === "string" ? body.restaurant_slug.trim().toLowerCase() : "";
        const branchId = typeof body.branch_id === "string" ? body.branch_id : "";
        if (!/^[a-z0-9][a-z0-9-]{1,99}$/.test(restaurantSlug) || !branchId) {
          return json({ error: "Restaurant and branch are required" }, 400);
        }
        if (session.logout_at) return json({ error: "Session already ended", expired: true }, 401);
        const { data: restaurant, error: restaurantError } = await admin.from("restaurants")
          .select("id").eq("slug", restaurantSlug).maybeSingle();
        if (restaurantError) return json({ error: "Unable to verify restaurant" }, 500);
        if (!restaurant || restaurant.id !== session.restaurant_id) {
          return json({ error: "The selected branch does not belong to this session's restaurant" }, 403);
        }
        const lastActivity = new Date(session.last_activity_at || session.login_at || 0).getTime();
        if (!isDispatcherSession && (!Number.isFinite(lastActivity) || Date.now() - lastActivity >= INACTIVITY_TIMEOUT_MS)) {
          if (isCashierSession) {
            return json({ success: false, locked: true, error: "Cashier screen is locked. Enter your PIN to continue." }, 423);
          }
          const now = new Date().toISOString();
          await admin.from("staff_sessions").update({ logout_at: now, last_seen_at: now, end_reason: "inactivity_timeout" })
            .eq("id", sessionId).eq("user_id", actorId).is("logout_at", null);
          return json({ success: false, expired: true, error: "Session expired after 30 minutes of inactivity." }, 401);
        }
        const { data: assignment, error: assignmentError } = await admin.from("staff_branch_access")
          .select("branch_id")
          .eq("restaurant_user_id", session.restaurant_user_id)
          .eq("restaurant_id", session.restaurant_id)
          .eq("branch_id", branchId)
          .eq("is_active", true)
          .maybeSingle();
        if (assignmentError) return json({ error: "Unable to verify branch assignment" }, 500);
        if (!assignment) return json({ error: "You are not assigned to this branch" }, 403);
        const { data: branch, error: branchError } = await admin.from("restaurant_branches")
          .select("id,name,code")
          .eq("id", branchId)
          .eq("restaurant_id", session.restaurant_id)
          .eq("is_active", true)
          .maybeSingle();
        if (branchError) return json({ error: "Unable to verify branch status" }, 500);
        if (!branch) return json({ error: "The selected branch is inactive or unavailable" }, 403);
        const now = new Date().toISOString();
        const { data: updatedSession, error: updateError } = await admin.from("staff_sessions").update({
          branch_id: branch.id,
          last_seen_at: now,
          last_activity_at: now,
        }).eq("id", sessionId).eq("user_id", actorId).is("logout_at", null)
          .select("id").maybeSingle();
        if (updateError) return json({ error: "Unable to switch active branch" }, 500);
        if (!updatedSession) return json({ error: "Session already ended", expired: true }, 401);
        return json({ success: true, restaurant_id: session.restaurant_id, branch_id: branch.id, branch_name: branch.name });
      }

      if (action === "heartbeat") {
        if (session.logout_at) return json({ error: "Session already ended", expired: true }, 401);
        const { data: membership, error: membershipError } = await admin.from("staff_branch_access")
          .select("is_active").eq("restaurant_user_id", session.restaurant_user_id)
          .eq("restaurant_id", session.restaurant_id)
          .eq("branch_id", session.branch_id).maybeSingle();
        const { data: activeBranch, error: branchError } = await admin.from("restaurant_branches")
          .select("id").eq("id", session.branch_id)
          .eq("restaurant_id", session.restaurant_id).eq("is_active", true).maybeSingle();
        if (membershipError || !membership?.is_active || branchError || !activeBranch) {
          const now = new Date().toISOString();
          await admin.from("staff_sessions").update({ logout_at: now, last_seen_at: now, end_reason: "branch_access_removed" })
            .eq("id", sessionId).is("logout_at", null);
          return json({ success: false, expired: true, error: "Your access to this branch has ended." }, 401);
        }
        const lastActivity = new Date(session.last_activity_at || session.login_at || 0).getTime();
        const nowMs = Date.now();
        if (!isDispatcherSession && (!Number.isFinite(lastActivity) || nowMs - lastActivity >= INACTIVITY_TIMEOUT_MS)) {
          const now = new Date(nowMs).toISOString();
          if (isCashierSession) {
            const { error } = await admin.from("staff_sessions").update({ last_seen_at: now })
              .eq("id", sessionId).is("logout_at", null);
            if (error) return json({ error: "Unable to update session heartbeat" }, 500);
            return json({ success: true, locked: true, branch_id: session.branch_id,
              inactivity_timeout_minutes: 30, activity_recorded: false });
          }
          const { error } = await admin.from("staff_sessions").update({
            logout_at: now, last_seen_at: now, end_reason: "inactivity_timeout",
          }).eq("id", sessionId).is("logout_at", null);
          if (error) return json({ error: "Unable to close inactive session" }, 500);
          return json({ success: false, expired: true, error: "Session expired after 30 minutes of inactivity." }, 401);
        }
        const now = new Date(nowMs).toISOString();
        const updates: Record<string, string> = { last_seen_at: now };
        if (body.activity === true) updates.last_activity_at = now;
        const { error } = await admin.from("staff_sessions").update(updates)
          .eq("id", sessionId).is("logout_at", null);
        if (error) return json({ error: "Unable to update session activity" }, 500);
        return json({ success: true, branch_id: session.branch_id, inactivity_timeout_minutes: isDispatcherSession ? null : 30, activity_recorded: body.activity === true });
      }

      const now = new Date().toISOString();
      const { error } = await admin.from("staff_sessions").update({
        logout_at: now, last_seen_at: now, end_reason: "logout",
      }).eq("id", sessionId).is("logout_at", null);
      if (error) return json({ error: "Unable to record logout" }, 500);
      return json({ success: true });
    }

    if (action === "remove_branch_access") {
      return json({ error: "Manager branch-access removal must be submitted through an Admin approval batch." }, 409);
    }
    if (action === "__disabled_legacy_remove_branch_access") {
      const targetId = typeof body.restaurant_user_id === "string" ? body.restaurant_user_id : "";
      const branchId = typeof body.branch_id === "string" ? body.branch_id : "";
      if (!targetId || !branchId) return json({ error: "Staff account and branch are required" }, 400);
      const { data: actorLinks, error: actorError } = await admin.from("restaurant_users")
        .select("id,restaurant_id,role,position,is_active,full_name,display_name,cashier_username")
        .eq("user_id", actorId).eq("is_active", true);
      if (actorError) return json({ error: "Unable to verify manager access" }, 500);
      const manager = (actorLinks || []).find((r: any) =>
        String(r.role).toLowerCase() === "staff" && String(r.position || "").toLowerCase() === "manager");
      if (!manager) return json({ error: "Manager access required" }, 403);
      const { data: actorAccess, error: accessError } = await admin.from("staff_branch_access")
        .select("permissions,is_active").eq("restaurant_user_id", manager.id)
        .eq("restaurant_id", manager.restaurant_id).eq("branch_id", branchId).eq("is_active", true).maybeSingle();
      if (accessError) return json({ error: "Unable to verify branch permissions" }, 500);
      if (!actorAccess?.permissions?.staff_management) return json({ error: "Staff management access is not enabled for this branch" }, 403);
      const { data: target, error: targetError } = await admin.from("restaurant_users")
        .select("id,user_id,restaurant_id,role,position,is_active,full_name,display_name,cashier_username")
        .eq("id", targetId).eq("restaurant_id", manager.restaurant_id).maybeSingle();
      if (targetError || !target || String(target.role).toLowerCase() !== "staff" ||
        String(target.position || "").toLowerCase() === "manager" || target.user_id === actorId) {
        return json({ error: "Only subordinate staff accounts in this restaurant can be removed from a branch" }, 404);
      }
      const { data: targetAccess, error: targetAccessError } = await admin.from("staff_branch_access")
        .select("id,is_active").eq("restaurant_user_id", target.id)
        .eq("restaurant_id", manager.restaurant_id).eq("branch_id", branchId).maybeSingle();
      if (targetAccessError || !targetAccess) return json({ error: "Staff account is not assigned to this branch" }, 404);
      if (!targetAccess.is_active) return json({ success: true, already_removed: true });
      const now = new Date().toISOString();
      const { error: updateError } = await admin.from("staff_branch_access").update({
        is_active: false, updated_at: now,
      }).eq("id", targetAccess.id).eq("is_active", true);
      if (updateError) return json({ error: "Unable to remove staff branch access" }, 500);
      const { error: sessionsError } = await admin.from("staff_sessions").update({
        logout_at: now, last_seen_at: now, end_reason: "branch_access_removed",
      }).eq("restaurant_user_id", target.id).eq("branch_id", branchId).is("logout_at", null);
      if (sessionsError) console.error("Branch access removed but active session cleanup failed", sessionsError.message);
      const { data: branchMeta } = await admin.from("restaurant_branches").select("name").eq("id", branchId).maybeSingle();
      const actorName = manager.display_name || manager.full_name || manager.cashier_username || "Manager";
      const targetName = target.display_name || target.full_name || target.cashier_username || "Staff";
      const { error: auditError } = await admin.from("audit_logs").insert({
        restaurant_id: manager.restaurant_id,
        actor_user_id: actorId,
        actor_name: actorName,
        actor_role: "manager",
        action_category: "Staff & Security",
        action: "Removed staff branch access",
        record_type: "staff_branch_access",
        record_id: target.id,
        result: "success",
        details: { branch_id: branchId, branch_name: branchMeta?.name || "Assigned branch", staff_name: targetName, username: target.cashier_username || "" },
      });
      if (auditError) console.error("Branch access removed but audit insert failed", auditError.message);
      return json({ success: true, branch_access_removed: true, active_sessions_closed: !sessionsError, audit_logged: !auditError });
    }

    if (action === "deactivate") {
      const targetId = typeof body.restaurant_user_id === "string" ? body.restaurant_user_id : "";
      if (!targetId) return json({ error: "Staff account ID required" }, 400);
      const { data: actorLinks, error: actorError } = await admin.from("restaurant_users")
        .select("id,restaurant_id,role").eq("user_id", actorId).eq("is_active", true);
      if (actorError) return json({ error: "Unable to verify administrator" }, 500);
      const adminLink = (actorLinks || []).find((r: any) => ["owner", "admin"].includes(String(r.role).toLowerCase()));
      if (!adminLink) return json({ error: "Owner/Admin access required" }, 403);
      const { data: target, error: targetError } = await admin.from("restaurant_users")
        .select("id,user_id,restaurant_id,role,is_active")
        .eq("id", targetId).eq("restaurant_id", adminLink.restaurant_id).maybeSingle();
      if (targetError || !target) return json({ error: "Staff account not found for this restaurant" }, 404);
      if (target.user_id === actorId) return json({ error: "You cannot deactivate your own account" }, 400);
      if (String(target.role).toLowerCase() !== "staff") return json({ error: "Only staff accounts can be deactivated" }, 400);
      if (!target.is_active) return json({ success: true, already_deactivated: true });
      const now = new Date().toISOString();
      const { error: updateError } = await admin.from("restaurant_users").update({
        is_active: false, deactivated_at: now, deactivated_by: actorId,
      }).eq("id", target.id).eq("is_active", true);
      if (updateError) return json({ error: "Unable to deactivate account" }, 500);
      await admin.from("staff_branch_access").update({ is_active: false, updated_at: now })
        .eq("restaurant_user_id", target.id);
      await admin.from("staff_sessions").update({
        logout_at: now, last_seen_at: now, end_reason: "deactivated",
      }).eq("restaurant_user_id", target.id).is("logout_at", null);
      const { error: banError } = await admin.auth.admin.updateUserById(target.user_id, { ban_duration: "876000h" });
      if (banError) console.error("Account was deactivated in restaurant records, but Auth ban failed", banError.message);
      return json({ success: true, auth_session_revoked: !banError });
    }
    return json({ error: "Unsupported action" }, 400);
  } catch (error) {
    console.error("staff-session-action error", error);
    return json({ error: "Unable to complete request" }, 500);
  }
});