# FaultLine — master context

> Working name. Crowdsourced, gamified infrastructure inspection. Every session in this folder builds against this doc.
> If a decision here changes, edit this file in the same session and don't leave it stale.

---

## 1. The prompt we're answering (summary)

Utilities, telecom, transport, insurers and infrastructure owners spend billions inspecting and repairing physical assets. Most of that work is manual and reactive. Disasters (wildfire, quake, flood, storm) make it worse because thousands of assets need assessing at once. Meanwhile phones, cameras and sensors produce huge amounts of physical-world data.

**Judging emphasis:** the best solutions handle *everyday* inspection, maintenance and asset-management workflows, with disasters as an extra high-value use case.

### Judging criteria (F26 Origin Weekend, each scored 1–5)
Every build and pitch decision should map to one of these. Source: `~/Downloads/F26 Origin Weekend Judging Criteria.md`.

| Criterion | What judges look for | Where we cover it |
|---|---|---|
| **1. Problem & Customer Insight** | Clear, specific, significant problem; understood target customers; **evidence** (interviews, research) validating the need | §4 Users, §12 Validation evidence |
| **2. Solution & Business Model** | Solution fits the customer; strong, differentiated value prop; plausible sustainability (who pays, how, why); **how we get the first 100 customers** | §3, §9, §9.3 First 100 customers |
| **3. Execution & Communication** | Compelling prototype/demo; clear, engaging, well-structured pitch; collaboration, creativity, awareness of what comes next | §10 MVP, §11 Demo script, §13 What's next |

**Implication:** this is a business pitch as much as a tech demo. Customer evidence and the first-100 plan are scored directly, so don't let the build eat all the time.

### Design system & research (read before any UI work)
- **`design-system/MASTER.md`** is the binding UI rulebook: principles, tokens, components, screens, on-device AI (Foundation Models), game-layer rules, accessibility. Screen-specific overrides go in `design-system/pages/<screen>.md`.
- **`design-system/DesignSystem.swift`** holds the tokens and core SwiftUI atoms. Use these and never hardcode hex, point sizes or spacing.
- **`design-system/contrast_check.py`** runs the WCAG contrast check and must exit 0 after any color change.
- **`ios/`** is the iOS app. `ios/project.yml` (XcodeGen) is the source of truth for the Xcode project. After adding/removing files or changing settings, run `cd ios && xcodegen`; never hand-edit the `.pbxproj`. Features go in `ios/FaultLine/Features/<Feature>/`, one folder per tab/flow, so parallel sessions don't collide. `DesignSystem.swift` is referenced from `design-system/`, not copied.
- **`ml/`** holds the on-device damage classifier (EfficientNet-B0 → Core ML, trained on Kaggle) and, in `ml/detector/`, a YOLO detector that boxes each issue in a photo (kernel `faultline-detector`). See `ml/README.md` for datasets, metrics, and the severity heuristic. Model artifacts are not in git; fetch them with `kaggle kernels output`. The shipped `.mlpackage`s in `ios/FaultLine/Resources/ML/` are the exception.
- **Dictation** is on-device: Whisper tiny.en via WhisperKit (SPM `argmaxinc/argmax-oss-swift`), then Foundation Models cleans the note (`ReportNoteDraft`, MASTER §8). The ~76 MB model is gitignored; run `ios/scripts/fetch_whisper.sh` once before building. Without it the app builds with no mic button.
- **`supabase/`** is the backend (project `faultline`, ref `kiygfzzdaqabrggjnrmf`). The `verify-report` Edge Function is the authoritative verdict: a vision model (OpenAI if `OPENAI_API_KEY` is set, else Claude) → `reports` table + `report-photos` bucket. Game layer (`*_game.sql`): anonymous-auth players (`profiles`), append-only `point_ledger` (points + XP; balances derived), `quests`, `award_report()` (zone multiplier, XP, quest payouts; called by verify-report) and `game_state()` (client RPC). `map-data` serves the map (pins + H3 res-9 bounty heat from the `bounties` table). `buyer` serves the buyer dashboard (`web/dashboard.html`, `python3 -m http.server -d web 8000`): the work queue, "Mark fixed" → `mark_report_fixed()` (sets `reports.fixed_at`, pays a `fix_bonus`), "Post bounty" (draw a polygon ≤ ~5 km, multiplier, optional surge) → `post_bounty()`, and "End bounty" → `end_bounty()`. A surge bounty (`bounties.surge`) adds a "Storm sweep" quest, draws red dashed on both maps, and doubles the queue priority of reports inside it (`surge_report_ids()`). It's gated by the `BUYER_TOKEN` secret (`x-buyer-token` header; `verify_jwt = false` for CORS). The app polls `my_fixes()` and reloads the map every 30 s while open and posts a local "your report got fixed" notification (no APNs yet). Danger zones (`danger_zones` table, `*_danger_zones.sql`): drawn on the dashboard like bounties; inside an active one `award_report()` pays 0 points/XP (returns `danger: true`), `multiplier_at()` is 1, map-data drops heat cells and returns the polygons, `game_state()` hides quests whose bounty touches one, and the app shows the SafetyBanner and pauses the Capture button. Demo pins/bounties around USC come from `supabase/seed_demo.sql` (flagged `demo`, one-line delete). Deploy with `supabase functions deploy <name> --project-ref kiygfzzdaqabrggjnrmf`. It needs the `OPENAI_API_KEY` (optional `OPENAI_MODEL`, default `gpt-6-luna`) or `ANTHROPIC_API_KEY` secret.
  - `asset-lookup` (GET `?lat&lng&heading&accuracy`) names the asset the camera is aimed at (§7.2): one OSM Overpass query (two public instances raced), heading ray → first building footprint within 50 m, else nearest; matching is pure in `asset-lookup/geo.ts`. It also returns `multiplier_at()` for the camera's zone chip. The confirmed asset is stored by verify-report in `reports.asset_kind / asset_name / asset_osm_id` (no assets table yet).
- **`research/RESEARCH_PLAN.md`** has the interview guides, survey, usability test and synthesis template (feeds §12).

## 2. One-liner

**FaultLine turns every smartphone into an inspection sensor.** People photograph infrastructure damage (or let the app find it in photos they already took), AI verifies it and scores its severity, and they earn redeemable points. We sell the resulting always-fresh, geolocated condition data to the governments, utilities, insurers and contractors who pay to find and fix those assets.

## 3. Why this wins the prompt

| Prompt asks for | FaultLine answer |
|---|---|
| Identify deterioration & damage | Vision model classifies damage type and scores severity 1–5 |
| Automate inspections | Crowd supplies continuous coverage; nobody is dispatched to *find* problems, only to fix them |
| Prioritize maintenance | Severity × asset criticality × report recency → ranked work queue per buyer |
| Predict failures | Time-series of repeat photos of the same asset → deterioration trend (a crack widening over months) |
| Disasters | "Surge mode": bounty multipliers over affected areas give rapid damage assessment within hours |
| Uses the flood of phone data | In-app capture **plus** passive gallery mining of photos people already have |

**Core insight:** inspection cost is mostly *getting eyes onto the asset*. Millions of people already walk past every asset every day. We pay them a fraction of a truck roll to look.

## 4. Users

### Supply side: Reporters (free app, iOS)
- **Casual citizens.** Annoyed by a pothole and like earning gift cards.
- **Power users / "hunters".** Treat it as a game, chase quests and leaderboards, like Pokémon Go / Geocaching players.
- **Gig workers & delivery drivers.** Already moving through the city all day.
- **Disaster-mode volunteers.** Residents documenting their own neighborhood after an event.

### Demand side: Buyers (paid, web dashboard + API)
- **Municipalities / DOTs / public works.** Roads, sidewalks, signage, bridges, streetlights. Many already run 311 intake.
- **Utilities & telecom.** Poles (leaning, cracked), transformers, exposed lines, vegetation encroachment, cabinets.
- **Insurers.** Pre-loss property condition, post-catastrophe damage assessment, claims triage.
- **Property managers / REITs / HOAs.** Facade, parking structure and roof condition across portfolios.
- **Contractors.** Qualified repair leads (priced per lead).

## 5. Core loop

```
Spot → Snap → Verify (AI) → Earn → See it on the map → Get pulled toward hotter zones → Spot …
```

1. **Snap.** In-app camera captures photo + GPS + compass heading + timestamp + device attestation.
2. **Identify asset.** Location + heading → nearest building footprint / road segment / pole (see §7.2). User confirms or corrects with one tap.
3. **Verify.** On-device prefilter rejects junk instantly; server model returns `{is_damage, damage_type, severity, confidence}`.
4. **Reward.** Points are *pending* immediately (instant dopamine) and *settle* after fraud checks pass (hold period).
5. **Map.** Report appears as a pin; the asset gets a condition history.
6. **Pull.** Heat map shows where reports are worth more, which steers the crowd to where buyers need coverage.

## 6. Feature spec

### 6.1 Capture & report (MVP)
- In-app camera only for full rewards. Captures EXIF, GPS accuracy, heading, pitch, timestamp.
- Optional one-line note + damage-type chip (AI pre-fills it and user can override).
- Asset auto-identified; shows address / asset name ("Pole #…", "Main St Bridge", "123 Oak Ave facade").
- Result screen: damage type, severity badge, points earned, "first finder" or "confirmation" tag.

### 6.2 AI damage detection
- **Damage taxonomy (v1):** crack (concrete/masonry), spalling / exposed rebar, corrosion/rust, pothole / pavement failure, water damage / leak, leaning or damaged pole, broken sign/streetlight, fallen tree / debris on asset, fire damage, structural collapse, other.
- **Severity 1–5:** 1 cosmetic · 2 monitor · 3 schedule repair · 4 urgent · 5 hazard/imminent failure (5 also surfaces "report to 911/311" prompt).
- **Not damage → no reward**, with friendly feedback ("Looks like a shadow, try closer").
- Human-in-the-loop review queue for low-confidence or high-severity results. Those labels become training data.

### 6.3 Gallery scan (opt-in)
- PhotoKit with **limited-library** support; user can pick albums or grant all.
- Runs **on-device** (Core ML / Vision). Photos never leave the phone unless the user approves a candidate.
- Only photos with GPS EXIF qualify. Candidate list → user swipes approve/reject → approved ones upload.
- Faces and license plates blurred on-device before upload.
- Rewarded lower than live capture (older, unverifiable timing). Older than N months → tagged "historical" and useful for trend baselines.
- Runs in background (BGProcessingTask) when charging.

### 6.4 Map & heat map
Two layers. **Keep them distinct, because this is the key economic lever:**
- **Damage layer.** Pins/clusters of verified reports, colored by severity.
- **Bounty heat layer.** How much a report is *worth* in each cell. Heat is **not** "where damage is". It's where buyers want data:
  ```
  heat(cell) = buyer_bounties(cell)
             + staleness(cell)        // time since last verified coverage
             + asset_criticality(cell) // bridges, hospitals, substations > sidewalk
             + disaster_surge(cell)    // active event polygons (built as a bounty flagged `surge`)
  multiplier = 1x … 5x, derived from heat
  ```
- Cells are **H3 hexagons** (res ~9, ≈ city block).
- Reporter sees multiplier before walking there. This turns buyer demand directly into crowd routing.

### 6.5 Game layer
- **Points** (redeemable) and **XP** (non-redeemable, drives levels). Separate so we can reward engagement without paying cash for it.
- **Levels & titles:** Rookie Spotter → Inspector → Structural Sleuth → Chief Engineer. Higher levels get a small point bonus and access to premium bounties.
- **First finder vs confirmation:** first verified report on an asset gets full reward. Later reports on the same asset within a window get a smaller "confirmation" reward. They're still valuable because they track progression.
- **Quests / bounties:** "Inspect 5 bridges downtown this week", "Storm sweep: Zone B7". Many are buyer-funded.
- **Streaks, badges, neighborhood leaderboards, rarity** (a severity-5 find is a "legendary").
- **Accuracy score / reputation:** rejected or fraudulent reports lower it. Low reputation means lower multipliers and longer holds.

### 6.6 Rewards & redemption
- Points ≠ crypto. Plain closed-loop loyalty points avoid securities / money-transmitter problems.
- Redeem via a gift-card API (Tremendous / Tango Card / Giftbit) with a minimum redemption threshold.
- US tax: track per-user annual payout value (1099 threshold). KYC only above a redemption cap.
- **Hackathon:** redemption is mocked (catalog UI + fake "code sent"). `redeem(sku)` (`*_rewards.sql`) spends settled points via a negative `redeem` ledger row + a `redemptions` row with a fake `FL-XXXX-XXXX` code; catalog lives in `reward_catalog`, priced at `points_per_dollar()` = 100 (prices stored in dollars), minimum $5. `game_state()` returns `catalog`, `redemptions`, `min_redeem` and a `surge` flag per quest (drives the Quests/Rewards tab dots).

### 6.7 Buyer dashboard (web, minimal for demo)
- Map of their territory/assets, filter by damage type & severity, time slider.
- Prioritized work queue (severity × criticality × recency), CSV/GeoJSON export, webhook/API.
- "Post a bounty": draw polygon + multiplier (+ surge flag), which feeds the heat layer. Budget comes later.
- 311 / work-order integrations (later).

### 6.8 Disaster / surge mode
- Ops (or an automated feed like NWS / USGS / CAL FIRE perimeters) activates an event polygon.
- Heat spikes, a disaster-specific quest is pushed, and the taxonomy adds FEMA-style damage levels (affected / minor / major / destroyed).
- **Safety gates (built: buyers draw danger zones on the dashboard and "Declare safe" ends them; hand-drawn, no NWS / CAL FIRE feed yet):** no rewards inside active evacuation / fire perimeter / flood zones until they are declared safe. In-app warnings. Never incentivize entering danger.
- Sold as rapid-assessment packages to insurers, utilities and emergency management.

## 7. Technical architecture

### 7.1 Stack (hackathon default, so change it here if we change it)
- **iOS:** iOS 26 minimum, SwiftUI (`@Observable`), AVFoundation camera, CoreLocation (location + heading), MapKit, PhotoKit, Core ML / Vision for on-device image prefilter, WhisperKit (Whisper tiny.en, bundled) for on-device dictation, Apple Foundation Models for on-device text structuring (note → fields, PII scrub; see design-system/MASTER.md §8).
- **Backend:** Supabase: Postgres + **PostGIS**, Storage (images), Auth (Sign in with Apple), Edge Functions.
- **Server-side damage model:** Claude vision (`claude-sonnet-5`) with a strict JSON schema output. It's the fastest path to good multi-class + severity + explanation. Replace or augment with a fine-tuned detector (YOLO / segmentation) later.
- **Asset data:** OpenStreetMap (Overpass API) / Overture Maps building footprints + road segments; utility pole datasets where public.
- **Spatial index:** H3 (`h3-js` in edge functions or `h3-pg` extension).
- **Buyer dashboard:** one static page, `web/dashboard.html` (MapLibre + OpenFreeMap tiles, MASTER §7.6 tokens) over the `buyer` Edge Function. Keep it small.

### 7.2 Asset identification
1. Take GPS fix (reject if horizontal accuracy > ~30 m) + compass heading.
2. Cast a ray from the phone position along the heading for ~50 m. First intersected building footprint = candidate. For roads/sidewalks use nearest road segment; for poles use nearest pole point.
3. Fall back to nearest footprint within radius if ray misses.
4. User confirms / taps a different asset on a mini-map.
5. Unknown asset → create a new `asset` row (point geometry) so the crowd builds the inventory too.

### 7.3 Verification pipeline
```
upload → EXIF/metadata sanity → attestation check → pHash dedupe → asset match
      → vision model (type, severity, confidence) → fraud scoring
      → auto-accept | human review | reject → settle points
```

### 7.4 Data model (sketch)
```
users(id, handle, xp, level, points_pending, points_settled, reputation, created_at)
assets(id, type, name, geom, source[osm|overture|user], criticality)
reports(id, user_id, asset_id, image_url, geom, heading, captured_at, source[camera|gallery],
        status[pending|accepted|rejected|review], damage_type, severity, confidence,
        is_first_finder, h3_cell, phash)
zones(h3_cell, heat, multiplier, last_verified_at, surge_event_id)
bounties(id, buyer_id, polygon, budget, per_report, damage_types[], starts_at, ends_at)
point_ledger(id, user_id, report_id, amount, kind[earn|bonus|redeem|clawback], state, created_at)
redemptions(id, user_id, points, reward_sku, status)
buyers(id, name, type[gov|utility|insurer|pm|contractor], territory)
surge_events(id, kind, polygon, danger_polygon, active)
```
Point ledger is **append-only**: balances are derived, never edited in place.

## 8. Trust, fraud & safety (the part judges will poke at)

Paying money for photos invites abuse. Defenses:

| Attack | Defense |
|---|---|
| Downloaded / web images | In-app capture only for full reward; App Attest / DeviceCheck; reverse-image + pHash against our corpus |
| AI-generated / edited images | Capture-time attestation, C2PA-style signing of in-app captures, synthetic-image detector |
| GPS spoofing | Attestation, location accuracy/consistency checks, impossible-travel detection |
| Same damage spammed | pHash + asset + time window dedupe; first finder only once per asset per window |
| Farming low-value reports | Diminishing returns per user per asset/day; rate limits; hold period before settling |
| **Creating damage to earn** (perverse incentive) | Reward *discovery of pre-existing* damage: cross-check prior reports / historical imagery; no reward on assets the user reported "undamaged" recently; ToS + bans + clawback; severity-5 finds get human review |
| Trespassing / danger | Only reward from public right-of-way; surge zones gated; in-app safety prompts |
| Privacy (faces, plates, homes) | On-device blurring; gallery scan on-device; private residences only shared with owner or with consent / insurer relationship |

## 9. Business model

### 9.1 Revenue streams
1. **Data subscriptions (primary):** per-territory annual license for the live condition map + work queue + API. Tiered by area / asset count.
2. **Bounties:** buyers fund coverage of a polygon or asset class. We take a margin on top of the reporter payout.
3. **Disaster rapid-assessment packages:** premium, event-based pricing for insurers, utilities, emergency management.
4. **Contractor leads:** per-lead fee for verified repair opportunities (commercial / public assets; private homes only with owner opt-in).
5. **Later: dataset licensing:** labeled damage imagery for training others' models.

### 9.2 Unit economics (illustrative, need validation)
- Reporter payout per accepted report: ~$0.10–$2.00 in points (multiplier-dependent).
- Value to buyer: a manual field inspection costs roughly **$50–$300+** per site visit. Even selling a verified report at $5–$25 is a large discount.
- Target: reporter payouts ≤ ~25% of revenue attributed to that report.
- Free public-good tier: forward severity-4/5 hazards to local 311 at no charge. Builds goodwill and gov pipeline.

### 9.3 Go-to-market & first 100 customers
"Customer" = a **paying buyer**. Reporters are supply, so track them separately.

**Supply first (it makes the data exist):** one metro, campus ambassadors + launch quests ("first 50 finds in downtown get 3x"), local Reddit / Nextdoor, delivery-driver communities. Target ~1,000 active reporters to cover a downtown densely.

**First 100 paying customers: go small and many before big and slow.**
Government sales cycles are 6–18 months, so govs are *design partners*, not the first revenue.
1. **Property managers, HOAs, small REITs (fastest).** Short sales cycle, clear pain (facade/parking liability), credit-card priced self-serve plan (~$99–$499/mo per portfolio). Cold outreach to local PM firms + BOMA / IREM chapters. **Bulk of the first 100.**
2. **Contractors (lead-gen).** Concrete, masonry, paving, roofing firms pay per lead. Reach via local trade associations, Google Maps / Angi listings. High count, low ACV.
3. **Municipal design partners (1–3).** Free pilot that forwards hazards to 311 and trades data for a public case study + LOI. Credibility for everything else. Reach via city innovation offices / Bloomberg Philanthropies networks.
4. **1 utility + 1 insurer pilot.** Paid pilot scoped to a service territory or post-storm event. Higher ACV, proves the enterprise tier.

Then expand city-by-city. Disaster events are marketing moments.

### 9.4 Competitive landscape
- **311 / civic apps** (SeeClickFix, FixMyStreet): intake only, no incentive, no severity AI, no data product.
- **Road AI** (RoadBotics/Michelin, Vialytics): vehicle-mounted, roads only, customer does the driving.
- **Drone / satellite inspection:** expensive per mission, great for scale but low street-level detail and cadence.
- **FaultLine edge:** incentivized, continuous, street-level, multi-asset, plus passive gallery mining and a demand-driven heat map that routes the crowd to where buyers pay.

## 10. Hackathon MVP scope

**Must demo:**
- [ ] iOS: capture → upload → AI result (type + severity) → points awarded
- [x] Asset identified from location (building footprint lookup). `asset-lookup` over Overpass; the user can change it; stored on `reports.asset_*`.
- [x] Map with damage pins + bounty heat layer (H3 hexes) + multiplier shown
- [x] Gamification surface: points, XP/level, one quest, leaderboard
- [x] Gallery scan on a handful of seeded photos (on-device prefilter → candidates → approve). Map → "Scan my photos"; seed the simulator with `ios/scripts/seed_gallery.sh`. Foreground only (no BGProcessingTask); faces blurred, plates not.
- [x] Minimal buyer dashboard: map + prioritized list + "post bounty" that visibly heats the app map (within one 30 s poll), plus "Mark fixed" (which notifies the reporter).
- [x] Surge mode toggle over a polygon (disaster story). No danger/evacuation polygons yet.

**ML hard limits (agreed 2026-09-26, deadline Sun 2026-09-27 23:59 PDT):**
- ~4 h cap on ML work. No retraining, no new models: thresholds and gates on the shipped ones only.
- On-device results are "Preliminary". The server verdict decides type, severity and points. Accuracy claims only from a cited test set.
- Detector boxes cover roads/sidewalks only. Walls and structures go through the classifier suggestion plus the server verdict. Leakage, detachment and bulge stay hidden on-device.
- Non-damage photos block the normal submit (Apple scene gate + no findings) but keep "Submit anyway".
- Own-photo test set: ~50 per visible class plus non-damage, shot around campus. It doubles as §12 evidence.

**Fake / mock for demo:** gift card redemption, attestation, KYC, 311 integration, trend prediction (show a mocked "crack widened 40% over 3 reports" timeline).

**Out of scope:** Android, real payouts, full fraud stack. (An on-device YOLO detector now exists in `ml/detector/`; the server model stays the authority.)

## 11. Demo script (≈3 min)
1. Problem in one line + the "billions on manual inspection" stat.
2. Live: photograph a crack → AI says "Spalling, severity 3, 120 pts (2x zone)".
3. Map: show heat. Buyer dashboard posts a bounty and the zone turns red in the app.
4. Gallery scan finds damage in old photos → approved → pins drop.
5. Flip surge mode ("storm hit Zone B") → quests + multipliers → dashboard work queue re-ranks.
6. Business: who pays, unit economics, fraud answer.

## 12. Validation evidence (scored: Criterion 1)
Collect during the weekend and log results here as they come in (who, role, date, key quote). **Don't fabricate. Empty is better than invented.**

- [ ] **Buyer interviews (target 5+):** public works / 311 staff, property managers, contractors, utility or insurer field ops. Ask: how do you find damage today, what does one inspection cost, how often, what would you pay for a live condition feed?
- [ ] **Reporter survey (target 20+ students):** would you photograph damage for $X in gift cards? How much per report makes it worth it? Would you allow a gallery scan?
- [ ] **Desk research with sources:** cost of manual inspections, deferred-maintenance backlog (e.g. ASCE Infrastructure Report Card), 311 pothole volumes, catastrophe claims cost. Cite each number in the pitch.
- [ ] **Prototype test:** have 3–5 people use the app and record reactions.

| Date | Who (role, org) | Channel | Key insight / quote |
|---|---|---|---|
| | | | |

## 13. What's next (scored: Criterion 3, "awareness of what comes next")
- Custom-trained detector on accumulated human-reviewed labels, which reduces LLM cost per report.
- Failure prediction from repeat-photo time series per asset.
- Passive sources: dashcams / connected vehicles, delivery-fleet partnerships.
- Work-order integrations (Cityworks, ESRI, SAP PM), 311 APIs.
- Android, real payouts with KYC, full fraud stack.

## 14. Open questions / decisions to make
- Final product name.
- Point → dollar rate and default multipliers.
- Which city / seed dataset for the demo.
- Buyer dashboard: separate web app or a screen in the same repo?
- How much of the ML is on-device vs Claude vision for the demo (latency vs quality).
- Private residential property: include or exclude in v1? (Leaning: exclude except owner-submitted.)
