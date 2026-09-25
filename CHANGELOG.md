# Changelog

## [0.1.6]

A fix from happyhappy production and follow-ups from 0.1.5.

- Zero-result relaxation. With a Cora product filter applied, the word "email" became a `Source: email` filter chip and results dropped from 50 to 0 because the tenant has no email sources. When a keystroke search under the encoding's filters returns nothing but would match without them, those filters now become soft boosts: they stay in the intent vector so matching records rank first, but nothing requires them. The words they consumed become keywords again. Truffler first relaxes only the filters no record in the tenant carries at their threshold and keeps the rest, then every filter if that still finds nothing. It never relaxes into "every record in the tenant" when no word, exact match, or vector match remains. The fallback costs one extra query, only on an empty result; non-empty keystrokes stay one SELECT. `Result#relaxed_labels` lists the relaxed storage keys, and their chips carry `relaxed: true`. Chips the searcher removed stay removed. Smart search candidate filtering falls back the same way instead of reranking an empty set, and records `relaxed_labels` on the run (`run.to_h`).
- New `config.skip_empty_options` (default false). When true, query encoding offers Jev only the choice options the tenant has label rows for (at or above `choice_min_probability`) and leaves out choice labels with none. The present-option set is digested into the encoding cache key and cached for 5 minutes, so a new option reaches encoding within that TTL and keystrokes stay one SELECT.
- `truffler:install` and `truffler:upgrade` migration templates pass rubocop-rails-omakase (`[ :a, :b ]` array brackets). A test renders every template and runs RuboCop with the omakase config on the output.
- `Records::BackfillSpend` no longer caches a missing `truffler_backfill_spends.tenant_key` for the life of the process. On a miss it reloads the column information at most once a minute, so workers started before `db:migrate` move to tenant ledgers without a restart.
- `Backfill.status` works with an `index_scope` that orders. It plucked distinct tenants over `index_relation` without `reorder(nil)`, which raised on Postgres (`for SELECT DISTINCT, ORDER BY expressions must appear in select list`).
- A per-tenant choice `options:` callable runs once per label and tenant for each keystroke search, query encoding, labeler batch, and Smart run step, instead of at every vocabulary, fingerprint, and wording read. In happyhappy that was about 8 times per keystroke, and 14 per encoding and 21 per labeler batch in the test model. The new `Truffler::Current.scope` memoizes for one unit of work and clears when it ends, so nothing is shared between searches, jobs, or tenants.
- Backfill spend ledgers key on the Jev-asked labels only (`Vocabulary#ledger_version`). Changing a supplied (`from:`) label, such as adding an option to a supplied product choice, no longer starts a fresh ledger; the backfill rewrites only that label with no Jev call and no charge. Changing an asked label still starts a new ledger. Existing ledgers keep counting: a model without supplied labels keeps the same key, and one with supplied labels has its pre-0.1.6 row taken over by the first backfill.

## [0.1.5]

Fixes from the Cora integration at Postgres scale, and two from happyhappy's 0.1.4 upgrade.

- Tenant-scoped indexing: `index_if ->(record) { ... }` and `index_scope ->(relation) { ... }` in `truffler do`, plus `config.tenant_enabled = ->(model, tenant_key) { ... }`. Records outside them, or in a disabled tenant, are never labeled, embedded or backfilled. The after-commit hooks, `Labeling::Queue`, the labeler, both backfills, lens backfills, `LabelFlushJob`, `ResumeJob` and `EmbedJob` all honor them. `BackfillJob` takes `tenant_key:`, over-cap demotion and `ResumeJob` enqueue one job per tenant, and `truffler:backfill` and `truffler:status` accept `TENANT=`.
- `Embeddings::Backfill` pages per tenant with a limited `NOT EXISTS` anti-join instead of a whole-table `NOT IN`.
- The backfill spend ledger is per tenant for tenant-scoped models (`truffler_backfill_spends.tenant_key`; `config.backfill_spend_cap_scope = :tenant`, the default, or `:app`), so `backfill_spend_cap` applies to each tenant. Existing installs: `rails g truffler:upgrade && rails db:migrate`.
- `rails g truffler:upgrade` is safe to rerun. It skips migrations already present or applied and writes only the missing ones, with no conflicts.
- Choice labels store a row only for options at or above `config.choice_min_probability` (default 0.05; `nil` stores all), plus the most likely option. Missing options read as 0.0 everywhere, and no migration is needed.
- An out-of-shape `from:` answer settles: nothing is stored for that label, the record is marked labeled, and `truffler.supplied_label_failed` fires with `permanent: true`. A raising `from:` still retries and fails after `max_attempts`.
- Postgres: upserts no longer assign `updated_at` twice (Rails 8.1 raised `PG::SyntaxError` on every live enqueue and embedding write). The suite now also runs on Postgres with pgvector in CI (`TRUFFLER_DATABASE_URL`). As a side effect, re-enqueuing an already pending row no longer refreshes its `updated_at`.
- Keystroke SQL at scale on Postgres. A `keyword` or `exact` callable that returns a relation runs once as `id = ANY(ARRAY(subquery))` instead of a hashed `IN` over every tenant row; returning an Array of ids is the documented fast path. Label-only and filtered searches add up label scores in one grouped subquery joined on `record_id` instead of a subquery per row: 120 ms p50 before, 51 ms after, for 50k records. New installs get `INCLUDE (record_id)` on `index_truffler_labels_for_search`, and `truffler:upgrade` adds it on existing Postgres installs. On Postgres, `NeighborStore` scores text from the tenant's top-K neighbors (`ORDER BY embedding <=> q LIMIT k`, default 200); `NeighborStore.new(k:, top_k:)` is new, and `config.vector_store` accepts a store instance. Records outside the top `k` get no text score. The README covers `SET LOCAL jit = off` for the keystroke transaction.
- New `invite_on_pending_encoding` declaration (default true): a model with a `keyword` source, such as a blind index, still shows the `:encoding_pending` Smart search row while a first-time query's encoding is in flight. `Result#local_weak?` keeps the backup provider off when the keyword list is strong.
- New `Truffler::Clients::Evaluator` for clients that read `schema.questions` and return an evaluation object without `to_h`, such as Cora's `TypeSafeClient`. The Cora checklist in `docs/host-integration.md` now shows it instead of the broken `Callable` line.
- A query word that names any declared label key, option key or option search-text word, applied or not, is never dropped as filler. `email` and `emails` are no longer default `config.filler_words`.
- Removing the last label chip no longer makes filler nouns required keywords while a time phrase still applies.
- A lens backfill never pages disabled tenants (filtered in SQL, so a capped `LensBackfillJob` cannot refetch them forever), and the labeler never deletes a disabled tenant's state rows; it returns them to pending at backfill priority, so re-enabling relabels only what is stale.
- Removing chips keeps declared label and option words (option search text included) as keywords, the same as the encoder and the cold-cache path.
- `truffler:status` and `Backfill.status(model, tenant_key:)` count only records inside `index_scope` and enabled tenants, and only their state rows, so a finished partial rollout reports nothing missing or pending.

## [0.1.4]

Fixes from happyhappy production.

- Generic filler nouns are no longer required keywords. "customers in the last 3 hours" returned nothing while "in the last 3 hours" returned the records. New `config.filler_words` (default: customer, customers, people, person, user, users, message, messages, email, emails, item, items, stuff, thing, things; replace or extend it, matched ignoring plurals). One rule now serves both the encoder's word reconciliation and the cold-cache keywords: stopwords and filler words are dropped unless that would leave the search with no keyword, no applied label, and no time phrase, so a lone "customers" still searches text and "customers refund this week" requires only "refund".
- `rake truffler:status` with no model prints the status of every registered Truffler model instead of " is not a Truffler model". An unknown model name still aborts with a message.
- A choice option may be `{ description:, search: }`: the long description stays what Jev labels with, and the short search text drives query-word matching and the request state's `option_names`. Plain descriptions and per-tenant callables keep working, and callables may return the new shape. Labeling fingerprints now cover only what Jev labels with: asked labels are unchanged (search texts are not part of the question), and a supplied label's fingerprint digests its type, option keys, legend, and `version:` but no longer its descriptions. Descriptions and search texts go into a separate encoding version that keys the query-encoding cache, so rewording re-encodes queries without staling labels.
- Removing a chip gives its words back to the keywords. The cached encoding records which applied labels each label-term word named (by token position, no query text); once every one of them is removed, the word is a keyword again, so "urgent refunds" without the urgent chip matches both words. A word that named a label or option key only by shared prefix adds a soft keyword score (a quarter of the keyword weight) and is never required.
- Upgrading from 0.1.3: supplied (`from:`) labels get a new fingerprint, so their stored rows and record states read stale once. `rake truffler:backfill` (or the next watched change) rewrites them at no Jev cost; the new vocabulary version also starts a fresh backfill spend ledger. Query encodings cached by 0.1.3 miss once and are re-encoded.
- Removing the chip that justified dropping a filler word (the time range, or the last applied label) brings the filler noun back as a keyword, cached or cold. When nothing anchors a search and only droppable words are left, filler nouns stay keywords and only pure stopwords are dropped ("the customers" searches "customers").

## [0.1.3]

- Display-name and description words of an applied choice option now match query words exactly (ignoring case and plurals) instead of by shared three-letter prefix. Under a filter, ordinary search words such as "email", "inbox" and "summary" (with Cora applied) or "chat" and "change" (with billing applied) no longer become label terms and keep ranking results. Label keys and option keys still match by shared prefix, so "angry" names `anger`.

## [0.1.2]

Fixes from happyhappy's production `churn_risk` backfill and its 0.1.1 upgrade.

- `rake truffler:backfill` waits out budget denials instead of ending on `budget_denied`. It backs off 1 s, doubling to 30 s (longer when the budget's new `Decision#retry_after` hint says so), and retries from the same cursor until the backfill completes or reaches the spend cap. `MAX_DURATION=<seconds>` stops it with `paused` and the cursor. While waiting it prints counts, spend, and the cursor, never record text. In code: `Labeling::Backfill#run(wait: true, max_duration:, sleeper:, clock:, progress:)`. `BackfillJob` reschedules denials with the same backoff (it used to wait a fixed 30 s), counting consecutive denials in its arguments.
- The backfill spend cap holds across runs. Spend is recorded per model and app-wide vocabulary version in a new `truffler_backfill_spends` table. Each Jev request reserves its estimate against the cap in SQL, so rerunning the rake task or overlapping `BackfillJob` chains can no longer spend more than `backfill_spend_cap` for one vocabulary version. Before, overlapping chains could spend up to twice the cap. A vocabulary change starts a new ledger. `truffler:status` prints the spend for the current version, and `RESET_SPEND=1` zeroes it before a backfill. Lens backfills still charge only their lens row.
- Upgrading from 0.1.1: run `bin/rails generate truffler:upgrade && bin/rails db:migrate` to add `truffler_backfill_spends`. Until you do, backfills log one warning and cap spend per run as in 0.1.1. Fresh installs get the table from `truffler:install`.
- Time phrases now include hours ("last 3 hours", "past hour", "last hour"), "past week", "past month", and "past/last N months" as rolling windows ending now; "this/last week" and "this/last month" keep their calendar meaning. Chips and suppression are unchanged.
- A query word now names a choice option by the words of its display name or description (minus stopwords), not only its key, so "spiral" names option `p_17` described as "Spiral writing tool" when the encoding applies it. The request state's label vocabulary adds `option_names` (option key to display name) next to `options`.

## [0.1.1]

Fixes from the first host integration (happyhappy).

- Live queries no longer return zero results next to a label filter. Query encoding sends the label vocabulary (descriptions and choice option names) in the request state; a keyword that names an applied label or its option (including a shared first-three-letter stem, so "angry" names `anger`) becomes a label term and common stopwords become filler; and when a label filter applies, keyword hits only add to the score instead of being required.
- Declaring `truffler` on a model whose table does not exist yet (a fresh database during `db:prepare`) no longer raises. Column checks run on the first labeling or search instead and raise `DefinitionError` then if columns are still unknown.
- Query encoding's "no option" answer is the reserved `Truffler::NO_OPTION` (`"truffler:none"`), so a host choice option named `none` can be filtered. Host options may not use the reserved name.
- Time phrases (`today`, `yesterday`, `this/last week`, `this/last month`, `past/last N days/weeks`, `since <weekday>`) are parsed locally, never asked of Jev or matched as keywords, and limit results on the `arrived_at` column. They show as a removable `kind: :time` chip (suppress `"time"`); keystroke search accepts a `clock:` for tests.
- `watch:` works on asked labels, not only on `from:` labels, and a model-level `watch :column, ...` relabels every label when those columns change, for `reads` fields backed by methods.
- `Clients::Fake` answers unscripted choices with their neutral option (`ignore`, `Truffler::NO_OPTION`, `keyword`) when present, so unscripted host tests no longer filter on every label.
- `config.backfill_spend_cap` defaults to 5.0 USD for `BackfillJob`, `ResumeJob` backfills, and `rake truffler:backfill`. Set it to `nil`, or pass `SPEND_CAP=none`, to disable it; an unparseable `SPEND_CAP` aborts.
- A per-tenant choice whose options callable returns `{}` or nil for a tenant is left out of that tenant's vocabulary (not asked, not encoded) instead of raising.

## 0.1.0

- `truffler do ... end` declarations on Active Record models: tenant, fields, noul/choice/score labels, keyword and exact sources, embeddings, a provider, surfaces, ranking weights, and `weak_below`.
- Labeling on commit through a tenant-grouped queue, with packed Jev requests, per-record fingerprints, relabeling when watched fields change, `ResumeJob`, and a spend-capped backfill (`rake truffler:backfill`, `rake truffler:status`).
- Host-supplied label answers: `label ..., from: ->(record) { ... }` stores answers your app already computes (with optional `watch:`, `version:`, and `description:`) and never asks Jev about them: no request, no budget slot, no spend, and written even while Jev is down. They filter, boost, fill label vectors, and take part in query encoding like asked labels. `record.truffler_refresh_labels!` rewrites them on demand.
- One account-wide Jev budget with headroom, priority ceilings (live, encode, rerank, backfill), per-user caps, and a per-tenant live cap.
- Jev clients for `ruby_llm-typesafe`, a `Callable` for host clients, a fake, and cassettes. `truffler.*` notifications carry only ids, numbers, and digests.
- Optional text embeddings, and label vectors stored as named-dimension embeddings. Vector stores for pgvector/sqlite-vec (`neighbor`), exact cosine in Ruby, or a host-maintained column.
- Keystroke search in one SQL query with hybrid dot-product scoring, chips, the Smart search invite row, the encoding status, and a watermark for "new matches".
- Query encoding with deduplicated prefetch, cached late answers, and per-user caching when lenses are visible.
- Smart search: a candidate snapshot, chunked Jev rerank into append-only Strong/Possible/Unlikely buckets, pause and cancel, and data-free Action Cable pings, plus a generated `TrufflerChannel`.
- Provider backup search for exact-text or weak-local queries, in its own section.
- Query miss log with distinct-user gating, retention (`PruneQueryMissesJob`), and `rake truffler:suggestions`.
- Lenses: drafting, preview, version comparison, activation with backfill, regenerate, restore, history, proposals from misses, expiry (`ExpireLensesJob`), a creators policy, and the `authorize_lens` hook.
- `rake truffler:bench` benchmark with synthetic fixtures, cassette replay, packed-batch agreement, and injection checks.
- Install generator, README, and host integration guide.
