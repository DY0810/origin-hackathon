// Asset identification (CLAUDE.md §7.2): which building / road / pole the phone is aimed at, plus the zone multiplier there
// for the camera's MultiplierChip (design-system/MASTER.md §7.1).
// GET ?lat&lng&heading?&accuracy?
// -> { primary: {kind, name, osm_id, distance_m} | null, candidates: [...up to 5], address: string | null,
//      multiplier: number, reason?: "low_accuracy" | "lookup_failed" }
// primary null = unknown asset: the app shows "New asset" and lets the reporter name it. Matching lives in geo.ts.
// ponytail: live OSM Overpass per lookup (two public instances raced, ~1-5 s, rate limited); cache footprints in a PostGIS assets table when traffic grows.
// ponytail: unknown assets create nothing yet; the crowd-built inventory (§7.2 step 5) comes with that assets table.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { matchAssets, MAX_ACCURACY_M, type OsmElement } from "./geo.ts";

// Public Overpass instances are individually flaky (errors, 5-15 s stalls), so every lookup races two.
const OVERPASS = ["https://overpass-api.de/api/interpreter", "https://overpass.private.coffee/api/interpreter"];
const RADIUS_M = 60;
const BOX_M = 100; // clip geometry to this half-size box: long roads would otherwise ship kilometres of points
const TIMEOUT_MS = 8000; // per instance; observed 0.8-7.3 s from overpass-api.de

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// One query: footprints (ways + multipolygons), road/path segments, bridges and point assets around the phone, with geometry
// inline. `out geom` (not `out tags geom`) because relations need their members.
function overpassQuery(lat: number, lng: number) {
  const at = `(around:${RADIUS_M},${lat},${lng})`;
  const dLat = BOX_M / 111_320, dLng = dLat / Math.cos((lat * Math.PI) / 180);
  const bbox = [lat - dLat, lng - dLng, lat + dLat, lng + dLng].map((n) => n.toFixed(6)).join(",");
  return `[out:json][timeout:8];(way${at}[building];rel${at}[building];way${at}[highway];way${at}[man_made=bridge];` +
    `node${at}[power=pole];node${at}[highway=street_lamp];node${at}[man_made][man_made!=surveillance];);out geom(${bbox});`;
}

// First instance to answer with valid JSON wins; the other is cancelled.
async function overpass(query: string): Promise<OsmElement[]> {
  const race = new AbortController();
  try {
    return await Promise.any(OVERPASS.map(async (url) => {
      const res = await fetch(url, {
        method: "POST",
        headers: { "User-Agent": "FaultLine/0.1 (hackathon asset lookup)" },
        body: new URLSearchParams({ data: query }),
        signal: AbortSignal.any([race.signal, AbortSignal.timeout(TIMEOUT_MS)]),
      });
      if (!res.ok) throw new Error(`${url} ${res.status}`);
      const { elements } = (await res.json()) as { elements?: OsmElement[] }; // an HTML error page throws here too
      if (!Array.isArray(elements)) throw new Error(`${url} no elements`);
      return elements;
    }));
  } finally {
    race.abort();
  }
}

Deno.serve(async (req) => {
  if (req.method !== "GET") return json({ error: "GET only" }, 405);
  const params = new URL(req.url).searchParams;
  const num = (key: string) => {
    const v = params.get(key);
    return v === null || v.trim() === "" ? null : Number(v);
  };
  const lat = num("lat"), lng = num("lng"), heading = num("heading"), accuracy = num("accuracy");
  if (lat === null || lng === null || !Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
    return json({ error: "lat and lng required" }, 400);
  }
  const aim = heading !== null && Number.isFinite(heading) ? ((heading % 360) + 360) % 360 : null;

  // Same SQL the points use (award_report), so the chip never promises a different multiplier than the payout.
  const multiplier = supabase.rpc("multiplier_at", { p_geom: `SRID=4326;POINT(${lng} ${lat})` }).then(({ data, error }) => {
    if (error) console.error("multiplier_at failed", error);
    return typeof data === "number" ? data : 1;
  });
  const none = { primary: null, candidates: [], address: null };

  if (accuracy !== null && !(accuracy >= 0 && accuracy <= MAX_ACCURACY_M)) {
    return json({ ...none, multiplier: await multiplier, reason: "low_accuracy" });
  }
  try {
    const elements = await overpass(overpassQuery(lat, lng));
    return json({ ...matchAssets(elements, lat, lng, aim), multiplier: await multiplier });
  } catch (error) {
    console.error("overpass failed", error);
    return json({ ...none, multiplier: await multiplier, reason: "lookup_failed" });
  }
});
