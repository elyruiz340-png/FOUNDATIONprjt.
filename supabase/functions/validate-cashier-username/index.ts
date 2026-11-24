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
    if (!/^[a-zA-Z0-9._-]{1,80}$/.test(username)) return json({ valid: false });

    const escapedPattern = username.replace(/[\\%_]/g, "\\$&");
    const admin = createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });
    const { data: rows, error } = await admin.from("restaurant_users")
      .select("id,restaurant_id,cashier_username,role,position,is_active")
      .ilike("cashier_username", escapedPattern)
      .eq("is_active", true)
      .eq("role", "staff")
      .limit(2);

    if (error) return json({ error: "Unable to validate username" }, 500);
    const staff = (rows || []).find((row: any) =>
      String(row.cashier_username || "").trim().toLowerCase() === username.toLowerCase() &&
      ["", "cashier"].includes(String(row.position || "").trim().toLowerCase())
    );
    if (!staff) return json({ valid: false });

    const { data: credential, error: credentialError } = await admin.from("cashier_credentials")
      .select("locked_at,pin_hash")
      .eq("restaurant_user_id", staff.id)
      .maybeSingle();
    if (credentialError) return json({ error: "Unable to validate username" }, 500);
    if (!credential?.pin_hash || credential.locked_at !== null) return json({ valid: false });

    const { data: access, error: accessError } = await admin.from("staff_branch_access")
      .select("branch_id")
      .eq("restaurant_user_id", staff.id)
      .eq("restaurant_id", staff.restaurant_id)
      .eq("is_active", true);
    if (accessError) return json({ error: "Unable to validate username" }, 500);

    const branchIds = (access || []).map((row: any) => row.branch_id).filter(Boolean);
    if (!branchIds.length) return json({ valid: false });

    const { data: branches, error: branchError } = await admin.from("restaurant_branches")
      .select("id")
      .eq("restaurant_id", staff.restaurant_id)
      .eq("is_active", true)
      .in("id", branchIds);
    if (branchError) return json({ error: "Unable to validate username" }, 500);

    return json({ valid: Array.isArray(branches) && branches.length > 0 });
  } catch (error) {
    console.error("Username validation failed:", error);
    return json({ error: "Unable to validate username" }, 500);
  }
});