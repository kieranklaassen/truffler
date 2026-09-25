# Changelog

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
