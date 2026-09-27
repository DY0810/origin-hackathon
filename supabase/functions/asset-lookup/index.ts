// Asset identification (CLAUDE.md §7.2): which building / road / pole the phone is aimed at, plus the zone multiplier there
// for the camera's MultiplierChip (design-system/MASTER.md §7.1).
// POST { lat, lng, heading?, accuracy?, elements?: OsmElement[] | null }
// -> { primary: {kind, name, osm_id, distance_m} | null, candidates: [...up to 5], address: string | null,
//      multiplier: number, danger: boolean, reason?: "low_accuracy" | "lookup_failed" }
// The phone fetches the OSM Overpass elements itself (ios AssetLookup.swift) and sends them here; this function only matches.
// Server-side Overpass doesn't work: the edge runtime appends "(…; SupabaseEdgeRuntime/…)" to every outbound User-Agent and
// overpass-api.de answers that with 406 (the other public instances rate limit or time out from here).
// elements null/missing = the phone's Overpass fetch failed: multiplier + danger still come back, reason "lookup_failed".
// danger = inside an active danger zone (CLAUDE.md §6.8): the camera shows the SafetyBanner, multiplier is 1 there.
// primary null = unknown asset: the app shows "New asset" and lets the reporter name it. Matching lives in geo.ts.
// ponytail: elements are client-supplied, which trusts nothing new (the reporter can already type any asset name, and the
// verdict + points don't depend on it). Cache footprints in a server-side PostGIS assets table when traffic grows.
// ponytail: unknown assets create nothing yet; the crowd-built inventory (§7.2 step 5) comes with that assets table.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { matchAssets, MAX_ACCURACY_M, validElements } from "./geo.ts";

const MAX_BODY = 1_000_000;
const MAX_ELEMENTS = 2000;

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (Number(req.headers.get("content-length") ?? 0) > MAX_BODY) return json({ error: "body too large" }, 413);
  const bytes = await req.arrayBuffer();
  if (bytes.byteLength > MAX_BODY) return json({ error: "body too large" }, 413);
  let body: Record<string, unknown>;
  try {
    body = JSON.parse(new TextDecoder().decode(bytes));
    if (typeof body !== "object" || body === null || Array.isArray(body)) throw new Error("not an object");
  } catch {
    return json({ error: "JSON object body required" }, 400);
  }
  const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);
  const lat = num(body.lat), lng = num(body.lng), heading = num(body.heading), accuracy = num(body.accuracy);
  if (lat === null || lng === null || Math.abs(lat) > 90 || Math.abs(lng) > 180) return json({ error: "lat and lng required" }, 400);
  if (body.accuracy != null && accuracy === null) return json({ error: "accuracy must be a number" }, 400);
  const { elements } = body;
  if (elements != null && (!Array.isArray(elements) || elements.length > MAX_ELEMENTS)) {
    return json({ error: `elements must be an array of at most ${MAX_ELEMENTS}` }, 400);
  }
  const aim = heading !== null ? ((heading % 360) + 360) % 360 : null;

  // Same SQL the points use (award_report), so the chip never promises a different multiplier than the payout.
  const multiplier = supabase.rpc("multiplier_at", { p_geom: `SRID=4326;POINT(${lng} ${lat})` }).then(({ data, error }) => {
    if (error) console.error("multiplier_at failed", error);
    return typeof data === "number" ? data : 1;
  });
  const danger = supabase.rpc("in_danger", { p_geom: `SRID=4326;POINT(${lng} ${lat})` }).then(({ data, error }) => {
    if (error) console.error("in_danger failed", error);
    return data === true;
  });
  const zone = { multiplier: await multiplier, danger: await danger };
  const none = { primary: null, candidates: [], address: null };

  if (accuracy !== null && !(accuracy >= 0 && accuracy <= MAX_ACCURACY_M)) return json({ ...none, ...zone, reason: "low_accuracy" });
  if (!Array.isArray(elements)) return json({ ...none, ...zone, reason: "lookup_failed" });
  return json({ ...matchAssets(validElements(elements), lat, lng, aim), ...zone });
});
