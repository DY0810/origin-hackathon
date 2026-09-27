// Pure asset matching for asset-lookup (CLAUDE.md §7.2). No imports, so it runs under plain Node for checks too.
// ponytail: flat-earth metres around the phone (equirectangular), fine within ~100 m; geodesic math if the radius grows.

type LatLon = { lat: number; lon: number };
// Overpass `out geom(bbox)`: points outside the box come back null; relations carry geometry on their members.
export type OsmElement = {
  type: "node" | "way" | "relation";
  id: number;
  lat?: number;
  lon?: number;
  geometry?: (LatLon | null)[];
  members?: { role: string; geometry?: (LatLon | null)[] }[];
  tags?: Record<string, string>;
};
export type Asset = { kind: string; name: string; osm_id: string; distance_m: number };
type XY = [number, number]; // metres east, north of the phone

export const MAX_ACCURACY_M = 30; // worse GPS than this can't pick a building
export const RAY_M = 50;
const M_PER_DEG = 111_320;

export function toXY(lat0: number, lng0: number, lat: number, lng: number): XY {
  return [(lng - lng0) * M_PER_DEG * Math.cos((lat0 * Math.PI) / 180), (lat - lat0) * M_PER_DEG];
}

// Distance from the phone (origin) to segment ab.
export function segDist(a: XY, b: XY): number {
  const dx = b[0] - a[0], dy = b[1] - a[1];
  const len2 = dx * dx + dy * dy;
  const t = len2 ? Math.max(0, Math.min(1, -(a[0] * dx + a[1] * dy) / len2)) : 0;
  return Math.hypot(a[0] + t * dx, a[1] + t * dy);
}

// Metres along a ray from the phone (heading: degrees clockwise from north) to segment ab, or null if it misses.
export function rayHit(heading: number, a: XY, b: XY): number | null {
  const r = (heading * Math.PI) / 180;
  const ux = Math.sin(r), uy = Math.cos(r);
  const ex = b[0] - a[0], ey = b[1] - a[1];
  const den = ux * ey - uy * ex;
  if (Math.abs(den) < 1e-12) return null; // parallel
  const t = (a[0] * ey - a[1] * ex) / den;
  const s = (a[0] * uy - a[1] * ux) / den;
  return t >= 0 && s >= 0 && s <= 1 ? t : null;
}

// Is the phone inside this ring? (even-odd rule)
export function inside(ring: XY[]): boolean {
  let hit = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i], [xj, yj] = ring[j];
    if (yi > 0 !== yj > 0 && 0 < ((xj - xi) * -yi) / (yj - yi) + xi) hit = !hit;
  }
  return hit;
}

const ROADS = /^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|service|living_street)(_link)?$/;
const PATHS = /^(footway|pedestrian|path|steps|cycleway|sidewalk)$/;
const LABEL: Record<string, string> = {
  pole: "Pole", streetlight: "Streetlight", bridge: "Bridge", building: "Building", road: "Road", sidewalk: "Sidewalk",
};

export function kindOf(t: Record<string, string>): string | null {
  if (t.power === "pole") return "pole";
  if (t.highway === "street_lamp") return "streetlight";
  if ((t.bridge && t.bridge !== "no") || t.man_made === "bridge") return "bridge";
  if (t.building) return "building";
  if (ROADS.test(t.highway ?? "")) return "road";
  if (PATHS.test(t.highway ?? "")) return "sidewalk";
  if (t.man_made) return "structure";
  return null;
}

// Only a full OSM address: guessing the street from the nearest road puts numbers on the wrong street.
export const addressOf = (t: Record<string, string>) =>
  t["addr:housenumber"] && t["addr:street"] ? `${t["addr:housenumber"]} ${t["addr:street"]}` : null;

// Human name: "Doheny Library", "Main St Bridge", "123 Oak Ave facade", "Pole near W 36th St".
export function nameOf(kind: string, t: Record<string, string>, street: string | null): string {
  const near = (label: string) => (street ? `${label} near ${street}` : label);
  if (kind === "bridge") return t.name ? (/bridge/i.test(t.name) ? t.name : `${t.name} Bridge`) : near("Bridge");
  if (t.name) return t.name;
  if (kind === "building" && addressOf(t)) return `${addressOf(t)} facade`;
  const label = LABEL[kind] ?? t.man_made.replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase());
  return near(label);
}

// Unbroken runs of points: a null (clipped by the bbox) breaks the line.
function runs(g: (LatLon | null)[] = []): LatLon[][] {
  const out: LatLon[][] = [[]];
  for (const p of g) p ? out.at(-1)!.push(p) : out.push([]);
  return out.filter((r) => r.length);
}

// §7.2: the first footprint the heading ray hits within 50 m, else the nearest footprint, else the nearest asset.
// Candidates: everything nearby, nearest first, one per name, primary on top, up to 5.
export function matchAssets(elements: OsmElement[], lat: number, lng: number, heading: number | null) {
  const found = elements.flatMap((e) => {
    const t = e.tags ?? {};
    const kind = kindOf(t);
    // ponytail: multipolygon inner rings (courtyards) are ignored; outer rings only.
    const lines = (e.type === "node" ? (e.lat === undefined || e.lon === undefined ? [] : [[{ lat: e.lat, lon: e.lon }]])
      : e.type === "way" ? runs(e.geometry)
      : (e.members ?? []).filter((m) => m.role === "outer").flatMap((m) => runs(m.geometry)))
      .map((line) => line.map((p) => toXY(lat, lng, p.lat, p.lon)));
    if (!kind || !lines.length) return [];
    const edges = lines.flatMap((pts) => pts.slice(1).map((p, i) => [pts[i], p] as [XY, XY]));
    const footprint = kind === "building" && edges.length > 2;
    const closed = (pts: XY[]) => pts.length > 3 && pts[0][0] === pts.at(-1)![0] && pts[0][1] === pts.at(-1)![1];
    const distance = edges.length === 0 ? Math.hypot(...lines[0][0])
      : footprint && lines.some((pts) => closed(pts) && inside(pts)) ? 0
      : Math.min(...edges.map(([a, b]) => segDist(a, b)));
    const hit = footprint && heading !== null ? Math.min(...edges.map(([a, b]) => rayHit(heading, a, b) ?? Infinity)) : Infinity;
    return [{ e, t, kind, distance, hit }];
  }).sort((a, b) => a.distance - b.distance);

  const street = found.find((f) => f.t.highway && f.t.name)?.t.name ?? null;
  const buildings = found.filter((f) => f.kind === "building");
  const aimed = buildings.filter((f) => f.hit <= RAY_M).sort((a, b) => a.hit - b.hit)[0];
  const primary = aimed ?? buildings[0] ?? found[0];
  const asset = (f: (typeof found)[number]): Asset => ({
    kind: f.kind, name: nameOf(f.kind, f.t, street), osm_id: `${f.e.type}/${f.e.id}`, distance_m: Math.round(f.distance),
  });

  const candidates: Asset[] = [];
  for (const f of primary ? [primary, ...found] : found) {
    const a = asset(f);
    if (!candidates.some((c) => c.name === a.name)) candidates.push(a);
    if (candidates.length === 5) break;
  }
  const address = primary?.t.name ? addressOf(primary.t) : null; // unnamed buildings already carry it in the name
  return { primary: primary ? candidates[0] : null, candidates, address };
}

const isNum = (n: unknown): n is number => typeof n === "number" && Number.isFinite(n);
const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const isPoints = (g: unknown) => Array.isArray(g) && g.every((p) => p === null || (isObj(p) && isNum(p.lat) && isNum(p.lon)));
const isTags = (t: unknown) => t === undefined || (isObj(t) && Object.values(t).every((v) => typeof v === "string"));

// Trust boundary: the phone sends the Overpass elements, so drop anything not shaped like `out geom` output
// (matchAssets would throw on a non-string tag or a point without lat/lon).
export function validElements(raw: unknown[]): OsmElement[] {
  return raw.filter((e): e is OsmElement =>
    isObj(e) && isNum(e.id) && isTags(e.tags) && (
      e.type === "node" ? isNum(e.lat) && isNum(e.lon)
      : e.type === "way" ? isPoints(e.geometry)
      : e.type === "relation" && Array.isArray(e.members) &&
        e.members.every((m) => isObj(m) && typeof m.role === "string" && (m.geometry === undefined || isPoints(m.geometry)))
    ));
}
