const API = "https://api.placedb.org/v1";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json"
};
const keyOf = (s: string) => s.toLowerCase().normalize("NFD").replace(/\p{Diacritic}/gu, "").replace(/[^a-z0-9]/g, "");
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: cors });
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "Location cache is not configured." }, 500);
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON body." }, 400); }
  const action = String(body?.action || "");
  const cc = String(body?.country_code || "").toUpperCase();
  if (!["countries", "regions", "search"].includes(action)) return json({ error: "Unsupported action." }, 400);
  if (action !== "countries" && !/^[A-Z]{2}$/.test(cc)) return json({ error: "A valid ISO alpha-2 country code is required." }, 400);
  const dbHeaders = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" };
  async function readCache(cacheKey: string) {
    const res = await fetch(`${url}/rest/v1/edmel_global_location_cache?cache_key=eq.${encodeURIComponent(cacheKey)}&select=payload,release,expires_at`, { headers: dbHeaders });
    if (!res.ok) throw new Error("Unable to read the geographic cache.");
    const rows = await res.json();
    if (rows?.[0] && Date.parse(rows[0].expires_at) > Date.now()) return rows[0].payload;
    return null;
  }
  async function writeCache(cacheKey: string, payload: any) {
    const release = payload?.release || payload?.s_version || payload?.countries?.[0]?.release || null;
    const res = await fetch(`${url}/rest/v1/edmel_global_location_cache?on_conflict=cache_key`, {
      method: "POST", headers: { ...dbHeaders, Prefer: "resolution=merge-duplicates,return=minimal" },
      body: JSON.stringify({ cache_key: cacheKey, payload, release, fetched_at: new Date().toISOString(), expires_at: new Date(Date.now() + 30 * 86400000).toISOString() })
    });
    if (!res.ok) throw new Error("Unable to update the geographic cache.");
  }
  async function load(cacheKey: string, path: string) {
    const cached = await readCache(cacheKey);
    if (cached) return cached;
    const res = await fetch(API + path, { headers: { Accept: "application/json" } });
    if (res.status === 404) return null;
    if (!res.ok) throw new Error("The global location provider is temporarily unavailable.");
    const payload = await res.json();
    await writeCache(cacheKey, payload);
    return payload;
  }
  try {
    if (action === "countries") {
      const payload = await load("countries", "/countries.json");
      if (!payload?.countries || !Array.isArray(payload.countries)) return json({ error: "Country dataset response was invalid." }, 502);
      return json({ countries: payload.countries, release: payload.release || null });
    }
    if (action === "regions") {
      const payload = await load("regions:" + cc, "/regions/" + cc + ".json");
      if (!payload?.regions || !Array.isArray(payload.regions)) return json({ error: "No regional dataset is available for this country." }, 404);
      return json({ regions: payload.regions, release: payload.release || null });
    }
    const query = String(body?.query || "").trim();
    const normalized = keyOf(query);
    if (normalized.length < 2 || normalized.length > 40) return json({ places: [], release: null });
    let best: any = null;
    for (let depth = 1; depth <= normalized.length; depth++) {
      const prefix = normalized.slice(0, depth);
      const payload = await load("ac:" + cc + ":" + prefix, "/ac/" + cc + "/" + prefix + ".json");
      if (!payload) break;
      best = payload;
      if (payload.complete === true) break;
    }
    const places = Array.isArray(best?.places) ? best.places.filter((p: any) => keyOf(String(p?.name || "")).startsWith(normalized)) : [];
    return json({ places, release: best?.release || null, complete: best?.complete === true });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Location lookup failed." }, 502);
  }
});