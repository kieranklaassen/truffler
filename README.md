# Truffler

Intent search for Rails apps, built on your own database and TypeSafe Jev.

When a record is saved, Truffler asks Jev the typed questions you declared about it (yes/no "nouls", choices, and scores) and stores each answer as a number in `truffler_labels`. Taken together, a record's answers form a named-dimension embedding: one float per label, and one per option for choice labels. Optional text embeddings sit beside them. A search query is encoded the same way: for each label, Jev decides whether the query filters on it, prefers it, or ignores it. Keystroke search then ranks records in one SQL query that adds up a weighted dot product over the label dimensions, text similarity, keyword hits, and exact-source hits:

```
score = w_label * SUM(intent weight * label value) + w_text * text similarity
      + w_keyword * keyword hit + w_exact * exact hit
```

Truffler also provides:

- **Smart search.** When the searcher asks for it explicitly, Jev reranks the top candidates in chunks. Results stream into Strong, Possible, and Unlikely buckets, announced by data-free Action Cable pings.
- **Provider backup.** An external search (Gmail, for example) runs in its own section when the query asks for exact text or the local results are weak.
- **Lenses.** A permitted user describes a kind of search in plain language. Truffler drafts label questions for it, previews them on a sample, and activates them as new, versioned dimensions in that user's scope.

Truffler ships no UI components. It returns plain Ruby data, which your controllers pass to your own views. [docs/host-integration.md](docs/host-integration.md) maps every field to the UI state it drives.

Requirements: Ruby 3.2+, Rails (Active Record, Active Job, Active Support) 7.2 or 8.x, a job backend, and a cache store shared by web and job processes that supports `increment` (Solid Cache, Redis, or Memcached).

## Install

```ruby
# Gemfile
gem "truffler"
gem "ruby_llm-typesafe" # the default Jev client; skip it if you wrap your own client
```

```bash
bin/rails generate truffler:install
bin/rails db:migrate
```

The generator writes three files:

- A migration that creates `truffler_labels`, `truffler_record_states`, `truffler_embeddings`, `truffler_query_misses`, `truffler_lenses`, `truffler_lens_versions`, and `truffler_backfill_spends`.
- `config/initializers/truffler.rb`.
- `app/channels/truffler_channel.rb`.

It takes two options. `--record-id-type=bigint|integer|string|uuid` must match your primary keys. `--vector-dimensions=N` stores embeddings in a pgvector column of that width; it needs Postgres and the `neighbor` gem, which provides the `t.vector` column type.

### Upgrading from 0.1.1

0.1.2 adds the `truffler_backfill_spends` table, which keeps the backfill spend cap across runs. Add it with:

```bash
bin/rails generate truffler:upgrade
bin/rails db:migrate
```

The migration creates only that table and skips it if it already exists. Until you run it, backfills log one warning and cap spend per run, as 0.1.1 did.

Truffler digests user keys and query misses with `secret_key_base`. Rails supplies it automatically; outside Rails, set `config.secret_key_base`.

## Declaring a model

Include `Truffler::Model` and declare what Jev reads and asks:

```ruby
class Email < ApplicationRecord
  include Truffler::Model

  truffler do
    tenant :account_id                          # every search and Jev request stays inside one tenant
    reads :subject, :body, :sender_name         # the fields Jev sees

    label :needs_action, :noul, question: "Does this email need the reader to act or reply?",
      criteria: { true => "Asks for a reply, a decision, a payment, or a task", false => "FYI, receipts, newsletters" },
      filter_at: 0.6, boost: 2.0
    label :urgent, :noul, question: "Is this email time-sensitive?", boost: 2.0
    label :category, :choice, question: "Which category fits this email?",
      options: { billing: "Invoices, receipts, and payments", travel: "Trips and bookings", other: nil },
      filter_at: 0.5
    label :importance, :score, question: "How important is this email to the reader?",
      legend: { 0 => "Ignorable", 1 => "Worth a look", 2 => "Must read" }

    keyword :subject, :body                     # LIKE match on plaintext columns
    exact :sender, ->(scope, token) { scope.where(sender_email: token) }
    embeddings dimensions: 256                  # optional text embeddings
    provider :gmail, label: "Gmail", search: ->(query, tenant:, user:) { GmailSearch.call(query, account_id: tenant, user_key: user) }
    order :received_at, :desc
    arrived_at :received_at                     # drives "N new matches" and lens samples (default created_at)
    surface :inbox, explicit_action: :enter     # :enter, :key, or :row
    ranking label: 1.0, text: 1.0, keyword: 0.5, exact: 1.0
    weak_below 3                                # fewer keystroke results than this counts as weak
  end
end
```

Here is what each option does:

- `filter_at` makes a label a hard filter at that probability when the query asks for it. `boost` is the label's weight when the query prefers it. `filter_weight:` (default 0) is how much intent weight a filter adds on top.
- Choice `options:` may be a callable of the tenant key, which gives each tenant its own vocabulary. A tenant it gives no options (`{}` or nil) simply lacks the label: it is neither asked nor encoded there. The option name `truffler:none` is reserved (see `Truffler::NO_OPTION` below).
- `watch :column, ...` relabels every label when one of those columns changes. Saving a record only relabels on columns that changed, so a `reads` field backed by a method (a conversation built from messages, say) needs the columns it is built from in `watch`.
- `keyword` also accepts a single callable, `->(scope, tokens) { relation }`.
- `embeddings column: :my_vector` searches a vector column you maintain yourself. Truffler never writes it.
- `embeddings` refuses to send encrypted fields to the embedding provider unless you pass `allow_encrypted: true`.

`label key, type, **options` takes:

| Option | Applies to | Meaning |
|---|---|---|
| `question:` | asked labels (required); optional with `from:` | What Jev is asked about each record. |
| `criteria:` | `:noul` | `{ true => "...", false => "..." }` guidance for Jev. |
| `options:` | `:choice` (required) | Option names, `{ option => description }`, or a callable of the tenant key. |
| `legend:` | `:score` (required) | Two or more ordered levels, as an array or `{ index => description }`. |
| `filter_at:`, `boost:`, `filter_weight:` | all | Filter threshold, boost weight, and the intent weight a filter adds. |
| `description:` | all | The label's wording in query encoding. Defaults to the question, then to the key. |
| `from:` | all | `->(record) { answer }`. Makes the label host-supplied; Jev is never asked. See [Labels you already compute](#labels-you-already-compute). |
| `watch:` | all | Extra columns whose change refreshes (or, for an asked label, re-asks) just this label, in addition to `reads`. |
| `version:` | with `from:` | Any value; changing it rewrites the label for every record on the next backfill. |

Keys must be lowercase snake case without a double underscore, and `lens` is reserved.

Saving a record enqueues labeling (and embedding, when enabled) after commit, but only when a column-backed field in `reads`, the tenant column, a model-level `watch` column, or a label's `watch:` column changed. Destroying a record removes its labels, state, and embeddings.

### Labels you already compute

If your app already classifies records, declare those answers with `from:` instead of asking Jev again. happyhappy, for example, stores sentiment, anger, category, product, actionability, and author role on each item's classification:

```ruby
class Item < ApplicationRecord
  include Truffler::Model

  truffler do
    tenant :workspace_id
    reads :title, :body

    label :sentiment, :choice, options: %w[positive neutral negative mixed],
      from: ->(item) { item.classification&.sentiment }, filter_at: 0.5
    label :anger, :noul, from: ->(item) { item.classification&.anger }, boost: 2.0
    label :category, :choice, options: ->(workspace_id) { Category.names_for(workspace_id) },
      from: ->(item) { item.classification&.category_probabilities }, description: "what the feedback is about"
    label :actionability, :score, legend: %w[none vague clear], from: ->(item) { item.classification&.actionability },
      watch: [ :triaged_at ], version: 2

    label :needs_reply, :noul, question: "Does this item ask the team for a reply?"   # still asked of Jev
  end
end
```

`from:` receives the record and returns the answer in the shape Jev answers are stored in:

| Type | `from:` returns | Stored |
|---|---|---|
| `:noul` | a probability from 0 to 1, or `true`/`false` | the probability under `label` |
| `:choice` | one option string (meaning 1.0 for it), or `{ option => probability }` | one row per option, `label:option`; options left out store 0.0 |
| `:score` | a level index into `legend:` | `index / (levels - 1)`, as for Jev scores |

`nil` stores nothing: the record reads as missing that label, not as 0. An answer out of shape (an undeclared option, a probability outside 0..1, a level past the legend) or a `from:` that raises stores nothing for that label and emits `truffler.supplied_label_failed` with the label key and error class. Rows already stored keep serving until the next good write.

Supplied labels never reach Jev. They are never in a labeling request, take no budget slot, cost nothing, and do not count toward a lens or backfill spend cap. A flush or backfill where only supplied labels are stale makes no Jev call. The labeling job writes them before it asks Jev anything, so a Jev outage or a budget denial never holds them back. Otherwise they behave like asked labels: same `truffler_labels` rows, the same filters, boosts, chips, and label vectors, and query encoding asks Jev how a query uses them (using `description:`), within the one encoding call per query.

To keep them fresh:

- Changing a `reads` field, the tenant column, or one of the label's `watch:` columns refreshes it after commit. Stored values keep serving until the labeling job rewrites them.
- Call `record.truffler_refresh_labels!` when the answers change somewhere truffler cannot see, such as the job that runs your classifier after insert. It rewrites the record's supplied labels immediately, with no Jev call.
- Bump `version:` when the logic behind `from:` changes. That changes the vocabulary version, so `rake truffler:backfill` rewrites the label for every record, again at no cost.

A supplied label's fingerprint digests its type, options, legend, description, and `version:`, never the Jev model, so changing `config.model` does not rewrite supplied labels.

## Clients

The default client is `Truffler::Clients::RubyLLMTypeSafe`. It needs ruby_llm 2 and `ruby_llm-typesafe`, and it calls `RubyLLM.chat(model:, provider: :typesafe).with_schema(...)`.

If you already have a TypeSafe client, wrap it in `Truffler::Clients::Callable`. The wrapped object must respond to `evaluate(state:, schema:)`, and may also accept `model:`. It returns either the answers hash or `{"answers" => ..., "model" => ..., "usage" => {"input_tokens" => ...}}`:

```ruby
config.client = Truffler::Clients::Callable.new(TypeSafeClient.new)
```

`schema:` holds the questions in TypeSafe wire shape. When a response carries no token count, Truffler estimates it from the request size and flags the estimate. Errors reach you as `Truffler::ClientError`, carrying only the HTTP status and the error class name.

## Keystroke search

```ruby
result = Email.truffler(params[:q], tenant: Current.account.id, scope: Current.account.emails, user: Current.user,
  suppressed: params[:removed_chips], surface: :inbox)
```

`tenant:` is required on a model that declares a tenant. `scope:` must be a relation of the model, and results never leave it. `suppressed:` takes the keys of chips the searcher removed. The call also accepts `limit:` (default 50) and `weights:`, which overrides `ranking` for one call.

A keystroke search makes no network call. It reads the query encoding and query vector from the cache. When the cache misses, it enqueues `EncodeQueryJob`, and the next keystroke or reload picks up the result.

Query encoding sends Jev the label vocabulary (each label's description and a choice label's option names) next to the query, and asks for each label whether the query filters on it, prefers it, or ignores it, plus the role of each word. A choice label's option question also offers `Truffler::NO_OPTION` (`"truffler:none"`), meaning the query names none of its options, so a host option literally called `none` stays filterable. Word roles are then checked locally: a word that names a label the query applies (its key, a word of its key, or the chosen option key, ignoring case and plurals or sharing their first three letters when both words have four letters or more, so "angry" names `anger`; or, matched exactly, a word of that option's display name or description) counts as naming the label, and common stopwords are dropped. When the encoding applies a label filter, the filter decides which records match and keyword hits only rank them; without one, the remaining keywords must match.

Time phrases are handled in Ruby and never asked of Jev: `today`, `yesterday`, `this week`, `last week`, `this month`, `last month`, `past|last N hours|days|weeks|months`, `last hour`, `past hour`, `past week`, `past month`, and `since monday` through `since sunday`. "Past/last N units" is a rolling window ending now; "this/last week" and "this/last month" are calendar windows. The first one in a query limits results to records whose `arrived_at` column falls in that window, its words are not keywords, and it shows as a chip `{key: "time", label: "time", kind: :time, name: "This week"}`. Pass `"time"` in `suppressed:` to drop it. Weeks start on `Date.beginning_of_week`, and the window is computed from `Time.current` (or a `clock:` callable passed to the search, for tests).

The returned `Truffler::Search::Result` exposes:

- `records` and `ids`.
- `chips`: `[{key:, label:, kind: :filter | :boost | :time, name:}]`.
- `invite_row`: `{query:, reason: :weak | :empty | :encoding_pending}` or nil.
- `encoding_status`: `:cached`, `:pending`, or `:none`.
- `watermark` and `new_matches_count`.
- `explicit_action`: the surface's declared action.
- `score(record)`, `breakdown(record)`, and `contributions(record)`, for debugging.
- `promoted_ids(run)` and `smart_ranking_paused?(run)`, used alongside a Smart run.

For the "N new matches" row on a later request, pass the watermark back in:

```ruby
Email.jev_new_matches_count(params[:q], tenant: account.id, scope: account.emails, user: current_user, since: Time.iso8601(params[:since]))
```

## Smart search and streaming

The searcher's explicit action (the `explicit_action` their surface declares) starts a Smart run:

```ruby
run = Email.jev_smart_search(params[:q], tenant: account.id, scope: account.emails, user: Current.user,
  surface: :inbox, suppressed: params[:removed_chips])
```

Starting a run happens in three steps:

1. Truffler takes a snapshot of candidate ids from your scope. The keystroke ranking comes first, topped up with the newest records when no encoding exists yet.
2. It supersedes the searcher's previous run.
3. It enqueues `SmartSearchJob`.

The keystroke list is left untouched. The job then does the following:

1. Starts the provider backup, if one is declared.
2. Takes a rerank slot under the per-user cap. If no slot is available, the run pauses.
3. Waits up to `encoding_deadline` for an in-flight query encoding and applies its filters.
4. Fans out one `RerankChunkJob` per `rerank_chunk_size` candidates.

Each chunk appends to the buckets and pings. When the searcher edits the query or accepts or removes a chip, call `Email.jev_cancel_smart_search(tenant:, user:, surface:)`.

Runs live in the cache store for `smart_run_ttl`. Load one with `Truffler::SmartSearch.find(run_id, user: Current.user, tenant: Current.account.id)`, passing the same `user:` and `tenant:` you gave `jev_smart_search`. A run that belongs to another searcher or tenant reads as expired, so a leaked run id shows nothing. `run.to_h` is the whole `smart` prop: ids, scores, and states, never record data.

### Pings and Inertia partial reloads

The generated `TrufflerChannel` streams `truffler:<user_key>`. The user key is `"User:42"` for a record and `to_s` for anything else, and it must match the `user:` you pass to searches. Each ping is `{run_id, section, changed_at}` with `section` either `"smart"` or `"provider"`. No result data travels over the socket.

The client ignores pings for other runs and reloads only the Smart prop, following happyhappy's `use-mood-stream.ts` pattern:

```ts
consumer.subscriptions.create({ channel: "TrufflerChannel" }, {
  received({ run_id }: { run_id: string; section: string }) {
    if (run_id === currentRunId) router.reload({ only: ["smart"] })
  },
})
```

On the server, the controller renders the run as a lazy prop, so a partial reload recomputes only that prop:

```ruby
run = params[:run_id] && Truffler::SmartSearch.find(params[:run_id], user: Current.user, tenant: account.id)

render inertia: "Emails/Index", props: {
  emails: -> { serialize(result.records) },
  chips: result.chips,
  invite_row: result.invite_row,
  smart: -> { run&.to_h },
}
```

The provider section is part of `smart` (`sections.provider`), so reloading `smart` covers both kinds of ping. To render a bucket, load its ids through your own scope, for example `account.emails.where(id: ids)`, and keep the order the ids arrive in. To route pings through something other than `ActionCable.server`, set `config.broadcaster` to any object that responds to `broadcast(stream, payload)`.

## Provider backup

A model can declare one `provider`. Its `search:` callable receives `(query, tenant:, user:)` and returns an array of result hashes. The provider runs during the Smart run under either of two conditions:

- **Exact text.** The query contains a quoted phrase, digits, an email address, or an identifier such as `INV-4471`.
- **Weak local results.** The keystroke results were weak.

Its state appears in `run.provider_section`, which has one of the statuses `:absent`, `:pending`, `:results`, `:empty`, or `:unavailable`. Each provider search is scoped to the run's own tenant and user. Results are stored in the cache store for the run's TTL, so return only the fields your UI needs.

## Lenses

A lens is a set of drafted label questions for one model and scope: the whole app (`Scope.app`), one tenant (`Scope.tenant(key)`), or one user within a tenant (`Scope.user(tenant_key, user_key)`). A lens's answers are stored as `lens:<id>:<label>` rows in `truffler_labels`. Filters, label vectors, staleness, backfill, and query encoding treat them exactly like declared labels.

```ruby
Lenses = Truffler::Lenses
scope = Lenses::Scope.tenant(account.id)

draft = Lenses::Drafter.draft("customers asking for a refund", model: Email, scope: scope)
preview = Lenses::Previewer.preview(draft, relation: account.emails, by: Current.user)
preview.distribution                # {label => {bucket => count}} on a sample of recent records
preview.examples                    # up to 5 record ids per bucket
preview.estimate                    # records, requests, input_tokens, cost_usd, duration_seconds, within_cap

lens = Lenses::Activator.activate(draft, by: Current.user)   # enqueues LensBackfillJob

version = lens.regenerate(by: Current.user, description: "customers asking for a refund or a credit")
comparison = Lenses::Previewer.compare(version, lens, relation: account.emails, by: Current.user)
comparison.shift                    # per-label bucket and mean movement on the same sample
Lenses::Activator.activate(version, by: Current.user)

lens.restore!(1, by: Current.user)  # copies version 1 forward as a new active version
lens.history                        # number, status, label keys, reused keys, author digests, and times
lens.promote!                       # prints `label ...` lines to paste into the model's declaration
```

Some rules that apply throughout:

- The drafting model sees the description and the existing label vocabulary, never record text.
- Search keeps using the active version until a new one is activated.
- Labels written by an earlier version keep serving searches until they are relabeled.
- Each lens has its own spend cap. Previews run at encode priority and fail with `LensSpendCapExceeded` when the lens would exceed its cap.
- A lens nobody searches with for `expire_after` expires.
- `Lenses::Proposer.propose(Email, tenant_key: account.id.to_s)` drafts `proposed` lenses from query-miss clusters when `config.lenses.proposals` is on. A proposed lens changes nothing until someone activates it.

Who may change lenses is set by `config.lenses.creators`:

- `:developers` (the default) allows app, tenant, and user lenses.
- `:tenant_users` allows tenant and user lenses.
- `:each_user` allows only personal lenses, and only for their own user.

The `authorize_lens` hook always has the final word. Without it, every change raises `Truffler::NotAuthorized`:

```ruby
config.lenses.creators = :tenant_users
config.lenses.authorize_lens = ->(user, scope) { user.admin? || scope.tenant_key == user.account_id.to_s }
```

For personal lenses, build the scope with the same key your searches use: `Scope.user(account.id, Truffler::Search::Keystroke.user_key(Current.user))`.

## Configuration

Set these in `Truffler.configure do |config| ... end`.

| Setting | Default | Meaning |
|---|---|---|
| `model` | `"jev-latest"` | Jev model pin. Changing it makes every asked label stale; supplied (`from:`) labels are unaffected. |
| `client` | `Clients::RubyLLMTypeSafe.new` | Jev client (see Clients). |
| `cache_store` | `Rails.cache` | Budget counters, encodings, Smart runs. Must be shared and support `increment`. |
| `requests_per_minute` | 1,200 (`TYPESAFE_REQUESTS_PER_MINUTE`) | TypeSafe account limit. |
| `headroom` | 0.25 | Share of the limit left for your app's other Jev calls. |
| `priority_ceilings` | `{live: 1.0, encode: 0.9, rerank: 0.75, backfill: 0.5}` | Share of the gem's per-second budget each priority may fill. Lower priorities give way first. |
| `user_caps` | `{encode: 30, rerank: 10}` | Per-user requests per minute. A denied rerank pauses the run. |
| `tenant_live_cap` | 120 | Records per tenant per minute labeled live. The rest wait at backfill priority. |
| `max_wait` | 5.0 | Seconds a live labeling call may wait for a budget slot. |
| `batch_size`, `grouping_window` | 10, 0 | Records per labeling request and the flush delay. |
| `max_attempts` | 5 | Labeling attempts per record before it is marked failed. |
| `max_field_chars`, `request_token_budget`, `max_questions_per_request` | 4,000, 48,000, 200 | Request packing limits. |
| `queue_name` | `:default` | Queue for every Truffler job. |
| `cost_per_million_tokens` | 0.042 | Jev input price, used in usage events and estimates. |
| `backfill_spend_cap` | 5.0 | Dollar cap on backfill spend per model and vocabulary version, shared by `BackfillJob` chains, `ResumeJob` backfills, and `truffler:backfill` runs (see Backfill). `nil` disables it; for the rake task, `SPEND_CAP=none` does. Supplied labels cost nothing and are still written once it is reached. |
| `resume_pending_after` | 5 minutes | How long before `ResumeJob` treats work as stuck. |
| `embedder` | `Embeddings::RubyLLMEmbedder.new` | Any `Embeddings::Embedder` subclass. The default calls `RubyLLM.embed`, which works on ruby_llm 1.x and 2. |
| `embedding_cost_per_million_tokens` | 0.02 | Embedding price. |
| `vector_store` | `:auto` | `:neighbor` (pgvector `<=>`, or sqlite-vec `vec_distance_cosine` when you load the extension), `:ruby` (exact cosine in Ruby), or `:auto` (neighbor when available, otherwise Ruby). A model declaring `embeddings column:` always reads its own column. |
| `encoding_prefetch` | `QueryEncoding::Prefetch.new` | Cache-miss hook, called as `call(model, query, cache_key:, tenant_key:, user_key:)`. |
| `encoding_deadline` | 1.0 | Seconds a Smart run waits for an in-flight query encoding. |
| `rerank_depth`, `rerank_chunk_size`, `rerank_max_field_chars` | 30, 10, 1,200 | Candidates reranked, candidates per Jev request, characters per field sent. |
| `smart_thresholds` | `{strong: 0.70, possible: 0.35}` | Bucket cutoffs on the relevance probability. |
| `smart_run_ttl`, `smart_candidate_pool` | 15 minutes, 200 | Run lifetime and snapshot size cap. |
| `broadcaster` | `ActionCable.server` | Ping target. |
| `miss_retention`, `miss_min_distinct_users` | 30 days, 5 | Miss log retention, and the number of distinct users a miss cluster needs before anyone sees it. |
| `secret_key_base` | Rails' | Keys user digests, miss digests, and Smart query encryption. |
| `lenses.creators`, `lenses.authorize_lens`, `lenses.proposals` | `:developers`, nil, false | Lens policy (see Lenses). |
| `lenses.spend_cap_usd`, `lenses.sample_size`, `lenses.max_questions`, `lenses.expire_after` | 1.0, 20, 8, 30 days | Lens limits. |
| `lenses.generator`, `lenses.drafter_model`, `lenses.user_key` | `RubyLLMGenerator`, nil, `"User:42"` style | Drafting model seam and user key mapping. |

## Jobs to schedule

Truffler enqueues most of its own jobs. Run a worker for `config.queue_name` and schedule these yourself:

| Job or task | When |
|---|---|
| `Truffler::Jobs::ResumeJob` | Every few minutes. Requeues failed and stuck labeling after an outage or a crashed worker, and enqueues up to 1,000 missing or stale embeddings per model per hour. |
| `Truffler::Jobs::PruneQueryMissesJob` | Daily. Enforces `miss_retention`. |
| `Truffler::Jobs::ExpireLensesJob` | Daily. Expires lenses unused for `lenses.expire_after`. |
| `bin/rails "truffler:backfill[Email]"` (see Backfill) or `Truffler::Jobs::BackfillJob.perform_later("Email")` | After adopting Truffler, changing a declaration, or changing the model pin. |
| `Truffler::Embeddings::Backfill.new(Email).enqueue` | After enabling embeddings or changing the embedding model, width, or fields, to re-embed everything now instead of through the `ResumeJob` sweep. It enqueues 1,000 jobs at a time; pass `limit:` to cap the total. |

`bin/rails "truffler:status[Email]"` prints labeling counts and the backfill spend for the current vocabulary version. `bin/rails "truffler:suggestions[Email]"` prints candidate questions drawn from logged query misses.

With Solid Queue, for example:

```yaml
# config/recurring.yml
truffler_resume:
  class: Truffler::Jobs::ResumeJob
  schedule: every 5 minutes
truffler_prune_misses:
  class: Truffler::Jobs::PruneQueryMissesJob
  schedule: every day at 3am
truffler_expire_lenses:
  class: Truffler::Jobs::ExpireLensesJob
  schedule: every day at 3am
```

### Backfill

`bin/rails "truffler:backfill[Email]"` labels missing, stale, and failed records inline, newest first, at backfill priority. Backfill has the lowest share of the request budget, so the task waits whenever the budget turns it away. It backs off 1 s, doubling to 30 s (or longer if the budget says a slot frees later), and resumes from the same cursor. It ends when every record is current (`complete`) or the spend cap is reached (`spend_cap_reached`). While it waits it prints the records labeled, the spend, and the cursor, never record text. Environment variables:

| Variable | Effect |
|---|---|
| `SPEND_CAP=20` or `none` | Overrides `backfill_spend_cap` for this run. |
| `MAX_DURATION=600` | Stops after that many seconds with `paused` and the cursor. Rerun to continue. |
| `RESET_SPEND=1` | Zeroes the spend recorded for the current vocabulary version before starting. |

The spend cap holds across runs. Truffler records backfill spend per model and app-wide vocabulary version in `truffler_backfill_spends`, and reserves each request's estimate against the cap in SQL. A rerun, a `ResumeJob` backfill, and overlapping `BackfillJob` chains all draw on the same total, so together they stop at `backfill_spend_cap`. Changing the vocabulary (a reworded question, a new label, or an activated lens) starts a new total. Lens backfills are capped separately by each lens's `spend_cap_usd`. `BackfillJob` reschedules itself after a denial with the same backoff. In code, `Truffler::Labeling::Backfill.new(Email).run(wait: true, max_duration: 600)` does what the task does.

## Privacy

These guarantees hold for every model, and matter most for models that use Active Record encryption:

- Decrypted text exists only in process memory during a labeling, embedding, encoding, rerank, or preview call.
- Tables, job arguments, and logs carry only ids, numbers, and digests. The same goes for `truffler.*` notifications: `jev_call`, `search`, `smart_search`, `embed_call`, `lens_draft`, and the rest.
- Client errors keep only the error class and HTTP status.
- On encrypted models, pending query payloads and Smart run queries in the cache are encrypted with a key derived from `secret_key_base`. Search notifications carry a query digest instead of the query.
- On encrypted models, the miss log and lens descriptions keep Active Record ciphertext when encryption is configured, and nothing otherwise. Miss clusters are shown only once they reach `miss_min_distinct_users`.
- Embeddings refuse encrypted fields unless you opt in with `allow_encrypted: true`, or declare a `column:` you fill yourself.
- `keyword` runs `LIKE` against columns, so it cannot see inside encrypted columns. Use `exact` with deterministic encryption for blind-index lookups.
- A Smart rerank sends only candidates from the snapshot of your scope, one tenant per request, with fields truncated to `rerank_max_field_chars`. Query and record text appear only in the request state, marked as untrusted data.

## Cost and rate limits

Jev costs $0.042 per million input tokens. The default account limit is 1,200 requests per minute. With the default 25% headroom, Truffler takes up to 900 requests per minute, or 15 per second, split by priority ceilings in this order: live labeling, then query encoding, then rerank, then backfill.

Here is what a typical session consumes:

- **Labeling.** Each labeling request packs `batch_size` records from one tenant.
- **Query encoding.** Each query is encoded once per vocabulary version and then cached.
- **Smart search.** A run costs `rerank_depth / rerank_chunk_size` requests, 3 by default.

Every call emits `truffler.jev_call` with input tokens (estimated and flagged when the client reports none), cost, model, and latency, so you can meter spend yourself. For a higher throughput ceiling, raise `TYPESAFE_REQUESTS_PER_MINUTE` once TypeSafe raises your account limit.

## Benchmark

```bash
bundle exec rake truffler:bench                           # replay committed cassettes (CI runs this)
bundle exec rake truffler:bench MODE=synthetic BENCH_RECORDS=5000
bundle exec rake truffler:bench PARAMS=bench/params.yml OUT=tmp/bench.json
TYPESAFE_API_KEY=... bundle exec rake truffler:bench MODE=record JEV=live
```

The benchmark loads fixtures into its own SQLite database and labels them through the real pipeline. It prints a JSON report with the following:

- Recall and precision for intent and exact-text queries.
- Keystroke p50 and p95 latency.
- Labeling throughput.
- Cost per labeled record and per query.
- Packed-batch agreement and the adopted batch size.
- Prompt-injection checks for labels and rerank.
- Rerank bucket counts.

It exits non-zero when a check fails. `bench/params.yml` holds the tunable thresholds, boosts, and blend weights.

## Development

```bash
bundle install
bundle exec rake test
bundle exec rubocop
```

Tests run on in-memory SQLite with fake clients. Any live Jev call raises `Truffler::LiveCallInTest`.

In your own tests, `Truffler::Clients::Fake` answers unscripted questions neutrally: nouls no, scores the lowest level, and choices their neutral option when they have one (`ignore` for a query's label intent, `Truffler::NO_OPTION` for an option question, `keyword` for a word role), otherwise the first option. An unscripted query encoding therefore applies no labels; script the ones a test needs, e.g. `fake.answer("intent__needs_action", "filter")`.
