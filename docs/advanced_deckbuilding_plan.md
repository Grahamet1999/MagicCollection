# Advanced Deck Building — Implementation Plan

Status: proposal for review · Target app: MTGApp (Flutter, Windows desktop + Android)
Decisions locked in with the user:
- **Knowledge source:** EDHREC (candidate lists) + Claude API (reasoning/explanations)
- **Card pool:** hybrid — produce **two result sets** everywhere it matters: (A) *owned-only*, and (B) *owned-prioritized but not owned-limited* (best cards regardless, owned ones flagged/preferred)
- **Model:** `claude-opus-5` for heavy reasoning (build/synergy), `claude-haiku-4-5` for light calls
- **Integration:** reuse the **food_meter** pattern — the Anthropic call lives in a **Firebase Cloud Function** with the key as a Firebase secret; the app never holds the key. MTGApp is already a Firebase app (project `mtgcollection-1add3`), so this fits existing infra. (See `C:/source/repos/food_meter/functions/recipes.js` as the template.)

---

## 1. The four features, restated

1. **Recommend cards** for a chosen commander.
2. **Analyze a built deck** and advise on what it lacks (lands, ramp, card draw, off-fit cards, curve).
3. **Build a deck from scratch** from the collection for a commander + focus prompts, with per-section reasoning.
4. **Critique a pasted list** — what to cut, what to add.

These split into two capability layers:

- **Deterministic layer (local, no network):** counting/classification — powers #2 and the "cut" half of #4. Fast, free, offline.
- **Knowledge layer (EDHREC + Claude):** synergy candidates + natural-language reasoning — powers #1, #3, and the "add" half of #4.

---

## 2. Architecture at a glance

```
                    ┌─────────────────────────────────────────┐
  Decks tab UI ───▶ │  DeckIntelligenceController (Change-      │
                    │  Notifier, per-selected-deck)            │
                    └───────────────┬──────────────────────────┘
                                    │
        ┌───────────────┬───────────┴───────────┬───────────────────┐
        ▼               ▼                        ▼                   ▼
  DeckAnalyzer     EdhrecService           RecommendationService   LlmService
  (local rules)    (unofficial JSON)       (merges EDHREC +        (Anthropic
                                            owned + legality)       raw HTTP)
        │               │                        │                   │
        └── existing DeckStore / CollectionStore / ScryfallService ──┘
```

New files (mirrors existing `services/` conventions):
- `lib/services/deck_analyzer.dart` — pure functions, unit-testable, no I/O
- `lib/services/edhrec_service.dart` — thin HTTP client, same shape as `scryfall_service.dart`
- `lib/services/llm_service.dart` — Anthropic Messages API over `http`
- `lib/services/recommendation_service.dart` — orchestration + the hybrid A/B pool logic
- `lib/models/deck_advice.dart` — result types (analysis findings, recommendations, build output)
- `lib/screens/deck_intelligence_tab.dart` (or a panel inside `decks_tab.dart`) — UI

---

## 3. Prerequisite: data-model gaps to close first

These block reliable analysis and must land before features #2/#4 work well.

### 3a. `DeckCard` has no `oracleText`
[lib/models/deck_card.dart](../lib/models/deck_card.dart) stores name/type/cmc/colors but **not oracle text** — yet detecting ramp ("Add {C}"), card draw ("draw a card"), removal ("destroy target"), etc. requires reading it. Work:
- Add `oracleText` field to `DeckCard` (+ `copyWith`, `toMap`, `fromMap`, `fromScryfall` — `sf.oracleTextFromScryfall` already exists).
- Schema migration in [lib/services/database_service.dart](../lib/services/database_service.dart): `ALTER TABLE deck_cards ADD COLUMN oracle_text` for both the SQLite and SQL Server backends ([sqlite_backend.dart](../lib/services/sqlite_backend.dart), [sql_server_backend.dart](../lib/services/sql_server_backend.dart)), bump the version constant, add a backfill path.
- Populate on add (already free from Scryfall JSON) + a one-time backfill of existing deck rows via `ScryfallService.getCollection`.

### 3b. Collection metadata is lazily backfilled
`MtgCard` already carries `oracleText`/`cmc`/`typeLine`, but only recently-touched cards are populated. "Build from my collection" (#3) needs the whole collection classified. Work: a one-time backfill sweep (batched `getCollection`, respect Scryfall rate limits) with a progress indicator, reusing the existing image-cache/backfill patterns.

---

## 4. The deterministic layer — `DeckAnalyzer` (Feature #2, first slice)

Pure Dart over the selected deck's cards. No dependency on anything new.

Classify each mainboard card into buckets from `typeLine` + `oracleText`:

| Bucket | Detection heuristic (illustrative) |
|---|---|
| Land | `primaryType == CardType.land` (already exists in [scryfall_parse.dart](../lib/models/scryfall_parse.dart)) |
| Ramp | non-land producing mana: `oracleText` matches `Add \{.\}`, "search your library for a … land", mana-rock artifacts |
| Card draw | "draw a card", "draw X cards", "investigate" |
| Removal / interaction | "destroy target", "exile target", "counter target", "-X/-X" |
| Wipe | "destroy all", "each creature", "all creatures" |
| Creature / other | fallback |

Then compare against format targets (Commander defaults, overridable):
- Lands ≈ 36–38 (scaled by avg CMC / ramp count), Ramp ≈ 10, Draw ≈ 10, Removal ≈ 8–12.
- Reuse existing `DeckStore.manaCurve` and `DeckStore.colorBreakdown` ([lib/services/deck_store.dart](../lib/services/deck_store.dart)) for curve/pip advice.
- Flag off-color-identity cards (compare `card.colorIdentity` vs `commanderColorIdentity`) and obvious off-curve outliers.

Output: `List<DeckFinding>` (severity, category, message, optionally offending cards) rendered as an "Analyze" panel. **Ships value with zero external dependencies, no API key — build this first.**

Effort: ~2–3 days incl. tests.

---

## 5. The knowledge layer

### 5a. `EdhrecService` — synergy candidates
Unofficial EDHREC JSON (commander pages expose a stable `…/commanders/<slug>.json` shape with themes and "top cards" grouped by category). Thin client like `ScryfallService`:
- `getCommanderRecommendations(commanderName, {theme})` → ranked candidate names grouped by role (ramp/draw/removal/creatures/lands/etc.).
- Resolve names → real printings via the existing `ScryfallService.getCollection` (also gives legality/color-identity/price).
- Cache responses (reuse the offline cache patterns from the recent cloud-sync/image-cache work) since EDHREC is rate-sensitive and unofficial.

Risk: unofficial API can change/break → isolate behind the service interface and degrade gracefully (fall back to Scryfall + LLM-only if EDHREC is unavailable).

### 5b. `LlmService` — via Firebase Cloud Function (food_meter pattern)
**The app does not call Anthropic directly.** Mirror food_meter: the Anthropic call runs in a Firebase Cloud Function that holds `ANTHROPIC_API_KEY` as a Firebase secret. `C:/source/repos/food_meter/functions/recipes.js` (Node, `@anthropic-ai/sdk`, `client.messages.create`) is the template — copy it into a `deck_advisor` function deployed to MTGApp's Firebase project (`mtgcollection-1add3`) and set the same secret.

- **Model in the function:** `claude-opus-5` for build/synergy/critique reasoning; `claude-haiku-4-5` for cheap classification-style calls. `thinking: {type: "adaptive"}`, `output_config: {effort: "high"}` on the heavy calls.
- **App side:** `LlmService` calls the function. Two options — (a) expose it as an **HTTPS endpoint** and hit it with the existing `http` client (no new dependency, matches MTGApp's current Realtime-DB-over-REST style), or (b) add the `cloud_functions` package and use `httpsCallable` exactly like food_meter's `RecipeService`. **Recommend (a)** for consistency with the current codebase.
- **No streaming:** callable/HTTP functions are request/response. Match food_meter — a single deck-build call finishing in tens of seconds is acceptable. If a live feel is wanted later, write progressive results to Realtime DB (infra already present).
- **Grounding:** the function receives the candidate list (EDHREC + owned cards) as structured input and instructs the model to use **only** cards from that list; validate every returned card against Scryfall + commander color identity before it enters a deck.

### 5c. `RecommendationService` — orchestration + hybrid pool
This is where the **A/B hybrid** the user asked for lives. Every recommendation/build/critique produces two outputs:

- **Pool A (owned-only):** candidates ∩ collection (via `DeckStore.ownedCount` / `CollectionStore`). "Build me a deck I can assemble tonight."
- **Pool B (owned-prioritized):** full candidate set; owned cards ranked/badged first, unowned included and flagged "need to acquire" (with `priceUsd` from Scryfall).

The UI presents them as a toggle or two columns so the user picks the mindset per request.

---

## 6. Feature-by-feature build

| # | Feature | Uses | Notes | Est. |
|---|---|---|---|---|
| 2 | Deck analysis | `DeckAnalyzer` | Local only. First to ship. | 2–3d |
| 1 | Recommend for commander | `EdhrecService` + `RecommendationService` (A/B) + `ownedCount` badges | Optional Claude pass to explain *why* each card fits. | 3–4d |
| 4 | Cut/add on pasted list | `DeckAnalyzer` (cuts) + `RecommendationService` (adds, A/B) | Reuse [deck_csv_import_service.dart](../lib/services/deck_csv_import_service.dart) + `getCollection` to resolve pasted names. | 3–4d |
| 3 | Build from scratch | Guided flow → EDHREC candidates → Claude assembles 99, grouped w/ per-section reasoning, A/B pools | Streamed. The flagship; depends on everything above. | 1–1.5wk |

Feature #3 flow: pick commander → focus prompts (archetype/budget/power level/themes) → generate → review sectioned list with rationale → one-tap "create deck" via existing `DeckStore.createDeck`/`addCard`.

---

## 7. Config, security, and the API key — solved by the food_meter pattern

The API key stays **server-side in the Cloud Function** (Firebase secret `ANTHROPIC_API_KEY`), exactly as food_meter does it — it never ships in the MTGApp client. This is a strict improvement over an on-device key:
- Deploy the `deck_advisor` function to MTGApp's Firebase project (`mtgcollection-1add3`); set the secret with `firebase functions:secrets:set ANTHROPIC_API_KEY` (or reuse food_meter's if same account).
- Gate AI features on Firebase auth (MTGApp already has `auth_service.dart`), so only signed-in users can invoke the function.
- New pubspec deps: **none** if using the HTTPS-endpoint + `http` route; add `cloud_functions` only if choosing the callable route.

---

## 8. Suggested phasing

1. **Data prep** (§3) — `DeckCard.oracleText` + migration + collection backfill.
2. **Feature #2** (§4) — local analyzer + Analyze panel. Ships immediately, no key.
3. **`EdhrecService`** (§5a) + `RecommendationService` skeleton with the A/B pools.
4. **`LlmService`** (§5b) + settings key field.
5. **Features #1 and #4** (§6).
6. **Feature #3** (§6) — guided builder, last.

Rough total: **3–5 weeks** for all four polished; #2 alone is a few days.

---

## 9. Key risks

- **EDHREC unofficial API** may change → isolate + graceful fallback to Scryfall-only + LLM.
- **LLM hallucinating illegal cards** → always constrain to the resolved candidate list; validate every returned card against Scryfall + commander color identity before it enters a deck.
- **Scryfall rate limits** on the collection backfill → batch (75/req) + throttle, reuse existing patterns.
- **Cost/latency** of Claude calls → stream, keep the deterministic layer doing the heavy lifting, only call Claude for reasoning/build.
- **API key exposure** → resolved by the food_meter pattern (key lives in the Cloud Function as a Firebase secret, never on the client).
- **No streaming from callable functions** → accepted; deck-build call is a single request/response (tens of seconds). Progress-to-Realtime-DB available later if wanted.
