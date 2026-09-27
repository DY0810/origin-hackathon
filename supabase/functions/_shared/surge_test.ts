// deno test supabase/functions/_shared/
import { assertEquals } from "jsr:@std/assert";
import { priceZone, type ZoneInputs } from "./surge.ts";

const NOW = Date.parse("2026-09-26T12:00:00Z");
const hoursAgo = (h: number) => new Date(NOW - h * 3_600_000).toISOString();
const zone = (z: Partial<ZoneInputs>): ZoneInputs => ({
  h3: "8929a1d6457ffff", bounty_id: null, bounty_name: null, bounty_multiplier: null,
  surge: false, danger: false, reports_24h: 0, last_report_at: null, ...z,
});
const bounty = (multiplier: number, z: Partial<ZoneInputs> = {}) =>
  zone({ bounty_id: "b", bounty_name: "Figueroa corridor", bounty_multiplier: multiplier, ...z });

Deno.test("no bounty: standard 1×, even when the cell was never reported", () => {
  assertEquals(priceZone(zone({}), NOW).multiplier, 1);
});

Deno.test("empty, never-reported bounty cell pays the full +50% need boost", () => {
  const p = priceZone(bounty(2), NOW);
  assertEquals(p.multiplier, 3);
  assertEquals(p.why, ["Figueroa corridor: 2×", "Needs coverage (never reported): +50%"]);
});

Deno.test("bounty cell already at target today prices at the bounty", () => {
  assertEquals(priceZone(bounty(2, { reports_24h: 3, last_report_at: hoursAgo(1) }), NOW).multiplier, 2);
});

Deno.test("crowded cell cools down but never below 1×", () => {
  assertEquals(priceZone(bounty(2, { reports_24h: 6, last_report_at: hoursAgo(0.1) }), NOW).multiplier, 1);
  assertEquals(priceZone(bounty(3, { reports_24h: 4, last_report_at: hoursAgo(0.1) }), NOW).multiplier, 2.25);
  assertEquals(priceZone(bounty(1.5, { reports_24h: 30, last_report_at: hoursAgo(0.1) }), NOW).multiplier, 1);
});

Deno.test("staleness alone lifts a quiet cell; old coverage counts as never", () => {
  // 0 today, last report 7 days ago: shortfall 1, staleness 0.5 → need 1.375
  assertEquals(priceZone(bounty(2, { last_report_at: hoursAgo(24 * 7) }), NOW).multiplier, 2.75);
  assertEquals(priceZone(bounty(2, { last_report_at: hoursAgo(24 * 60) }), NOW).multiplier, 3);
});

Deno.test("a 5× surge bounty on an empty block is capped at 5× and says so", () => {
  const p = priceZone(bounty(5, { bounty_name: "Storm: Arts District", surge: true }), NOW);
  assertEquals(p.multiplier, 5);
  assertEquals(p.surge, true);
  assertEquals(p.name, "Storm: Arts District");
  assertEquals(p.why, ["Storm: Arts District (surge): 5×", "Needs coverage (never reported): +50%", "Capped at 5×"]);
});

Deno.test("danger area pays nothing, whatever the demand", () => {
  const p = priceZone(bounty(5, { danger: true, surge: true }), NOW);
  assertEquals(p.multiplier, 0);
  assertEquals(p.danger, true);
});

Deno.test("multipliers land on 0.25 steps", () => {
  for (let n = 0; n <= 10; n++) {
    for (const m of [1.5, 2, 3]) {
      const p = priceZone(bounty(m, { reports_24h: n, last_report_at: hoursAgo(n * 5) }), NOW);
      assertEquals(p.multiplier % 0.25, 0);
    }
  }
});
