// Buyer dashboard API (CLAUDE.md §6.7, web/dashboard.html). Every call needs `x-buyer-token: <BUYER_TOKEN secret>`.
// GET  -> { reports: [{id, lat, lng, severity, primary_type, damage_types, status, note, explanation,
//                      immediate_danger, created_at, fixed_at, fixed_note, photo_url, priority}] }  open first, by priority
// POST { report_id, note? } -> mark_report_fixed(): sets fixed_at once, pays the reporter a fix bonus.
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

// Severity dominates; a report loses half its weight every 14 days; immediate danger doubles it.
export function priority(r: { severity: number | null; created_at: string; immediate_danger: boolean }, now = Date.now()) {
  const ageDays = (now - Date.parse(r.created_at)) / 86_400_000;
  return Math.round((r.severity ?? 1) * 0.5 ** (ageDays / 14) * (r.immediate_danger ? 2 : 1) * 100) / 100;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (!authorized(req)) return json({ error: "Wrong or missing buyer passcode" }, 401);

  if (req.method === "POST") {
    const body = await req.json().catch(() => ({}));
    if (typeof body.report_id !== "string") return json({ error: "report_id required" }, 400);
    const note = typeof body.note === "string" ? body.note.slice(0, 280) : null;
    const { data, error } = await supabase.rpc("mark_report_fixed", { p_report: body.report_id, p_note: note });
    if (error) return json({ error: error.code === "P0002" ? "Report not found" : "Couldn't mark it fixed" }, error.code === "P0002" ? 404 : 500);
    return json(data);
  }
  if (req.method !== "GET") return json({ error: "GET or POST only" }, 405);

  const { data, error } = await supabase.from("reports")
    .select("id, latitude, longitude, severity, primary_type, damage_types, status, note, explanation, immediate_danger, created_at, fixed_at, fixed_note, image_path")
    .neq("status", "rejected").not("latitude", "is", null)
    .order("created_at", { ascending: false }).limit(300);
  if (error) {
    console.error("buyer queue failed", error);
    return json({ error: "Couldn't load reports" }, 500);
  }
  const paths = data.map((r) => r.image_path).filter((p) => p && p !== "demo");
  const signed = paths.length ? (await supabase.storage.from("report-photos").createSignedUrls(paths, 3600)).data ?? [] : [];
  const urls = new Map(signed.map((s) => [s.path, s.signedUrl]));
  const reports = data.map(({ image_path, latitude, longitude, ...r }) => ({
    ...r, lat: latitude, lng: longitude, photo_url: urls.get(image_path) ?? null, priority: priority(r),
  }));
  reports.sort((a, b) => Number(!!a.fixed_at) - Number(!!b.fixed_at) || b.priority - a.priority);
  return json({ reports });
});
