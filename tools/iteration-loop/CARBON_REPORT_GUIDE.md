# Carbon Engineering Report Guide

**Maintainer:** `@prose-reviewer` (`gemini-4-carbon-high`)  
**Consumers:** `@reporter` (during drafting and local staging) and `@prose-reviewer` (during mandatory pre-publish review)

This guide defines the editorial, information-architecture, and visual bar for the public Mothman StarCraft II report (`index.html`, `history.html`, `loop-flywheel-retro.html`, `video-gallery.html`, and shared chart scripts). It is a living document: whenever a review pass catches a new class of flaw or discovers a clearer way to show an engineering concept, `@prose-reviewer` appends that lesson to Section 7.

---

## 1. The Carbon Report Review Phase

Every public site update goes through four steps before reaching `gh-pages`:

1. **Draft against this guide (`@reporter`):** Build local HTML into a staging directory (`/tmp/site_preview_r<N>`) without `--push`. Keep `tools/observatory_charts.js` and `mothman-dashboard` synchronized.
2. **Audit prose, structure, data parity, and live pixels (`@prose-reviewer`):** Inspect both the generated DOM and headless Playwright Chromium renders at `1440px` desktop and `390px` mobile. Assume a technically literate StarCraft II reader who has never seen our codebase, commit log, or swarm board.
3. **Iterate on exact `file:line` fixes (`RED -> GREEN`):** If any P0 (factual/numerical contradiction, leaked unshipped data, broken asset) or P1 (bad heading, visual collision, cold-reader jargon, layout bloat) issue appears, post numbered `file:line` fixes to `@reporter` and re-verify the restaged output.
4. **Update this guide & publish:** When a review uncovers a generalizable lesson, `@prose-reviewer` records it in Section 7. `@reporter` pushes to `gh-pages` and verifies live HTTP `200` only after `@prose-reviewer` posts explicit `GREEN`.

---

## 2. Information Architecture & Reader-First Headings

A heading must name **what the reader learns about the bot**, never **what we named our internal script** or **how many charts we drew**.

### Core Heading Rules
- **Ban internal spec, tool, and ticket names from headings.** Words like `"Observatory"`, `"Tactics Arena"`, `"North Star"`, `"Chart 8"`, `"Graph 9a..22"`, and `"v1/v2 Cohort"` belong in internal specs, not public headings.
- **Never put chart, table, or catalog counts in headings.** `"(22 Graphs)"` or `"All Scenarios 278"` highlights report volume rather than bot performance.
- **Keep hierarchy flat and unnumbered.** Do not stack `SECTION 2` + `<h2>` + `2.4` + `FIGURE 1` + `Graph 15`. Use plain `<h2>` section titles and unnumbered `<h3>`/`<h4>` subheadings.
- **State the active build tag once per context.** Show `Release #19 (Build 67B)` in the masthead eyebrow and once in the benchmark intro sentence. Do not repeat `(Release #19, Build 67B)` on every sub-table and figure title down the page.
- **Separate current state from history.** `index.html` answers *"How does the live bot play right now?"* `history.html` answers *"How did it improve over time, and what bugs did we fix?"* Never leave pre-redesign `Pre-Fix` baseline charts on `index.html` where readers will mistake them for current behavior.

### Concrete `Bad -> Good` Heading Examples

| Bad (Internal / Meta / Stacked) | Good (Reader-First) | Why It Improves Clarity |
| :--- | :--- | :--- |
| `2.4 Pro Comparison Observatory (22 Graphs)` | `Economy, Army, Upgrades & Spells vs. Grandmaster Pros` | Drops internal `"Observatory"` branding and self-congratulatory chart count; states the actual comparison. |
| `Tactics Arena Scenarios` | `Isolated Micro & Spell Drills` | Replaces internal runner script name (`sc2-tactics-arena.py`) with what the clips actually test. |
| `v2 Cohort (Division 6–7)` / `v1 Cohort (Division 9)` | `Current Season Bots (Division 8)` / `Long-Running Bots (Division 9)` | Explains why one set of accounts has ~60 matches and the other ~440 without forcing readers into a footnote. |
| `Graph 9b · Army Retention (Alive / Cum)` | `Army Survival Rate (Alive / Total Built)` | Removes out-of-order spec ticket ID (`Graph 9b`) and cryptic abbreviation (`Cum`). |
| `North Star: Minerals Collected Ratio × Trade Ratio` | `Match Outcomes by Mining & Trade Efficiency` | Names what the scatter plot shows instead of internal KPI jargon. |
| `Base #4–#6 & Gas #7–#10 Timing Dumbbell & Adoption Funnel` | `Late-Game Base (#4–#6) & Gas (#7–#10) Timings` | Strips data-viz jargon (`Dumbbell & Adoption Funnel`). |
| `2.6 Current Open Weaknesses` | `Where the Bot Still Loses` | Direct, active, concrete English. |

---

## 3. Signal vs. Noise: What Numbers Earn Hero Weight

Highlighting twenty numbers on one screen highlights none of them. Every metric on the page belongs to one of three tiers:

### Tier 1: Primary Headline Metrics (Hero Cards & Top Tables)
- **Live AI Arena Ladder:** Division, Elo rating (always anchored with *"AI Arena ratings start at 1600."*), win-loss-tie record, opponent average Elo, and career crash count (`0`).
- **Benchmark Outcomes:** Win rate (`Win %` and `Win + Tie %`) split honestly across `All External`, `14 Core Bots` (tuned practice pool), and `12 Held-Out Bots` (unseen generalization check).
- **Two Core Gameplay Ratios:** **Trade Ratio** (`Destroyed / Lost`) and **Minerals Collected Ratio** (`Us / Opponent`). Convey their primary status through card styling (warm accent border), not by printing `"PRIMARY ·"` and `"SECONDARY ·"` text labels on every card.

### Tier 2: Supporting Diagnostic Signals (Subordinate Cards, Captions & Charts)
- Gas Collected Ratio, Combat Upgrade Levels (`+1/+2/+3`), Unit Tier Share (`T1 / T2 / T3`), Supply-Blocked %, Active Worker / Income / Army Curves, Expansion & Tech Timings, and Spell / Energy Splits.
- Release-to-release highlights belong in a **3-bullet callout box** (`What Changed in Release #N`: max 3 bullets, 1 to 2 sentences and 2 to 3 numbers per bullet), never in multi-paragraph prose dumps reciting 25+ numbers ahead of the charts.

### Tier 3: Metadata & Clutter to Demote or Cut
- **Demote to quiet footnotes or hover tooltips:** Sample denominators (`n=78`, `n=402`, battle counts per race), tie-adjudication state scores (`/100`), and per-matchup edge cases.
- **Cut from visible prose altogether:** Chart counts (`22 Pro-comparison graphs`), drill catalog accounting (`32 recorded · 32 in catalog (15 core)`, `ab-p01` raw IDs), internal telemetry log volumes (`137,107 decisions logged`), vanity unit-test or assertion counts (`2,473/2,473 PASS`), raw commit hashes (`wqqmqyvl`), and inline 11-digit CI run IDs (`deploy run 45379956983` -> link the release name directly instead).

---

## 4. Show, Don't Tell: Diagrams, Real SC2 Captures & Progressive Disclosure

Tables of ratios cannot teach a reader what a spatial or architectural mechanism looks like. Whenever a section introduces **geometry, movement on a map, base layout, or multi-stage control flow**, show it visually first and tuck raw breakdown tables behind `<details>`.

### Rules for Visual Explanations
1. **Pair schematic SVG diagrams with real in-game 3D captures.**
   - *Schematic inline SVG* isolates the causal rule cleanly (for example: why a concave arc puts all 10 units in range while a clumped ball blocks rear ranks and eats splash damage; or how base-to-base rotation, synchronized drops, and staging points differ from solo trickle).
   - *Real 3D StarCraft II capture* proves the bot executes that geometry in the real engine, not just on a whiteboard. Add non-destructive corner callout pills over the image container (`Wide firing arc`, `Phased Warp Prism + Immortal screen`, `Flank A / Flank B`) while keeping the underlying lightbox image clean.
2. **Verify extracted video frames visually before publishing.**
   - Frame `0.0s` of a drill MP4 often shows idle starting units before creep spreads, Warp Prisms phase, or flanks collide. Extract mid-action timestamps (`ffmpeg -ss <sec>`) and inspect the actual JPG/PNG via `read_file`.
3. **Keep architecture diagrams synchronized with the live codebase.**
   - When major architectural layers ship (such as the shared Resource & Unit Arbiter or Multi-Prong Coordinator), update Section 4's frame-loop SVG so prose and diagram never diverge.
4. **Use progressive disclosure (`<details>`) for wide reference tables.**
   - Multi-column per-race geometry and harassment tables (`8 to 9` columns) are valuable for deep readers, yet stall scanning when placed above charts. Lead with the visual card + 1-sentence takeaway, then place `<details><summary>View per-race battle geometry table (Pro vs. Mothman)</summary>...</details>` directly underneath.

---

## 5. Scannability, Page Height & Visual QA

A report that stretches to `23,500px` (`~26` desktop screens) buries bottom sections where readers never reach them.

- **Cap repetitive media grids at 6 cards initially.** In `Isolated Micro & Spell Drills`, show 6 representative clips (`3 rows × 2 cols`) with a `"Show all N drills in <Category>"` expand button. Never dump 32 video players onto the initial page load.
- **Run Playwright visual and geometry checks at `1440px` (desktop) and `390px` (mobile) on every review:**
  - `documentElement.scrollWidth - clientWidth == 0` across every tab and page.
  - Zero JS `pageerror`s, zero broken local links/posters, and zero unpublished GitHub Release media URLs (`404`s).
  - **Inspect actual PNG screenshots, not just DOM text.** Bounding-box scripts catch `<text>`-on-`<text>` collisions, whereas human visual inspection catches dots plotted over quadrant labels, polylines slicing through bar labels, long upgrade names crossing the `0m` vertical gridline, or unaligned X-axes across side-by-side comparison panels.
- **Chart integrity rules (`observatory_charts.js`):**
  - Side-by-side small-multiple comparison charts (`Mothman` vs. `Pro GM`) must share an identical fixed X-axis domain (`2m–18m`) so timestamps align horizontally.
  - Distinguish **zero casts when casters were built** (`0.00×` cast-logic blind spot, styled crimson at top) from **caster unit never built in sample** (`0 casters`, styled muted dashed at bottom under an explicit divider).
  - Add a theme-matched `paint-order: stroke` halo on labels placed over scatter points or dual-axis lines.
  - Hide markdown heading anchor pilcrows (`#`) until `:hover`/`:focus` (`opacity: 0` by default via CSS `::after` so `innerText` stays clean).

---

## 6. Prose Craft & Data Parity Standards

Every sentence on the public site must pass five checks:

1. **Plain, checkable engineering English:** Explain every domain or internal term on first use (`Core-14`, `Unseen-12`, `Supply-blocked`, `escrow`, `our original 12-bot baseline set`). Replace internal code jargon (`phasing thrash`, `wire-level command lease`, `canonical expansion guards`, `non-loss`, `TechUpgrades`, `Sec · Gas`, ASCII `>=`) with reader language (`rapid mode-toggle loops`, `unit-order tracking`, `base-site clearance checks`, `win+tie`, `Tech Upgrades`, `Secondary` or border styling, `≥`).
2. **Zero AI-slop vocabulary or self-invented slogans:** Never use `delve`, `leverage`, `seamlessly`, `pivotal`, `testament`, `robust`, `tapestry`, `underscore`, `multifaceted`, or pompous internal coinages (`4-Law`, `Doctrine`, `Mirror Mind`, `Phase A/B/C/D` without plain description).
3. **Zero prose punctuation crutches:** Zero prose em dashes (`—`; allowed only as empty-cell `—` markers in tables or `<title>` separators), zero spaced prose en dashes (` – `; use unspaced figure en dashes `31–43–4` for records and ranges), and zero trailing `-ing` participle clauses (`", cutting tail wait..."` -> `"and cut tail wait..."`; always verify subject and verb tense agreement after any rewrite).
4. **100% same-page numerical & directional parity:**
   - Never hardcode release numbers in `"Where the Bot Still Loses"` or prose captions when adjacent charts compute them dynamically from `pro_curves_and_timings.json` or SQLite.
   - Gate directional verbs dynamically in generators (`"topped"` vs. `"tracked right near"` based on `m_val >= p_val`; check sign parity across all races before claiming *"all three races posted positive..."*).
   - Match filter predicates (`opp_gas_collected > 0`) and rounding rules (half-up `int(val + 0.5)` matching JS `Math.round`) across Python and JS so summary text and chart cards never disagree by `1` unit or `0.03×`.
   - Prefer shipped builds first in every loader (`pro_deep.json`, H2H cohorts, Pro curves) so held sub-iterations (`Build 63`, `iter65_h2h`, `67A`) never leak onto `index.html`.
   - Use singular/plural helpers (`1 cloaked-unit loss` vs. `2 cloaked-unit losses`) on all dynamic counts.

---

## 7. Pre-Publish Gate Checklist & Living Lessons Log

### Quick Gate Checklist (Run Before Posting `GREEN`)
- [ ] **Headings & Tabs:** Zero internal tool/ticket names, zero chart/catalog counts in headings, zero stacked `SECTION`/`FIGURE`/`2.x` prefixes, zero visible `#` anchor pilcrows.
- [ ] **KPI Hierarchy & Prose:** Hero weight reserved for Ladder Elo/Div, Win %, Trade Ratio, and Minerals Collected Ratio; Release changes summarized in <= 3 bullets; `"AI Arena ratings start at 1600."` intact; zero prose em dashes, `-ing` tails, or unglossed internal terms.
- [ ] **Data Parity:** Zero unshipped `HOLD` build or wrong-sub-iteration H2H leaks; exact match on Minerals/Gas/Trade/EPM/Timings across Section 2 tables, interactive charts, and weaknesses list; non-blank `Core-14` & `Unseen-12` cells in `history.html`.
- [ ] **Visuals & Scannability:** Spatial concepts shown via inline SVG schematics + verified mid-action 3D SC2 captures; wide tables tucked into `<details>`; drill grid capped at 6 cards initially; Playwright `1440px` + `390px` passes with `0` JS errors, `0` broken assets/release URLs, `0px` horizontal overflow, and `0` SVG label collisions.

### Living Lessons Log

- **2026-11-23 (Releases #14–#18: Initial Pro-Comparison Launch & Parity Fixes):**
  - *Loader parity:* Secondary loaders (`pro_deep.json`, H2H fallback queries, `_mt_slice` SQLite filters) drifted from primary shipped-build loaders when held sub-iterations existed (`Build 63` leaked onto `Build 62C`; held `iter65_h2h` `5–7` leaked onto `Build 65H`; missing `opp_gas_collected > 0` shifted Gas Ratio from `0.81×` to `0.84×` on the same page). Every loader must share the same shipped-build filter, cohort predicate, and half-up rounding.
  - *Dynamic directional prose:* Static verbs like *"held above"* or *"all three races posted positive concave wrap"* break as soon as Pro baselines re-index (`148.2 vs. Pro 151.0`) or one race sits at `-0.03`. Always compute comparative verbs from the live numbers being formatted.
  - *Visual chart legibility:* Automated `<text>`-vs-`<text>` bounding-box checks missed long upgrade names (`Glial Reconstitution (Roach Speed)`) crossing the `0m` vertical `<line>` (`PL=152 -> 224`), side-by-side streamgraphs auto-scaling X-axes to mismatched time ranges (`4m–14m` vs. `2m–18m`), and `0 casters built` tech-tree gaps masquerading as crimson `0.00×` cast-logic blind spots. Always inspect rendered PNGs across race/matchup sub-tabs.
  - *Grammar after regex cleanups:* Mechanical regex rewrites of `-ing` participle tails (`s/, cutting/ and cut/`) create subjectless fragments (`"968.7 min and cut..."`) or tense clashes (`"Prevents ... and lifted"`). Re-read the full rendered sentence after every automated text substitution.
- **2026-11-24 (Release #19: Full Editorial, Structure & Visual Redesign):**
  - *Kill meta-headings and ticket IDs:* Naming a section `"2.4 Pro Comparison Observatory (22 Graphs)"` and cards `"Graph 9a..22"` / `"Chart 8"` leaked internal swarm spec numbering (which appeared out of sequence `9a -> 10 -> 15` once grouped into tabs) and emphasized chart quantity over insight. Plain topic headings (`Economy, Army, Upgrades & Spells vs. Grandmaster Pros`, `Fights Taken & Retreats by Army Odds`) and border-driven KPI hierarchy (`Trade Ratio` & `Minerals Collected` accented without printing `"PRIMARY ·"` / `"SECONDARY ·"`) are cleaner and faster to scan.
  - *Diagrams + real 3D captures beat wide geometry tables:* Cold readers could not picture `Concave +0.24`, `Role Inv. 31.7%`, or `Rot./Game 0.38` from 8- and 9-column tables. Replacing the dry table intros with side-by-side inline SVG schematics (`Clumped Ball` vs. `Concave Arc & Melee Screen`; top-down `Rotation / Multi-Prong / Staging` map) paired with mid-action 3D SC2 stills (`t=3.8s` Stalker arc, `t=4.7s` Phased Warp Prism + Immortal screen, `t=0.9s` 2-prong Tank surround, `t=43s` Creep spread) and tucking the raw tables into `<details>` turned the hardest section of the report into the clearest.
  - *Purge stale `Pre-Fix` visuals from `Current State` and cap video walls:* Leaving a Loop 55 `Pre-Fix` scatter (`Clump=75%`, `PvP (PRO): NULL`) on `index.html` contradicted our live `0.0%` Pylon clumping, and rendering all 32 drill videos expanded by default inflated `index.html` to `23,534px` (~26 screens). Removing stale pre-fix charts from `index.html` and capping initial drill cards at 6 with an expand toggle cut page height by `34.8%` (`-8,195px`) and surfaced full-match replays and the 5-row Arbiter frame-loop diagram without endless scrolling.
- **2026-11-24 (Release #20: Release-Box Density, Opponent Code Pills & Sanitizer Deduplication):**
  - *Keep `What Changed` bullets under 3 to 4 numbers and never wrap bot names in `<code>`:* Packing 10 to 14 numbers into a single bullet (or repeating the hero KPI cards right above it) stretches the callout box to a full screen on `390px` mobile, and wrapping opponent bot handles (`who`, `Mulebot`) in `<code>` pills makes player names look like shell commands.
  - *Deduplicate mapped findings and align table-adjacent prose on generated subpages:* When a sanitizer maps raw diagnostic lines into cold-reader bullets (`loop-flywheel-retro.html`), deduplicate mapped strings (`dict.fromkeys`) so multiple raw hits never emit identical consecutive bullets, and verify that summary sentences beneath tables match exact column semantics (active work vs. idle wall time, when-run mean vs. all-run mean, and 18-match canary stops vs. 84-match roster regressions).
- **2026-11-25 (Release #21: JS-Rendered CamelCase Tokens & Cross-Race Overtake Templates):**
  - *Audit JS-rendered chart headings for SC2 API CamelCase:* Static BeautifulSoup checks on `index.html` miss strings rendered client-side by `observatory_charts.js` (such as `TownHalls` / `TownHall Role`). Always inspect Playwright-rendered text across new chart cards and replace internal CamelCase API names with plain spaced English (`Non-Mining Bases & Planetary Fortresses`, `Base Structure Role`, `town halls`).
  - *Avoid hardcoded race-order contrast templates:* A static sentence assuming *"Terran stays low while Protoss and Zerg sit higher when early pressure kills Pylons or Overlords"* broke as soon as Protoss supply-blocked time dropped to `1.4%–2.7%` below Terran (`1.9%–2.5%`). Format per-race ranges neutrally or sort/branch dynamically on live min/max values.
- **2026-11-25 (Loops 69–78 Campaign Wrap-Up: Champion Isolation, Plain-English Held Arcs & Live Snapshot Fallbacks):**
  - *Keep `index.html` anchored strictly on the active live champion when later loops are held:* When a campaign ends on held or branch-preserved runs (`Loops 74B–76B` micro branch, `Loops 77–78` held experiments), `index.html` (`Current State`) and `pro_curves_and_timings.json` must remain 100% anchored on the live deployed build (`Release #21`, `Build 73`), while multi-loop campaign arcs and ship-gate takeaways route cleanly to `history.html` (`10-Loop Campaign Review`).
  - *Translate protocol IDs and preserve ranked `Opp Elo` across post-deploy snapshots:* Spell out raw SC2 ability IDs (`1343` -> *Zerg larva command drops*, `562` -> *Ghost drops*, `1450` -> *Mining Planetary Fortresses*) and omit raw match/branch slugs in reader prose; when a fresh post-deploy AI Arena check logs only unranked verification games, fall back to the prior ranked `opp_elo_before` summary so `Opp Elo` columns never blank out to `—`.
