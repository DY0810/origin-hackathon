// Surge pricing (CLAUDE.md §6.4, docs/surge-and-rewards.md): what one report is worth in one H3 cell right now.
// Pure and shared by map-data (the heat the player sees) and verify-report (the multiplier they're paid), so the
// number on the map is the number on the receipt. Raw inputs come from the zone_inputs() SQL function.
//
//   demand   = the highest live buyer bounty covering the cell (a disaster surge is a bounty flagged `surge`)
//   need     = 1 … 1.5  when the cell is under-covered today or its last report is old
//   crowd    = 0.5 … 1  when more reports than buyers need already came in today
//   multiplier = clamp(round_to_0.25(demand × need × crowd), 1, 5)   ·   0 inside a danger zone
//
// Outside every bounty the multiplier is 1: we only surge where a buyer pays for it.

export const SURGE = {
  targetPerDay: 3, // reports per cell per day a buyer needs; past this, extra photos of the same block add little
  staleAfterDays: 14, // coverage this old counts as fully stale
  maxNeedBoost: 0.5, // an empty, stale cell pays up to +50%
  crowdFloor: 0.5, // an over-reported cell cools to no less than half its demand price (and never below 1×)
  min: 1,
  max: 5,
  step: 0.25,
} as const;

/** One row of zone_inputs(): what's true about a cell, before pricing. */
export type ZoneInputs = {
  h3: string;
  bounty_id: string | null;
  bounty_name: string | null;
  bounty_multiplier: number | null;
  surge: boolean; // a live surge bounty covers the cell
  danger: boolean; // a live danger zone covers the cell center
  reports_24h: number; // non-rejected reports within the cell in the last 24 h (supply)
  last_report_at: string | null; // newest non-rejected report within the cell, any age
};

export type ZonePrice = {
  h3: string;
  multiplier: number; // 0 = danger (no rewards), else 1…5 in 0.25 steps
  danger: boolean;
  surge: boolean;
  bounty_id: string | null;
  name: string | null;
  demand: number;
  need: number;
  crowd: number;
  why: string[]; // plain-language lines for the "why this price" sheet (MASTER §9: rewards are explained)
};

const x = (n: number) => `${Number(n.toFixed(2))}×`;
const pct = (f: number) => `${Math.round(Math.abs(f - 1) * 100)}%`;

export function priceZone(z: ZoneInputs, now = Date.now()): ZonePrice {
  const base = { h3: z.h3, danger: z.danger, surge: z.surge, bounty_id: z.bounty_id, name: z.bounty_name };
  if (z.danger) {
    return { ...base, multiplier: 0, demand: 0, need: 1, crowd: 1,
      why: ["Danger area: no points here until it's declared safe. Stay out and stay safe."] };
  }

  const demand = Math.max(1, z.bounty_multiplier ?? 1);
  if (demand <= 1) return { ...base, multiplier: 1, demand: 1, need: 1, crowd: 1, why: ["Standard points. No bounty here."] };
  const why = [`${z.bounty_name ?? "Buyer bounty"}${z.surge ? " (surge)" : ""}: ${x(demand)}`];

  const recent = Math.max(0, z.reports_24h);
  const shortfall = Math.max(0, 1 - recent / SURGE.targetPerDay);
  const ageDays = z.last_report_at ? Math.max(0, (now - Date.parse(z.last_report_at)) / 86_400_000) : Infinity;
  const staleness = Math.min(1, ageDays / SURGE.staleAfterDays);
  const need = 1 + SURGE.maxNeedBoost * (shortfall + staleness) / 2;
  const crowd = recent > SURGE.targetPerDay ? Math.max(SURGE.crowdFloor, SURGE.targetPerDay / recent) : 1;

  if (need > 1.005) {
    const reason = !z.last_report_at ? "never reported"
      : ageDays >= 1 ? `last report ${Math.floor(ageDays)} day${Math.floor(ageDays) === 1 ? "" : "s"} ago`
      : `${recent} of ${SURGE.targetPerDay} reports today`;
    why.push(`Needs coverage (${reason}): +${pct(need)}`);
  }
  if (crowd < 1) why.push(`Busy today (${recent} reports): −${pct(crowd)}`);

  const raw = demand * need * crowd;
  const multiplier = Math.min(SURGE.max, Math.max(SURGE.min, Math.round(raw / SURGE.step) * SURGE.step));
  if (raw > SURGE.max) why.push(`Capped at ${x(SURGE.max)}`);
  return { ...base, multiplier, demand, need, crowd, why };
}
