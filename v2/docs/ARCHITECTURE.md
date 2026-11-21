# Contractor Corner — Standalone Architecture (Stage 3)

Target: **Next.js (App Router) + Supabase (Postgres, Auth, Storage) + Stripe
in TEST mode only**, deployed on **Vercel only**. This is the build spec the
implementation workers follow. It is derived from the v2 inventory
(`INVENTORY.md` in this folder — read it first); where this doc changes v2
behaviour, the change is marked **CHANGE** with the reason.

Non-goals for this stage: building the app UI from scratch (port the v2
screens), workflow features that depend on Cherylene's walkthrough (tasks,
change orders, scheduling, customer portal, missed-call text-back),
customer card payments (Stage 4), Advisor inference (Phase 2).

---

## 1. Repo and deploy (decisions already made — follow them)

- **Repo:** `Darknezz-0/contractor-corner`, branch `standalone-v2` (from
  main `95d0ccf`). New app lives in **`v2/` at repo root**. v1 files at root
  (`README.md`, `index.html`, `vercel.json`) are **untouched and frozen**.
- **Vercel project (new):** `contractor-corner-v2`, **FREE Hobby plan**,
  linked to the same repo with **rootDirectory `v2`**, under team
  `precision-web-concepts` (teamId
  `team_KgYPFbHAzVvWS9lRMrgdX10R`).
- **Do NOT deploy into the existing `contractor-corner` Vercel project** —
  its production deployment is the v1 demo and must stay live untouched.
- **Do NOT purchase or upgrade anything** in this stage. The Hobby project
  is for building and testing. The move to Vercel Pro happens only with
  Rob's separate approval, when BTYH is ready to be charged (see §13).
- **Framework:** Next.js App Router (latest stable at build time),
  TypeScript strict, React Server Components + Server Actions for mutations.
  No server SQLite, no Node-only libraries in request paths — **Supabase-
  first, fetch-style server code** so the code stays portable.

### 1.1 `v2/` layout

```text
v2/
  docs/
    INVENTORY.md            # this stage's code inventory (Worker 1)
    ARCHITECTURE.md         # this file
  app/
    (auth)/sign-in/page.tsx
    (auth)/sign-up/page.tsx
    (auth)/callback/route.ts        # Supabase Auth code exchange
    (app)/layout.tsx               # authed shell: header, bottom nav, sync badge
    (app)/jobs/page.tsx            # Jobs tab (board, filters, checklist)
    (app)/jobs/[id]/page.tsx       # one scrolling job page
    (app)/jobs/new/page.tsx        # JobForm (also used for edit)
    (app)/customers/page.tsx
    (app)/money/page.tsx
    (app)/prices/page.tsx
    (app)/setup/page.tsx
    (app)/onboarding/page.tsx      # create/join business (+ Advisor Q, §10)
    api/
      sync/push/route.ts           # pushCaptures (kept as a route: batch JSON)
      stripe/webhook/route.ts      # Stripe test-mode webhook (subscription only)
      storage/sign/route.ts        # signed-URL minting for private photos
  lib/
    supabase/
      client.ts                    # browser client (@supabase/ssr)
      server.ts                    # server client + service-role client
      middleware.ts                # session refresh (proxy.ts)
    db/
      schema.ts                    # Drizzle Postgres schema (mirrors §4)
      queries.ts                   # shared helpers: session, totals, ledger, events
    actions/
      session.ts  customers.ts  jobs.ts  items.ts  money.ts
      texts.ts  prices.ts  sync.ts  dashboard.ts  advisor.ts
      # one Next.js Server Action module per v2 action group; each action
      # keeps its v2 name and zod request schema (INVENTORY.md §4)
    adapters/
      storage.ts  payments.ts  sms.ts  advisor.ts
      # provider interfaces + implementations (see §8)
    stripe/
      client.ts  subscriptions.ts
    money.ts                       # cents formatting, totals
  supabase/
    migrations/                    # SQL migrations, one per table group (§4)
    config.toml
  public/
    logo-full.jpg  logo-mark.jpg   # copied from the v2 artifact assets
  components/                      # ported from App.tsx (Section, Card, …)
  middleware.ts / proxy.ts         # Supabase session handling
  next.config.ts
  package.json
  .env.example                     # variable NAMES only, no values (§11)
  README.md                        # how to run locally, deploy, and rotate keys
```

`proxy.ts` (Next.js middleware convention) refreshes the Supabase session on
every request; unauthenticated users are redirected to `/sign-in` except for
`(auth)` routes. The Research tab is **not** carried over (see §12).

---

## 2. Supabase Auth model

v2's identity was platform-verified `ctx.viewer` mapped to an `accounts`
row. The standalone replaces that with **Supabase Auth (email + password)**
— no other provider in this stage.

### 2.1 Mapping

| v2 concept | Standalone |
| --- | --- |
| `accounts.identity_key` (`local:<id>` / `peer:<id>` / `share:<id>`) | **Dropped.** Identity is `auth.users.id` (UUID). |
| `accounts` row | One row per user, `id uuid PK REFERENCES auth.users(id) ON DELETE CASCADE`, `display_name`, `created_at`. Created by a trigger on `auth.users` insert OR lazily by the onboarding action — pick the trigger (single source of truth, no race). |
| `memberships` | Unchanged in shape, but `account_id uuid FK → accounts(id)`; UNIQUE(`account_id`) — one business per account, as in v2. |
| `workspace` (business) | Unchanged in shape; `id bigint` identity; `owner_account_id uuid FK → accounts(id)`; `invite_code` 6 chars, same alphabet. |
| Role | `memberships.role` enum `field \| office`, as in v2. Set at business creation / join time; changeable by office only. |
| Session | Supabase Auth session (cookie via `@supabase/ssr`). Server Actions and Route Handlers call `supabase.auth.getUser()` on every request — never trust a client-sent user id or role. |

### 2.2 Invite-code join flow (port v2 exactly)

1. Owner finds the 6-char code in Setup (office only) and reads it to the
   teammate; owner can regenerate it (old code dies immediately).
2. Joiner (signed in, no membership yet) enters the code + picks a role.
   **CHANGE from v2 (security hardening, needs Rob's awareness, not his
   approval to spec):** the code alone grants membership with a self-picked
   role, including office. In the standalone, joining with a code grants
   **field** by default; the role picker at join time is removed, and an
   office member promotes the joiner afterwards in Setup. Rationale: v2's
   self-picked office role meant anyone with the code could approve their
   own drafts and record payments. If Rob/Cherylene object, the v2 behaviour
   can be restored with one line — but the default ships as field-only join.
3. One account = one business. Joining or creating a second business is
   rejected while a membership exists (same as v2).
4. **Claim path dropped.** v2's `claimBusiness` existed only to adopt the
   pre-sign-in workspace 1. There is no pre-sign-in data in the standalone;
   do not implement it. (If BTYH's v2 data ever needs migrating, that is a
   separate, explicitly approved migration task — it is not part of Stage 3.)

### 2.3 Onboarding order (port v2, plus Advisor)

`getSession` stages map to routes: `no_account` → sign-up/sign-in →
`no_business` → onboarding (create / join) → `ready` → app shell. After a
business is **created** (creator only — joiners and the claim path skip
it), show the **Advisor personalization questionnaire, Phase 1 trimmed
version** (§10), skippable in one tap with defaults applied. It must not
compete with the Getting Started checklist on the Jobs tab (separate moment,
earlier, one screen).

---

## 3. Data-access rules (the layer every worker must obey)

1. **Every query is workspace-scoped.** Server code resolves the workspace
   from the authed user (`memberships` → `workspace_id`) exactly as v2's
   `requireSess` did, then filters `workspace_id = <id>` on every table.
   RLS (§5) is the backstop, not the only layer.
2. **Money in integer cents.** No floats for money. `qty` is `numeric`
   (fractional hours); line totals are `round(qty × unit_price_cents)` per
   line, then summed — same as v2's `jobTotals`.
3. **One zod schema per Server Action**, kept next to the action, and form
   field limits derived from it (v2 used `actionFields`; the standalone
   uses the same zod schemas for both client validation hints and server
   validation).
4. **Append-only tables are INSERT-only in code.** No update/delete code
   path may touch `ledger_entries` or `job_events` — enforce by RLS (§5)
   as well as by code review.
5. **Frozen documents are INSERT-only.** Once `documents` has a row, no
   code path updates it.
6. **No direct client access to tables.** The browser client uses the anon
   key with RLS, but all business mutations go through Next.js Server
   Actions (service-role or RLS-scoped server client). The browser never
   holds the service-role key.
7. **Timestamps:** `timestamptz` everywhere (`created_at`, `updated_at`,
   `archived_at`, `applied_at`). Date-only business fields stay `date`
   (`scheduled_date`, `issued_date`, `due_date`, `paid_date`) — v2 stored
   these as `YYYY-MM-DD` text; Postgres `date` is the faithful mapping.
   Month bucketing (`YYYY-MM`) is computed from `paid_date` / `created_at`
   exactly as v2 did (local date of the business — America/Chicago; store
   UTC, render in the business timezone).

---

## 4. SQLite → Postgres table mapping

All 19 v2 tables, plus new tables. Conventions: `bigint GENERATED ALWAYS
AS IDENTITY` primary keys (preserves v2's integer ids and ordering);
`uuid` only for `accounts.id` (Supabase Auth) and references to it;
`workspace_id bigint NOT NULL REFERENCES workspaces(id)` on every business
row (table renamed `workspaces` in Postgres — plural, per Supabase
convention; the v2 name `workspace` is singular and is a reserved-ish
word in some tooling); `timestamptz` timestamps; money `integer` cents;
enums as native Postgres enums (safer than text + check, and Drizzle
supports `pgEnum`).

**CHANGE — rename:** `workspace` → `workspaces`. All other table names
stay as in v2 (`accounts`, `memberships`, `customers`, `jobs`,
`line_items`, `costs`, `photos`, `voice_notes`, `invoices`, `payments`,
`ledger_entries`, `price_books`, `price_book_items`, `sync_outbox`,
`job_events`, `documents`, `sync_refs`, `client_updates`).

### 4.1 The 19 (with deltas)

| Table | Postgres shape | Delta vs v2 |
| --- | --- | --- |
| `workspaces` | `id` identity PK; `business_name text NOT NULL DEFAULT ''`; `trade text NOT NULL DEFAULT ''`; `owner_account_id uuid REFERENCES accounts(id)`; `invite_code text NOT NULL`; `updated_at timestamptz`; **new:** `storage_used_bytes bigint NOT NULL DEFAULT 0`, `stripe_customer_id text`, `stripe_subscription_id text`, `subscription_status text`, `subscription_current_period_end timestamptz` | Renamed; + storage accounting + Stripe subscription columns (§9) |
| `accounts` | `id uuid PK REFERENCES auth.users(id) ON DELETE CASCADE`; `display_name text NOT NULL DEFAULT ''`; `created_at timestamptz` | `identity_key` dropped; id is the Auth UUID |
| `memberships` | `id` identity PK; `account_id uuid NOT NULL UNIQUE REFERENCES accounts(id)`; `workspace_id bigint NOT NULL REFERENCES workspaces(id)`; `role role_enum NOT NULL DEFAULT 'field'`; `created_at`; UNIQUE(`workspace_id`, `account_id`) | `account_id` type change only |
| `members` | — | **DROPPED. Dead in v2; do not create.** |
| `customers` | as v2; `phone/email/address/notes text DEFAULT ''` | None |
| `jobs` | as v2; `status job_status_enum DEFAULT 'lead'`; `scheduled_date date`; `archived_at timestamptz`; `updated_at timestamptz` | `scheduled_date` text → `date` |
| `line_items` | as v2; `qty numeric NOT NULL DEFAULT 1`; `price_book_version integer` | `qty` real → `numeric` |
| `costs` | as v2 | None |
| `photos` | as v2; `blob_key text NOT NULL` (now the Supabase Storage object path, §6); `storage_provider text DEFAULT 'supabase_storage'`; **new:** `size_bytes bigint NOT NULL DEFAULT 0` | Provider name changes; + size for quota accounting |
| `voice_notes` | as v2 | None |
| `invoices` | as v2; `issued_date date`, `due_date date`; `number text NOT NULL` | Date columns text → `date` |
| `payments` | as v2; `paid_date date NOT NULL`; `provider_ref text` (will hold Stripe PaymentIntent id in Stage 4) | `paid_date` text → `date` |
| `ledger_entries` | as v2 | None (append-only, §5) |
| `price_books` | as v2; `is_active boolean NOT NULL DEFAULT false` (was int 0/1) | Boolean instead of int |
| `price_book_items` | as v2 | None |
| `sync_outbox` | as v2; `payload_json jsonb NOT NULL`; `error text`; `applied_at timestamptz` | `payload_json` text → `jsonb` |
| `job_events` | as v2; `account_id uuid REFERENCES accounts(id)`; `actor_name text` | `account_id` type change only |
| `documents` | as v2; `lines_json jsonb NOT NULL DEFAULT '[]'` | `lines_json` text → `jsonb` |
| `sync_refs` | as v2 | **CHANGE:** unique index becomes `(workspace_id, entity, client_ref)` — v2's index omitted `entity` (INVENTORY.md §10.2.15) |
| `client_updates` | as v2 | None |

Enums to create: `role_enum ('field','office')`,
`job_status_enum ('lead','quoted','scheduled','in_progress','done','invoiced','paid','cancelled')`,
`line_kind_enum ('labor','material','other')`,
`line_source_enum ('manual','voice_draft','price_book')`,
`line_status_enum ('draft','approved')`,
`photo_kind_enum ('before','after','receipt','site')`,
`invoice_status_enum ('draft','sent','paid','overdue')`,
`payment_kind_enum ('payment','refund')`,
`ledger_type_enum ('invoice_issued','payment_received','cost_recorded','refund','adjustment')`,
`sync_kind_enum ('voice_note','photo','cost','status_change','note','customer','job')`,
`sync_status_enum ('pending','applied','failed')`,
`job_event_type_enum` (22 values, INVENTORY.md §6.3),
`document_kind_enum ('estimate','invoice')`,
`sync_entity_enum ('customer','job')`,
`update_kind_enum ('estimate','en_route','milestone','payment','custom')`,
`update_status_enum ('draft','sent')`,
`advisor_*` enums in §10.

### 4.2 Numbering fix (CHANGE)

v2 numbers estimates/invoices as `EST-/INV-` + (1001 + **count** of existing
rows) — a deleted estimate's number can be reused. Standalone: use a
per-workspace sequence. Implementation: a `counters` approach — a
`workspace_counters` table (`workspace_id`, `estimate_seq bigint DEFAULT
1000`, `invoice_seq bigint DEFAULT 1000`) incremented in the same
transaction as the insert (`UPDATE … SET estimate_seq = estimate_seq + 1
RETURNING`), so numbers are gapless-per-workspace and never reused. First
numbers remain `EST-1001` / `INV-1001` to match v2.

### 4.3 Indexes (minimum — v2 had almost none)

Keep v2's unique indexes (`accounts` is the PK now; `memberships(account_id)`
UNIQUE; `memberships(workspace_id, account_id)` UNIQUE;
`sync_outbox(workspace_id, client_id)` UNIQUE;
`sync_refs(workspace_id, entity, client_ref)` UNIQUE) and add the ones v2
was missing for its N+1 reads: `jobs(workspace_id, id DESC)`,
`line_items(job_id)`, `costs(job_id)`, `photos(job_id)`,
`voice_notes(job_id)`, `invoices(job_id)`, `payments(invoice_id)`,
`ledger_entries(workspace_id, id DESC)`, `job_events(job_id, id DESC)`,
`documents(job_id)`, `client_updates(job_id)`, `customers(workspace_id,
name)`, `price_books(workspace_id, version DESC)`,
`price_book_items(price_book_id)`, `sync_outbox(workspace_id, status)`.

---

## 5. RLS policy design

Enable RLS on **every** table. Two security-definer helpers (in a
`private` schema, `SECURITY DEFINER`, `SET search_path` locked):

```sql
-- returns the caller's workspace id, or NULL
create or replace function private.current_workspace_id() returns bigint
  language sql security definer stable as $$
    select workspace_id from public.memberships
    where account_id = auth.uid() limit 1 $$;
-- returns the caller's role in that workspace, or NULL
create or replace function private.current_role() returns text
  language sql security definer stable as $$
    select role::text from public.memberships
    where account_id = auth.uid() limit 1 $$;
```

Policies (per table; `auth.uid()` = the Supabase Auth user):

| Table | SELECT | INSERT | UPDATE | DELETE |
| --- | --- | --- | --- | --- |
| `workspaces` | member of it (`id = current_workspace_id()`) | — (only via `createBusiness` server action, service role) | office only, own workspace | never |
| `accounts` | own row (`id = auth.uid()`) | — (trigger on `auth.users`) | own row | never (cascade from `auth.users`) |
| `memberships` | own workspace | — (server actions only) | office only, own workspace (role changes) | office only, own workspace, not owner/self (also enforced in code) |
| `customers` | own workspace | any member | any member | any member (blocked in code when jobs exist) |
| `jobs` | own workspace | any member | any member, **except**: `status` may only move along `TRANSITIONS` (enforced in code, not RLS) | office only (code also requires zero invoices) |
| `line_items` | own workspace | any member | **CHANGE:** `status` draft→approved only when `current_role() = 'office'` (use a separate UPDATE policy with `WITH CHECK` on the new row); other fields any member | office only for drafts (reject path); any member for own approved items? **Decide:** delete of an approved item = office only as well (it changes money). Implement as: DELETE requires office. |
| `costs` | own workspace | any member | never (costs are corrected by delete + ledger adjustment, as in v2) | any member (code writes the offsetting ledger adjustment) |
| `photos` | own workspace | any member | caption only, any member | any member (code also removes the Storage object — **CHANGE** from v2, which orphaned the blob; see §6) |
| `voice_notes` | own workspace | any member | never | never (notes are history) |
| `invoices` | own workspace | office only | office only (status draft/sent/overdue; `paid` only via payment flow in code) | never |
| `payments` | own workspace | office only | never | never |
| `ledger_entries` | own workspace | service-role / server actions only (no direct client insert) | **never** | **never** |
| `price_books`, `price_book_items` | own workspace | office only | never (new version instead) | never |
| `sync_outbox` | own workspace | any member (server action path) | server actions only | never |
| `job_events` | own workspace | server actions only | **never** | **never** |
| `documents` | own workspace | server actions only | **never** | never (a job delete in code deletes its documents only when it has no invoices — same guard as v2) |
| `sync_refs` | own workspace | server actions only | never | never |
| `client_updates` | own workspace | any member | any member (status draft→sent only via the send/mark flows) | any member |
| Advisor tables (§10) | own workspace | per §10 (business prefs: office; account prefs: own row; alerts: server only) | per §10 | never (alerts are answered, not deleted) |
| `sync_conflicts` (§7) | own workspace | server actions only | office only (resolution) | never |

**Field vs office enforcement — the rule:** approval, invoice creation,
payment recording, refunds, delete/archive, price-book versions, exports,
workspace settings, member management, and (new) draft approval/rejection
require **office**. Field accounts can: create/edit jobs and customers,
change job status along the machine, capture photos/voice notes/costs,
draft line items and client texts, and sync. This closes the v2 gap where
`saveLineItem`/`deleteLineItem` were not office-gated (INVENTORY.md
§10.1.1). Enforcement lives in **both** layers: RLS policies above for the
coarse boundary, and the Server Action role check (the port of v2's
`requireOffice`, extended to draft approval) for the fine boundary. A
field member calling an office action gets the same plain-language error
v2 used ("That's an office job — …").

**Service-role use:** only in server code (Route Handlers / Server Actions
via `createClient` with the service key) for: ledger/event inserts (to
satisfy the no-direct-insert policies), Storage admin (signed URLs are
minted with the service client or with RLS-scoped storage policies — prefer
storage RLS, §6), Stripe webhook processing, and the `createBusiness`
transaction. The service key never reaches the browser.

---

## 6. Storage bucket design (photos)

- **Bucket:** `job-photos`, **private** (no public access). Created in the
  Supabase dashboard / migration (`insert into storage.buckets`).
- **Paths:** `<workspace_id>/<job_id>/<uuid>.<ext>` — replaces v2's
  `jobs/<jobId>/<ms>-<rand>.<ext>` (adds the workspace segment so a path
  alone proves tenancy). `photos.blob_key` stores this path;
  `photos.storage_provider` = `'supabase_storage'`.
- **Upload path:** browser → client resize first (keep v2's rule: max edge
  1400px, JPEG quality 0.82, via canvas — same `fileToResizedBase64`
  behaviour) → upload to a **presigned upload URL** minted by a Route
  Handler (or direct `supabase.storage.from('job-photos').upload()` from
  the browser client with a storage RLS policy restricting to
  `auth.uid()` members and the workspace path prefix). Prefer direct
  browser upload with storage policies; fall back to a Route Handler if
  policy authoring proves awkward.
- **Read path:** `getJob` returns **signed URLs** (1-hour expiry) minted
  server-side, never public URLs. Do not store signed URLs in the DB.
- **Validation:** MIME allowlist `image/jpeg, image/png, image/webp`
  (enforced in the Route Handler / storage policy AND the Server Action,
  as v2 did); per-file cap **10 MB** post-resize (resized photos are
  typically < 500 KB; the cap is a guard, not a target).
- **Quota:** per-workspace soft cap **5 GB** (configurable via
  `WORKSPACE_STORAGE_CAP_BYTES`). Enforced in code: `workspaces.storage_used_bytes`
  is incremented on upload and decremented on delete (single transaction
  with the `photos` row write); uploads beyond the cap are rejected with a
  plain-language error. **CHANGE from v2:** `deletePhoto` also deletes the
  Storage object and decrements the counter — v2 orphaned the blob.
- **Storage RLS policies:** `SELECT`/`INSERT`/`DELETE` on
  `storage.objects` where `bucket_id = 'job-photos'` and the object path's
  first segment = `current_workspace_id()` (as text), and the caller is a
  member. (Implement with `storage.foldername(name)[1]`.)
- **No original-file retention rule beyond this:** the resized upload IS
  the stored file (same as v2 — the phone never uploads the full-size
  original). Note it in the README so nobody is surprised later.

---

## 7. Offline outbox design (extended) + conflict rule

Keep v2's design (§6.2 of the inventory) and fix its three weaknesses:

1. **Queue storage — CHANGE:** move the device queue from `localStorage`
   (`cc-outbox-v1`, ~5 MB limit, and v2 silently swallowed quota errors)
   to **IndexedDB** (via `idb-keyval` or equivalent tiny wrapper) under the
   same logical key. Photos as base64 in the queue are the reason: a few
   photos already strain `localStorage`. Keep the same record shape
   `{clientId, kind, payload}` and the same 7 kinds.
2. **Coverage — already complete in v2, keep it:** `customer` and `job`
   creation go through the queue (with `sync_refs` resolution), plus
   `voice_note`, `photo`, `cost`, `status_change`, `note`. A queued job
   whose customer hasn't synced yet fails with "…hasn't synced yet — it
   will retry" and stays queued (do not drop it).
3. **Sync triggers:** same as v2 — on app-ready, on `online`, on demand
   ("Sync now"), and immediately after each capture (best-effort). Add a
   **retry back-off**: a failed capture is retried on the next sync, not in
   a tight loop; `pushCaptures` batch stays ≤ 100. Keep per-capture
   results (`applied | skipped | failed` + error) and the visible "N to
   sync" badge + Setup sync screen (counts + recent 30 + errors).
4. **Idempotency — unchanged:** server dedupes on
   `(workspace_id, client_id)`; already-`applied` ⇒ `skipped`. `sync_refs`
   maps offline-created customer/job refs to real ids (unique on
   `(workspace_id, entity, client_ref)` — fixed, §4.1).

### 7.1 Conflict rule (new — v2 had none)

v2 failed a queued `status_change` outright when the job had already moved,
and direct online edits were last-write-wins. The standalone rule,
decided in the task brief and to be implemented as specified:

- **Field captures append, never overwrite office fields.** Voice notes,
  photos, costs, and notes always apply (they only ever add rows). A queued
  `cost` or `note` never conflicts.
- **Money fields are office-wins.** A queued capture never changes an
  invoice, payment, price, or approved line item. There is no queued kind
  that writes money fields (keep it that way — do not add one).
- **Job detail edits (title/description/address/date) and status changes
  can clash.** Rule: if the job's `updated_at` (or status) changed on the
  server after the capture was queued, do **not** silently overwrite and do
  **not** silently fail. Instead:
  - Mark the capture `failed` with a conflict error AND write a row to a
    new **`sync_conflicts`** table:
    `id, workspace_id, job_id, outbox_id, kind ('status_change' |
    'job_edit'), field_payload jsonb, server_value jsonb, state
    ('open'|'resolved'), resolved_by uuid, resolution ('kept_office' |
    'applied_field'), created_at, resolved_at`.
  - Surface open conflicts in Setup (sync screen) and as a Money-tab
    follow-up ("1 sync conflict needs a look") — an office member resolves
    each one by picking **Keep office version** (discards the field change)
    or **Apply field change** (applies it through the normal status
    machine / edit path, logging a `job_events` row with the resolver's
    name). Resolution writes the outcome into `sync_conflicts` and marks
    the outbox row `applied` (if applied) or leaves it `failed` with the
    resolution noted.
  - A queued `status_change` whose transition is still legal applies
    normally (no conflict) — a conflict is only when the server state
    moved in a way that makes the capture's intent ambiguous (status no
    longer the one the capture was based on, or the job was archived /
    cancelled / invoiced past the capture's target).
- **Ordering guarantee to keep:** captures apply in queue order; a job
  capture that references an unsynced customer stays `failed`-retryable,
  never a conflict.

---

## 8. Provider adapters to preserve

Port v2's `providers = {storage, payments, sms, ai}` object 1:1 in shape
(`lib/adapters/`), same interface names, new implementations:

| Adapter | Interface (same as v2) | Standalone implementation | Notes |
| --- | --- | --- | --- |
| Storage | `put(key, bytes, contentType)`, `getUrl(key)` | `SupabaseStorage` — `supabase.storage.from('job-photos')`; `getUrl` mints a 1-hour signed URL | `name: 'supabase_storage'` (replaces `local_blobs`); `photos.storage_provider` records it |
| Payments | `record({amountCents, method}) → {providerRef}` | `ManualPayments` unchanged (`manual`, `providerRef: null`) — customer card payments are **Stage 4**, out of scope here | The Stripe adapter for *customer* payments is a separate Stage 4 task; do not build it now. The *subscription* Stripe wiring (§9) is a different adapter surface (`lib/stripe/`), not this one. |
| SMS | `send({toPhone, message}) → {delivered, note}` | `DraftSms` unchanged (`draft_only`, always `delivered: false`) | Real texting is Stage 4, one provider at a time, with Rob's approval. `sendClientUpdate` still only marks `sent` when `delivered` is true. |
| Advisor | `extractLineItems(ctx, transcript) → {items[]}` | `BuiltInAdvisor` — same prompt + zod schema as v2 (never invent a price; null price when none stated; hours-only note → one labour item with null price). **Inference provider TBD by the implementing worker:** v2 used the artifact's built-in inference, which does not exist in Next.js. Options in order: (a) a small/cheap model via an env-configured provider the team already has access to, (b) a rules-only fallback that extracts nothing and returns an empty list with the existing "couldn't be created" note. **Do not** invent a paid subscription or sign up for a new AI service to solve this — if (a) has no already-available provider, ship (b) and flag it as a blocker for the Advisor extraction step. The extraction must never block saving the note. | Phase 2 adds one method to this same interface (§10). Internal naming (`ai`, `AiProvider`) stays — it never reaches users. |

Adapter names are **not** shown raw to users in the standalone — Setup's
Connected services rows show human labels ("Built in", "By hand",
"Drafts only", "Supabase Storage") with the adapter name in a tooltip/
detail line only. (Fixes INVENTORY.md §9, caveat 2.)

---

## 9. Stripe test-mode wiring plan

Scope: **the contractor's own subscription only** (Contractor Corner
charging the contractor, e.g. BTYH $100/mo). Customer card payments
(BTYH's customers paying BTYH through the app) are **deferred to Stage 4**
and are out of scope — `recordPayment` stays manual in this stage.

1. **Keys (test mode only):** `STRIPE_SECRET_KEY` (`sk_test_…`),
   `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY` (`pk_test_…`), and
   `STRIPE_WEBHOOK_SECRET` (`whsec_…`) for the test webhook endpoint.
   Test keys come from the **connected Stripe connector** — never from
   chat, never pasted into code or docs. Live keys are never introduced
   in this stage; any code path that would accept a `sk_live_` key must
   refuse it (fail fast at boot with a clear error).
2. **Test product/price:** in the Stripe **test-mode** dashboard (or via
   the connector), create product "Contractor Corner" with a recurring
   test price of **$100/mo** (the BTYH plan figure — Rob's plan, not a
   price Cherylene agreed to). Record its price id in
   `STRIPE_PRICE_ID`. Do not create any other product/price in this stage.
3. **Checkout:** a Setup → Billing section (office + owner only) with a
   "Start subscription" button → Stripe Checkout (test mode) for the
   $100/mo price → success/cancel return URLs on the app. Store
   `stripe_customer_id` + `stripe_subscription_id` + status on
   `workspaces` from the webhook, not from the redirect.
4. **Webhook:** `app/api/stripe/webhook/route.ts`, signature-verified with
   `STRIPE_WEBHOOK_SECRET`, handling (test mode):
   `checkout.session.completed`, `customer.subscription.created/updated/
   deleted`, `invoice.payment_failed`. Update `workspaces.subscription_*`
   columns. `payment_failed` surfaces as a Setup banner ("Your
   subscription payment failed — update your card in the billing portal")
   with a link to the Stripe billing portal (test mode). No dunning
   emails in this stage.
5. **Billing portal:** link to Stripe's customer portal (test mode) for
   card update / cancel. Cancelling ends access at period end; the app
   must not hard-lock a business out of its own data on cancellation —
   read-only access to export data remains (same principle as the CSV
   export: the business's data is theirs).
6. **Free-tier gate:** the 5-free-jobs/month limit is display-only in v2
   and unenforced. Decision needed before wiring enforcement (see §12):
   either enforce it server-side in `saveJob` (count jobs created this
   month in the workspace; reject the 6th with a plain-language message
   pointing at Billing) or drop it when the paid plan exists. **Do not
   silently enforce it** — pick one, record it, implement that one.
7. **What Stripe never touches in this stage:** invoice payments from
   BTYH's customers, refunds via Stripe (refunds stay manual ledger
   entries), SMS, or Advisor inference. The `payments.provider` /
   `provider_ref` columns are ready for Stage 4 (PaymentIntent id) but
   stay `manual` / null now.

---

## 10. Advisor — Phase 1 rules-only checks (no inference calls)

Source: the Advisor onboarding evaluation. **Phase 0 (rename) is done**
(INVENTORY.md §9). This stage implements **Phase 1 only**: the trimmed
questionnaire, the preferences tables, the Setup section, and **rule-based
checks — zero inference calls, zero added running cost**.

### 10.1 New tables

| Table | Columns | Rules |
| --- | --- | --- |
| `advisor_business_preferences` | `id` identity PK; `workspace_id bigint NOT NULL UNIQUE REFERENCES workspaces(id)`; `check_forgotten_expenses boolean DEFAULT true`; `check_missing_material_labour boolean DEFAULT true`; `check_unpaid_invoices boolean DEFAULT true`; `check_cost_overrun boolean DEFAULT true`; `check_low_margin boolean DEFAULT true`; `margin_floor_percent integer DEFAULT 20`; `overrun_threshold_percent integer DEFAULT 100`; `proactiveness text CHECK IN ('conservative','balanced','detailed') DEFAULT 'balanced'`; `advisor_enabled boolean DEFAULT true` (master off switch); `updated_at timestamptz` | One row per business. Set once by the business owner during creation (questionnaire), editable later in Setup by **office only**. Turning `advisor_enabled` off stops all checks **and** hides all alerts. |
| `advisor_account_preferences` | `id` identity PK; `workspace_id bigint NOT NULL REFERENCES workspaces(id)`; `account_id uuid NOT NULL UNIQUE REFERENCES accounts(id)`; `surfacing text CHECK IN ('important_only','important_and_savers','everything') DEFAULT 'important_only'` | One row per account. Personal surfacing only — it changes highlighting, never whether an alert exists. Editable by the account themselves in Setup. |
| `advisor_alerts` | `id` identity PK; `workspace_id bigint NOT NULL`; `job_id bigint REFERENCES jobs(id)`; `check_type text NOT NULL` (one of the five checks, §10.2); `document_id bigint REFERENCES documents(id)` (nullable — the frozen version checked, for suppression); `severity text CHECK IN ('high','medium','low')`; `state text CHECK IN ('open','reviewed','accounted_for','dismissed') DEFAULT 'open'`; `figures jsonb NOT NULL DEFAULT '{}'` (the numbers the alert was raised from); `message text NOT NULL`; `answered_by uuid REFERENCES accounts(id)`; `answered_at timestamptz`; `created_at timestamptz`; UNIQUE(`workspace_id`, `job_id`, `check_type`, `document_id`) where state handling requires it — enforce "same job, same check, same document version: never raised again once answered" in code (see §10.3) | The suppression memory. Alerts are **read-only**: "Review" links to the relevant job section; the Advisor gets no edit action. Answering an alert is a business-level act — record who answered and how in `job_events` (new event types `advisor_alert_answered` — add to the enum). |
| `advisor_usage_monthly` | `id` identity PK; `workspace_id bigint NOT NULL`; `month text NOT NULL` (`YYYY-MM`); `inference_calls integer NOT NULL DEFAULT 0`; `ceiling integer NOT NULL DEFAULT 50`; UNIQUE(`workspace_id`, `month`) | The usage counter. Phase 1 makes **zero** inference calls, so this stays at 0 — it exists now so Phase 2's ceiling check has somewhere to live. Ceiling default 50 calls/business/month (tunable via env `ADVISOR_MONTHLY_CEILING`); hitting it turns inference off while rules keep running. |

### 10.2 The five Phase 1 checks (all rules, all explainable from the job's own figures)

| Check | Rule | Severity | When it runs |
| --- | --- | --- | --- |
| Unpaid invoices | Invoice past due date with balance > 0 | high | Dashboard compute (already a follow-up in v2 — this check is the on/off switch for it) |
| Jobs costing more than expected | Logged costs ≥ `overrun_threshold_percent`% of the approved quote (default 100% — costs have passed the quote) | high | When a cost is added; dashboard compute |
| Forgotten expenses | Issued estimate (frozen copy) has material + labour lines but **no** `other` line and no line mentioning disposal / dump / travel / delivery | medium | When an estimate is issued (against the frozen copy) |
| Estimates with no materials / no labour | Issued estimate has no `material` lines at all, or no `labour` lines at all | medium | When an estimate is issued (against the frozen copy) |
| Estimates priced below your level | Margin implied by the estimate's own lines < `margin_floor_percent`% (default 20%) | medium | When an estimate is issued (against the frozen copy) |
| Drafts waiting | (Already a v2 follow-up; kept as an alert source so it can be surfaced/answered the same way) | low/medium | Dashboard compute |

Out of scope for Phase 1 (return with their foundations — per the
evaluation): scheduling conflicts, change orders, permits, labour-hours
underestimated, profitability patterns (need ≥5 finished jobs of a similar
type — floor to be confirmed, §12), and the catch-all "other things I might
be overlooking" (never a check). Question 2's priorities (save money / save
time / …) are **held back** from onboarding; they only re-rank alerts and
return in Phase 2 as a Setup option.

### 10.3 Behaviour rules (from the evaluation — all mandatory)

- **Triggers are events, not screens.** Checks run when an estimate is
  issued, a cost is recorded, an invoice's due date passes with a balance,
  or a job is marked done. Nothing runs on page load. Dashboard follow-ups
  are computed from the same data (extend `getDashboard`).
- **One feed, not a new channel.** Alerts land in the existing dashboard
  follow-ups, tagged as Advisor items, and on the job's own page in the
  relevant section. No modals, no pop-ups, no push/email/text (no channel
  exists). At most **one Advisor alert highlighted per job per day** in the
  feed; the rest wait quietly on the job page.
- **Suppression is keyed to the document.** Same job + same check + same
  frozen document version, once answered (Review / Already accounted for /
  Dismiss), is never raised again. A re-issued estimate is a new version,
  so the check may run once on it. Dismissing a category three times in a
  row prompts **once** to turn that check off in Setup (a suggestion, never
  a silent settings change).
- **Wording is always a question, never an accusation** ("Have you
  accounted for disposal on this estimate?"), and every alert says what was
  checked ("no expense line on this estimate"), never that the estimate is
  complete. Every alert is labelled as one of: **a figure from the job's
  own records / an assumption to check / a recommendation** — no mixing.
- **Offline-safe:** checks run on the server when the triggering event
  syncs; never delay or block the sync itself.
- **Priority is arithmetic:** sort by dollars overdue, dollars over quote,
  margin points below the set level, then days stale. Personal surfacing
  settings re-weight groups per person; they never hide an alert from the
  office.
- **No invented numbers, ever.** A figure comes from the job, the price
  book, or the ledger, or it is not stated.
- **Master off switch** in Setup stops all checks and hides all alerts for
  the business.
- **Minimums before alerting:** estimate checks run only on *issued*
  estimates; overrun checks only once at least one cost is logged; pattern
  observations only past the finished-job floor (Phase 2).

### 10.4 The trimmed questionnaire (one screen, after business creation, creator only, skippable)

Title: **"Let's make Contractor Corner work smarter for you"** — subtitle:
"Tell us what you'd like a second set of eyes on. We'll look for
opportunities to save you time, protect your profits, and help you avoid
overlooking important details."

- **What should your Advisor keep an eye on?** (business settings — the
  owner can change these any time in Setup): forgotten expenses (travel,
  disposal, misc.); estimates with no materials or no labour; invoices that
  haven't been paid; jobs whose costs are running over the quote; estimates
  whose margin falls below the level you set.
- **How much should your Advisor surface to you?** (personal — each
  teammate picks their own): Only what's important *(default)* / Important
  things, plus anything that could save money or time / Everything it finds,
  quietly, in my follow-ups.
- **How thorough should it be?** Conservative — only flag clear problems /
  Balanced — flag meaningful problems and opportunities *(default)* /
  Detailed — look for smaller details too.
- Buttons side by side, equal size: **Use these settings** and **Skip —
  use defaults**. Defaults: Balanced, Important only, all five checkable
  items on. Target: under a minute. Joiners skip it entirely and inherit
  the business settings; their personal surfacing choice lives in Setup.

### 10.5 Phase 2 (reserved, not built here)

One Advisor check against the frozen lines when an estimate is issued, for
the categories rules cannot judge — via **one new method on the existing
Advisor provider interface**, called once per issued estimate, cached
against that frozen version, behind the monthly ceiling in
`advisor_usage_monthly`. Pattern observations once a business passes the
finished-job floor, always shown with their numbers ("On your last 6 door
jobs, labour ran about 20% over the estimate" — never "you usually
underestimate labour"). Nothing in Phase 2 changes the Phase 1 tables.

---

## 11. Env var list

No secrets in this doc, in code, or in chat. All values come from the
Supabase dashboard / Stripe connector / Vercel project settings.

| Variable | Where it comes from | Required |
| --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase project URL — **needed from Rob** (see §14a) | Yes |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Supabase project anon key — **needed from Rob** | Yes |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase project service-role key — **needed from Rob** (server only; never `NEXT_PUBLIC_`, never in the browser bundle) | Yes |
| `STRIPE_SECRET_KEY` | Stripe **test** secret key, from the connected Stripe connector | Yes (billing) |
| `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY` | Stripe **test** publishable key | Yes (billing) |
| `STRIPE_WEBHOOK_SECRET` | Stripe test webhook secret for `api/stripe/webhook` | Yes (billing) |
| `STRIPE_PRICE_ID` | Test price id for the $100/mo Contractor Corner plan | Yes (billing) |
| `NEXT_PUBLIC_APP_URL` | e.g. the Vercel deployment URL of `contractor-corner-v2` | Yes |
| `ADVISOR_MONTHLY_CEILING` | Optional; default 50 inference calls/business/month | No |
| `WORKSPACE_STORAGE_CAP_BYTES` | Optional; default 5 GB | No |
| `NEXT_PUBLIC_FREE_JOB_LIMIT` | Optional; default 5 (only if the limit is enforced — see §9.6 / §12) | No |

`.env.example` in `v2/` lists these names with placeholder text only
(`https://your-project.supabase.co`, `sk_test_…`). **Never commit a real
`.env.local`.** Vercel env vars are set in the `contractor-corner-v2`
project settings (all environments, or Production only for the service key
— the implementing worker should prefer Production + Preview, not
Development, for the service-role key).

---

## 12. Decisions needed before / during implementation

These are Rob's (or the parent orchestrator's) calls. The spec does not
assume answers; where a default is given, it is marked.

1. **Walkthrough gating (parity review — the gating issue).** 14 Nov: "no
   walkthrough needed"; 15 Nov: Cherylene's customer-to-payment walkthrough
   is the most important outstanding item and gates workflow features.
   **This stage builds no workflow features either way** (tasks, change
   orders, scheduling, portal, missed-call text-back are all out of scope
   here), so the rebuild is not blocked — but the decision must be recorded
   before Stage 4 planning starts.
2. **Free-tier limit: enforce or drop?** (§9.6). Default recommendation:
   enforce server-side once billing exists (it is the only honest basis for
   a paid tier), with the limit shown in Jobs + Setup as today.
3. **Advisor thresholds:** cost-overrun trigger (default: costs ≥ 100% of
   quote), default margin floor (default 20%), finished-job floor for
   pattern observations (evaluation suggests 5). Confirm or change.
4. **Advisor split + trim:** confirm business-wide check settings (owner/
   office) vs personal surfacing (per account), the five-item trimmed
   questionnaire, and placement after business creation for the creator
   only.
5. **Phase 1 is rules-only:** confirm no inference calls until Phase 2, so
   the first version adds zero running cost.
6. **Research tab:** the v2 Research tab contains the remaining
   user-facing "AI" strings (quoted competitor product names) and is
   internal planning material shipped in the customer app. Options: (a)
   drop it from the standalone app and keep the content in `v2/docs/`
   (recommended); (b) keep it behind an office-only flag; (c) keep as-is.
   **Default: (a).** Do not ship it to BTYH as a customer-facing tab.
7. **Field-join role:** §2.2 changes join to field-only by default (office
   promotes afterwards). Confirm, or restore v2's self-picked role.
8. **Invite-code join without owner approval:** keep as-is (code = access)
   or add an owner-approval step. Default: keep as-is; rotation is the
   revocation mechanism.
9. **Overpayment / draft-invoice refund quirks** (INVENTORY.md §10.2.17–18):
   keep v2's behaviour (accept overpayment, clamp the displayed balance;
   allow refund on any invoice with payments) or tighten (reject
   overpayment; require invoice `sent`+ for refunds). Default: tighten —
   reject overpayment with a plain message, and require the invoice to be
   `sent` or `overdue` before a refund.
10. **Storage cap number:** 5 GB default — confirm, or set from BTYH's
    actual photo usage once measured.
11. **Advisor inference provider** (§8): v2's built-in inference does not
    exist in Next.js. If no already-available provider exists, ship the
    rules-only fallback for extraction and flag it — do not buy or sign up
    for anything.

---

## 13. Go-live cost table (planning figures — verify at purchase time)

All figures are the planning numbers from the parity review / task brief.
**Nothing here is a purchase approval.** Each spend needs Rob's separate
approval for that specific spend, and no profit figure may be quoted to
anyone until one real month of BTYH usage has been measured with the real
providers switched on.

| Item | Cost | When it starts | Approval needed |
| --- | --- | --- | --- |
| Vercel `contractor-corner-v2` | **Free** (Hobby) now; **~$20/mo Pro** when going live for charging | Pro only when BTYH is ready to be charged | Rob, separately |
| Supabase | **Free tier** for build/test; **~$25/mo Pro** when going live | Pro only when live data + auth + storage are in production use | Rob, separately |
| Stripe | **2.9% + $0.30 per payment** (on the subscription itself and, from Stage 4, on customer card payments). No monthly fee. Test mode is free. | When the first real subscription is taken | Rob, separately (test keys only in this stage) |
| SMS provider | **$0** — draft-only, no provider connected | Stage 4, one provider at a time | Rob, separately |
| Advisor inference | **$0 in Phase 1** (rules only). Phase 2 is usage-priced and unmeasured. | Phase 2 | Rob, separately |
| Photo/file storage | Included in Supabase tier at time of purchase; grows with every job — watch `storage_used_bytes` per workspace | Ongoing | — (cap enforced in code, §6) |
| Monthly support touchpoint (HandOff-equivalent) | Rob's time — a real cost of keeping the account; not a line item above | When BTYH is live | — |

Arithmetic that must **not** be quoted as profit: $100 (BTYH plan, Rob's
figure, not agreed) − $20 (Vercel Pro) − $25 (Supabase Pro) = $55 before
Stripe's cut on the subscription (~$3.20), SMS, Advisor inference,
storage overage, the support call, and Rob's time. The parity review is
explicit: **do not quote a $50 (or any) profit figure** until a real month
is measured.

---

## 14. Known blockers (do not try to solve by spending or by asking for secrets in chat)

**(a) No Supabase project for Contractor Corner is known.** A grep of the
workspace found no `supabase.co` project URL, and there is no Supabase
connector in Muse. The app takes all Supabase config from env vars
(§11). **What the parent needs from Rob:** a Supabase project URL +
anon key + service-role key (paste via the secure flow, never in chat),
**or** a new free project created in his Supabase dashboard. No
implementation work that needs a live database can start until this
lands — the implementing worker can still write migrations, schema, and
UI against the spec, but cannot verify against a live project.

**(b) Vercel API access to the `precision-web-concepts` team scope is
currently 403-blocked** and needs a re-auth (`authorize_team_access`)
that only Rob can approve via a link. **Deploy is blocked until then.**
The deploy worker will surface that link; this spec assumes the new
`contractor-corner-v2` project (Hobby, rootDirectory `v2`) is created
once access is restored. Nothing in this stage deploys into the existing
`contractor-corner` project.

**(c) Stripe test mode only.** The Stripe connector is connected; test keys
come from the connector, never from chat. No live keys in this stage; code
must refuse `sk_live_` at boot. Customer card payments are Stage 4.

**(d) Advisor extraction inference provider.** v2's built-in inference
does not exist outside the artifact (§8). If no already-available provider
exists, extraction ships as the rules-only fallback and is flagged — not
solved by buying a service.

---

## 15. Migration / build order for the implementing workers

Suggested order (each step verifiable before the next starts):

1. **Scaffold** `v2/` (Next.js + Supabase clients + env example + README).
   Verify: builds, serves the sign-in page, no secrets committed.
2. **Migrations** (§4): workspaces/accounts/memberships first, then the
   job/money tables, then sync + Advisor tables. Verify: `supabase db push`
   against a dev project (blocked on §14a for a shared project — a worker's
   own throwaway project is acceptable for verification if Rob's project
   is not ready; do not treat that as the production project).
3. **Auth + onboarding** (§2): sign-up/sign-in, create/join business,
   `getSession` stages, invite codes. Verify: two test accounts, one
   business, second account joins by code as field.
4. **Core actions port** (INVENTORY.md §4, groups 4.3–4.6): customers,
   jobs, line items, costs, photos (Storage, §6), estimates/invoices/
   payments/refunds, ledger + events. Verify: the full quote-to-cash loop
   for one job, and the ledger re-adds up.
5. **Sync** (§7): outbox in IndexedDB, `pushCaptures`, `sync_refs`,
   conflict surface. Verify: offline job + customer creation, retry
   idempotency (same `clientId` twice ⇒ one row), conflict surfacing.
6. **Dashboard / Money / Prices / Setup** (port the v2 screens; black/
   silver/gold theme, logo assets, jump-nav, scroll-to-top, Getting
   Started checklist). Verify against the inventory's screen list.
7. **Advisor Phase 1** (§10): questionnaire, preferences, five rule
   checks, alerts feed + suppression. Verify: each check fires and
   suppresses exactly as specified; zero inference calls.
8. **Stripe test-mode subscription** (§9): test product/price, Checkout,
   webhook, Billing section. Verify end-to-end in test mode only.
9. **Vercel deploy** to `contractor-corner-v2` (Hobby) — blocked on §14b.
   Verify: production deployment serves the app; v1 demo untouched.
10. **Handover checks:** RLS spot-checks (second business cannot see the
    first's rows; field cannot approve drafts via the API), CSV export,
    storage quota, "AI" string sweep of all user-facing copy (must be zero
    outside quoted competitor names — and the Research tab is gone per
    §12.6, so zero, period).

**Do not** merge `standalone-v2` into `main` as part of this stage, do not
redirect the v1 domain, and do not message BTYH. The v1 demo stays live
until the standalone is verified and Rob says to switch.

---

*Architecture spec prepared 2026-11-21 by Worker 1 (Stage 3), from the
v2 inventory in `INVENTORY.md`. Branch `standalone-v2` in
`Darknezz-0/contractor-corner`, from main `95d0ccf`.*
