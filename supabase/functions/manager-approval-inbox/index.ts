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
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "Server configuration error" }, 500);

  const match = (req.headers.get("Authorization") || "").match(/^Bearer\s+(.+)$/i);
  if (!match) return json({ error: "Authentication required" }, 401);

  const db = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  try {
    const { data: auth, error: authError } = await db.auth.getUser(match[1]);
    if (authError || !auth.user) return json({ error: "Invalid or expired session" }, 401);
    const actorId = auth.user.id;
    const body = await req.json();
    const action = typeof body.action === "string" ? body.action : "inbox";
    const requestedRestaurantId = typeof body.restaurant_id === "string" ? body.restaurant_id : "";
    const { data: links, error: linkError } = await db.from("restaurant_users")
      .select("id,restaurant_id,role,position,full_name,display_name,is_active")
      .eq("user_id", actorId).eq("is_active", true);
    if (linkError) return json({ error: "Unable to verify account access" }, 500);

    const adminLink = (links || []).find((x: any) =>
      x.restaurant_id && (!requestedRestaurantId || x.restaurant_id === requestedRestaurantId) && ["owner", "admin"].includes(String(x.role).toLowerCase()));
    const managerLink = (links || []).find((x: any) =>
      x.restaurant_id && (!requestedRestaurantId || x.restaurant_id === requestedRestaurantId) && String(x.role).toLowerCase() === "staff" &&
      String(x.position || "").toLowerCase() === "manager");
    const role = adminLink ? "admin" : managerLink ? "manager" : "";
    const link = adminLink || managerLink;
    if (!link || !role) return json({ error: "Owner, Admin, or Manager access required" }, 403);

    if (action === "inbox") {
      const limit = Math.min(Math.max(Number(body.limit) || 50, 1), 100);
      let query = db.from("manager_approval_batches")
        .select("id,restaurant_id,branch_id,requested_by_user_id,requested_by_staff_id,status,summary,actions,decision_by_user_id,decision_at,decision_reason,applied_at,created_at")
        .eq("restaurant_id", link.restaurant_id)
        .order("created_at", { ascending: false }).limit(limit);
      if (role === "admin") query = query.in("status", ["pending", "approved", "rejected", "failed"]);
      else query = query.eq("requested_by_user_id", actorId);
      const { data: batches, error } = await query;
      if (error) return json({ error: "Unable to load approval requests" }, 500);

      const { data: notifications, error: notificationError } = await db.from("manager_approval_notifications")
        .select("id,batch_id,notification_type,title,message,is_read,created_at")
        .eq("restaurant_id", link.restaurant_id)
        .eq("recipient_role", role)
        .or(role === "admin" ? "recipient_user_id.is.null" : "recipient_user_id.eq." + actorId)
        .order("created_at", { ascending: false }).limit(100);
      if (notificationError) return json({ error: "Unable to load approval notifications" }, 500);

      const requesterIds = [...new Set((batches || []).map((b: any) => b.requested_by_staff_id))];
      let requesters: any[] = [];
      if (requesterIds.length) {
        const { data } = await db.from("restaurant_users")
          .select("id,full_name,display_name,cashier_username,position")
          .in("id", requesterIds);
        requesters = data || [];
      }
      const branchIds = [...new Set((batches || []).map((b: any) => b.branch_id))];
      let branches: any[] = [];
      if (branchIds.length) {
        const { data } = await db.from("restaurant_branches").select("id,name").in("id", branchIds);
        branches = data || [];
      }
      const requesterMap = new Map(requesters.map((x: any) => [x.id, x]));
      const branchMap = new Map(branches.map((x: any) => [x.id, x]));
      return json({
        success: true, role,
        batches: (batches || []).map((b: any) => ({
          ...b,
          requester: requesterMap.get(b.requested_by_staff_id) || null,
          branch: branchMap.get(b.branch_id) || null,
        })),
        notifications: notifications || [],
      });
    }

    if (action === "mark_read") {
      const notificationId = typeof body.notification_id === "string" ? body.notification_id : "";
      if (!notificationId) return json({ error: "Notification ID required" }, 400);
      let update = db.from("manager_approval_notifications")
        .update({ is_read: true, read_at: new Date().toISOString() })
        .eq("id", notificationId).eq("restaurant_id", link.restaurant_id)
        .eq("recipient_role", role).eq("is_read", false);
      if (role === "manager") update = update.eq("recipient_user_id", actorId);
      else update = update.is("recipient_user_id", null);
      const { error } = await update;
      if (error) return json({ error: "Unable to update notification" }, 500);
      return json({ success: true });
    }

    return json({ error: "Unsupported action" }, 400);
  } catch (error) {
    console.error("manager-approval inbox error", error);
    return json({ error: "Unable to complete approval request" }, 500);
  }
});