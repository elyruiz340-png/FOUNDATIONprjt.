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
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("create-staff: missing server configuration");
    return json({ error: "Server configuration error" }, 500);
  }

  const authHeader = req.headers.get("Authorization") || "";
  const tokenMatch = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!tokenMatch) return json({ error: "Authentication required" }, 401);

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  let createdAuthUserId: string | null = null;

  try {
    const { data: authData, error: authError } = await admin.auth.getUser(tokenMatch[1]);
    const actor = authData?.user;
    if (authError || !actor) return json({ error: "Invalid or expired session" }, 401);

    const body = await req.json();
    const restaurantId = typeof body.restaurant_id === "string" ? body.restaurant_id : "";
    const fullName = typeof body.full_name === "string" ? body.full_name.trim() : "";
    const displayName = typeof body.display_name === "string" ? body.display_name.trim() : "";
    const position = typeof body.position === "string" ? body.position : "";
    const username = typeof body.username === "string" ? body.username.trim() : "";
    const pin = typeof body.pin === "string" ? body.pin : "";
    const managerEmail = typeof body.manager_email === "string" ? body.manager_email.trim().toLowerCase() : "";
    const managerRedirectTo = typeof body.manager_redirect_to === "string" ? body.manager_redirect_to.trim() : "";
    const suppliedPermissions = body.permissions;
    const managerAssignments = body.manager_assignments;
    const rawBranchIds = Array.isArray(body.branch_ids)
      ? body.branch_ids
      : (typeof body.branch_id === "string" ? [body.branch_id] : []);
    const branchIds = rawBranchIds.filter((id: unknown): id is string => typeof id === "string");

    if (!restaurantId || !/^[0-9a-f-]{36}$/i.test(restaurantId)) return json({ error: "Invalid restaurant" }, 400);
    if (!fullName || fullName.length > 100 || displayName.length > 60) return json({ error: "Check the required name fields" }, 400);
    if (!["Cashier", "Manager", "Kitchen Staff", "Dispatcher"].includes(position)) return json({ error: "Invalid staff position" }, 400);
    if (username.length < 3 || username.length > 40 || !/^[A-Za-z0-9._-]+$/.test(username)) return json({ error: "Invalid username format" }, 400);
    if (position !== "Manager" && !/^[0-9]{6}$/.test(pin)) return json({ error: "PIN must contain exactly six digits" }, 400);
    if (position === "Manager" && managerEmail && (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(managerEmail) || managerEmail.length > 254)) return json({ error: "Enter a valid Manager email address" }, 400);
    if (position === "Manager" && managerEmail && !managerRedirectTo) return json({ error: "Manager invitation redirect is missing. Refresh Admin and try again." }, 400);
    const rolePermissionKeys: Record<string, string[]> = {
      "Cashier": ["orders", "void", "tables", "stocks", "settings"],
      "Kitchen Staff": ["orders"],
      "Dispatcher": ["dispatcher", "orders"],
    };
    if (position === "Manager") {
      if (suppliedPermissions !== undefined && suppliedPermissions !== null &&
          (typeof suppliedPermissions !== "object" || Array.isArray(suppliedPermissions) || Object.keys(suppliedPermissions).length !== 0)) {
        return json({ error: "Manager permissions must be configured per branch in the Manager Permissions editor" }, 400);
      }
      if (!Array.isArray(managerAssignments) || managerAssignments.length < 1 || managerAssignments.length > 20) {
        return json({ error: "Configure Manager permissions for every assigned branch" }, 400);
      }
      const assignmentIds = managerAssignments.map((item: any) => item?.branch_id);
      if (assignmentIds.some((id: unknown) => typeof id !== "string") ||
          new Set(assignmentIds).size !== assignmentIds.length) {
        return json({ error: "Invalid Manager branch permission assignments" }, 400);
      }
    } else {
      if (!suppliedPermissions || typeof suppliedPermissions !== "object" || Array.isArray(suppliedPermissions)) {
        return json({ error: "Invalid permissions" }, 400);
      }
      const allowed = rolePermissionKeys[position] || [];
      const suppliedKeys = Object.keys(suppliedPermissions);
      if (suppliedKeys.some((key) => !allowed.includes(key)) ||
          suppliedKeys.some((key) => typeof suppliedPermissions[key] !== "boolean")) {
        return json({ error: "One or more permissions are not available for this position" }, 400);
      }
      for (const key of allowed) {
        if (Object.prototype.hasOwnProperty.call(suppliedPermissions, key) &&
            typeof suppliedPermissions[key] !== "boolean") {
          return json({ error: "Invalid permissions" }, 400);
        }
      }
    }

    if (branchIds.length < 1 || branchIds.length > 20 ||
        branchIds.some((id: string) => !/^[0-9a-f-]{36}$/i.test(id)) ||
        new Set(branchIds).size !== branchIds.length) {
      return json({ error: "Select one to twenty unique active branches" }, 400);
    }
    if (position !== "Manager" && branchIds.length !== 1) {
      return json({ error: "Cashier, Kitchen Staff, and Dispatcher must be assigned to exactly one branch" }, 400);
    }
    if (position === "Manager") {
      const assignmentIds = managerAssignments.map((item: any) => item.branch_id);
      if (assignmentIds.length !== branchIds.length || branchIds.some((id: string) => !assignmentIds.includes(id))) {
        return json({ error: "Manager permissions must match every selected branch exactly" }, 400);
      }
    }
    const { data: branches, error: branchLookupError } = await admin
      .from("restaurant_branches").select("id,restaurant_id,is_active")
      .eq("restaurant_id", restaurantId).in("id", branchIds).eq("is_active", true);
    if (branchLookupError) return json({ error: "Unable to verify selected branches" }, 500);
    if (!branches || branches.length !== branchIds.length) {
      return json({ error: "One or more selected branches are missing or inactive" }, 404);
    }

    const { data: actorLinks, error: actorLinkError } = await admin
      .from("restaurant_users")
      .select("id,role,position,is_active,full_name,display_name,cashier_username")
      .eq("user_id", actor.id).eq("restaurant_id", restaurantId).eq("is_active", true);

    if (actorLinkError) {
      console.error("create-staff: authorization lookup failed");
      return json({ error: "Unable to verify permissions" }, 500);
    }
    const ownerAdmin = (actorLinks || []).some((link: any) => ["owner", "admin"].includes(String(link.role).toLowerCase()));
    if (!ownerAdmin) {
      return json({ error: "Active Owner/Admin access is required to create staff accounts." }, 403);
    }

    let created: any;
    if (position === "Manager" && managerEmail) {
      let redirectUrl: URL;
      try {
        const originHeader = req.headers.get("origin") || "";
        redirectUrl = new URL(managerRedirectTo);
        const originUrl = new URL(originHeader);
        const localDevelopment = originUrl.hostname === "localhost" || originUrl.hostname === "127.0.0.1";
        if ((!localDevelopment && originUrl.protocol !== "https:") ||
            redirectUrl.origin !== originUrl.origin ||
            !redirectUrl.pathname.endsWith("/manager.html") ||
            redirectUrl.username || redirectUrl.password || redirectUrl.search || redirectUrl.hash) {
          throw new Error("Invalid invitation redirect");
        }
      } catch (_error) {
        return json({ error: "The Manager invitation URL is invalid. Open Admin from the HTTPS application and try again." }, 400);
      }

      const { data: invited, error: inviteError } = await admin.auth.admin.inviteUserByEmail(managerEmail, {
        redirectTo: redirectUrl.toString(),
        data: { account_type: "edmel_staff", staff_position: "Manager" },
      });
      if (inviteError || !invited?.user) {
        if (inviteError?.code === "email_exists" || inviteError?.status === 422) {
          return json({ error: "This email address is already registered in EDMEL Auth. Use an unused email address for this new Manager account." }, 409);
        }
        console.error("create-staff: Manager invitation failed", inviteError?.status || "unknown");
        return json({ error: "Unable to send the Manager invitation. Check Supabase Auth email delivery and the allowed redirect URL." }, 502);
      }
      created = invited;
    } else {
      const internalEmail = `staff-${crypto.randomUUID()}@staff.halina.invalid`;
      const randomBytes = crypto.getRandomValues(new Uint8Array(24));
      const randomPassword = Array.from(randomBytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
      const { data: staffCreated, error: createError } = await admin.auth.admin.createUser({
        email: internalEmail, password: randomPassword, email_confirm: true,
        user_metadata: { account_type: "edmel_staff" },
      });
      if (createError || !staffCreated.user) {
        console.error("create-staff: Auth account creation failed");
        return json({ error: "Unable to create staff account" }, 500);
      }
      created = staffCreated;
    }
    createdAuthUserId = created.user.id;

    const managerPasswordRpcArgs = {
      p_actor_user_id: actor.id, p_staff_user_id: created.user.id,
      p_restaurant_id: restaurantId, p_full_name: fullName,
      p_display_name: displayName || null, p_username: username,
      p_manager_email: managerEmail, p_assignments: managerAssignments,
      p_can_change_pin: false, p_can_change_password: true,
    };
    const managerPinRpcArgs = {
      p_actor_user_id: actor.id, p_staff_user_id: created.user.id,
      p_restaurant_id: restaurantId, p_full_name: fullName,
      p_display_name: displayName || null, p_username: username,
      p_pin: pin, p_assignments: managerAssignments,
    };
    const staffRpcArgs = {
      p_actor_user_id: actor.id, p_staff_user_id: created.user.id,
      p_restaurant_id: restaurantId, p_branch_ids: branchIds,
      p_full_name: fullName, p_display_name: displayName || null,
      p_position: position, p_username: username,
      p_permissions: suppliedPermissions, p_pin: pin,
    };
    const { data: staffLinkId, error: profileError } = position === "Manager"
      ? (managerEmail
        ? await admin.rpc("edmel_create_password_manager_profile_with_branch_permissions", managerPasswordRpcArgs)
        : await admin.rpc("edmel_create_staff_profile_with_branch_permissions", managerPinRpcArgs))
      : await admin.rpc("edmel_create_staff_profile_with_branches", staffRpcArgs);

    if (profileError || !staffLinkId) {
      await admin.auth.admin.deleteUser(created.user.id);
      createdAuthUserId = null;
      if (profileError?.code === "23505") return json({ error: "That username is already in use" }, 409);
      if (profileError?.code === "42501") return json({ error: profileError.message }, 403);
      if (profileError?.code === "22023") return json({ error: profileError.message }, 400);
      console.error("create-staff: profile/credential transaction failed");
      return json({ error: "Unable to finish staff creation; no staff account was kept" }, 500);
    }

    const auditLogged = true;

    createdAuthUserId = null;
    return json({
      success: true, staff_id: staffLinkId, username, branch_id: branchIds[0], branch_ids: branchIds, audit_logged: auditLogged,
      message: position === "Manager" && managerEmail
        ? "Manager account created. An invitation email has been sent."
        : "Staff account created. Set up login through the staff login screen.",
    }, 201);
  } catch (_error) {
    if (createdAuthUserId) {
      try { await admin.auth.admin.deleteUser(createdAuthUserId); }
      catch (_cleanupError) { console.error("create-staff: cleanup of incomplete Auth account failed"); }
    }
    console.error("create-staff: request failed");
    return json({ error: "Unable to create staff account" }, 500);
  }
});