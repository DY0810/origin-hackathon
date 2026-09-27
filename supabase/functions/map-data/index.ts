// Map read model (design-system/MASTER.md §7.3): damage pins + surge-priced bounty heat + sponsored stops for a box.
// GET ?bbox=minLng,minLat,maxLng,maxLat
// -> { reports: [{id, lat, lng, severity, primary_type, status, created_at}],
//      bounties: [{id, name, multiplier, surge, label_lat, label_lng}]  (label point = north edge),
//      cells: [{h3, multiplier, bounty_id, surge, name, why, boundary: [[lat, lng], ...]}],
//      danger_zones: [{id, name, boundary: [[lat, lng], ...]}]  (every active zone, not just the bbox; outer ring),
//      stops: [{id, campaign_id, name, title, sponsor, offer, bonus_points, radius_m, lat, lng}] }  (sponsored campaigns)
// Every H3 res-9 cell inside a live bounty is priced by _shared/surge.ts (bounty × coverage need × crowd decay), the
// same code verify-report pays with, so the map shows what a report there earns (CLAUDE.md §6.4). Cells inside a
// danger zone are dropped: no multiplier there (CLAUDE.md §6.8).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { cellToBoundary, cellToLatLng, polygonToCells } from "npm:h3-js@4";
import { createClient } from "npm:@supabase/supabase-js@2";
import { priceZone, type ZoneInputs } from "../_shared/surge.ts";

const H3_RES = 9; // ~0.1 km² per cell, about a city block
const MAX_SPAN_DEG = 0.5; // beyond this (zoomed out past a metro), skip hexes and send bounty labels only
const MAX_CELLS = 5000;

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

type Polygon = { type: "Polygon"; coordinates: number[][][] };
type DangerZone = { id: string; name: string; area: Polygon };

type Bounty = {
  id: string;
  name: string;
  multiplier: number;
  surge: boolean;
  label_lat: number;
  label_lng: number;
  area: Polygon;
};

Deno.serve(async (req) => {
  if (req.method !== "GET") return json({ error: "GET only" }, 405);
  const box = new URL(req.url).searchParams.get("bbox")?.split(",").map(Number);
  if (!box || box.length !== 4 || box.some((n) => !Number.isFinite(n))) {
    return json({ error: "bbox=minLng,minLat,maxLng,maxLat required" }, 400);
  }
  const [minLng, minLat, maxLng, maxLat] = box;
  if (minLng >= maxLng || minLat >= maxLat) return json({ error: "bbox min must be below max" }, 400);

  const args = { min_lng: minLng, min_lat: minLat, max_lng: maxLng, max_lat: maxLat };
  const [{ data, error }, stops] = await Promise.all([supabase.rpc("map_data", args), supabase.rpc("campaign_stops", args)]);
  if (error) {
    console.error("map_data failed", error);
    return json({ error: "Couldn't load the map" }, 500);
  }
  if (stops.error) console.error("campaign_stops failed", stops.error); // the map still works without sponsored stops
  const bounties = data.bounties as Bounty[];
  const danger = (data.danger_zones ?? []) as DangerZone[];

  let cells: unknown[] = [];
  if (maxLng - minLng <= MAX_SPAN_DEG && maxLat - minLat <= MAX_SPAN_DEG) {
    const ids = new Set<string>();
    for (const b of bounties) {
      for (const h3 of polygonToCells(b.area.coordinates, H3_RES, true)) {
        if (ids.size >= MAX_CELLS) break;
        ids.add(h3);
      }
    }
    for (const d of danger) for (const h3 of polygonToCells(d.area.coordinates, H3_RES, true)) ids.delete(h3);
    if (ids.size) {
      const centers = [...ids].map((h3) => {
        const [lat, lng] = cellToLatLng(h3);
        return { h3, lat, lng };
      });
      const inputs = await supabase.rpc("zone_inputs", { p_cells: centers });
      if (inputs.error) {
        console.error("zone_inputs failed", inputs.error);
        return json({ error: "Couldn't price the map" }, 500);
      }
      const now = Date.now();
      cells = (inputs.data as ZoneInputs[]).flatMap((z) => {
        const { demand: _d, need: _n, crowd: _c, danger: inDanger, ...price } = priceZone(z, now);
        // No heat without a live bounty (budget just ran out) or inside a danger zone.
        return price.bounty_id && !inDanger ? [{ ...price, boundary: cellToBoundary(z.h3) }] : [];
      });
    }
  }

  return json({
    reports: data.reports,
    bounties: bounties.map(({ area: _area, ...rest }) => rest),
    cells,
    danger_zones: danger.map(({ area, ...d }) => ({ ...d, boundary: area.coordinates[0].map(([lng, lat]) => [lat, lng]) })),
    stops: stops.data ?? [],
  });
});
