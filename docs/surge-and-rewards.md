# Surge pricing, heat map & rewards

How FaultLine decides what a report is worth, and how the points turn into a business. Code:
`supabase/functions/_shared/surge.ts` (surge), `supabase/migrations/20260926030000_surge_pricing_rewards.sql` (inputs, rate
card, budgets, danger cores, redemption), `20260926040000_campaigns.sql` (sponsored campaigns), `map-data` /
`verify-report` / `buyer` Edge Functions, iOS `Map/`, `Quests/` and `Rewards/`, `web/dashboard.html`.

Tests: `deno test supabase/functions/_shared/` (pricing) and `deno run -A supabase/tests/surge_rewards_db.ts`
(all migrations + seed in PGlite with PostGIS, 21 end-to-end checks). Without a Deno install, `npx deno` also works.

---

## 1. The idea in one line

**Buyers post demand, the map turns demand into a price, and the price moves the crowd.** It's Uber surge applied to
inspection coverage: when a block needs eyes and nobody's been there, it pays more; once enough people have covered it,
the price cools so the crowd spreads out instead of piling onto one hot spot.

## 2. Points for one report (the receipt)

```
points = base(severity) × asset tier × zone surge × finder × daily
```

| Factor | Values | Why |
|---|---|---|
| **Base by severity** | 1 cosmetic **10** · 2 monitor **20** · 3 repair soon **30** · 4 urgent **50** · 5 hazard **80** | Worse damage is worth more to the buyer |
| **Asset tier** | Structure at risk (exposed rebar, collapse, bulge, detachment) **×1.5** · utility/safety device (pole, light/sign, leak, fire) **×1.25** · surface **×1** | Critical assets cost more to inspect and fail harder |
| **Zone surge** | **×1 to ×5**, in 0.25 steps (see §3). **×0 in a danger area** | Routes people to where buyers need data |
| **Finder** | First finder **×1** · confirming someone else's open report **×⅓** · re-reporting your own find **×0** | Pays discovery, still pays for confirmations, kills spam |
| **Library photo** | **×0.5**, no zone | Old photos have no trustworthy time or place |
| **Daily** | **×0.5** after 15 reports a day | Diminishing returns against farming |

Plus: quest bonuses (existing), a +25 **fix bonus** when a buyer marks your report fixed, and XP (not redeemable) for levels.

Every receipt is itemized in the app, straight from `award_report()`:

```
Severity 4 exposed rebar: 50 pts
Structure at risk: ×1.5
Figueroa corridor: 3×
Needs coverage (never reported): +50%
Zone: ×4.5
First finder: full points
= 338 pts
```

**100 points = $1.** A typical report pays 20–150 points ($0.20–$1.50). The rare maximum is a first-found severity-5
structural hazard in a 5× zone: 600 points ($6). This matches CLAUDE.md §9.2.

## 3. Surge model (the heat map)

Each H3 res-9 hexagon (about a city block) inside a live bounty gets a live price. A disaster surge is a bounty flagged
`surge` (posted from the dashboard with "Surge (disaster)" ticked):

```
demand     = highest live bounty multiplier covering the cell
need       = 1 + 0.5 × (shortfall + staleness) / 2        → 1.0 … 1.5
             shortfall = 1 − reports_today / 3              (3 reports/cell/day is "covered")
             staleness = days_since_last_report / 14        (capped at 1; never reported = 1)
crowd      = 3 / reports_today when more than 3 came in     → 0.5 … 1.0
multiplier = clamp(round_to_0.25(demand × need × crowd), 1, 5)
danger core → 0 (no points, capture paused in the app)
outside every bounty → 1 (we only surge where someone pays)
```

| Situation | Multiplier |
|---|---|
| 2× bounty, block never reported | **3×** |
| 2× bounty, last report 7 days ago | **2.75×** |
| 2× bounty, 3 reports already today | **2×** |
| 3× bounty, 4 reports today | **2.25×** |
| 2× bounty, 6 reports today | **1×** (floor) |
| 5× surge, block never reported | **5×** (cap) |
| Inside the storm's danger core | **0** |

**One number, everywhere.** `surge.ts` prices the map (`map-data`) *and* the payout (`verify-report`). The report is
priced *before* it's inserted, so it can't cool its own cell. Players tap any gold hex to see the "why" lines.

**Budgets.** A bounty can carry `budget_points`. When the points paid inside it reach the budget, it stops heating the
map on its own. Buyers see spend against budget in the bounty's popup on the dashboard.

**Surges (disaster mode, CLAUDE.md §6.8).** "Post bounty" with "Surge (disaster)" ticked draws red and dashed, adds a
storm-sweep quest and doubles queue priority inside it. Optionally its middle 40% becomes a **danger core** that pays
nothing: both maps paint it red, the app pauses the capture button there, sponsored stores inside it disappear, and the
server pays 0. We never pay people to walk into danger.

### Why surge beats fixed bounties
- **Spreads the crowd.** Pokémon Go's failure mode is 200 people on one corner. Crowd decay makes the 4th photo of a
  block worth less than the 1st photo of the next block over.
- **Fresh data is what buyers pay for.** Staleness means coverage renews itself without anyone posting a new bounty.
- **Budget-safe.** Caps (5×), floors (1×) and budgets make buyer spend predictable.

## 4. The points economy: a CRED-style loop

**What CRED does (India):** members earn CRED coins for paying credit-card bills through the app. They spend the coins on
brand-funded offers, discounts and experiences. Brands pay for access to CRED's creditworthy audience, so the rewards
cost CRED far less than face value. The currency sits between an audience brands want and brands that fund the rewards.

**FaultLine's version:** two groups want the same people.
1. **Data buyers** (cities, utilities, insurers, property managers) pay for verified, fresh condition data. That funds the base points.
2. **Local merchants** want foot traffic from people already walking the neighborhood. They fund **partner offers**
   ("free coffee for 150 pts"). A redemption costs us $0 and the merchant pays for the visit.

Catalog (seeded, brand-neutral placeholders per MASTER §7.5):

| Reward | Points | Our cash cost |
|---|---|---|
| 20% off a bike tune-up (partner) | 100 | $0 (merchant-funded) |
| Free coffee (partner) | 150 | $0 |
| 2-for-1 lunch (partner) | 300 | $0 |
| $5 / $10 / $25 gift card | 500 / 1,000 / 2,500 | $5 / $10 / $25 |
| $5 to the neighborhood fix-it fund | 500 | $5 |

Partner offers are cheaper in points **on purpose**. That steers redemptions toward rewards merchants fund, which lowers our
effective cost per point. Standard loyalty economics also apply: pending points settle after 24 hours of fraud checks,
redemption only spends settled points (server-checked, one redemption at a time), and unredeemed points (breakage) are
a real line item. *All cost ratios here are assumptions to validate, not measured numbers.*

**Guardrails (don't trip these in the pitch):**
- Points are closed-loop loyalty points. No cash-out, no crypto, no transfers between users, so no money-transmitter or
  securities exposure (CLAUDE.md §6.6).
- **No randomized rewards** (CRED's "jackpots", spin wheels). Paid-entry chance games are regulated sweepstakes in the
  US, and MASTER §9 bans them anyway. Rewards are deterministic and explained.
- Track each user's yearly redemption value against the IRS information-reporting threshold. KYC only above a cap.

## 5. Foot traffic: sponsored campaigns (built)

The pull comes from the **map**: gold hexes that change through the day, a surge after a storm, a streak to keep. Brands
pay to turn that foot traffic into store visits.

**How it works.** A brand (say a convenience chain launching a new slushie) runs **Slushie Sweep** from the dashboard's
"New campaign": sponsor, offer ("Free small slushie"), price per visit, optional bonus points, a visit cap, days, and the
participating stores (click to place). In the app each store is a blue storefront pin, and the campaign is a Sponsored
card on the Quests tab.

1. The player reports a **real issue within 300 m** of a store (a normal verified report, not a repeat).
2. At the store (**within 75 m**) they tap **Check in**: the server checks the report, the geofence and the visit cap.
3. They get a **6-character code** for the till and the brand's bonus points (pending 24 h like all points).
4. Staff type the code into the store's popup on the dashboard: redeemed once, ever.

**How we charge.** Per verified check-in: the visit fee ($1.50 default, $0.25–$20) + the bonus points at $1.25 per 100
(they cost us at most $1 per 100). Default campaign: $2.13 per visit. The brand also pays for its own offer. The report
made on the way is ordinary condition data we still sell, so **one walk earns twice**.

**Why brands pay.** Proven visits (an attested report nearby + a code used at the till), not estimated ones; they pay only
for completions, capped by `max_visits`; and "report a pothole, get a slushie" is a good-news story.

**Guardrails.** Always labelled Sponsored; stores inside a danger core are hidden and can't check in; fixed offers (no
random draws); no age-restricted products; one visit per player per store per campaign; sponsors see totals only, never
who reported what.

Niantic sold "sponsored locations" to retailers who paid for the visits a game spot drove. This is the same idea, with a
useful task attached. The honest difference from Pokémon Go: we don't need millions of casual players. We need **dense
coverage in the territories buyers pay for**, and surge plus sponsored stops concentrate the crowd there.

## 6. Business model summary (for the pitch)

| Who pays | For what | How it hooks into this system |
|---|---|---|
| Cities / DOTs, utilities | Territory subscription + bounties | Bounties = gold hexes; budgets cap spend; we keep a margin over points paid |
| Insurers, emergency mgmt | Disaster rapid-assessment | Surge events with danger cores; priced per event |
| Property managers / HOAs | Portfolio condition feed | Standing bounties on their parcels |
| Brands & local merchants | Foot traffic | Sponsored campaigns (paid per verified visit + bonus points) and partner offers ($0 to us) |
| Contractors | Repair leads | Verified reports, severity-ranked |

**Unit economics (illustrative, to validate):** average payout ≈ 60 pts ≈ $0.60 face value. Partner-funded redemptions
and breakage bring the effective cost below that. A manual site inspection costs $50–$300+, so selling a verified,
geolocated, severity-scored report for $5–$25 leaves room for the ≤25% reporter-payout target (CLAUDE.md §9.2).

## 7. Demo beats for this piece (fits CLAUDE.md §11 steps 2, 3 and 5)
1. App map: gold hexes around USC. Tap one: "Figueroa corridor 3×, Needs coverage (never reported) +50% = 4.5×".
2. Snap a crack there. The receipt itemizes severity × tier × zone × first finder.
3. Dashboard → **Post bounty**, tick Surge + Danger core, draw the area. Within 30 s the app shows dashed surge hexes,
   a red danger core, and capture paused inside it.
4. Dashboard → **New campaign** ("Slushie Sweep", a free slushie, $1.50 per visit + 50 bonus points), click to place
   stores. In the app a blue storefront pin appears: report an issue nearby, tap Check in, show the code. Type the code
   in the store's popup on the dashboard: redeemed, billed $2.13.
5. Rewards tab: balance with its dollar value, partner offers first, redeem → code.

## 8. Tuning knobs
`SURGE` in `surge.ts` (target 3/day, staleness 14 days, +50% max need, 0.5 crowd floor, 1–5×, 0.25 steps) and the rate card
functions in the migration (`severity_points`, `damage_tier`). Change them there. The app reads the rate card from
`rewards_catalog()`, so the Rewards tab stays in sync.
