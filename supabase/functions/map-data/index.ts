// Map read model (design-system/MASTER.md §7.3): damage pins + bounty heat for a bounding box.
// GET ?bbox=minLng,minLat,maxLng,maxLat
// -> { reports: [{id, lat, lng, severity, primary_type, status, created_at}],
//      bounties: [{id, name, multiplier, surge, label_lat, label_lng}]  (label point = north edge),
//      cells: [{h3, multiplier, bounty_id, surge, boundary: [[lat, lng], ...]}] }  (surge if any covering bounty is)
// Heat = max multiplier of any active bounty covering an H3 res-9 cell (CLAUDE.md §6.4).
// ponytail: bounties only (surge = a flagged bounty, CLAUDE.md §6.8); staleness and asset criticality join the heat formula when their data exists.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { cellToBoundary, polygonToCells } from "npm:h3-js@4";
import { createClient } from "npm:@supabase/supabase-js@2";

const H3_RES = 9; // ~0.1 km² per cell, about a city block
const MAX_SPAN_DEG = 0.5; // beyond this (zoomed out past a metro), skip hexes and send bounty labels only
const MAX_CELLS = 5000;

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

type Bounty = {
  id: string;
  name: string;
  multiplier: number;
  surge: boolean;
  label_lat: number;
  label_lng: number;
  area: { type: "Polygon"; coordinates: number[][][] };
};

Deno.serve(async (req) => {
  if (req.method !== "GET") return json({ error: "GET only" }, 405);
  const box = new URL(req.url).searchParams.get("bbox")?.split(",").map(Number);
  if (!box || box.length !== 4 || box.some((n) => !Number.isFinite(n))) {
    return json({ error: "bbox=minLng,minLat,maxLng,maxLat required" }, 400);
  }
  const [minLng, minLat, maxLng, maxLat] = box;
  if (minLng >= maxLng || minLat >= maxLat) return json({ error: "bbox min must be below max" }, 400);

  const { data, error } = await supabase.rpc("map_data", {
    min_lng: minLng, min_lat: minLat, max_lng: maxLng, max_lat: maxLat,
  });
  if (error) {
    console.error("map_data failed", error);
    return json({ error: "Couldn't load the map" }, 500);
  }
  const bounties = data.bounties as Bounty[];

  const cells = new Map<string, { multiplier: number; bounty_id: string; surge: boolean }>();
  if (maxLng - minLng <= MAX_SPAN_DEG && maxLat - minLat <= MAX_SPAN_DEG) {
    for (const b of bounties) {
      for (const h3 of polygonToCells(b.area.coordinates, H3_RES, true)) {
        const current = cells.get(h3);
        if (!current || b.multiplier > current.multiplier) {
          cells.set(h3, { multiplier: b.multiplier, bounty_id: b.id, surge: b.surge || !!current?.surge });
        } else if (b.surge) current.surge = true;
        if (cells.size >= MAX_CELLS) break;
      }
    }
  }

  return json({
    reports: data.reports,
    bounties: bounties.map(({ area: _area, ...rest }) => rest),
    cells: [...cells].map(([h3, c]) => ({ h3, ...c, boundary: cellToBoundary(h3) })),
  });
});
