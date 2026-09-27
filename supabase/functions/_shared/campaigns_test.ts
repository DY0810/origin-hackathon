// deno test supabase/functions/_shared/
import { assertEquals } from "jsr:@std/assert";
import { parseCampaign, visitPriceCents } from "./campaigns.ts";

const valid = {
  sponsor: "Demo: Convenience chain", title: "Slushie Sweep", offer: "Free small slushie", detail: "",
  bonus_points: 50, price_per_visit_cents: 150, max_visits: 2000, radius_m: 300, days: 14,
  stores: [{ name: "Figueroa & Jefferson", lat: 34.0253, lng: -118.2787 }, { lat: 34.0301, lng: -118.2735 }],
};

Deno.test("a valid campaign parses and unnamed stores get a default name", () => {
  const c = parseCampaign(valid);
  if (typeof c === "string") throw new Error(c);
  assertEquals(c.stores.map((s) => s.name), ["Figueroa & Jefferson", "Store 2"]);
  assertEquals(c.title, "Slushie Sweep");
});

Deno.test("rejects bad input with a message a sponsor can act on", () => {
  assertEquals(parseCampaign({ ...valid, title: " " }), "Give the campaign a title (up to 60 characters)");
  assertEquals(parseCampaign({ ...valid, price_per_visit_cents: 10 }), "Price per visit must be between $0.25 and $20");
  assertEquals(parseCampaign({ ...valid, bonus_points: 12.5 }), "Bonus points must be a whole number from 0 to 1,000");
  assertEquals(parseCampaign({ ...valid, stores: [] }), "Place between 1 and 50 stores on the map");
  assertEquals(parseCampaign({ ...valid, stores: [{ lat: 34, lng: 999 }] }), "Store 1 needs a valid location");
  assertEquals(parseCampaign({ ...valid, stores: [{ lat: 34, lng: -118 }, { lat: 40.7, lng: -74 }] }),
    "Keep a campaign's stores within one metro area (about 100 km)");
  assertEquals(parseCampaign(null), "Add the sponsor's name (up to 80 characters)");
});

Deno.test("visit price = fee + bonus points at $1.25 per 100", () => {
  assertEquals(visitPriceCents({ price_per_visit_cents: 150, bonus_points: 50 }), 213); // $1.50 + $0.625 → $2.13
  assertEquals(visitPriceCents({ price_per_visit_cents: 100, bonus_points: 0 }), 100);
});
