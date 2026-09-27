// Sponsored campaign input (buyer Edge Function → post_campaign(), supabase/migrations/*_campaigns.sql).
// Returns an error message for the dashboard, or the row to insert. Money is in cents.

export type CampaignInput = {
  sponsor: string;
  title: string;
  offer: string;
  detail: string;
  bonus_points: number;
  price_per_visit_cents: number;
  max_visits: number;
  radius_m: number;
  days: number;
  stores: { name: string; lat: number; lng: number }[];
};

const text = (v: unknown, max: number) => (typeof v === "string" ? v.trim() : "").slice(0, max + 1);
const int = (v: unknown, lo: number, hi: number) => Number.isInteger(v) && (v as number) >= lo && (v as number) <= hi;

// deno-lint-ignore no-explicit-any
export function parseCampaign(c: any): string | CampaignInput {
  const sponsor = text(c?.sponsor, 80), title = text(c?.title, 60), offer = text(c?.offer, 80), detail = text(c?.detail, 140);
  if (!sponsor || sponsor.length > 80) return "Add the sponsor's name (up to 80 characters)";
  if (!title || title.length > 60) return "Give the campaign a title (up to 60 characters)";
  if (!offer || offer.length > 80) return "Say what players get at the till (up to 80 characters)";
  if (detail.length > 140) return "Keep the description under 140 characters";
  if (!int(c.bonus_points, 0, 1000)) return "Bonus points must be a whole number from 0 to 1,000";
  if (!int(c.price_per_visit_cents, 25, 2000)) return "Price per visit must be between $0.25 and $20";
  if (!int(c.max_visits, 1, 100_000)) return "Max visits must be between 1 and 100,000";
  if (!int(c.radius_m, 50, 1000)) return "Report radius must be between 50 and 1,000 m";
  if (!int(c.days, 1, 90)) return "Run it for 1 to 90 days";
  if (!Array.isArray(c.stores) || c.stores.length < 1 || c.stores.length > 50) return "Place between 1 and 50 stores on the map";
  const stores: CampaignInput["stores"] = [];
  for (const [i, s] of c.stores.entries()) {
    const ok = s && Number.isFinite(s.lat) && Number.isFinite(s.lng) && Math.abs(s.lat) <= 90 && Math.abs(s.lng) <= 180;
    if (!ok) return `Store ${i + 1} needs a valid location`;
    stores.push({ name: text(s.name, 60) || `Store ${i + 1}`, lat: s.lat, lng: s.lng });
  }
  const span = (k: "lat" | "lng") => Math.max(...stores.map((s) => s[k])) - Math.min(...stores.map((s) => s[k]));
  if (span("lat") > 1 || span("lng") > 1) return "Keep a campaign's stores within one metro area (about 100 km)";
  return { sponsor, title, offer, detail, bonus_points: c.bonus_points, price_per_visit_cents: c.price_per_visit_cents,
           max_visits: c.max_visits, radius_m: c.radius_m, days: c.days, stores };
}

/** What the sponsor pays per verified visit: the visit fee + bonus points at their price (default $1.25 / 100). */
export const visitPriceCents = (c: Pick<CampaignInput, "price_per_visit_cents" | "bonus_points">, pointPriceCents = 125) =>
  c.price_per_visit_cents + Math.ceil(c.bonus_points * pointPriceCents / 100);
