// Runs every migration + seed_demo.sql in PGlite (real Postgres + PostGIS, in WASM; no Docker) and checks surge
// pricing, the rate card, first-finder/confirmation, danger cores, bounty budgets, redemption and sponsored
// campaigns end to end.
// Run: deno run -A supabase/tests/surge_rewards_db.ts   (exit 1 on any failure)
import { PGlite } from "npm:@electric-sql/pglite@0.5.8";
import { postgis } from "npm:@electric-sql/pglite-postgis@0.2.8";
import { cellToLatLng, latLngToCell, polygonToCells } from "npm:h3-js@4";
import { priceZone, type ZoneInputs } from "../functions/_shared/surge.ts";
import { parseCampaign } from "../functions/_shared/campaigns.ts";

const ROOT = new URL("../", import.meta.url); // supabase/
const db = await PGlite.create({ extensions: { postgis } });

await db.exec(`
  create schema extensions; create schema auth; create schema storage;
  create table storage.buckets (id text primary key, name text, public boolean);
  create role anon; create role authenticated;
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
`);
const migrations = [...Deno.readDirSync(new URL("migrations/", ROOT))].map((e) => e.name).sort();
for (const m of migrations) {
  try { await db.exec(Deno.readTextFileSync(new URL(`migrations/${m}`, ROOT))); console.log("migrated", m); }
  catch (e) { console.error("FAILED", m, (e as Error).message); Deno.exit(1); }
}
await db.exec(Deno.readTextFileSync(new URL("seed_demo.sql", ROOT)));
console.log("seeded");

let failures = 0;
const check = (label: string, ok: boolean, detail?: unknown) => {
  console.log(ok ? "  ok  " : "  FAIL", label, ok ? "" : JSON.stringify(detail));
  if (!ok) failures++;
};
// deno-lint-ignore no-explicit-any
const val = async <T = any>(sql: string, params: unknown[] = []) =>
  Object.values((await db.query<Record<string, T>>(sql, params)).rows[0] ?? {})[0] as T;
const as = (uid: string | null) => db.exec(`set test.uid = '${uid ?? ""}'`);

async function priceAt(lat: number, lng: number) {
  const h3 = latLngToCell(lat, lng, 9);
  const [clat, clng] = cellToLatLng(h3);
  const inputs = await val<ZoneInputs[]>(`select public.zone_inputs($1::jsonb)`, [JSON.stringify([{ h3, lat: clat, lng: clng }])]);
  return priceZone(inputs[0]);
}

// ── zone inputs + pricing ──
const figueroaEmpty = await priceAt(34.0440, -118.2730); // inside Figueroa (3×), no seed reports nearby
console.log("  Figueroa empty cell:", figueroaEmpty.multiplier, figueroaEmpty.why);
check("empty Figueroa cell surges above its 3× bounty", figueroaEmpty.multiplier > 3 && figueroaEmpty.bounty_id !== null, figueroaEmpty);
check("outside every bounty = 1×", (await priceAt(34.0600, -118.3500)).multiplier === 1);

// ── surge bounty with a danger core, posted the way the dashboard does ──
const ring = "POLYGON((-118.3100 34.0500, -118.2980 34.0500, -118.2980 34.0590, -118.3100 34.0590, -118.3100 34.0500))";
const posted = await val(`select public.post_bounty('Storm: West Adams', 3, $1, true, 20000, true)`, [ring]);
check("post_bounty v3 stores surge, budget and a danger core", posted.surge && posted.budget_points === 20000 && posted.danger, posted);
const stormCells = polygonToCells([[[-118.3100, 34.0500], [-118.2980, 34.0500], [-118.2980, 34.0590], [-118.3100, 34.0590]]], 9, true);
const stormPrices = await Promise.all(stormCells.map((h3) => priceAt(...cellToLatLng(h3))));
check("surge cells are flagged and priced from their bounty; the core pays 0",
  stormPrices.some((p) => p.surge && !p.danger && p.multiplier >= 3) && stormPrices.some((p) => p.danger && p.multiplier === 0),
  stormPrices.map((p) => [p.multiplier, p.surge, p.danger]));
const core = await priceAt(34.0545, -118.3040);
check("danger core pays 0", core.danger && core.multiplier === 0, core);
check("surge bounty still gets its storm-sweep quest",
  await val(`select count(*)::int from public.quests where title = 'Storm sweep: Storm: West Adams'`) === 1);
const active = await val(`select public.active_bounties()`);
const storm = active.find((b: { name: string }) => b.name === "Storm: West Adams");
check("active_bounties returns budget, spend and the danger core", storm?.budget_points === 20000 && storm?.spent_points === 0
  && storm?.danger_area?.type === "Polygon", storm);
const map = await val(`select public.map_data(-118.32, 34.00, -118.22, 34.06)`);
const cellCount = map.bounties.reduce((n: number, b: { area: { coordinates: number[][][] } }) =>
  n + polygonToCells(b.area.coordinates, 9, true).length, 0);
check("map_data bounties carry surge + areas that produce hexes", map.bounties.some((b: { surge: boolean }) => b.surge) && cellCount > 20, cellCount);

// ── award_report ──
const alice = crypto.randomUUID(), bob = crypto.randomUUID();
await db.query(`select public.ensure_profile($1)`, [alice]);
await db.query(`select public.ensure_profile($1)`, [bob]);
async function report(user: string, lat: number | null, lng: number | null, type: string, severity: number, source = "camera") {
  const zone = source === "camera" && lat !== null && lng !== null ? await priceAt(lat, lng) : null;
  const id = crypto.randomUUID();
  await db.query(`insert into public.reports (id, user_id, image_path, source, latitude, longitude, status, is_damage,
      damage_types, primary_type, severity, confidence, model) values ($1,$2,'x',$3,$4,$5,'accepted',true,array[$6],$6,$7,0.9,'test')`,
    [id, user, source, lat, lng, type, severity]);
  return { id, zone, award: await val(`select public.award_report($1, $2::jsonb)`, [id, zone && JSON.stringify(zone)]) };
}

const a1 = await report(alice, 34.0440, -118.2730, "exposed_rebar", 4);
console.log("  receipt:", a1.award.points, a1.award.why);
check("first finder, structure tier: 50 × 1.5 = 75 base", a1.award.base_points === 75 && a1.award.finder === "first", a1.award);
check("points = base × zone multiplier", a1.award.points === Math.round(75 * a1.zone!.multiplier), { pts: a1.award.points, m: a1.zone!.multiplier });

const b1 = await report(bob, 34.04401, -118.27301, "exposed_rebar", 4);
check("someone else, same spot + type = confirmation (⅓)", b1.award.finder === "confirmation"
  && b1.award.points === Math.round(75 * b1.zone!.multiplier / 3), b1.award);
check("coverage cooled the cell after reports landed", b1.zone!.multiplier < a1.zone!.multiplier, [a1.zone!.multiplier, b1.zone!.multiplier]);

const a2 = await report(alice, 34.04402, -118.27302, "exposed_rebar", 4);
check("own repeat = 0 points, 0 XP", a2.award.finder === "repeat" && a2.award.points === 0 && a2.award.xp === 0, a2.award);

const lib = await report(alice, null, null, "pothole", 3, "library");
check("library photo: half base (30 → 15), no zone", lib.award.points === 15 && lib.award.multiplier === 1, lib.award);

const d = await report(bob, 34.0545, -118.3040, "crack", 3);
check("danger core: 0 points, 0 XP", d.award.points === 0 && d.award.xp === 0 && d.award.multiplier === 0, d.award);

check("bounty spend tracks points paid inside it", await val(`select public.bounty_spent(bounty_id) from public.reports where id = $1`, [a1.id]) > 0);

await db.exec(`update public.bounties set budget_points = 1 where name = 'Figueroa corridor'`);
const exhausted = await priceAt(34.0440, -118.2730);
check("exhausted budget: Figueroa bounty stops pricing", exhausted.bounty_id === null && exhausted.multiplier === 1, exhausted);
await db.exec(`update public.bounties set budget_points = null where name = 'Figueroa corridor'`);

// ── redemption ──
await as(alice);
check("can't redeem pending points", (await val(`select public.redeem_reward('gift-5')`)).ok === false);
await db.exec(`insert into public.point_ledger (user_id, currency, amount, kind, settles_at, note)
               values ('${alice}', 'points', 600, 'earn', now() - interval '1 hour', 'settled test')`);
const bought = await val(`select public.redeem_reward('gift-5')`);
check("redeem spends settled points", bought.ok === true && bought.balance === 100 && /^FL-[0-9A-F]{8}$/.test(bought.code), bought);
check("second redemption refused", (await val(`select public.redeem_reward('gift-5')`)).ok === false);
const state = await val(`select public.game_state()`);
check("game_state balance reflects redemption", state.points_settled === 100 && state.history.some((h: { kind: string }) => h.kind === "redeem"), state.points_settled);
const catalog = await val(`select public.rewards_catalog()`);
check("catalog lists partner offers first", catalog.items[0].kind === "partner_offer" && catalog.severity_points[3] === 50, catalog.items[0]);

// ── sponsored campaigns ──
const stops = await val(`select public.campaign_stops(-118.30, 34.00, -118.22, 34.05)`);
check("seeded Slushie Sweep shows 3 sponsored stops on the map", stops.length === 3 && stops[0].offer === "Free small slushie", stops);
const store = stops.find((s: { name: string }) => s.name === "Store: Jefferson & Hoover");

const carol = crypto.randomUUID();
await db.query(`select public.ensure_profile($1)`, [carol]);
await as(carol);
const before = await val(`select public.campaign_state()`);
check("campaign_state: not qualified before reporting nearby",
  before[0]?.stores.find((s: { id: string }) => s.id === store.id)?.qualified === false, before);
const noReport = await val(`select public.campaign_check_in($1, $2, $3)`, [store.id, store.lat, store.lng]);
check("check-in without a nearby report is refused", noReport.ok === false && /report a real issue/.test(noReport.error), noReport);

await as(null);
await report(carol, 34.0222, -118.2868, "pothole", 3); // ~90 m from the store
await as(carol);
const far = await val(`select public.campaign_check_in($1, 34.0300, -118.2862)`, [store.id]);
check("check-in from ~960 m away is refused with the distance", far.ok === false && far.distance_m > 900, far);
const ok = await val(`select public.campaign_check_in($1, $2, $3)`, [store.id, store.lat + 0.0003, store.lng]);
check("check-in within 75 m after a nearby report returns an offer code + bonus",
  ok.ok === true && /^[0-9A-F]{6}$/.test(ok.code) && ok.bonus_points === 50 && ok.offer === "Free small slushie", ok);
const again = await val(`select public.campaign_check_in($1, $2, $3)`, [store.id, store.lat, store.lng]);
check("second check-in returns the same code and pays nothing", again.ok && again.already && again.code === ok.code && again.bonus_points === 0, again);
const bonus = await val(`select count(*)::int from public.point_ledger where user_id = $1 and kind = 'campaign'`, [carol]);
check("bonus points land once, as a 'campaign' ledger row", bonus === 1, bonus);
const after = await val(`select public.campaign_state()`);
const mine = after[0].stores.find((s: { id: string }) => s.id === store.id);
check("campaign_state shows the code and qualified", mine.qualified && mine.code === ok.code, mine);

await as(null);
const redeemed = await val(`select public.redeem_campaign_code($1)`, [ok.code.toLowerCase()]);
check("till redeems the code (case-insensitive)", redeemed.already_redeemed === false && redeemed.offer === "Free small slushie", redeemed);
check("redeeming twice says already redeemed", (await val(`select public.redeem_campaign_code($1)`, [ok.code])).already_redeemed === true);
const summary = await val(`select public.campaign_summary()`);
const sweep = summary.find((c: { title: string }) => c.title === "Slushie Sweep");
check("sponsor summary bills $2.13 per verified visit", sweep.visits === 1 && sweep.redeemed === 1 && sweep.billed_cents === 213, sweep);

const input = parseCampaign({ sponsor: "Test brand", title: "Cold brew crawl", offer: "Free cold brew", bonus_points: 0,
  price_per_visit_cents: 100, max_visits: 1, radius_m: 200, days: 7, stores: [{ name: "Test store", lat: 34.0350, lng: -118.2720 }] });
if (typeof input === "string") throw new Error(input);
const created = await val(`select public.post_campaign($1::jsonb)`, [JSON.stringify(input)]);
check("post_campaign creates a campaign with its stores", created.stores === 1 && created.price_per_visit_cents === 100, created);
const brewStore = (await val(`select public.campaign_stops(-118.30, 34.00, -118.22, 34.05)`)).find((s: { title: string }) => s.title === "Cold brew crawl");
await report(carol, 34.0352, -118.2721, "crack", 2);
await as(carol);
check("max_visits = 1: first check-in succeeds", (await val(`select public.campaign_check_in($1, $2, $3)`, [brewStore.id, brewStore.lat, brewStore.lng])).ok);
await as(null);
check("a fully claimed campaign drops off the map",
  !(await val(`select public.campaign_stops(-118.30, 34.00, -118.22, 34.05)`)).some((s: { title: string }) => s.title === "Cold brew crawl"));
await db.query(`select public.end_campaign((select id from public.campaigns where title = 'Slushie Sweep'))`);
check("ended campaign has no stops", (await val(`select public.campaign_stops(-118.30, 34.00, -118.22, 34.05)`)).length === 0);

console.log(failures ? `\n${failures} FAILED` : "\nall checks passed");
Deno.exit(failures ? 1 : 0);
