import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

Deno.serve(async (req: Request) => {
  const json = (body: Record<string, unknown>, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
    });

  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "Server configuration error" }, 500);

  try {
    const body = await req.json().catch(() => null);
    const tableId = typeof body?.table_id === "string" ? body.table_id.trim() : "";
    const qrToken = typeof body?.qr_token === "string" ? body.qr_token.trim() : "";
    const tableNumber = typeof body?.table_number === "string" ? body.table_number.trim() : "";

    if (!UUID_RE.test(tableId) || qrToken.length < 16 || qrToken.length > 512 ||
        !tableNumber || tableNumber.length > 40) {
      return json({ error: "A valid table QR code is required." }, 400);
    }

    const admin = createClient(url, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: qrRecord, error: qrError } = await admin
      .from("restaurant_table_qr_tokens")
      .select("table_id")
      .eq("table_id", tableId)
      .eq("token", qrToken)
      .maybeSingle();

    if (qrError) {
      console.error("Customer QR lookup failed:", qrError.message);
      return json({ error: "Unable to verify this table QR code." }, 500);
    }
    if (!qrRecord) return json({ error: "This table QR code is invalid or has been replaced." }, 404);

    const { data: table, error: tableError } = await admin
      .from("restaurant_tables")
      .select("id,restaurant_id,table_number,branch_id,is_active,is_locked")
      .eq("id", qrRecord.table_id)
      .maybeSingle();

    if (tableError) {
      console.error("Customer table lookup failed:", tableError.message);
      return json({ error: "Unable to verify this table QR code." }, 500);
    }
    if (!table || !table.is_active || table.is_locked ||
        String(table.table_number).trim().toLowerCase() !== tableNumber.toLowerCase() ||
        !table.restaurant_id || !table.branch_id) {
      return json({ error: "This table is inactive, locked, or the QR details do not match." }, 404);
    }

    const { data: branch, error: branchError } = await admin
      .from("restaurant_branches")
      .select("id,is_active,menu_catalog_mode,menu_source_branch_id")
      .eq("id", table.branch_id)
      .eq("restaurant_id", table.restaurant_id)
      .eq("is_active", true)
      .maybeSingle();

    if (branchError) {
      console.error("Customer branch lookup failed:", branchError.message);
      return json({ error: "Unable to verify this table QR code." }, 500);
    }
    if (!branch) return json({ error: "This table belongs to an inactive branch." }, 404);

    const catalogBranchId = branch.menu_catalog_mode === "inherit"
      ? (branch.menu_source_branch_id || table.branch_id)
      : table.branch_id;
    const { data: catalogBranch, error: catalogBranchError } = await admin
      .from("restaurant_branches")
      .select("id,is_active")
      .eq("id", catalogBranchId)
      .eq("restaurant_id", table.restaurant_id)
      .eq("is_active", true)
      .maybeSingle();
    if (catalogBranchError) {
      console.error("Customer catalog branch lookup failed:", catalogBranchError.message);
      return json({ error: "Unable to load this restaurant menu." }, 500);
    }
    if (!catalogBranch) return json({ error: "The branch menu source is unavailable." }, 404);

    const { data: categories, error: categoryError } = await admin
      .from("menu_categories")
      .select("id,name,sort_order,is_active,image_url,branch_id")
      .eq("restaurant_id", table.restaurant_id)
      .eq("branch_id", catalogBranchId)
      .eq("is_active", true)
      .order("sort_order", { ascending: true })
      .order("name", { ascending: true });

    if (categoryError) {
      console.error("Customer menu category lookup failed:", categoryError.message);
      return json({ error: "Unable to load this restaurant menu." }, 500);
    }

    const categoryIds = (categories || []).map((category: any) => category.id);
    let menuItems: any[] = [];
    if (categoryIds.length) {
      const { data: items, error: itemError } = await admin
        .from("menu_items")
        .select("id,restaurant_id,category_id,name,description,price,image_url,is_available,sort_order,stock_product_id,branch_id")
        .eq("restaurant_id", table.restaurant_id)
        .eq("is_available", true)
        .in("category_id", categoryIds)
        .eq("branch_id", catalogBranchId)
        .order("sort_order", { ascending: true })
        .order("name", { ascending: true });

      if (itemError) {
        console.error("Customer menu item lookup failed:", itemError.message);
        return json({ error: "Unable to load this restaurant menu." }, 500);
      }
      menuItems = items || [];
    }

    const { data: restaurantProfile, error: profileError } = await admin
      .from("restaurants")
      .select("name,logo_url,address,contact_number,email,website,currency,timezone,tax_rate,appearance_settings")
      .eq("id", table.restaurant_id)
      .maybeSingle();

    if (profileError) {
      console.error("Customer restaurant profile lookup failed:", profileError.message);
      return json({ error: "Unable to load this restaurant profile." }, 500);
    }

    return json({
      success: true,
      restaurant_id: table.restaurant_id,
      branch_id: table.branch_id,
      table_id: table.id,
      table_number: table.table_number,
      categories: categories || [],
      menu_items: menuItems,
      restaurant_profile: restaurantProfile || null,
    });
  } catch (error) {
    console.error("Customer QR resolver error:", error);
    return json({ error: "Unable to verify this table QR code." }, 500);
  }
});