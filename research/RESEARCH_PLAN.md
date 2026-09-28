# Mend User Research Plan

Feeds judging **Criterion 1 (Problem & Customer Insight)** and the *[hypothesis]* tags in `design-system/MASTER.md`.
Log raw evidence in `/CLAUDE.md` §12 and synthesize below. **Never invent participants, quotes or numbers.** An empty synthesis is better than a fabricated one.

## 1. Objectives

| # | Question | Decides | Method |
|---|---|---|---|
| O1 | How do buyers find infrastructure damage today, what does it cost, and what's broken about it? | Problem framing, pricing, pitch stats | Buyer interviews + desk research |
| O2 | Would buyers pay for crowd-sourced condition data, and in what form (feed, API, per-report, bounty)? | Business model, first-100 plan | Buyer interviews |
| O3 | What reward per report makes people bother, and what makes it feel worth it (money vs status vs civic)? | Point economics, game layer | Reporter survey + interviews |
| O4 | Would people allow an on-device gallery scan? What would make them trust it? | Gallery-scan permission UX | Reporter survey |
| O5 | Can a first-time user report damage in < 30 s outdoors, one-handed? | Capture flow, principle #1 | Usability test on prototype |

## 2. Participants & recruiting (weekend-scale)

| Segment | Target n | Where to find them |
|---|---|---|
| **Buyers:** public works / 311 / city ops | 2+ | City innovation office, campus facilities department, LinkedIn "public works" + city name |
| **Buyers:** property managers / HOA boards | 2+ | Local PM firms (cold call), campus housing, apartment leasing offices |
| **Buyers:** contractors (concrete, paving, roofing) | 1+ | Google Maps listings, cold call |
| **Buyers:** utility / insurer field ops (stretch) | 1 | Hackathon mentors/judges' networks, LinkedIn |
| **Reporters:** students / passers-by | 20+ survey, 5 interviews | On-site at the hackathon, campus quad |
| **Usability testers** | 5 | Other hackathon attendees (not teammates) |

5 interviews per segment surface most major themes. 20+ survey responses give directional numbers only, so say that in the pitch.

## 3. Interview guide: Buyers (≈ 20 min)

**Warm-up (2 min).** Explain: we're students researching how organizations find and prioritize repairs. No pitch. Ask for permission to take notes and quote anonymously.

**Context (6 min)**
1. Walk me through the last time you found out about damage to something you're responsible for. How did you hear about it?
2. Who inspects your assets today, how often, and what does one inspection roughly cost (people, trucks, contractors)?
3. What tools do you use to track issues? (311 system, spreadsheet, work-order software, email)

**Deep dive (8 min)**

4. What was the most expensive problem you found *too late*? What would finding it earlier have been worth?
5. How do you decide what gets fixed first?
6. After a storm or other event, how do you figure out what's damaged? How long does it take?
7. Have you used citizen reports (311, SeeClickFix)? What's good and bad about them? *(probe: noise, duplicates, missing location, no severity)*

**Reaction (3 min).** Show one screen: a map with severity-ranked reports + photo + location.

8. If this showed up for your territory tomorrow, what would you do with it? What would you need to trust it?
9. How would something like this get paid for at your organization? Who signs off? *(probe: budget line, rough range, pilot appetite)*

**Wrap-up (1 min).** Anything we should have asked? Can we follow up / list you as a pilot contact? *(LOI = gold for judges)*

## 4. Interview guide: Reporters (≈ 8 min, guerrilla)

1. When did you last notice something broken in public: a pothole, cracked sidewalk, broken light? What did you do?
2. Have you ever reported it anywhere? Why or why not?
3. *(Show capture screen)* If an app paid you to snap these, what would make it worth your time? Would $0.25 / $1 / $5 per verified report change your behavior?
4. Would gift cards, leaderboard rank or "you got it fixed" notifications motivate you most?
5. Would you let the app scan your camera roll *on your phone* to find damage in old photos? What would make you say yes or no?
6. Anything that would make you uncomfortable (privacy, safety, looking weird photographing buildings)?

## 5. Reporter survey (Google Form, ≤ 2 min)

1. How often do you notice damaged public infrastructure? (daily / weekly / monthly / rarely)
2. Have you ever reported it? (yes via 311/app / yes other / never)
3. Minimum reward per verified report that would make you report regularly: ($0 civic duty / $0.25 / $0.50 / $1 / $2+)
4. Most motivating: (gift cards / leaderboard & badges / seeing it fixed / helping my city)
5. Would you allow an on-device scan of your photo library? (yes / only specific albums / no). Why? (optional text)
6. Would you walk to a nearby "2× points" zone to earn more? (yes / maybe / no)
7. Age range, iPhone or Android (screener for iOS-first)

## 6. Usability test (prototype, 5 people, ≈ 10 min each)

**Setup:** outdoors if possible, phone in one hand, think-aloud. Don't help.

| Task | Success = | Measure |
|---|---|---|
| T1: "You see a crack in that wall. Report it." | Result sheet shown | Time (target < 30 s), taps, errors |
| T2: "Find where you'd earn the most points nearby." | Identifies the highest-multiplier zone | Correct Y/N, time |
| T3: "How many points can you spend right now?" | States the *settled*, not pending, amount | Correct Y/N (tests pending/settled clarity) |
| T4: "Find damage in your old photos." | Reaches the candidate list | Completion, hesitation at the permission step |

After: "What was confusing?" and "Would you use this again? Why?" (1–5).

## 7. Desk research to cite (sources required)

- [ ] Cost of manual infrastructure inspection per site / per mile (DOT, utility sources)
- [ ] ASCE Infrastructure Report Card grade + investment gap
- [ ] 311 volume for potholes / sidewalks in one large city (open data portals)
- [ ] Insured catastrophe losses, last year (Swiss Re / Aon)
- [ ] Utility pole inspection cycle and cost (utility filings / PUC documents)

## 8. Synthesis (fill as data arrives, research-synthesis format)

### Research Synthesis: Mend discovery
**Method:** Interviews / survey / usability | **Participants:** _pending_
**Date:** _pending_ | **Researchers:** _team_

**Executive summary:** _Pending. Write 3–4 sentences once ≥ 3 buyer interviews are done._

#### Themes
Add one block per theme once ≥ 2 participants support it. Use counts ("4 of 6"), not "most". Keep observations ("3 of 5 tapped Pending when asked for spendable points") separate from interpretations ("pending/settled isn't distinct enough").

```
#### Theme: <name>
Prevalence: X of Y
Summary:
Evidence: "<quote>" (P#, role)
Implication:
```

#### Insights → opportunities

| Insight | Opportunity | Impact | Effort |
|---|---|---|---|
| | | | |

#### Segments identified

| Segment | Characteristics | Needs | Size |
|---|---|---|---|
| | | | |

#### Design decisions affected
When a finding confirms or kills a *[hypothesis]* in `design-system/MASTER.md`, edit that line and note it here.

| Decision | Status (confirmed / changed / killed) | Evidence |
|---|---|---|
| Capture ≤ 2 taps, one-handed, outdoors | hypothesis | |
| Pending vs settled points shown separately | hypothesis | |
| Gallery scan acceptable if on-device + approve-each | hypothesis | |
| Gold = value is intuitive | hypothesis | |

#### Open questions
- _pending_

#### Methodology notes / limits
Convenience sample (hackathon attendees, local businesses). Small n, directional only. Say this in the pitch.

## 9. Proto-personas *[hypotheses, not findings]*

| Persona | Who | Wants | Fears |
|---|---|---|---|
| **Maya, the Walker** | Student, walks campus/downtown daily | Easy side cash, feeling useful | Looking weird photographing buildings; privacy |
| **Dev, the Hunter** | Plays location games, competitive | Rank, rare finds, quests | Grind with no payoff; cheaters |
| **Rosa, Public Works Supervisor** | City ops, owns 311 backlog | Fewer truck rolls, prioritized list, fewer duplicates | Junk reports, liability of *knowing* about hazards |
| **Tom, Property Manager** | 12 buildings, small team | Catch facade/parking damage before tenants or insurers do | Another subscription nobody uses |
