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
    const suppliedPermissions = body.permissions;
    let branchId = typeof body.branch_id === "string" ? body.branch_id : "";

    if (!restaurantId || !/^[0-9a-f-]{36}$/i.test(restaurantId)) return json({ error: "Invalid restaurant" }, 400);
    if (!fullName || fullName.length > 100 || displayName.length > 60) return json({ error: "Check the required name fields" }, 400);
    if (!["Cashier", "Manager", "Kitchen Staff", "Dispatcher"].includes(position)) return json({ error: "Invalid staff position" }, 400);
    if (username.length < 3 || username.length > 40 || !/^[A-Za-z0-9._-]+$/.test(username)) return json({ error: "Invalid username format" }, 400);
    if (!/^[0-9]{6}$/.test(pin)) return json({ error: "PIN must contain exactly six digits" }, 400);
    const permissionKeys = ["orders", "tables", "stocks", "dispatcher", "settings", "void"];
    if (!suppliedPermissions || typeof suppliedPermissions !== "object" || Array.isArray(suppliedPermissions)) return json({ error: "Invalid permissions" }, 400);
    const suppliedKeys = Object.keys(suppliedPermissions);
    if (!["orders", "tables", "stocks", "dispatcher", "settings"].every((key) => typeof suppliedPermissions[key] === "boolean") ||
      suppliedKeys.some((key) => !permissionKeys.includes(key)) ||
      (Object.prototype.hasOwnProperty.call(suppliedPermissions, "void") && typeof suppliedPermissions.void !== "boolean")) {
      return json({ error: "Invalid permissions" }, 400);
    }

    if (branchId && !/^[0-9a-f-]{36}$/i.test(branchId)) return json({ error: "Invalid branch" }, 400);
    if (!branchId) {
      const { data: mainBranch, error: branchError } = await admin
        .from("restaurant_branches").select("id").eq("restaurant_id", restaurantId)
        .eq("is_default", true).eq("is_active", true).maybeSingle();
      if (branchError || !mainBranch) return json({ error: "Main Branch is not configured" }, 409);
      branchId = mainBranch.id;
    }

    const { data: branch, error: branchLookupError } = await admin
      .from("restaurant_branches").select("id,restaurant_id,is_active")
      .eq("id", branchId).eq("restaurant_id", restaurantId).maybeSingle();
    if (branchLookupError || !branch || !branch.is_active) return json({ error: "Branch not found or inactive" }, 404);

    const { data: actorLinks, error: actorLinkError } = await admin
      .from("restaurant_users")
      .select("id,role,position,is_active,full_name,display_name,cashier_username")
      .eq("user_id", actor.id).eq("restaurant_id", restaurantId).eq("is_active", true);

    if (actorLinkError) {
      console.error("create-staff: authorization lookup failed");
      return json({ error: "Unable to verify permissions" }, 500);
    }
    const ownerAdmin = (actorLinks || []).some((link: any) => ["owner", "admin"].includes(String(link.role).toLowerCase()));
    const managerLink = (actorLinks || []).find((link: any) =>
      String(link.role).toLowerCase() === "staff" && String(link.position || "").toLowerCase() === "manager");

    if (!ownerAdmin) {
      if (!managerLink || position === "Manager") return json({ error: "Manager access cannot create or promote another Manager" }, 403);
      const { data: branchAccess, error: accessError } = await admin
        .from("staff_branch_access").select("permissions,is_active")
        .eq("restaurant_user_id", managerLink.id).eq("branch_id", branchId)
        .eq("restaurant_id", restaurantId).eq("is_active", true).maybeSingle();
      if (accessError) return json({ error: "Unable to verify branch permissions" }, 500);
      if (!branchAccess?.permissions?.staff_management) return json({ error: "Staff management access is not enabled for this branch" }, 403);
      for (const key of Object.keys(suppliedPermissions)) {
        if (suppliedPermissions[key] === true && branchAccess.permissions[key] !== true) {
          return json({ error: "You cannot assign permissions beyond your own branch access" }, 403);
        }
      }
    }

    const internalEmail = `staff-${crypto.randomUUID()}@staff.halina.invalid`;
    const randomBytes = crypto.getRandomValues(new Uint8Array(24));
    const randomPassword = Array.from(randomBytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email: internalEmail, password: randomPassword, email_confirm: true,
      user_metadata: { account_type: "edmel_staff" },
    });
    if (createError || !created.user) {
      console.error("create-staff: Auth account creation failed");
      return json({ error: "Unable to create staff account" }, 500);
    }
    createdAuthUserId = created.user.id;

    const { data: staffLinkId, error: profileError } = await admin.rpc("edmel_create_staff_profile_with_pin", {
      p_actor_user_id: actor.id, p_staff_user_id: created.user.id,
      p_restaurant_id: restaurantId, p_branch_id: branchId,
      p_full_name: fullName, p_display_name: displayName || null,
      p_position: position, p_username: username,
      p_permissions: suppliedPermissions, p_pin: pin,
    });

    if (profileError || !staffLinkId) {
      await admin.auth.admin.deleteUser(created.user.id);
      createdAuthUserId = null;
      if (profileError?.code === "23505") return json({ error: "That username is already in use" }, 409);
      if (profileError?.code === "42501") return json({ error: profileError.message }, 403);
      if (profileError?.code === "22023") return json({ error: profileError.message }, 400);
      console.error("create-staff: profile/credential transaction failed");
      return json({ error: "Unable to finish staff creation; no staff account was kept" }, 500);
    }

    let auditLogged = true;
    if (!ownerAdmin) {
      const actorName = managerLink?.display_name || managerLink?.full_name || managerLink?.cashier_username || "Manager";
      const { error: auditError } = await admin.from("audit_logs").insert({
        restaurant_id: restaurantId,
        actor_user_id: actor.id,
        actor_name: actorName,
        actor_role: "manager",
        action_category: "Staff & Security",
        action: "Created staff account",
        record_type: "staff_account",
        record_id: staffLinkId,
        result: "success",
        details: { branch_id: branchId, staff_name: fullName, username, position, permissions: suppliedPermissions },
      });
      if (auditError) {
        auditLogged = false;
        console.error("create-staff: Manager staff creation audit insert failed", auditError.message);
      }
    }

    createdAuthUserId = null;
    return json({
      success: true, staff_id: staffLinkId, username, branch_id: branchId, audit_logged: auditLogged,
      message: "Staff account created. Set up login through the staff login screen.",
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