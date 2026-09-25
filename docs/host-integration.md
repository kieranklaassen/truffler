# Host integration guide

Truffler returns data. Your app renders it. This guide maps each field Truffler returns to the UI state it drives, then gives a checklist for the two first adopters. The APIs themselves are described in the [README](../README.md).

## Host UI contract map

### Keystroke results (`Truffler::Search::Result`)

| UI element | Source | Notes |
|---|---|---|
| Result list | `result.records` | Already scoped to your `scope:` and tenant, and ranked. Keep the order. |
| Chips | `result.chips` | `[{key:, label:, kind:, name:}]`, filters first, then boosts. `kind` is `:filter` (narrows the results) or `:boost` (reorders them). Show `name`. When the searcher removes a chip, send its `key` back in `suppressed:`, and cancel any Smart run. |
| Smart search invite row | `result.invite_row` | `nil` means no row. Otherwise it is `{query:, reason:}`, where `reason` is one of the values below. |
| Pending indicator | `result.encoding_status` | `:pending` means the query encoding is in flight, so a reload shortly will rank by intent. `:cached` means intent ranking already applied. `:none` means no encoding applies. |
| Explicit action hint | `result.explicit_action` | The surface's declared action (`:enter`, `:key`, or `:row`), or nil when no `surface:` was passed. Label the invite row with it. |
| "N new matches" row | `result.watermark`, then `Model.jev_new_matches_count(query, tenant:, scope:, since:)` | Store the watermark with the rendered list and poll or recount later. Hide the row at 0. `result.new_matches_count` gives the same count for a result still in memory. |
| Promoted marks | `result.promoted_ids(run)` | Keystroke rows that the Smart run placed in Strong or Possible. Mark them in place without moving them. |
| Paused note | `result.smart_ranking_paused?(run)` | True when the run hit the rerank budget. |

The invite row's `reason` takes one of these values:

- `:weak`: fewer results than the model's `weak_below` (default 3).
- `:empty`: no results.
- `:encoding_pending`: the model has no `keyword` source and the query has no cached encoding yet. Only Smart search can answer intent queries there, even if an `exact` source matched.

### Smart results (`run.to_h`, the `smart` prop)

| UI element | Field | Notes |
|---|---|---|
| Reserved space | `reserved`, `reserved_slots` | The section holds its space from the moment the action fires. Its size is the candidate count once planned, and `min(snapshot, rerank_depth)` before that. A `:cancelled` or `:expired` run reserves 0. |
| Buckets | `buckets` | `{strong:, possible:, unlikely:}`, each a list of `{id:, score:}`. The lists only grow. Each chunk is sorted within itself and appended in the order chunks arrive, so nothing already shown moves. Load the ids through your own scope. |
| Pending state | `pending` | `{strong: bool, possible: bool, unlikely: bool}`, all true while the run is `:pending` or `:running`. Show a skeleton under each bucket until then. |
| Collapsed buckets | `collapsed` | `[:unlikely]`. Render these buckets collapsed by default. |
| Promoted ids | `promoted_ids` | Strong and Possible ids, which the keystroke list marks. |
| No strong matches | `no_strong_matches` | True once the run is complete and Strong is empty. Show a "no strong matches" line instead of an empty bucket. |
| Paused | `paused`, `status == :paused` | Over the rerank budget. Offer the action again later. |
| Status | `status` | `:pending`, `:running`, `:complete`, `:paused`, `:cancelled` (edited, chip changed, or superseded), or `:expired` (evicted from the cache, so offer the action again). |
| Applied filters | `applied_filters` | Label keys that narrowed the candidates before the rerank. |
| Explicit action | `explicit_action` | Carried over from the surface. |

### Provider section (`smart[:sections][:provider]`, or `run.provider_section`)

Render this section below every local section. `status` is one of the following:

| Status | Meaning | Render |
|---|---|---|
| `:absent` | No provider is declared, or it did not run for this query. | Nothing. |
| `:pending` | Enqueued because the query asked for exact text or the local results were weak. | A loading row titled with `label` (for example "Gmail"). |
| `:results` | `results` holds what the provider's `search:` returned. | The results, with a link out to the provider. |
| `:empty` | The provider found nothing. | "No results in Gmail". |
| `:unavailable` | The provider raised an error (`error_class`), or the run's scope did not match (`reason: :scope_mismatch`, `:no_query`). | A quiet "Gmail unavailable" note. Never show the error class to users. |

Every state carries `name` and `label`.

### Pings

The channel streams `truffler:<user_key>` with `{run_id, section, changed_at}`, where `section` is `"smart"` or `"provider"`. Ignore pings whose `run_id` is not the current run, and reload the `smart` prop. The provider section is inside it. Pings are hints: a missed ping only delays the UI until the next reload.

### Lens screens

| UI element | Source |
|---|---|
| Draft review | `Draft#questions` (wire-shape questions keyed by label) and `Draft#reused` (existing label keys it builds on) |
| Preview | `Previewer.preview(...)` returns `distribution`, `means`, `examples` (up to 5 ids per bucket), and `estimate`: `records`, `requests`, `input_tokens`, `cost_usd`, `duration_seconds`, `within_cap` |
| Compare versions | `Previewer.compare(new, lens)` returns `shift` (per label: `buckets`, `mean`, `changed`), `changed_ids`, `added`, and `removed` |
| History | `lens.history` returns entries with `number`, `status`, `label_keys`, `reused`, `restored_from`, `created_by_digest`, `created_at`, `activated_by_digest`, and `activated_at` |
| Permission gating | `Truffler::Lenses::Policy.allowed?(user, scope, model: Email)` |
| Proposals inbox | `Truffler::Lenses::Lens.proposed.for_model(Email)` |

## Adopter checklist: happyhappy

happyhappy runs on SQLite with Inertia, ruby_llm 2, and `ruby_llm-typesafe`.

1. Add `gem "truffler"`. `ruby_llm-typesafe` is already present, so the default `RubyLLMTypeSafe` client works with no `config.client` line.
2. Run `bin/rails generate truffler:install` with `--record-id-type` matching your ids, then migrate.
3. Confirm that `Rails.cache` is Solid Cache (or another shared store with `increment`). Web and job processes must see the same budget counters, encodings, and Smart runs.
4. Declare `truffler` on items and messages: `tenant`, `reads`, the labels, `keyword` over the plaintext columns, and `order` and `arrived_at`. Declare `surface :feed, explicit_action: :enter` for the feed search box.
5. Embeddings are optional. The ruby vector store works anywhere. For database-side similarity, load sqlite-vec on the connection, and `vector_store :auto` will pick it up.
6. In the feed controller, call `Model.truffler(...)` on every keystroke, and pass `result.records`, `chips`, `invite_row`, `encoding_status`, and `watermark` as props. On the explicit action, call `jev_smart_search` and redirect with `run_id`. Render `smart: -> { run&.to_h }` as a lazy prop after checking `run.user_key`.
7. Subscribe to `TrufflerChannel` in a hook modeled on `use-mood-stream.ts`, and call `router.reload({ only: ["smart"] })` for pings on the current run. Call `jev_cancel_smart_search` when the query or a chip changes.
8. Schedule `ResumeJob`, `PruneQueryMissesJob`, and `ExpireLensesJob`. Run `rails "truffler:backfill[Item]"` and `rails "truffler:backfill[Message]"` with a `SPEND_CAP`.
9. Build a gold set from real feed queries, and tune `filter_at`, `boost`, `ranking`, and `weak_below` with `rake truffler:bench PARAMS=...`.
10. Validate the live budget: watch `truffler.jev_call` and `truffler.budget_denied` while backfill runs beside live traffic.
11. If users will write lenses, set `config.lenses.creators` and `authorize_lens`.

## Adopter checklist: Cora

Cora runs on Postgres with pgvector, uses ruby_llm 1.x with its own `TypeSafeClient`, has encrypted email models and a Gmail provider, and turns embeddings on.

1. Add `gem "truffler"` and `gem "neighbor"`. Do not add `ruby_llm-typesafe`: the default client needs ruby_llm 2.
2. Set `config.client = Truffler::Clients::Callable.new(TypeSafeClient.new)`. The client must respond to `evaluate(state:, schema:)`, and may also accept `model:` so the pin reaches it. Return the answers hash, or `{"answers", "model", "usage" => {"input_tokens"}}` so costs are real rather than estimated.
3. Run `bin/rails generate truffler:install --record-id-type=<your id type> --vector-dimensions=256`, then migrate. Keep `vector_store :auto`, or set it to `:neighbor`. An HNSW index on `truffler_embeddings.embedding` is an optional follow-up migration.
4. Encrypted models need some decisions:
   - Make sure Active Record encryption is configured, so that miss-log text and lens descriptions are stored as ciphertext rather than dropped.
   - `embeddings` refuses encrypted fields until you pass `allow_encrypted: true`. This is an explicit decision to send decrypted text to the embedding provider. Alternatively, fill your own vector column and declare `embeddings column:`.
   - Encrypted bodies cannot use `keyword`. Use `exact` sources over deterministically encrypted columns (sender, thread id) for blind-index lookups. With no `keyword`, the invite row reads `:encoding_pending` until the query has an encoding.
5. `RubyLLMEmbedder` (`RubyLLM.embed`) and the lens `RubyLLMGenerator` both work on ruby_llm 1.x.
6. Declare `provider :gmail, label: "Gmail", search: ->(query, tenant:, user:) { ... }`. Look up the Gmail connection from `tenant` and `user` inside the callable, and return only the fields the section renders. The results sit in the cache for `smart_run_ttl`.
7. Map Cora's categories onto `choice` labels. Per-tenant categories can use `options: ->(tenant_key) { ... }`.
8. Run the benchmark at Cora scale (`MODE=synthetic BENCH_RECORDS=...`) and load-test keystroke p95 against the `truffler_labels` index size.
9. Ask TypeSafe for a higher rate limit, then set `TYPESAFE_REQUESTS_PER_MINUTE`. Cora's other Jev calls share the account, so keep `headroom`.
10. Schedule `ResumeJob`, `PruneQueryMissesJob`, and `ExpireLensesJob`. Run the label backfill with a `SPEND_CAP` and the embeddings backfill (`Truffler::Embeddings::Backfill.new(Email).enqueue`).
