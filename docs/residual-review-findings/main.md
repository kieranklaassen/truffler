# Residual review findings: main

Risks the 2026-09-25 code review (`06f31d5` to `4d75a0f`) left open after its nine actionable findings were fixed on `main`. None blocks release. Each one is either a documented design trade-off or a gap in coverage.

## Named by the review

1. **Changing a lens's choice options drops records from filters on the new options until relabel.** Relabeling asks only the questions whose fingerprint changed (KTD5). When a choice question's options change, the new option keys have no label rows until the lens backfill reaches each record. Meanwhile, filters on a new option leave those records out instead of falling back to the old values.
2. **Removed lens labels leave orphan rows.** Labels dropped in a new lens version leave `lens:<id>:<old>` rows in `truffler_labels` that nothing prunes. Searches ignore them because they are not in the vocabulary, but they take up space in the index.
3. **The active-lens list can lag by up to a minute on a per-process cache.** Its generation token lives in the cache store. A shared store (which the README requires) invalidates at once. A per-process store does not. In that case a `LensBackfillJob` that runs right after activation can label with the old lens set and still report `:complete`.
4. **Rails 7.2 is untested.** CI covers Ruby 3.2 to 3.4 on the locked Rails 8.1 (Active Record, Active Job, and Active Support 8.1.4). The gemspec allows `>= 7.2, < 9`.
5. **The review lenses ran inline, not independently.** The harness could not dispatch subagents, so every lens (correctness, security, reliability, performance, testing, maintainability, adversarial) ran in one context, and no cross-model peer ran. The reviewer re-checked the cited lines and reproduced the cause-chain and bench-stdout findings by hand. Findings that only an independent pass would catch may remain.

## Other residual risks in the review

- Provider results are stored in the cache store exactly as the host returns them, and they are not encrypted on encrypted models (plan U11 design).
- Query digests in cache keys are unkeyed SHA-256, so someone with a cache dump could run a dictionary attack against them.
- When the vocabulary is not per-tenant, encodings are shared across tenants (R15). `encoding_status` can therefore reveal that someone in another tenant searched the same text.
- SQLite `LOWER()` is ASCII-only, so keyword matches on non-ASCII text miss.
- A `keyword` on an encrypted column is not rejected at declaration. LIKE then runs on ciphertext and silently finds nothing.
- While any lens is active, `Labeling::Backfill` and `Lenses::Backfill` scans grow with table size (performance at Cora scale).

## Left by the fixes

- `ResumeJob` enqueues up to `embedding_sweep_limit` (1,000) stale embeddings per model per `embedding_sweep_interval` (1 hour). A record whose `EmbedJob` is still queued can get a second one. That job is idempotent but costs one extra embedding call.
- A `BackfillJob` chain carries its own `spend_cap`. Chains started separately (by `ResumeJob`, by a demotion, or by hand) do not share spend, so two chains that overlap can together spend up to twice the cap. This predates the review. The retry fix only stops one chain from losing its own spend.
- The Smart dispatcher now checks only the per-user cap. When the account-wide second is exhausted, the first chunk's `acquire` pauses the run, not the dispatcher. Chunk jobs are enqueued first, and the result is still a paused run with no Jev call.
