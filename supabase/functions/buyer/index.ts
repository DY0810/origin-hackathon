// Buyer dashboard API (CLAUDE.md §6.7, web/dashboard.html). Every call needs `x-buyer-token: <BUYER_TOKEN secret>`.
// GET  -> { reports: [{id, lat, lng, severity, primary_type, damage_types, status, note, explanation,
//                      immediate_danger, created_at, fixed_at, fixed_note, photo_url, in_surge, priority}] }  open first, by priority
//         + bounties: [{id, name, multiplier, surge, area (GeoJSON Polygon)}]  active ones, for the map
//         Reports inside an active surge bounty get in_surge: true and double priority (CLAUDE.md §6.8).
// POST { report_id, note? } -> mark_report_fixed(): sets fixed_at once, pays the reporter a fix bonus.
// POST { bounty: { name, multiplier, ring: [[lng, lat], ...], surge? } } -> post_bounty(): {id, name, multiplier, surge}.
//      The app map heats up on its next map-data load (CLAUDE.md §6.4); surge also adds a storm-sweep quest.
// POST { end_bounty: "<uuid>" } -> end_bounty(): ends it and its quests now (404 if missing or already ended).
// Deployed with verify_jwt = false (supabase/config.toml) so the browser's CORS preflight gets through; the token is the gate.
// ponytail: one shared buyer passcode; per-buyer accounts + territories when there's a second buyer.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { createHash, timingSafeEqual } from "node:crypto";

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, x-buyer-token",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const sha = (s: string) => createHash("sha256").update(s).digest();

function authorized(req: Request) {
  const expected = Deno.env.get("BUYER_TOKEN");
  const given = req.headers.get("x-buyer-token");
  return !!expected && !!given && timingSafeEqual(sha(given), sha(expected));
}

const MULTIPLIERS = [1.5, 2, 3, 5];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_SPAN_DEG = 0.05; // ~5 km: map-data polyfills whole bounties at H3 res 9 into one 5000-cell budget, and the app draws each cell

// Checks a drawn bounty; returns an error message or the row to insert (ring closed as WKT).
// deno-lint-ignore no-explicit-any
export function parseBounty(b: any): string | { name: string; multiplier: number; surge: boolean; wkt: string } {
  const name = typeof b?.name === "string" ? b.name.trim() : "";
  if (!name || name.length > 80) return "Give the bounty a name (up to 80 characters)";
  if (!MULTIPLIERS.includes(b.multiplier)) return "Multiplier must be 1.5, 2, 3 or 5";
  if (b.surge !== undefined && typeof b.surge !== "boolean") return "surge must be true or false";
  if (!Array.isArray(b.ring)) return "Draw the area on the map";
  const ring: number[][] = [...b.ring];
  const ok = ring.every((p) => Array.isArray(p) && p.length === 2 && p.every(Number.isFinite) && Math.abs(p[0]) <= 180 && Math.abs(p[1]) <= 90);
  if (!ok) return "Every point needs a valid [lng, lat]";
  if (ring.length > 1 && ring[0][0] === ring.at(-1)![0] && ring[0][1] === ring.at(-1)![1]) ring.pop();
  if (ring.length < 3 || ring.length > 50) return "Draw between 3 and 50 points";
  const span = (i: number) => Math.max(...ring.map((p) => p[i])) - Math.min(...ring.map((p) => p[i]));
  if (span(0) > MAX_SPAN_DEG || span(1) > MAX_SPAN_DEG) return "Keep the area under about 5 km across";
  return { name, multiplier: b.multiplier, surge: b.surge === true, wkt: `POLYGON((${[...ring, ring[0]].map(([lng, lat]) => `${lng} ${lat}`).join(", ")}))` };
}

// Severity dominates; a report loses half its weight every 14 days; immediate danger doubles it, so does a surge area.
export function priority(r: { severity: number | null; created_at: string; immediate_danger: boolean }, inSurge = false, now = Date.now()) {
  const ageDays = (now - Date.parse(r.created_at)) / 86_400_000;
  return Math.round((r.severity ?? 1) * 0.5 ** (ageDays / 14) * (r.immediate_danger ? 2 : 1) * (inSurge ? 2 : 1) * 100) / 100;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (!authorized(req)) return json({ error: "Wrong or missing buyer passcode" }, 401);

  if (req.method === "POST") {
    const body = await req.json().catch(() => ({}));
    if (body?.bounty !== undefined) {
      const b = parseBounty(body.bounty);
      if (typeof b === "string") return json({ error: b }, 400);
      const { data, error } = await supabase.rpc("post_bounty", { p_name: b.name, p_multiplier: b.multiplier, p_area: b.wkt, p_surge: b.surge });
      if (error?.code === "22023") return json({ error: "That shape isn't a valid area (lines cross or it has no width). Redraw it" }, 400);
      if (error) {
        console.error("post_bounty failed", error);
        return json({ error: "Couldn't post the bounty" }, 500);
      }
      return json(data);
    }
    if (body?.end_bounty !== undefined) {
      if (typeof body.end_bounty !== "string" || !UUID.test(body.end_bounty)) return json({ error: "end_bounty must be a bounty id" }, 400);
      const { data, error } = await supabase.rpc("end_bounty", { p_id: body.end_bounty });
      if (error?.code === "P0002") return json({ error: "Bounty not found or already ended" }, 404);
      if (error) {
        console.error("end_bounty failed", error);
        return json({ error: "Couldn't end the bounty" }, 500);
      }
      return json(data);
    }
    if (typeof body?.report_id !== "string") return json({ error: "report_id required" }, 400);
    const note = typeof body.note === "string" ? body.note.slice(0, 280) : null;
    const { data, error } = await supabase.rpc("mark_report_fixed", { p_report: body.report_id, p_note: note });
    if (error) return json({ error: error.code === "P0002" ? "Report not found" : "Couldn't mark it fixed" }, error.code === "P0002" ? 404 : 500);
    return json(data);
  }
  if (req.method !== "GET") return json({ error: "GET or POST only" }, 405);

  const [{ data, error }, active, surge] = await Promise.all([
    supabase.from("reports")
      .select("id, latitude, longitude, severity, primary_type, damage_types, status, note, explanation, immediate_danger, created_at, fixed_at, fixed_note, image_path")
      .neq("status", "rejected").not("latitude", "is", null)
      .order("created_at", { ascending: false }).limit(300),
    supabase.rpc("active_bounties"),
    supabase.rpc("surge_report_ids"),
  ]);
  if (active.error) console.error("active_bounties failed", active.error); // the queue still loads without the areas
  if (surge.error) console.error("surge_report_ids failed", surge.error); // ...or without the surge boost
  const inSurge = new Set<string>(surge.data ?? []);
  if (error) {
    console.error("buyer queue failed", error);
    return json({ error: "Couldn't load reports" }, 500);
  }
  const paths = data.map((r) => r.image_path).filter((p) => p && p !== "demo");
  const signed = paths.length ? (await supabase.storage.from("report-photos").createSignedUrls(paths, 3600)).data ?? [] : [];
  const urls = new Map(signed.map((s) => [s.path, s.signedUrl]));
  const reports = data.map(({ image_path, latitude, longitude, ...r }) => ({
    ...r, lat: latitude, lng: longitude, photo_url: urls.get(image_path) ?? null,
    in_surge: inSurge.has(r.id), priority: priority(r, inSurge.has(r.id)),
  }));
  reports.sort((a, b) => Number(!!a.fixed_at) - Number(!!b.fixed_at) || b.priority - a.priority);
  return json({ reports, bounties: active.data ?? [] });
});
