# Changelog

## [0.1.1]

Fixes from the first host integration (happyhappy).

- Live queries no longer return zero results next to a label filter. Query encoding sends the label vocabulary (descriptions and choice option names) in the request state; a keyword that names an applied label or its option becomes a label term and common stopwords become filler; and when a label filter applies, keyword hits only add to the score instead of being required.
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
