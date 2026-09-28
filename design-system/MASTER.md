# Mend Design System (MASTER)

**Every UI change in this repo follows this file.** Product context lives in `/CLAUDE.md`.

- **Code:** `design-system/DesignSystem.swift` holds the tokens and core atoms. Import it and never redefine them.
- **Checks:** `python3 design-system/contrast_check.py` must exit 0 after any color change.
- **Page overrides:** before building a screen, check `design-system/pages/<screen>.md`. If it exists, its rules win over this file for that screen only. If it doesn't, this file is the whole rulebook.
- **Research:** `research/RESEARCH_PLAN.md` holds the interview guides and synthesis. Design decisions tagged *[hypothesis]* below are unvalidated until research lands there.

Skills this system was built with (re-load them when extending it): `design:design-system`, `design:user-research`, `design:research-synthesis`, `design:accessibility-review`, `ui-ux-pro-max`, `everything-claude-code:swiftui-patterns`, `everything-claude-code:foundation-models-on-device`.

---

## 1. Design principles

Derived from who uses this and where (see CLAUDE.md §4). Each one settles arguments.

1. **Built for the sidewalk.** Used outdoors, in sunlight, one-handed, often walking. That means high contrast, big targets, primary actions in the thumb zone, and at most one decision per screen. *[hypothesis: validate in usability test]*
2. **Snap first, details later.** Capture must be ≤ 2 taps from app open. Everything else (asset, note, type) is pre-filled by the system and only *confirmed* by the user.
3. **Game energy lives in moments, not chrome.** The base UI is calm and airy so it's trustworthy to the cities and insurers we demo to. Celebration (gold, bounce, haptics) is reserved for earning: points awarded, level up, badge, quest complete.
4. **Gold means value.** Gold is used only for points, multipliers and bounty heat. If something is gold, it pays. Never use it decoratively.
5. **Text never breaks its container.** Every label wraps or reflows at any Dynamic Type size (§3.2 rules). Clipped, overlapping or protruding letters are bugs.
6. **Never color alone.** Severity, status and heat always carry an icon + text/numeral too.
7. **Honest about uncertainty.** Distinguish *preliminary* (on-device) from *verified* (server) and *pending* points from *settled* points. Don't show a number we might claw back as final.
8. **Safety over engagement.** No incentive UI inside danger zones, no streak pressure that pushes people into unsafe places, no dark patterns (fake scarcity, loot boxes, guilt copy).
9. **Private by default.** Privacy is explained once, in onboarding and the gallery-scan intro copy. Screens don't carry an "On-device" label (removed 2026-09-27: it was noise). Uploads are always an explicit user action.

## 2. Visual direction: "Cloud"

Adopted 2026-09-27 from the reference boards the team picked (soft sky onboarding, Poppins learning app, Foku focus app, Headstart AI kit). Plain white surfaces with soft Sky accents, Midnight navy for text and the one primary action, big rounded cards, capsule buttons and chips, Poppins type, and Sunbeam yellow only where something pays. It should feel calm, friendly and modern, like a consumer app people want to open, while the data stays legible enough for buyers.

What we take from the references:
- **Backdrop:** plain white (`flCanvas`). The references use a Sky wash; the team chose white on 2026-09-27. Sky lives in the hero card, chips and the map header fade instead.
- **Primary action:** a full-width Midnight capsule, 56 pt, at the bottom of the screen ("Get Started", "Start focus session").
- **Secondary action:** a Sky gradient capsule ("Continue"). Tertiary actions are plain text buttons ("Log In").
- **Hero card:** one Sky gradient card per screen, 32 pt radius, holding the headline number plus small white stat tiles ("Hunger 65%" becomes "Streak 4 days").
- **Chips:** capsule, Surface2 when unselected and Sky when selected, text only (no icons or emoji); the selected one also gets a 2 pt Midnight outline.
- **Top bar:** a 44 pt rounded-square icon button (back / bell) with a centered title or a greeting ("Hello, Jane!").
- **Section rows:** "Today's focus ……… View all →" headers over white cards with soft shadows.

**Rejected directions:**
- **Claymorphism.** Reads as a kids' app and undermines buyer trust.
- **Serif display titles** (reference 1). They're pretty but clash with Poppins, so we keep one family.
- **Vivid electric-blue primary** (reference 1). Midnight is calmer and keeps blue free for Sky accents and severity 2.
- **Emoji as icons** (references 2, 5). They render inconsistently and break §3.6. We use SF Symbols instead.

## 3. Tokens

All tokens live in `DesignSystem.swift`. Use `.foregroundStyle(.flInk)`, `.font(.flTitle)`, `FLSpace.lg`, and so on. **Raw hex, raw point sizes and ad-hoc spacing in screens are bugs.**

### 3.1 Color

The palette is five brand swatches plus one value color. Anything else is a functional token (feedback, severity, media).

| Swatch | Hex | Role |
|---|---|---|
| Midnight | #18212D | Text, primary buttons, dark-mode surface |
| Slate | #6887A4 | Tertiary text, control borders (3.7:1 on white, so never body text) |
| Sky | #ADD9F3 | Accent fills: selected chips, hero card, secondary button, map header fade |
| White | #FFFFFF | Canvas. **No grey screen backgrounds** (team decision 2026-09-27) |
| Paper | #FEFEFE | Cards, sheets |
| Sunbeam | #FFE66D | Value only: points, multipliers, bounty heat |

| Token | Light | Dark | Use | Never |
|---|---|---|---|---|
| `flCanvas` | #FFFFFF | #0F141C | Screen and sheet background | Cards |
| `flSurface` | #FEFEFE | #18212D | Cards, sheets, list rows, stat tiles | Screen background |
| `flSurface2` | #F0F7FD | #222D3B | Sky tint (not grey): unselected chips, icon buttons, inputs, banners | Text |
| `flInk` | #18212D | #F4F6FA | Primary text, icons | — |
| `flInk2` | #4E6A86 | #A9BACD | Secondary text, metadata (a darker Slate that passes 4.5:1) | Primary actions |
| `flInk3` | #6887A4 | #8A9FB6 | Placeholder, large non-essential text | Body copy |
| `flStroke` | #6887A4 | #6887A4 | Control boundaries, Increase Contrast card borders (3:1) | Decorative dividers (use `flInk.opacity(0.06)`) |
| `flBrand` | #18212D | #ADD9F3 | Primary button fill, selected tab, focus | Status, severity |
| `flOnBrand` | #FEFEFE | #18212D | Text/icons on brand | — |
| `flAccent` | #ADD9F3 | #2B4A66 | Selected chip, hero card, secondary button | Text |
| `flOnAccent` | #18212D | #F4F6FA | Text/icons on accent | — |
| `flAccentText` | #2F6690 | #ADD9F3 | Links, "View all →", inline actions | Body copy |
| `flGold` | #FFE66D | #FFE66D | Points pill, multiplier chip, bounty heat hexes | Anything that doesn't pay |
| `flOnGold` | #18212D | #18212D | Text on gold | — |
| `flGoldText` | #7A5E00 | #FFE66D | Gold *as text* ("+120 pts") on surfaces | — |
| `flSuccess` | #1B7F4B | #4CC38A | Verified, settled | Severity |
| `flWarning` | #A15C00 | #F5B040 | Rejected report, soft warnings | Severity |
| `flDanger` | #C8202F | #FF6B6B | Errors, destructive actions, danger zones | Severity 5 in lists (use the severity token) |
| `flMedia` | #000000 | #000000 | Camera / full-bleed photo background | App surfaces |
| `flOnMedia` | #FFFFFF | #FFFFFF | Shutter, icons, text over camera or photos. **Always on glass, a scrim, or `flMedia`** | Text on app surfaces |

**Severity ramp** (`Severity.color`, always paired with `Severity.symbol` + numeral):

| Level | Label | Light | Dark | SF Symbol |
|---|---|---|---|---|
| 1 | Cosmetic | #5B6878 | #9AA6B6 | `info.circle.fill` |
| 2 | Monitor | #1F72C4 | #5AA9F0 | `eye.fill` |
| 3 | Repair soon | #9E6300 | #F0A62A | `wrench.and.screwdriver.fill` |
| 4 | Urgent | #C9480A | #FF8540 | `exclamationmark.triangle.fill` |
| 5 | Hazard | #C8202F | #FF5A64 | `exclamationmark.octagon.fill` |

**Bounty heat** (map hexes): `flGold` at opacity 0.12 / 0.22 / 0.34 / 0.46 / 0.58 for multiplier bands 1× / 1.5× / 2× / 3× / 5×. Each bounty also gets a white callout bubble with its multiplier (§7.3). It's a single hue, so it never competes with severity pins.

### 3.2 Typography

**Poppins** (Regular 400, Medium 500, SemiBold 600, Bold 700; SIL OFL) is the one family. The TTFs live in `design-system/fonts/`. XcodeGen bundles that folder and `FLFont.register()` loads them at launch. If the files are missing, `Font.custom` falls back to SF Pro, so the app still builds. Every token is `Font.custom(_, size:, relativeTo:)`, so it scales with Dynamic Type up to AX5.

| Token | Poppins | Base pt | Scales with | Use |
|---|---|---|---|---|
| `flDisplay` | Bold | 34 | largeTitle | Point totals, level-up, hero numbers |
| `flTitle` | SemiBold | 26 | title | Screen and sheet titles ("Join Us") |
| `flSection` | SemiBold | 19 | title3 | Section headers ("Nearby bounties") |
| `flHeadline` | SemiBold | 16 | headline | Card titles, button labels |
| `flBody` | Regular | 16 | body | Default copy |
| `flCallout` | Regular | 14 | callout | Subtitles under titles, supporting copy |
| `flCaption` | Medium | 12 | caption | Chips, metadata, badges. **Smallest allowed.** |
| `flNumber` | SemiBold | 20 | title3, monospaced digits | Points, XP, counts, stat tiles |

**Anti-overflow rules** (the "letters protruding" bugs):
- **Never give text a fixed `height` or `width`.** Use `minHeight` / `maxWidth: .infinity`. Buttons already do this.
- Titles and subtitles are centered only on onboarding and empty states. Everywhere else they're leading-aligned.
- Rows with a label plus a trailing value use `ViewThatFits` (HStack first, then VStack) or `HStack(alignment: .firstTextBaseline)` with `Spacer(minLength: FLSpace.sm)`. Never an HStack that can't wrap.
- Multi-line text inside a card: `.fixedSize(horizontal: false, vertical: true)` so the card grows rather than clipping.
- `lineLimit` only with a reason, max 2, and the full string goes in the accessibility label. `minimumScaleFactor` only on the single number in `PointsPill` / `MultiplierChip`, never below 0.8.
- Poppins has tall ascenders. Don't stack text with negative spacing, and keep `.padding(.vertical, FLSpace.xs)` or more inside capsules.
- Test every new screen at the default size **and** at AX3 in previews before merging.
- Any changing number uses `.monospacedDigit()` + `.contentTransition(.numericText())`.
- Weight hierarchy: Bold for display, SemiBold for titles/labels/buttons, Medium for chips/captions, Regular for body.

### 3.3 Spacing, radius, elevation

- **Spacing (4-pt grid):** `FLSpace.xs 4 · sm 8 · md 12 · lg 16 · xl 24 · xxl 32 · xxxl 48`. Screen gutter `16` (use `xl` 24 on onboarding). Between cards `12`. Between sections `24`.
- **Sizes:** `FLSize.button 56` (primary/secondary min height) · `FLSize.iconButton 44` · `FLSpace.minTap 44`.
- **Radius:** `FLRadius.sm 10` (icon buttons, inner tiles) · `md 16` (stat tiles, inputs, thumbnails) · `lg 24` (cards, banners, sheets) · `xl 32` (the hero card). Always continuous corners. Buttons and chips use `.capsule`.
- **Elevation:** three levels.
  - Flat: stat tiles and chips, no shadow.
  - Card: `flCard()` with one soft shadow `(flInk 6%, radius 16, y 6)`. Increase Contrast swaps it for an `flStroke` border.
  - Floating: controls over the map or camera. Liquid Glass (`.glassEffect()`), or solid Midnight/Paper with a tinted shadow: map FABs `flBrand` 25% (radius 10–12, y 4–6), bounty bubbles `flInk` 12% (radius 10, y 4).
  - The primary button, the round map buttons and the map bounty bubbles carry their own soft shadows. Nothing else adds shadows.

### 3.4 Motion

| Token | Curve | Use |
|---|---|---|
| `FLMotion.quick` | snappy 0.2 s | Press, toggle, chip select |
| `FLMotion.standard` | smooth 0.3 s | Sheet content, list insert/remove, mode switch |
| `FLMotion.reward` | bouncy 0.45 s | **Only** points earned, level up, badge unlock, quest complete |

- Wrap animations in `FLMotion.resolve(_, reduceMotion)` (read `@Environment(\.accessibilityReduceMotion)`). With Reduce Motion on: no scale/bounce, crossfade only.
- Animate transform/opacity only. Every animation must mean something (cause → effect). Never block input during animation.
- Max 1–2 animated elements per view at a time.

### 3.5 Haptics

Use `.sensoryFeedback`, never in scroll or continuous gestures.

| Moment | Feedback |
|---|---|
| Shutter press | `.impact(weight: .light)` |
| Report verified / points awarded | `.success` |
| Level up / badge | `.success` + `FLMotion.reward` |
| Report rejected | `.warning` |
| Entering danger zone | `.error` |

Haptics are never the only feedback.

### 3.6 Iconography

- **SF Symbols only.** No emoji as icons, no PNG icons.
- Rendering: `.hierarchical` for decorative icons, `.monochrome` inside badges.
- Filled symbols for selected/status, outline for navigation and unselected. Don't mix them at the same level.
- Icon-only buttons need `.accessibilityLabel` and a ≥ 44×44 pt hit area (`.contentShape(.rect)` + frame).

## 4. Platform & architecture (UI layer)

- **iOS 26 minimum, SwiftUI only.** That brings Liquid Glass bars for free, the Foundation Models framework, and `@Observable`.
- **State:** `@Observable` view models owned via `@State`; dependencies via `@Environment(Type.self)`. No `ObservableObject` / `@Published` / `@EnvironmentObject`.
- **Navigation:** one `NavigationStack(path:)` per tab with a typed `Destination` enum and an `@Observable Router`. Sheets are for tasks (capture result, redeem), not primary navigation.
- **Async:** `.task {}` only. No I/O in `body` or `init`.
- **Lists:** `LazyVStack` / `List` with stable IDs. Small views so state changes invalidate little.
- **Previews:** every component and screen has `#Preview`s for empty, loaded, error, dark mode and AX-size states.
- **Sheets are white:** every sheet sets `.presentationBackground(.flCanvas)`; a `List` inside one also sets `.scrollContentBackground(.hidden)`, rows `.listRowBackground(Color.flSurface2)`, and `FLSectionHeader` headers (Poppins, not the system grey caps). No grey sheets (team decision 2026-09-27).
- **Don't hand-roll glass.** Tab bar and toolbars get Liquid Glass from the system. Use `.glassEffect()` only for floating map/camera controls.

## 5. Information architecture

```
TabView
├── Map        (default)  bounty heat + damage pins, floating Capture button, "Scan my photos" entry
├── Quests                active quests, bounties near you, surge events
├── Rewards               balance (pending vs settled), redeem catalog, history
└── Profile               level/XP, badges, leaderboard, my reports, settings/privacy
Capture  → fullScreenCover from the Map FAB or any quest card (not a tab: it's an action)
Result   → sheet after upload (verification result)
```

- 4 tabs, icon + label, the selected state uses `flBrand`. A badge dot only on Quests (new surge) or Rewards (points settled) and clears on visit.
- Deep links: `mend://report/<id>`, `mend://quest/<id>`, `mend://map?cell=<h3>`.

## 6. Components

Atoms marked **(code)** already exist in `DesignSystem.swift`. Everything else is a spec: build it from tokens and add it to `DesignSystem.swift` once a second screen needs it.

| Component | Purpose | Anatomy | States | Accessibility |
|---|---|---|---|---|
| **FLPrimaryButtonStyle** (code) | The one primary action per screen | Full-width Midnight capsule, min height 56, faint brand shadow, label wraps | default, pressed (0.97 scale / 0.8 opacity with Reduce Motion), disabled 0.4, loading (swap label for `ProgressView`, keep width) | Label is a verb ("Submit report") |
| **FLSecondaryButtonStyle** (code) | Supporting actions | Full-width Sky gradient capsule, `flOnAccent` label | default, pressed, disabled | — |
| Tertiary (plain) | "Log In", "Skip" | `Button` + `.buttonStyle(.plain)`, `flHeadline`, `flInk` or `flAccentText` | — | ≥ 44 pt hit area |
| **FLIconButton** (code) | Back, close, notifications | 44 pt rounded square (`FLRadius.sm`), `flSurface2`, SF Symbol | — | `label` is required |
| **FLChip** (code) | Filters, damage types, choices | Capsule, `flCaption` text only; Surface2 → Sky + 2 pt Midnight outline when selected | unselected, selected | `.isSelected` trait |
| **FLInfoRow** (code) | Label + value facts ("Emergency level … [SeverityBadge]", "Points … [PointsPill]") | `flCallout` `flInk2` title leading, value trailing; stacks via `ViewThatFits` | — | Combined element |
| **FLSectionHeader** (code) | Section title + optional "View all →" | `flSection` title, `flAccentText` trailing action | with / without action | Title is a header |
| **flHeroCard()** (code) | The one highlighted card per screen | Sky gradient, `FLRadius.xl`, padding 24; holds `flDisplay` number + `FLStatTile`s | — | — |
| **FLStatTile** (code) | Small metric inside a hero card | White tile, radius md, caption label with symbol, `flNumber` value | — | Combined element |
| **SeverityBadge** (code) | Severity anywhere | Icon + numeral + optional label, severity fill | compact (no label) / full | Reads "Severity 3 of 5, Repair soon" |
| **PointsPill** (code) | Points amounts | Star + monospaced number (+ "pending") | settled (solid gold), pending (45% gold light / 75% dark + dashed border) | "120 points, pending review" |
| **MultiplierChip** (code) | Zone value | "2×" on gold | — | "2 times points zone" |
| **StatusBanner** (code) | Report / zone status | Icon + title + optional detail | pending, accepted, review, rejected, failed, dangerZone, fixed, queued (offline: "Saved. Sends when you're back online.") | Combined element; status changes posted as announcements |
| **flCard()** (code) | Container | Surface, radius 24, soft shadow (stroke with Increase Contrast) | — | — |
| **CaptureButton (FAB)** | Open camera from map | 64 pt Midnight circle, `camera.fill`, 3 pt Sky ring, bottom-center above the Maps attribution | default, pressed, disabled in danger zone (with reason on tap) | "Report damage" |
| **ShutterButton** | Take photo | 72 pt white ring + inner disc | ready, capturing (inner shrinks), processing (spinner) | "Take photo". Volume buttons also shoot. |
| **AssetHeader** | Which asset this is | Asset-type symbol + name + address + "Change" | matched, low-confidence ("Is this right?"), unknown ("New asset") | "Change" is a button, not text |
| **DamageTypeChip** | Damage type (AI-suggested, user-editable) | Text label only, no type icon (team decision 2026-09-27); Surface2 fill | unselected, selected (Sky fill + 2 pt Midnight outline, no icon), AI-suggested ("Suggested" text line, no icon) | Selected state announced |
| **ResultSheet** | Verification result | Photo thumbnail, SeverityBadge, damage type, PointsPill (animated count-up), first-finder or confirmation tag, StatusBanner, primary "Done" + secondary "Report another" | pending (skeleton + "Checking…"), accepted, review, rejected (reason + retake tip) | Result announced on arrival |
| **ReportCard** | Report in lists | Thumbnail 64 pt, type, asset, SeverityBadge compact, PointsPill, relative date | pending, accepted, review, rejected | One combined element + "Opens report" hint |
| **MapPin** | Damage on map | Severity-colored circle with numeral, white 2 pt ring. Clusters show a count. | default, selected (scaled 1.2 + callout) | Every pin is also in the list view (§7.3) |
| **HeatHex** | Bounty value cell | H3 polygon, gold opacity by band, `MultiplierChip` at ≥ 2× | normal, surge (animated dashed outline; static with Reduce Motion; the app ships static for now, see MapScreen), danger (red hatch, no multiplier) | Summarized in list view |
| **MapModeToggle** | Switch map layers | `FLChip` row: All · Bounties · Damage | — | Chips carry `.isSelected` |
| **XPBar** | Level progress | `ProgressView(value:)` tinted `flBrand` + "Lv 4 · 320/500 XP" | — | Native progress semantics |
| **QuestCard** | Quest / bounty | Title, area name, progress (n/m), reward PointsPill, MultiplierChip, deadline | available, active, complete (reward animation), expired | Deadline read as a relative date |
| **LeaderboardRow** | Rank | Rank (`flNumber`), avatar initials, handle, points. Self row highlighted `flSurface2`. | — | "Rank 3, dylan, 4,210 points" |
| **CandidateCard** | Gallery-scan candidate | Photo, "Possible crack · Oak Ave garage", date, Approve / Skip buttons | — | **Buttons are required.** Swipe is an optional shortcut, never the only way. |
| **SafetyBanner** | Danger zone | StatusBanner `.dangerZone` pinned top of map/camera | — | Posted as announcement on enter |
| **EmptyState** (`FLEmptyState`) | Nothing yet | Symbol, one line, one action; Poppins title + body (never a bare `ContentUnavailableView`, which draws SF Pro) | — | — |

## 7. Screen patterns

### 7.1 Capture flow (the core loop; must be fast)
1. The Map FAB opens a full-screen camera (the system camera via `AVCaptureSession`, not the image picker, so we get heading, GPS and attestation).
2. A top overlay shows `AssetHeader` (live-matched as the user aims), a `MultiplierChip` if in a bounty zone, and `SafetyBanner` if applicable.
3. Shutter, then a review screen: photo, pre-filled DamageTypeChips (on-device suggestion), optional note field, primary "Submit report".
4. Upload, then `ResultSheet` shows pending → accepted/rejected. The points count-up uses `FLMotion.reward` + `.success` haptic.
5. **Offline:** queue the report and show "Saved. Sends when you're back online" with pending points. Never lose a capture.

### 7.2 Result honesty
- "Preliminary" label on anything on-device; "Verified" only after the server result.
- Rejected results always give a reason and a way to recover ("Too blurry: hold steady and retake").

### 7.3 Map
- Default mode: **All** at low-opacity heat. Pins cluster when zoomed out.
- Layout (map mock, 2026-09-27): a white header fading into a muted basemap, holding a centered "Near you" title with "List" on the right, then `FLChip`s **All · Bounties · Damage**. Bounties show as white callout bubbles with a tail (multiplier big, gold underline, name only on the Bounties layer). Round Midnight buttons: "Scan my photos" bottom-left, Capture FAB bottom-center with a Sky ring. Both sit `FLSpace.xxxl` above the tab bar so the Apple Maps logo and Legal link stay visible.
- **Accessible alternative required:** a "List" toggle shows nearby bounties and damage as a sorted list (distance, multiplier, severity). VoiceOver users and anyone in bright sun can use the app without reading the map.
- Danger polygons: red hatch, no multipliers, Capture FAB disabled with explanation.

### 7.4 Gallery scan
- Explain the scan before asking for permission: what it does, that it runs on-device, and that nothing uploads without approval. Then request limited-library access (PhotoKit).
- Progress: "Scanned 212 of 1,480 photos" with a determinate `ProgressView`, pausable, runs while charging.
- Results: a stack of `CandidateCard`s, then an "Upload 4 approved" primary button.

### 7.5 Rewards
- Balance: settled total in `flDisplay`, pending shown separately beneath ("+340 pending").
- Catalog: grid of cards (brand-neutral placeholders; don't use real merchant logos without rights).
- Redemption confirmation sheet states the cost and what happens next.

### 7.6 Buyer web dashboard (web, same system)
> **Not migrated yet (2026-09-27):** the iOS app moved to "Cloud" (§2). The dashboard and the block below still use the previous "Field-grade" palette. When the dashboard is migrated, copy the §3.1 hex values here and load Poppins from Google Fonts.

Mirror the tokens as CSS variables so the web dashboard reads as the same product:

```css
:root {
  --fl-canvas:#F4F3EF; --fl-surface:#FFFFFF; --fl-surface2:#ECEAE4;
  --fl-ink:#101318; --fl-ink2:#4A5361; --fl-ink3:#6B7483; --fl-stroke:#8A93A1;
  --fl-brand:#2350E6; --fl-on-brand:#FFFFFF; --fl-gold:#FFC233; --fl-gold-text:#8A5A00;
  --fl-success:#1B7F4B; --fl-warning:#A15C00; --fl-danger:#C8202F;
  --fl-sev1:#5B6878; --fl-sev2:#1F72C4; --fl-sev3:#9E6300; --fl-sev4:#C9480A; --fl-sev5:#C8202F; --fl-on-sev:#FFFFFF;
  --fl-r-md:12px; --fl-r-lg:20px;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", system-ui, sans-serif;
}
@media (prefers-color-scheme: dark) { :root {
  --fl-canvas:#0B0D10; --fl-surface:#171A1F; --fl-surface2:#22262D;
  --fl-ink:#F2F4F7; --fl-ink2:#A7B0BD; --fl-ink3:#838C99; --fl-stroke:#5D6673;
  --fl-brand:#6E8EFF; --fl-on-brand:#0B0D10; --fl-gold:#FFC940; --fl-gold-text:#FFD166;
  --fl-success:#4CC38A; --fl-warning:#F5B040; --fl-danger:#FF6B6B;
  --fl-sev1:#9AA6B6; --fl-sev2:#5AA9F0; --fl-sev3:#F0A62A; --fl-sev4:#FF8540; --fl-sev5:#FF5A64; --fl-on-sev:#0B0D10;
}}
```
- Dashboard is data-dense and calm: **no** game motion or gold celebration. Gold is only for bounty budgets.
- Layout: ranked queue (left) · map (center) · selected report (right). One primary action on screen, **Mark fixed**, in the detail panel; list rows are selectable, not buttons-per-row.
- Severity numerals sit on `--fl-on-sev` (white light / near-black dark). White on the dark ramp fails (2.1–3.0:1). Map pins carry the numeral and re-read tokens when the theme flips; the basemap follows the theme (OpenFreeMap `positron` / `dark`).
- Every map has a list alternative (the queue). The queue sorts by priority, severity or newest via a `Sort` control and shows *why* a report ranks where it does.
- States: skeleton while loading, filter-aware empty state, error banner with retry that keeps the last list, toast on success, busy label on in-flight buttons. Polling never repaints unchanged data or steals focus.

## 8. On-device AI (Apple Foundation Models)

**What it is:** Apple's on-device LLM (`import FoundationModels`, iOS 26, Apple Intelligence devices only). It runs text in, text or structured output out, with a 4,096-token window. *Verify against the current SDK before relying on image input; as of this writing, treat it as text-only.* **Image screening is Vision / Core ML, not Foundation Models.**

**Where we use it:**

| Use | Input → output | Why on-device |
|---|---|---|
| **Note → structured fields** | Free-text or dictated note → `@Generable ReportNoteDraft { damageTypeHint, locationOnAsset ("north wall, 2nd floor"), mentionsImmediateDanger: Bool, cleanedNote }` | Instant, works offline, and `cleanedNote` strips names/phone numbers before upload |
| **Gallery candidate titles** | Vision classifier labels + matched asset name → short card title ("Possible crack · Oak Ave garage") | Photos never leave the phone during the scan |
| **Offline draft** | Same as the first row when there's no network, so the queued report is already structured | Never block a capture on connectivity |

**Rules:**
1. **FM never decides points, severity or acceptance.** The server model is the authority. FM output is a *suggestion* (DamageTypeChip "Suggested" state) and always editable.
2. **Availability-gated, never required.** Switch on `SystemLanguageModel.default.availability`. If unavailable (ineligible device, Apple Intelligence off, model not ready), fall back **silently** to manual chips. Never show a "enable Apple Intelligence" wall in the core flow.
3. Use `@Generable` + `@Guide` for structured output, not string parsing.
4. One `LanguageModelSession` per request (single-turn). Check `isResponding`. Keep instructions + prompt + output well under 4,096 tokens.
5. Stream with `streamResponse(generating:)` when filling visible fields, so chips and fields fill progressively (`PartiallyGenerated`). Use `FLMotion.standard` crossfade.
6. Mark every FM-produced field with a "Suggested" label (the dictated note keeps its small `sparkles`; damage chips say "Suggested" as plain text, no icon). The user always knows what the machine wrote.
7. `mentionsImmediateDanger == true` → show the 911/311 prompt card immediately (severity 5 path), regardless of what the server later says.

```swift
@Generable(description: "Structured fields extracted from a user's damage report note")
struct ReportNoteDraft {
    @Guide(description: "One of: crack, spalling, corrosion, pothole, water, pole, sign_or_light, debris, fire, collapse, other")
    var damageTypeHint: String
    @Guide(description: "Where on the asset, short, e.g. 'north wall, second floor'. Empty if not stated.")
    var locationOnAsset: String
    @Guide(description: "True only if the note describes immediate danger to people")
    var mentionsImmediateDanger: Bool
    @Guide(description: "The note rewritten plainly with any names, phone numbers, emails or plates removed")
    var cleanedNote: String
}
```

## 9. Game layer UI rules

- **Pending vs settled** is always visible. Don't show a combined total that includes pending points as if spendable.
- **Reward moments:** points count-up + `FLMotion.reward` + `.success` haptic, max once per event. No confetti loops or sound by default.
- **Streaks:** show them, but a missed day never shows guilt copy and streak freezes are automatic. No "you'll lose everything" framing.
- **Leaderboards:** neighborhood-scoped, weekly reset, and the user's own row always visible. Handles only, no real names.
- **Quests in danger zones** are hidden, not just disabled.
- **No randomized rewards** (loot boxes, spin wheels). Rewards are deterministic and explained ("Base 40 × 2× zone + 20 first-finder").

## 10. Voice & copy

- Plain, short, friendly-competent: "Nice find. Spalling on Oak Ave." not "Congratulations!!! 🎉".
- Verbs on buttons ("Submit report", "Retake", "Redeem"). No "OK" / "Yes" / "No".
- Errors say cause + fix: "No GPS signal. Step outside or wait a few seconds."
- Say "points", never "tokens" or "coins" (legal: they're loyalty points, see CLAUDE.md §6.6).
- No emoji in UI copy.

## 11. Accessibility standard (WCAG 2.1 AA + Apple HIG)

### 11.1 Contrast audit (from `contrast_check.py`, all passing)

| Pair | Light | Dark | Min |
|---|---|---|---|
| ink / canvas | 16.23 | 17.07 | 4.5 |
| ink2 / canvas · surface · surface2 | 5.63 · 5.58 · 5.21 | 9.31 · 8.18 · 7.03 | 4.5 |
| ink3 / surface | 3.72 | 5.96 | 3.0 |
| stroke / surface | 3.72 | 4.32 | 3.0 |
| onBrand / brand (primary button) | 16.09 | 10.81 | 4.5 |
| onAccent / accent (secondary, selected chip) | 10.81 | 8.53 | 4.5 |
| accentText / surface · canvas (links) | 6.08 · 6.13 | 10.81 · 12.31 | 4.5 |
| onGold / gold | 12.97 | 12.97 | 4.5 |
| goldText / surface | 6.07 | 12.97 | 4.5 |
| success / warning / danger text | 4.98 / 5.15 / 5.62 | 7.32 / 8.63 / 5.85 | 4.5 |
| severity 1–5 vs surface | 4.72–5.63 | 5.33–7.88 | 3.0 |
| numeral on severity 1–5 | 4.76–5.68 | 6.07–8.96 | 4.5 |

Run `python3 design-system/contrast_check.py` for exact numbers. Raw Slate (#6887A4) is 3.7:1 on the white canvas, which is why `flInk2` uses a darker slate. **Sky (#ADD9F3) is never a text color on light surfaces** (1.5:1). Use `flAccentText`.

### 11.2 Requirements every screen must meet

| Area | Requirement |
|---|---|
| **Perceivable** | No info by color alone (severity = color + icon + numeral; status = icon + text). Photos get labels ("Photo of spalling on north wall"). Map has the list alternative. |
| **Dynamic Type** | Tested at default and **AX5**. Layout switches HStack → VStack via `ViewThatFits` or `dynamicTypeSize`. No clipped text. |
| **Touch** | ≥ 44×44 pt targets, ≥ 8 pt between targets. Primary actions in the bottom half. Nothing important under the Dynamic Island or home indicator. |
| **VoiceOver** | Logical order (title → content → primary action). Cards combine children into one element with a hint. Status changes use `AccessibilityNotification.Announcement`. The camera announces the matched asset and the zone multiplier. |
| **Motion** | Reduce Motion → no bounce/scale/parallax, crossfades only. Surge outline static. |
| **Gestures** | Every swipe or long-press has a visible button equivalent. Never block the system back swipe. |
| **Contrast settings** | Support *Increase Contrast* (`colorSchemeContrast == .increased` → card shadows become `flStroke` borders; `flCard()` does this). Both themes tested separately. |
| **Time** | No time limits in capture or redeem flows. Quest deadlines are informational. |
| **Forms** | Visible labels (not placeholder-only), errors under the field, correct keyboard types, `textContentType` for autofill. |

### 11.3 Screen reader copy for key elements

| Element | Announced as |
|---|---|
| Capture FAB | "Report damage, button" |
| Shutter | "Take photo, button" |
| AssetHeader | "Asset: 123 Oak Ave, north facade. Change, button" |
| MultiplierChip | "2 times points zone" |
| SeverityBadge | "Severity 4 of 5, Urgent" |
| PointsPill (pending) | "120 points, pending review" |
| HeatHex (list alt) | "Downtown B7, 3 times points, 0.2 miles" |
| ResultSheet (accepted) | Announcement: "Verified. Spalling, severity 3. 120 points pending." |

## 12. Pre-merge UI checklist

- [ ] Only tokens from `DesignSystem.swift` (grep the diff for `Color(red`, `#`, `.system(size:`, and literal padding numbers)
- [ ] `python3 design-system/contrast_check.py` exits 0 (if colors changed)
- [ ] Light + dark previews; AX3/AX5 preview with no clipped or overlapping text; Reduce Motion checked
- [ ] White screen and sheet backgrounds (no grey); at most one `flHeroCard()`; primary button is the Midnight capsule at the bottom
- [ ] Report surfaces show severity as an `FLInfoRow` ("Emergency level" left, badge right); no "On-device" labels
- [ ] Every interactive element: ≥ 44 pt, accessibility label, visible pressed state
- [ ] One primary button per screen
- [ ] Gold used only for value; severity always with icon + numeral
- [ ] Pending vs settled points distinguishable
- [ ] FM features work (fall back) with Apple Intelligence off
- [ ] Empty, loading, error and offline states designed, not blank

## 13. Figma → code

The Figma board (https://www.figma.com/design/G9oJpTiHtOBVLfTEAyUm6E) still shows the previous "Field-grade" tokens and needs re-skinning to "Cloud". Until that happens, this file wins over the board. When implementing a Figma frame through the Figma MCP (`get_design_context`, `get_screenshot`):

1. **The output is a reference, not code to paste.** The MCP emits React + Tailwind. Translate it to SwiftUI with these tokens and never carry its hex, px or class names over.
2. **Map values to tokens, snapping to the nearest one:**

| Figma | SwiftUI |
|---|---|
| Fill #18212D / #6887A4 / #ADD9F3 / #FFFFFF / #FEFEFE / #FFE66D | `.flInk`/`.flBrand` · `.flInk3`/`.flStroke` · `.flAccent` · `.flCanvas` · `.flSurface` · `.flGold` |
| Secondary grey text | `.flInk2` (never raw Slate) |
| Poppins 34/26/19/16/16/14/12 | `.flDisplay` / `.flTitle` / `.flSection` / `.flHeadline` / `.flBody` / `.flCallout` / `.flCaption` |
| Spacing 4·8·12·16·24·32·48 | `FLSpace.xs…xxxl` |
| Radius 10·16·24·32 / full | `FLRadius.sm…xl` / `.capsule` |
| Auto-layout vertical / horizontal | `VStack` / `HStack` (`ViewThatFits` when the row can overflow) |
| Fixed-height text frames | `minHeight` (§3.2 anti-overflow) |
| Emoji / PNG icons | SF Symbols |

3. **Reuse atoms before building.** Button → `.flPrimary`/`.flSecondary`; pill → `FLChip`/`PointsPill`/`MultiplierChip`/`SeverityBadge`; back button → `FLIconButton`; card → `flCard()`/`flHeroCard()`; header row → `FLSectionHeader`. A new atom goes into `DesignSystem.swift` only when a second screen needs it.
4. **Assets:** icons are SF Symbols only. Photos come from reports at runtime and never ship in the bundle. Illustrations exported from Figma (if any) go into an asset catalog as PDF/SVG with `preserves-vector-representation`, never as `localhost` URLs.
5. **Validate against the screenshot** in the simulator (light, dark, AX3) before calling a screen done.
