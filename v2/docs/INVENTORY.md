# Contractor Corner — v2 Code Inventory

Stage 3 standalone rebuild, Worker 1. Read from the running v2 artifact
(`~/workspace/ts-spaces/contractor-corner/`, space slug `contractor-corner`),
**not** from design notes. A feature is listed as built only when the code
does it. All line numbers refer to the v2 files as read on 2026-11-21.

Sources read in full:

- `server/src/schema.ts` — 365 lines, 19 tables
- `server/src/actions.ts` — 2,903 lines, **43 actions**
- `client/src/App.tsx` — 4,291 lines
- `client/src/api.ts` (20 lines), `client/src/main.tsx`, `client/src/theme.css`
  (80 lines), `client/src/research.tsx` (Research tab content)
- `drizzle/0001_initial.sql`, `0002_contractor_corner_backend_tables.sql`,
  `0003_stage_1_foundations_accounts_events_snapshots.sql`
- `space.json` — slug `contractor-corner`, runtime `typescript`
- Background: `contractor-corner-parity-review.md`,
  `contractor-corner-ai-onboarding-evaluation.md` (both read in full)

Companion doc: `ARCHITECTURE.md` (the standalone target this inventory feeds).

---

## 1. At a glance

| Item | Count / value |
| --- | --- |
| Server actions (`defineAction` in `actions.ts`) | **43** |
| Server helper functions (non-action) | 17 (see §3) |
| Schema tables | **19** (one, `members`, is dead — see §2.1) |
| Client top-level tabs | 6: Jobs, Customers, Money, Prices, Research, Setup |
| Client components in `App.tsx` | ~30 (see §5) |
| Job statuses | 8 (`lead, quoted, scheduled, in_progress, done, invoiced, paid, cancelled`) |
| Outbox capture kinds | 7 (`voice_note, photo, cost, status_change, note, customer, job`) |
| Ledger entry types | 5 (`invoice_issued, payment_received, cost_recorded, refund, adjustment`) |
| Job event types | 22 (see §6) |
| Free-tier job limit | 5/month — counted and displayed, **never enforced** (see §8.4) |
| Money unit | Integer cents everywhere; profit = approved quote − costs |

---

## 2. Schema — all 19 tables (`server/src/schema.ts`)

Every business record carries `workspace_id` (tenant id). All server reads
and writes scope to the caller's workspace (derived from the signed-in
account's membership — no hard-coded workspace anywhere in the actions;
the single hard-coded id is the one-time claim bridge for workspace 1, §4.5).

| # | Table | Key columns / enums | Notes |
| --- | --- | --- | --- |
| 1 | `workspace` | `id` PK; `business_name`, `trade`; `owner_account_id` (nullable = unclaimed); `invite_code` (6 chars); `updated_at` | One row per business |
| 2 | `accounts` | `id` PK; `identity_key` UNIQUE; `display_name` | One row per verified platform identity (`ctx.viewer`); **no password, no email column** |
| 3 | `memberships` | `id` PK; `account_id` FK→accounts (UNIQUE — one business per account); `workspace_id`; `role` enum `field\|office` | The tenancy + role join |
| 4 | `members` | `id` PK; `workspace_id`; `name`; `role` | **DEAD TABLE — no action references `schema.members`** (only `memberships` + `accounts` are used). Drop in the rebuild; do not migrate data from it (there is none reachable). |
| 5 | `customers` | `id` PK; `workspace_id`; `name`, `phone`, `email`, `address`, `notes` | Delete blocked when jobs exist |
| 6 | `jobs` | `id` PK; `workspace_id`; `customer_id` FK; `title`, `description`, `address`; `status` enum (8); `scheduled_date` TEXT `YYYY-MM-DD` (single date, no times); `archived_at` nullable; `created_at`, `updated_at` | `archived_at` set = hidden from working lists, money trail kept |
| 7 | `line_items` | `id` PK; `workspace_id`; `job_id` FK; `description`; `qty` REAL; `unit_price_cents` INT; `kind` enum `labor\|material\|other`; `source` enum `manual\|voice_draft\|price_book`; `status` enum `draft\|approved`; `price_book_version` nullable INT | Drafts never count toward quote totals |
| 8 | `costs` | `id` PK; `workspace_id`; `job_id` FK; `description`; `amount_cents` INT; `kind` enum `material\|labor\|other` | No person/hours/supplier fields |
| 9 | `photos` | `id` PK; `workspace_id`; `job_id` FK; `blob_key`; `storage_provider` (default `local_blobs`); `kind` enum `before\|after\|receipt\|site`; `caption` | Blob key format `jobs/<jobId>/<ms>-<rand>.<ext>` |
| 10 | `invoices` | `id` PK; `workspace_id`; `job_id` FK; `number` TEXT (`INV-1001+n`); `total_cents`; `status` enum `draft\|sent\|paid\|overdue`; `issued_date`, `due_date` TEXT | `paid` is derived, never set by hand (see §7) |
| 11 | `payments` | `id` PK; `workspace_id`; `invoice_id` FK; `amount_cents` INT (**negative for refunds**); `kind` enum `payment\|refund`; `method` (default `cash`); `provider` (default `manual`); `provider_ref` nullable; `paid_date` TEXT | Paid total of an invoice = plain SUM of its payment rows |
| 12 | `ledger_entries` | `id` PK; `workspace_id`; `job_id` nullable; `invoice_id` nullable; `type` enum (5); `amount_cents` INT signed; `note` | **Append-only**: no action updates or deletes rows |
| 13 | `price_books` | `id` PK; `workspace_id`; `version` INT; `name`; `is_active` INT 0/1 | One row per version; exactly one active per workspace (enforced by update-then-insert, not a DB constraint) |
| 14 | `price_book_items` | `id` PK; `workspace_id`; `price_book_id` FK; `description`; `unit` (default `each`); `unit_price_cents`; `kind` enum | Belong to one version; never edited after creation |
| 15 | `sync_outbox` | `id` PK; `workspace_id`; `client_id` TEXT; UNIQUE `(workspace_id, client_id)`; `kind` enum (7); `payload_json` TEXT; `status` enum `pending\|applied\|failed`; `error` nullable; `applied_at` nullable | Server-side mirror of the device queue; retry-safe by `client_id` |
| 16 | `job_events` | `id` PK; `workspace_id`; `job_id` FK; `account_id` nullable; `actor_name`; `type` enum (22); `detail` | **Append-only** job audit trail |
| 17 | `documents` | `id` PK; `workspace_id`; `job_id` FK; `invoice_id` nullable; `kind` enum `estimate\|invoice`; `number`; `lines_json` TEXT (JSON array); `total_cents`; `issued_by_name` | Frozen verbatim snapshot at issue time; never edited |
| 18 | `sync_refs` | `id` PK; `workspace_id`; `client_ref` TEXT; UNIQUE `(workspace_id, client_ref)` — **entity is NOT in the index** (see quirk §8.5); `entity` enum `customer\|job`; `entity_id` INT | Maps offline-created client refs → real server ids |
| 19 | `client_updates` | `id` PK; `workspace_id`; `job_id` FK; `kind` enum `estimate\|en_route\|milestone\|payment\|custom`; `message`; `channel` (default `sms_draft`); `status` enum `draft\|sent` | Client texts; `sent` is honest only when a provider delivers (today: never — draft-only) |

Indexes (from the drizzle SQL): `accounts(identity_key)` UNIQUE,
`memberships(account_id)` UNIQUE, `memberships(workspace_id, account_id)`
UNIQUE, `sync_outbox(workspace_id, client_id)` UNIQUE,
`sync_refs(workspace_id, client_ref)` UNIQUE. No other indexes — `listJobs`,
`getDashboard` and `exportData` do per-row follow-up queries (N+1) in code.

### 2.1 Dead / vestigial items

- `members` table: defined, migrated, never read or written by any action.
- `workspace.owner_account_id` is the only ownership marker; there is no
  separate owner role — ownership matters only for "can't change/remove the
  owner" guards.
- `photos.storage_provider` is recorded per photo (`local_blobs`) but never
  branched on at read time.

---

## 3. Server helpers (`actions.ts`, lines 34–664)

| Helper | What it does (exact behaviour to preserve) |
| --- | --- |
| `viewerIdentity(ctx)` | Derives identity key from platform-verified `ctx.viewer`: `local:<userId>`, `peer:<museId>`, `share:<shareId>`, or `local:primary` when no viewer exists. **The `local:primary` fallback must NOT survive into the standalone** — Supabase Auth replaces it. |
| `getAccount(ctx)` | Lookup `accounts` by `identity_key`. |
| `getMembership(ctx, accountId)` | The account's single membership (unique index guarantees ≤1). |
| `requireSess(ctx)` → `Sess` | Every data action starts here. Throws plain-language errors if no account / no membership / workspace gone. Returns `{wsId, accountId, actorName, role, isOwner}`. |
| `requireOffice(sess)` | Throws unless `role === "office"`. Called by 14 actions (see §4.6). |
| `newInviteCode()` | 6 chars from `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (no ambiguous 0/O/1/I/L). |
| `claimableWorkspace(ctx)` | Workspace 1 only: unowned, no memberships, and has a name/trade or ≥1 job/customer. One-time pre-sign-in bridge. |
| `getJobRow(ctx, sess, jobId)` | Job by id **and** workspace; throws "Job not found." otherwise. |
| `jobTotals(ctx, sess, jobId)` | `quoteCents` = Σ `round(qty × unitPriceCents)` over **approved** items only; `draftCents` same over drafts; `costCents` = Σ costs; `profitCents = quote − costs`. |
| `invoicePaidCents(ctx, sess, invoiceId)` | Plain SUM of that invoice's payment rows (refunds are negative). |
| `appendLedger(ctx, sess, entry)` | INSERT-only into `ledger_entries`. No update/delete path exists. |
| `logEvent(ctx, sess, jobId, type, detail)` | INSERT-only into `job_events` with `accountId` + `actorName`. |
| `applyStatusTransition(ctx, sess, jobId, next)` | Enforces `TRANSITIONS` (§6); writes `jobs.status` + `updated_at`; logs `stage_changed` (`"Stage: X → Y"`). |
| `freezeDocument(ctx, sess, {jobId, invoiceId, kind, number})` | Copies the job's **approved** line items verbatim into `documents` (`lines_json`, `totalCents`, `issued_by_name`); returns `{totalCents, lineCount}`. |
| `applyVoiceNote(ctx, sess, jobId, transcript, memberName)` | Saves `voice_notes` row; logs `note_added`; calls Advisor extraction; inserts each extracted item as `line_items` (`source: voice_draft`, `status: draft`, `unitPriceCents: price ?? 0`); returns `{voiceNoteId, draftsCreated, aiNote}`. On extraction failure **or zero items**, the note is still saved and `aiNote` explains ("Saved the note, but no billable items were found in it." / "…couldn't be created this time — the note itself is kept on the job."). |
| `applyCost(...)` | Inserts `costs`; appends ledger `cost_recorded` with **negative** amount; logs `cost_added`. |
| `applyPhoto(...)` | Builds blob key, `providers.storage.put`, inserts `photos`, logs `photo_added`, returns `{photoId, url}`. |
| `applyCustomerCreate(ctx, sess, values)` | Inserts `customers`; returns id. (No job event — customers have no history.) |
| `applyJobCreate(ctx, sess, values)` | Inserts `jobs` (status defaults `lead`); logs `created` ("Job created: <title>"). |
| `monthPrefix(d)` / `todayStr()` | `YYYY-MM` / `YYYY-MM-DD` local-date strings used for month bucketing and `paid_date`/`issued_date`. |
| `statusLabel(s)` | `in_progress` → `"in progress"` (single underscore replace) for error messages. |

---

## 4. Server actions — all 43

`export const Actions = { … } satisfies ActionsModule` (line 674).
Validation is zod on every request; form limits in the client are derived
from these schemas (`actionFields<typeof Actions>()`), so the rebuild must
keep one zod schema per action as the single source of truth for limits.

### 4.1 Sign-in / onboarding (5)

| Action | Inputs | Outputs | Tables touched | Rules |
| --- | --- | --- | --- | --- |
| `getSession` | `{}` | `{stage: no_account\|no_business\|ready, accountName, suggestedName, businessName, role, claimableBusinessName}` | `accounts`, `memberships`, `workspace` | Read-only. `claimableBusinessName` is set only when a claimable workspace exists. |
| `createAccount` | `{displayName 1–80}` | `{ok: true}` | `accounts` | Idempotent: existing account gets its name updated. |
| `createBusiness` | `{businessName 1–120, trade ≤80, role: field\|office}` | `{ok: true}` | `workspace`, `memberships` | Requires account; rejects if account already has a membership. Caller becomes owner (`owner_account_id`) with chosen role; fresh invite code. |
| `joinBusiness` | `{inviteCode 1–20, role}` | `{ok: true, businessName}` | `workspace` (read), `memberships` | Code trimmed + uppercased; rejects unknown/empty code and accounts that already belong to a business. Joiner picks their own role — **no owner approval step**. |
| `claimBusiness` | `{role}` | `{ok: true}` | `workspace`, `memberships` | Claims workspace 1 if claimable (§3); sets owner + invite code if blank; rejects if already in a business or nothing claimable. |

### 4.2 Business / team (5)

| Action | Inputs | Outputs | Tables | Rules |
| --- | --- | --- | --- | --- |
| `getState` | `{}` | `{businessName, trade, accountName, role, isOwner, inviteCode, members[], providers{storage,payments,sms,ai}, jobsThisMonth, freeJobLimit}` | `workspace`, `memberships`, `accounts`, `jobs` | `members[]` = `{id (accountId), name, role, isYou, isOwner}` ordered by membership id. `jobsThisMonth` counts jobs whose `created_at` month == current month. `freeJobLimit` = 5. Provider values are the adapter names (`local_blobs`, `manual`, `draft_only`, `built_in`). |
| `updateWorkspace` | `{businessName ≤120, trade ≤80}` | `{ok: true}` | `workspace` | **Office only.** Sets `updated_at`. |
| `regenerateInviteCode` | `{}` | `{inviteCode}` | `workspace` | **Office only.** Old code stops working immediately. |
| `setMemberRole` | `{accountId, role}` | `{ok: true}` | `workspace` (read), `memberships` | **Office only.** Owner's role cannot be changed. No-op silently if target has no membership row (update matches 0 rows, still returns ok). |
| `removeMember` | `{accountId}` | `{ok: true}` | `memberships` | **Office only.** Cannot remove self or the owner. Deletes the membership row only — the `accounts` row and their authored history (`job_events.actor_name`, documents `issued_by_name`) remain. |

### 4.3 Customers (3)

| Action | Inputs | Outputs | Tables | Rules |
| --- | --- | --- | --- | --- |
| `listCustomers` | `{}` | `{customers[]: {…customer fields, jobCount}}` | `customers`, `jobs` | Ordered by name asc. `jobCount` computed in code. |
| `saveCustomer` | `{id nullable, name 1–120, phone ≤40, email ≤120, address ≤300, notes ≤1000}` | `{id}` | `customers` | Create (via `applyCustomerCreate`) or update by id **scoped to workspace**. Any role. No history event. |
| `deleteCustomer` | `{customerId}` | `{ok: true}` | `customers`, `jobs` (read) | Any role. Throws if the customer has any jobs. Otherwise hard-deletes the customer row. |

### 4.4 Jobs (7)

| Action | Inputs | Outputs | Tables | Rules |
| --- | --- | --- | --- | --- |
| `listJobs` | `{}` | `{jobs[]: {id, customerId, customerName, customerPhone, title, description, address, status, scheduledDate, archived, quoteCents, costCents, profitCents, draftCount, createdAt}}` | `jobs`, `customers`, `line_items`, `costs` | Newest first (id desc). Per-job totals via `jobTotals` (N+1 in code). Includes archived jobs; client filters. |
| `getJob` | `{jobId}` | Full job detail: `job{…, hasMoney, allowedNext[]}`, `lineItems[]`, `costs[]`, `photos[]` (with resolved URLs), `voiceNotes[]`, `invoices[]` (each with `payments[]` incl. refunds), `documents[]` (frozen lines), `events[]` (latest 200, desc), `updates[]` (client texts, desc), `totals{quoteCents, draftCents, costCents, profitCents}` | all job tables | Read-only. `hasMoney` = job has ≥1 invoice. `allowedNext` = `TRANSITIONS[status]`. |
| `saveJob` | `{id nullable, customerId, title 1–160, description ≤2000, address ≤300, scheduledDate nullable (≤10 chars)}` | `{id}` | `jobs` (+ `job_events` on create/update) | Create (via `applyJobCreate`, logs `created`) or update details (**not** status) + logs `edited`. Customer must exist in workspace. **No free-tier limit check** — the 5/month limit is display-only. Any role. |
| `changeJobStatus` | `{jobId, status}` | `{status}` | `jobs`, `job_events` | Via `applyStatusTransition` (§6). Any role. |
| `archiveJob` | `{jobId}` | `{ok: true}` | `jobs`, `job_events` | **Office only.** Sets `archived_at`; logs `archived`. Nothing deleted. |
| `restoreJob` | `{jobId}` | `{ok: true}` | `jobs`, `job_events` | **Office only.** Clears `archived_at`; logs `restored`. |
| `deleteJob` | `{jobId}` | `{ok: true}` | `jobs`, `line_items`, `costs`, `photos`, `voice_notes`, `client_updates`, `documents`, `job_events` | **Office only. Hard delete ONLY when the job has zero invoices** — otherwise throws ("…can't be deleted — that would erase the money trail. Cancel it or archive it instead"). Deletes all child rows including `job_events` and frozen `documents`. No ledger correction (there is nothing to correct: no invoices ⇒ no invoice/payment ledger rows; cost ledger rows for a deleted job are orphaned in the ledger — see §8.6). |

### 4.5 Line items, costs, voice notes, photos (8)

| Action | Inputs | Outputs | Tables | Rules |
| --- | --- | --- | --- | --- |
| `saveLineItem` | `{id nullable, jobId, description 1–300, qty >0 ≤100000, unitPriceCents ≥0, kind, status: draft\|approved}` | `{id}` | `line_items`, `job_events` | Create (`source: manual`) or update. Draft→approved logs `item_approved`; other edits log `item_edited`; creates log `item_added`. **NOT office-gated — a field member can approve drafts through this action** (see §8.1). |
| `deleteLineItem` | `{lineItemId}` | `{ok: true}` | `line_items`, `job_events` | **NOT office-gated.** Deleting a draft logs `item_rejected` ("Draft rejected: …"); deleting an approved item logs `item_removed`. Silent ok if the row is already gone. |
| `addCost` | `{jobId, description 1–300, amountCents ≥0, kind}` | `{id}` | `costs`, `ledger_entries`, `job_events` | Via `applyCost`. Any role. |
| `deleteCost` | `{costId}` | `{ok: true}` | `costs`, `ledger_entries`, `job_events` | **NOT office-gated.** Deletes the cost row but appends ledger `adjustment` **+amount** (offsetting the original negative `cost_recorded`); logs `cost_removed`. Silent ok if gone. |
| `addVoiceNote` | `{jobId, transcript 1–5000, memberName ≤80}` | `{voiceNoteId, draftsCreated, aiNote}` | `voice_notes`, `line_items`, `job_events` | Via `applyVoiceNote` (§3). Transcript is typed/pasted text — **no audio is recorded or transcribed in v2**. Any role. |
| `addPhoto` | `{jobId, kind, caption ≤200, dataBase64, mimeType}` | `{photoId, url}` | `photos`, `job_events` (+ blob storage) | MIME allowlist: `image/jpeg`, `image/png`, `image/webp` only. Client resizes to max edge 1400px, JPEG 0.82 before sending. Any role. |
| `deletePhoto` | `{photoId}` | `{ok: true}` | `photos` | **NOT office-gated.** Deletes the photo row only — the stored blob is **not** deleted (orphaned blob; no storage reclamation). No job event. |
| `addLineItemFromPriceBook` | `{jobId, priceBookItemId, qty >0 ≤100000}` | `{id}` | `price_book_items`, `price_books` (read), `line_items`, `job_events` | Copies description/unit price/kind from the price-book item; `source: price_book`, `status: approved` immediately, stamped `price_book_version` from the owning book. Any role. |

### 4.6 Estimates, invoices, payments, refunds (6)

| Action | Inputs | Outputs | Tables | Rules |
| --- | --- | --- | --- | --- |
| `issueEstimate` | `{jobId}` | `{number, totalCents, lineCount}` | `documents`, `job_events` | **Office only.** Requires approved quote total > 0. Number = `EST-${1001 + count of all estimate documents in workspace}` (count-based — see §8.5). Freezes approved lines via `freezeDocument`; logs `estimate_issued`. Does **not** change job status. |
| `createInvoice` | `{jobId, dueDate nullable}` | `{invoiceId, number, totalCents}` | `invoices`, `documents`, `ledger_entries`, `job_events`, `jobs` | **Office only.** Requires approved quote total > 0. Number = `INV-${1001 + count of all invoices in workspace}`. Total = current approved quote. Status starts `draft`; `issued_date` = today. Freezes lines; appends ledger `invoice_issued` +total; logs `invoice_issued`; if job is `done`, moves it to `invoiced` via the state machine. |
| `updateInvoiceStatus` | `{invoiceId, status: draft\|sent\|overdue}` | `{ok: true}` | `invoices`, `job_events` | **Office only.** `paid` is **not** an allowed input — paid is derived (see `recordPayment`). `sent` logs `invoice_sent`; others log `invoice_status`. |
| `recordPayment` | `{invoiceId, amountCents >0, method 1–30, paidDate 4–10 chars}` | `{invoiceStatus, paidCents, balanceCents}` | `payments`, `ledger_entries`, `job_events`, `invoices`, `jobs` | **Office only.** Via `providers.payments.record` (manual adapter returns `providerRef: null`). Inserts payment row; ledger `payment_received` +amount; logs `payment_recorded`. If balance hits 0: invoice → `paid`, and a job in `invoiced` → `paid` via the state machine. Overpayment is **not** rejected — balance is clamped at 0 for the return value, but the full amount is recorded. |
| `recordRefund` | `{invoiceId, amountCents >0, method 1–30, note ≤300}` | `{invoiceStatus, paidCents, balanceCents}` | `payments`, `ledger_entries`, `job_events`, `invoices`, `jobs` | **Office only.** Requires `paidSoFar > 0` and `amount ≤ paidSoFar` (else throws with the paid amount). Inserts payment row with **negative** amount, `kind: refund`, `paid_date` = today; ledger `refund` −amount; logs `refund_recorded`. If a balance reopens on a `paid` invoice: invoice → `sent`, and a `paid` job → `invoiced` via the state machine. |
| `exportData` | `{}` | `{customersCsv, jobsCsv, moneyCsv}` | `customers`, `jobs`, `ledger_entries`, `invoices`, `line_items`/`costs` (via totals) | **Office only.** Three CSVs built in code with quote-escaping: customers (Name, Phone, Email, Address, Notes, Jobs, Added); jobs (Job ID, Title, Customer, Status, Address, Scheduled date, Quote $, Costs $, Profit $, Archived, Created); money ledger (Date, Type, Job, Invoice, Amount $, Note). No line-item, photo, voice-note, or Advisor data in the export. |

### 4.7 Client texts (4)

| Action | Inputs | Outputs | Tables | Rules |
| --- | --- | --- | --- | --- |
| `draftClientUpdate` | `{jobId, kind: estimate\|en_route\|milestone\|payment\|custom, message ≤1000}` | `{updateId, message}` | `client_updates`, `job_events`, `jobs`/`customers`/`invoices` (read) | Builds the message from templates when `message` is empty (estimate: quote total; en_route; milestone; payment: latest invoice balance; custom **requires** a message). Templates use first name + business name + job title. `channel` = provider name (`draft_only`); `status: draft`. Logs `text_drafted`. Any role. |
| `sendClientUpdate` | `{updateId}` | `{delivered, note}` | `client_updates`, `job_events` | Calls `providers.sms.send` (draft-only adapter: `delivered: false`, note "No texting service is connected yet — this stays a draft…"). Only marks `sent` + logs `text_sent` when `delivered` is true — so today it **never** marks sent. Any role. |
| `markUpdateSent` | `{updateId}` | `{ok: true}` | `client_updates`, `job_events` | Manual "I sent it from my own phone" path: sets `sent`, logs `text_sent`. Any role. |
| `deleteClientUpdate` | `{updateId}` | `{ok: true}` | `client_updates` | Hard delete of a draft. No job event. Any role. |

### 4.8 Price book (2)

| Action | Inputs | Outputs | Tables | Rules |
| --- | --- | --- | --- | --- |
| `getPriceBook` | `{}` | `{versions[]: {id, version, name, isActive, createdAt}, activeItems[]}` | `price_books`, `price_book_items` | Versions desc by version number; active = the one with `is_active = 1`. |
| `createPriceBookVersion` | `{name ≤120, items[] ≤500: {description 1–300, unit 1–30, unitPriceCents ≥0, kind}}` | `{version}` | `price_books`, `price_book_items` | **Office only.** New version = max existing + 1; deactivates all old versions, then inserts the new book + all its items wholesale. Old versions are never edited. Empty name → `Price book v<n>`. Empty item list is allowed (creates an empty active book). |

### 4.9 Offline sync (2)

| Action | Inputs | Outputs | Tables | Rules |
| --- | --- | --- | --- | --- |
| `pushCaptures` | `{captures[] ≤100: {clientId 1–120, kind (7), payload: record}}` | `{results[]: {clientId, status: applied\|skipped\|failed, error}}` | `sync_outbox`, `sync_refs`, + target tables per kind | Per capture, in order: skip if `(workspace, clientId)` already `applied`; else insert/update `sync_outbox` row as `pending`, apply, then mark `applied` (+`applied_at`) or `failed` (+error). One capture's failure does not stop the batch. See §6.2 for per-kind apply rules and the missing conflict rule. |
| `getSyncStatus` | `{}` | `{pending, applied, failed, recent[≤30]}` | `sync_outbox` | Counts are computed over the latest 200 outbox rows (not the whole table); `recent` is the latest 30. Any role. |

### 4.10 Dashboard (1)

| Action | Inputs | Outputs | Tables | Rules |
| --- | --- | --- | --- | --- |
| `getDashboard` | `{}` | `{collectedMonthCents, outstandingCents, profitMonthCents, statusCounts{}, unpaid[], followUps[], ledger[≤25]}` | `payments`, `ledger_entries`, `jobs`, `customers`, `invoices`, `line_items` | `collectedMonthCents` = Σ payment rows (incl. negative refunds) whose `paid_date` starts with current `YYYY-MM`. `profitMonthCents` = Σ ledger rows in the month of types `payment_received + cost_recorded + refund + adjustment` (**excludes** `invoice_issued`). `outstandingCents` = Σ balances of invoices in `sent`/`overdue` only (draft invoices with a balance are listed in `unpaid[]` but not counted as outstanding). `statusCounts` counts active (non-archived) jobs only. `unpaid[]` = every invoice with balance > 0 and status ≠ `paid`. Follow-ups (see §5.4): stale leads (>3 days in `lead`), drafts waiting (grouped per job), overdue invoices. `ledger[]` = latest 25 of the latest 500 rows. Any role. |

**Action count check:** 5 + 5 + 3 + 7 + 8 + 6 + 4 + 2 + 2 + 1 = **43**.

### 4.11 Office-gated vs not (server enforcement)

Office-gated (14, all via `requireOffice`): `updateWorkspace`,
`regenerateInviteCode`, `setMemberRole`, `removeMember`, `archiveJob`,
`restoreJob`, `deleteJob`, `issueEstimate`, `createInvoice`,
`updateInvoiceStatus`, `recordPayment`, `recordRefund`,
`createPriceBookVersion`, `exportData`.

**Not** office-gated (29): all reads, `createAccount`, `createBusiness`,
`joinBusiness`, `claimBusiness`, `saveCustomer`, `deleteCustomer`, `saveJob`,
`changeJobStatus`, `saveLineItem`, `deleteLineItem`, `addCost`, `deleteCost`,
`addVoiceNote`, `addPhoto`, `deletePhoto`, `addLineItemFromPriceBook`,
`draftClientUpdate`, `sendClientUpdate`, `markUpdateSent`,
`deleteClientUpdate`, `pushCaptures`, `getSyncStatus`, `getDashboard`.
The gaps that matter are in §8.1.

---

## 5. Client — screens and flows (`client/src/App.tsx`, 4,291 lines)

State: TanStack Query (`spaceQueryClient`); types derived from the server
actions (`ApiResponse<typeof api, …>`); form field limits derived from the
action zod schemas (`actionFields`). Navigation always scrolls to top
(`scrollPageToTop` + rAF + 150 ms + 500 ms timers — needed because the page
scrolls inside a shell container, not the window).

### 5.1 Shell + onboarding

- **Loading / error states** for session and workspace queries, each with a
  retry button.
- **`Onboarding`** (lines 351–551): three stages from `getSession`.
  - `no_account`: "First, who are you?" — display name only (placeholder
    "Jeremy"); creates the account. Copy states the name goes on job history,
    notes and invoices.
  - `no_business`: welcome + three cards — **Claim this business** (only if
    `claimableBusinessName` is set), **Start a new business** (business name
    placeholder "Better Than Your Husband LLC", trade placeholder
    "Handyman / home repair", role picker), **Join a business** (invite code,
    placeholder "ABC123", role picker).
  - `ready`: main app.
- **Header** (sticky): logo mark, business name, `memberName · Field|Office ·
  trade`; gold "N to sync" badge when the outbox is non-empty (tapping it
  opens Setup).
- **Bottom nav** (6 tabs): Jobs, Customers, Money, Prices, Research, Setup.
  Selecting a tab or a job clears the selection and scrolls to top.

### 5.2 Jobs tab (`JobsView`, `MoneyBoard`, `PipelineBoard`, `JobValueCard`, `GettingStarted`, `JobForm`)

- **`GettingStarted`** checklist (3 steps, dismissible, dismissal stored in
  `localStorage` key `cc-checklist-dismissed`): 1) Name your business, 2) Add
  a teammate (done when members > 1), 3) Add your first customer. Hides when
  dismissed or all done. Checklist action buttons are a quieter secondary
  style, not the gold New Job button (Nov 16 fix).
- **Free-job counter**: "{n} of 5 free jobs used this month." (display only).
- **`MoneyBoard`**: collected this month / still owed / profit this month
  (from `getDashboard`).
- **`PipelineBoard`**: HandOff-style board — job counts by status, tap a
  stage to filter the list.
- **Filters** (10): Active, All, Leads, Quoted, Scheduled, In progress, Done,
  Invoiced, Paid, Archived. Active = not archived and not `paid`/`cancelled`.
- **Job rows**: customer name, title, status chip (dot colours: silver shades
  for work states, gold for money states, muted brick for cancelled), quote,
  cost, profit, draft count badge. Field role sees the same list; money
  figures are shown to both roles in v2 (role only changes job-page sections).
- **`JobForm`**: new job (customer picker — with "add a customer first"
  guidance when there are 0 customers — plus an add-customer button on that
  screen, Nov 16 correction) or edit details. Title/description/address/
  scheduled date. Creating a job calls `saveJob` directly (online only);
  offline creation goes through the outbox (`capture("job", …)`, §6.2).
- **New Job button**: single gold button; no duplicate in the list (Nov 16 fix).

### 5.3 Job detail — one scrolling page (`JobDetail`, lines 1805+)

Sticky jump-nav under the header with sections: **Estimate, Photos, Notes,
Costs, Invoices, Texts, History** (plus office-only Edit + Settings at the
bottom). Each section is a `div id="jobsec-…"` with `scroll-mt-36`.

- **`JobValueCard`**: quote / costs / profit for the job, with profit as a
  share of quote.
- **Status controls**: only the statuses in `allowedNext` are offered
  (server is the enforcer); `nextStepHint` text tells the user the next move.
- **`QuoteSection`**: numbered estimate line items (approved vs drafts
  separated). Drafts show the Advisor note (see §9). `DraftRow`: approve
  (set price first if none stated) or reject (deletes the draft).
  `ApprovedRow` + `LineItemForm`: add/edit items; `addLineItemFromPriceBook`
  picker from the active price book. **Issue estimate** button (office) →
  `issueEstimate`; issued estimates render as `FrozenDocCard` (frozen lines +
  total + number + who issued) — read-only proof of what the customer got.
- **`PhotosSection`**: before / after / receipt / site grids; capture from
  camera or file; client resizes to max edge 1400px, JPEG quality 0.82
  (`fileToResizedBase64`); caption; delete (row only, blob orphaned — §8.6).
- **`VoiceSection`**: typed/pasted transcript field (labelled as a field
  note / voice note) + member name; saves via outbox when offline, direct
  `addVoiceNote` when online. **No audio recording or transcription in v2**
  (v1 records audio but never transcribes; neither build has the whole flow).
  Offline note text: "Note saved. When it syncs, the Advisor pulls out draft
  line items for the office to approve — nothing is priced or sent without a
  human check."
- **`CostsSection`**: add cost (description / amount / kind); delete cost
  (ledger adjustment, §7).
- **`InvoiceSection`** (office-visible invoicing; field sees totals only):
  create invoice (due date) → `createInvoice`; invoice cards with number,
  total, paid, balance, status; `updateInvoiceStatus` (draft/sent/overdue);
  `PaymentForm` (amount/method/date → `recordPayment`); `RefundForm`
  (amount/method/reason → `recordRefund`); frozen invoice documents as
  `FrozenDocCard`.
- **`ClientTextsSection`**: draft templates (estimate ready, on the way,
  milestone, payment reminder, custom); the draft text, a copy button, an
  "open in Messages" button, **Mark sent** (manual), delete. `sendClientUpdate`
  is wired but always reports not-delivered (draft-only provider).
- **`HistorySection`**: job events, latest 200, newest first — actor name,
  type, detail, time. This is the job's audit trail.
- **`EditJobSection`** (office only): edit title/description/address/date.
- **`JobSettingsSection`** (office only): archive / restore / hard-delete
  (delete blocked with explanation when invoices exist).

### 5.4 Money tab (`MoneyView`)

`MoneyBoard` (same as Jobs tab) + **Follow-ups** (from `getDashboard`):
stale leads, drafts waiting, overdue invoices — each with an "Open job →"
button; empty state "Nothing waiting on you." + **Unpaid invoices** list
(number · job title, customer · status, gold balance, Open →) + recent
ledger lines (latest 25). No separate reports page; no monthly view beyond
"this month" totals.

### 5.5 Customers tab (`CustomersView`, `CustomerForm`)

Alphabetical list with job count per customer; tap to filter that customer's
jobs; add/edit form (name/phone/email/address/notes); delete blocked when
jobs exist (server error surfaced). Offline creation via outbox
(`capture("customer", …)`).

### 5.6 Prices tab (`PricesView`)

Active price-book version + items; version history list; **new version**
editor (name + up to 500 rows: description/unit/price/kind) — saving creates
a new version and deactivates the old one (office only). Line items can be
added to a job from the active book (stamped with its version).

### 5.7 Setup tab (`SetupView`)

- Business name + trade editor (office only; save → `updateWorkspace`).
- Invite code display + copy + regenerate (office).
- Team list: name, role, "you"/owner markers; role change + remove member
  (office; owner protected).
- **Sync status**: pending/applied/failed counts + recent 30 captures with
  errors; **Sync now** button; the header "N to sync" badge links here.
- **Data export** (office): downloads three CSVs
  (`contractor-corner-customers-<date>.csv` etc.) via `exportData`.
- **Connected services**: four rows showing the provider adapter names —
  "Photo & file storage" (`local_blobs`), "Payments" (`manual`),
  "Customer texts" (`draft_only`), **"Voice-note Advisor"** (`built_in` —
  raw internal value shown verbatim, see §9).
- **Free plan line**: "{n} of 5 jobs used this month."
- No Advisor preferences section exists yet (Phase 1 in the evaluation
  adds one here).

### 5.8 Research tab (`ResearchView`, `client/src/research.tsx`)

Static in-app planning pages (not a product feature for contractors):
**Competitor features**, **Launch strategy**, **Backend decision**. Content is
dated research snapshots (Nov 2026) with source lines. This tab is internal
planning material shipped inside the customer app — the rebuild must decide
whether to keep it, move it to docs, or drop it (see `ARCHITECTURE.md` §12
and the "AI" verdict in §9: this tab is where the remaining user-facing
"AI" strings live).

### 5.9 Theme (`theme.css`)

Black / silver / gold only, matching the logo
(`~/workspace/goals/contractor-corner/files/contractor-corner-logo.png`):
`--bg #080707`, `--surface #151312`, `--surface2 #221f1b`,
`--text #f0efec`, `--dim #b3b0a9`, `--border #37332c`,
`--accent/--gold #d9a441`, `--gold-bright #f2c14e`, `--gold-deep #9a741f`,
`--silver #c9c9c7`. Dark-only (`color-scheme: dark`). Display font Barlow
Semi Condensed (Google Fonts import) + metallic gradient text classes
(`.text-metal-silver`, `.btn-metal-gold`). Buttons/selects/inputs
`min-height: 2.75rem`; inputs `font-size: 16px` (no iOS zoom). Logo assets:
`client/src/assets/logo-full.jpg` (full lockup) and `logo-mark.jpg`
(C's-and-hammer crop for the header). `CCMark`/`LogoFull` components render
them.

---

## 6. State machine, offline sync, and events

### 6.1 Job stage machine (`TRANSITIONS`, `actions.ts` lines 160–169)

Enforced server-side in `applyStatusTransition`; the client only offers
`allowedNext`. Every transition logs a `stage_changed` event.

| From | Allowed next |
| --- | --- |
| `lead` | `quoted`, `scheduled`, `cancelled` |
| `quoted` | `scheduled`, `lead`, `cancelled` |
| `scheduled` | `in_progress`, `quoted`, `cancelled` |
| `in_progress` | `done`, `scheduled` |
| `done` | `invoiced`, `in_progress` |
| `invoiced` | `paid`, `done` |
| `paid` | `invoiced` (only — so a refund can reopen the job) |
| `cancelled` | `lead` (re-open) |

Notes: `paid` is normally reached only via `recordPayment` (balance 0 moves
`invoiced` → `paid`) or `createInvoice` (`done` → `invoiced`); a direct
`changeJobStatus` to `paid` is allowed by the machine from `invoiced` but
the UI does not offer it as a manual move in the normal flow. `cancelled`
cannot be reached from `in_progress`/`done`/`invoiced`/`paid` — a job that
far along must be archived instead. There is **no** `on_hold` / `waiting`
state and no task/checklist states.

### 6.2 Offline outbox — client + server

**Client** (`App.tsx` lines 102–165, 596–660):

- Queue in `localStorage` under key `cc-outbox-v1` (JSON array of
  `{clientId, kind, payload}`). `clientId` = `${Date.now()}-${random}`.
- `capture(kind, payload)`: appends to the queue, persists, then calls
  `syncNow()` immediately (best-effort; works when online, stays queued
  when offline).
- `syncNow()`: no-op if already syncing or queue empty; calls
  `pushCaptures({captures: list})`; drops applied/skipped results from the
  queue; **keeps failed captures**; on network error keeps everything.
  Runs on app-ready and on the browser `online` event. There is no
  background/periodic sync and no retry back-off.
- `writeOutbox` swallows storage errors (quota full/blocked): captures stay
  unsent with only the header badge count as a warning.
- Photos travel inside the queue as base64 strings (resized first, §5.3).

**Server** (`pushCaptures`, §4.9): batch ≤ 100; per capture, idempotent on
`(workspace_id, client_id)` — already-`applied` ⇒ `skipped`, never
re-applied. Per-kind apply:

| Kind | Apply rule |
| --- | --- |
| `customer` | `clientRef` (or `clientId`) → `sync_refs`; if not already mapped, `applyCustomerCreate`; save ref. Name required. |
| `job` | Resolve `customerId` (number) **or** `customerClientRef` via `sync_refs`; if the customer hasn't synced yet ⇒ `failed` with "…hasn't synced yet — it will retry." Title required. Saves job ref. |
| `voice_note` / `note` | Resolve job by server id or `jobClientRef`; `applyVoiceNote` (incl. Advisor extraction at sync time). |
| `cost` | Resolve job; `applyCost`. Unknown kind string defaults to `material`. |
| `status_change` | Resolve job; `applyStatusTransition` — **fails outright if the transition is no longer legal** (e.g. office already moved the job). No merge, no review queue. |
| `photo` | Resolve job; `applyPhoto` with the queued base64. Unknown photo kind defaults to `site`. |

**Ordering dependency:** a queued job that references a queued customer only
applies if the customer capture is earlier in the same batch (or an earlier
batch). The client does not reorder the queue — it pushes in insertion order,
which normally satisfies this.

### 6.3 Job events — all 22 types (`job_events.type`)

`created, edited, stage_changed, item_added, item_edited, item_approved,
item_rejected, item_removed, cost_added, cost_removed, note_added,
photo_added, estimate_issued, invoice_issued, invoice_sent, invoice_status,
payment_recorded, refund_recorded, text_drafted, text_sent, archived,
restored`.

Logged with `account_id` + `actor_name` + timestamp; `getJob` returns the
latest 200. What is **not** logged: customer creates/edits, price-book
changes, member role changes/removals, invite-code regeneration, workspace
renames, photo deletes, line-item price edits are logged only as
`item_edited` (no before/after values), cost deletes log the description but
not the amount in the event (the amount is in the ledger adjustment).

---

## 7. Ledger rules (verified in code)

- **Append-only.** Only `appendLedger` writes; no update/delete path exists
  anywhere. Sign convention: money in positive, money out negative.
- **Writers:** `createInvoice` → `invoice_issued` +total;
  `recordPayment` → `payment_received` +amount; `applyCost` (incl. offline)
  → `cost_recorded` −amount; `recordRefund` → `refund` −amount;
  `deleteCost` → `adjustment` +amount (offsets the original cost row).
- **What never writes a ledger row:** estimate issue (estimates are not
  money), draft creation/approval/rejection, status changes, photo/voice
  actions, client texts, price-book versions, job delete (blocked when
  invoices exist), customer delete.
- **Invoice "paid" is derived:** `paidCents = SUM(payments)`; balance =
  `total − paid`; status flips to `paid` only when balance hits 0 in
  `recordPayment`; a refund that reopens a balance flips `paid` → `sent`
  and job `paid` → `invoiced`. `updateInvoiceStatus` cannot set `paid`.
- **Profit:** per job `approved quote − costs` (`jobTotals`); per month from
  the ledger (`payment_received + cost_recorded + refund + adjustment` in
  the month — `invoice_issued` excluded, so issuing an invoice never counts
  as profit).
- **Rounding:** line totals are `round(qty × unitPriceCents)` per line, then
  summed. `qty` is REAL (fractional hours allowed).
- **Numbering:** `EST-`/`INV-` + (1001 + count of existing documents/invoices
  in the workspace). Count-based, not max-based — see §8.5.

---

## 8. Price-book versioning rules

- `createPriceBookVersion` (office only): new version number = max + 1;
  **all** existing versions set `is_active = 0`, then the new book + its full
  item list are inserted; old versions and their items are never edited or
  deleted.
- A line item added from the book copies description/unit price/kind at that
  moment, `source: price_book`, `status: approved` immediately, and is
  stamped `priceBookVersion` = the owning book's version — so an old quote
  keeps its numbers even after prices change.
- `getPriceBook` returns all versions (desc) + the active version's items.
  There is no per-item edit, no item delete, no version delete, no "revert
  to an old version" (reverting = saving a new version with the old prices).
- No price-book data is included in the CSV export.

---

## 9. "AI" strings check — verdict

Task: verify in `client/src/App.tsx` whether any user-facing "AI" strings
remain (a Nov 16 scrub claims zero remain).

**Verdict: CONFIRMED for the product UI in `App.tsx`, with two caveats
outside it.**

Evidence (greps run 2026-11-21 against the files as read):

- `grep -c "AI" client/src/App.tsx` → **0 lines**. The literal substring
  `AI` does not occur anywhere in `App.tsx`.
- All three strings named in the Advisor onboarding evaluation are fixed:
  - Job page, draft line items (line 2045): *"These were pulled out of
    field notes by the Advisor. Prices only appear when the note stated
    one…"* (was: "…by AI.")
  - Field note, offline sync note (line 2619): *"Note saved. When it syncs,
    the Advisor pulls out draft line items for the office to approve…"*
    (was: "…AI pulls out…")
  - Setup → Connected services (line 4045): label **"Voice-note Advisor"**
    (was: "Voice-note AI").
- The feature is called "Advisor" in every user-facing string in `App.tsx`
  and in the `addVoiceNote` action description ("uses the Advisor to turn
  it into draft line items…").

**Caveat 1 — `client/src/research.tsx` (Research tab, user-facing).**
The Research tab is rendered inside the app and contains many standalone
"AI" mentions: competitor add-on names ("AI Receptionist ~$29/mo",
"Operator AI answering", "Chat AI", "Genius Answering AI"), "AI job
matching", "AI estimate drafting", and the heading **"HandOff AI"**
(line 2308). These are quoted competitor product names / research notes,
not Contractor Corner's own feature naming — but a user opening the
Research tab does see "AI" repeatedly, so the Nov 16 "zero remain" claim
is true only for the product UI, not for the whole app. The rebuild must
decide: keep the Research tab (and accept quoted competitor "AI" names),
reword it, or move it out of the customer app (recommended — see
`ARCHITECTURE.md` §12).

**Caveat 2 — Setup shows a raw internal value.** The Connected services
row for the Advisor displays `state.providers.ai`, whose value is the
adapter name `built_in` — internal jargon visible to users. It does not
contain the string "AI", but it is not user-facing copy either. The
rebuild should show a human label ("Built in" / "On") instead of the
adapter name for all four rows.

**Internal code naming** (allowed by the rule — it never reaches users):
`AiProvider`, `inferenceAi`, `providers.ai`, the `aiNote` response field,
`getState.providers.ai`. Keep these names in the rebuild; only user-facing
copy is governed.

---

## 10. Spec gaps and contradictions found while reading

### 10.1 Gaps (things the code does not do that the direction assumes)

1. **Draft approval is not office-enforced server-side (§8.1).** The
   parity direction's rule is "Cherylene retains final approval", and the
   client only shows approve/reject controls in the office view — but
   `saveLineItem` and `deleteLineItem` have no `requireOffice` check. Any
   signed-in field member can approve a draft (or reject one) by calling
   the action. In v2 the role comes from the membership row (not a client
   switch), so this needs a deliberate API call, not a tap — but it is
   still unenforced. **Standalone fix (in `ARCHITECTURE.md` §5): gate
   draft→approved transitions and draft deletes on office role.**
2. **Free-tier limit unenforced.** `FREE_JOB_LIMIT_PER_MONTH = 5` is counted
   in `getState` and displayed in Jobs + Setup, but `saveJob` never checks
   it. With paid subscriptions coming, the rebuild must decide: enforce
   server-side, or drop the limit when the $100/mo plan replaces "free".
3. **No conflict rule for offline edits.** `pushCaptures` fails a queued
   `status_change` outright when the job has already moved (error returned
   per capture, capture stays failed in the queue). Direct online edits are
   last-write-wins with no version check. There is no "needs review" surface
   anywhere. The standalone design (conflict rule + `sync_conflicts`) is in
   `ARCHITECTURE.md` §7.
4. **No deposits / partial-payment schedule.** Invoices have one total and
   payments accumulate against it; there is no deposit concept (v1 models a
   50% deposit in its invoice view — not carried into v2) and no scheduled
   instalments.
5. **No tasks, checklists, change orders, calendar, time tracking, materials
   inventory, customer portal, or automated reminders.** All are planned-only
   (parity review). Schema has no tables for them; the rebuild must not
   pretend otherwise.
6. **No notification channel.** Texts are draft-only; no email, no push.
   Every "notification" is in-app (dashboard follow-ups count) until a real
   sending service is approved separately.
7. **Voice notes are text-only.** No audio capture, no transcription step.
   The Advisor extraction runs on a typed/pasted transcript.
8. **Advisor does not exist as a feature** — only the extraction step
   (§11). No preferences, no alerts, no checks. The evaluation's Phase 0
   rename is done (§9); Phase 1 is specified in `ARCHITECTURE.md` §10.
9. **No per-business storage cap, no backup/restore.** Photos accumulate
   unboundedly; export covers customers/jobs/ledger only (no line items,
   photos, voice notes, events, or documents).
10. **Invite-code join has no owner approval.** Anyone with the 6-char code
    joins and picks their own role (including office). Rotating the code is
    the only revocation.
11. **No audit for admin actions.** Role changes, member removals, invite
    regeneration, workspace renames, and price-book saves write no
    `job_events` row (they are not job-scoped) and there is no admin audit
    log at all.

### 10.2 Contradictions / quirks in the code itself

12. **v1 vs v2 stage vocabulary differs.** v1: Lead, Estimate Sent,
    Approved, Scheduled, Done, Paid. v2: lead, quoted, scheduled,
    in_progress, done, invoiced, paid, cancelled. A job history written in
    one does not map cleanly onto the other. v2's vocabulary is canonical
    for the rebuild; v1 stays frozen as a demo.
13. **v1 vs v2 pricing differs.** v1 advertises Paid $19/mo early / $29
    regular with a non-charging upgrade button; the BTYH plan is $100/mo
    (Rob's plan, **not** agreed by Cherylene — she said "cheaper", no
    number; HandOff benchmark $200/mo). Neither figure is in v2's code
    (only the 5-free-jobs limit). The rebuild must not copy v1's prices.
14. **Numbering is count-based, not max-based.** `EST-${1001 + count}` and
    `INV-${1001 + count}`. `deleteJob` deletes a job's `documents` (only
    possible when it has no invoices — estimates can be deleted with it),
    so an EST number can be reused after a delete. Same for invoice counts
    only if invoices could be deleted — they cannot (no delete-invoice
    action), so INV numbers are stable in practice. Recommend a sequence /
    max+1 in the rebuild.
15. **`sync_refs` uniqueness ignores entity.** The unique index is
    `(workspace_id, client_ref)` with no `entity` column, although the
    comment says "one row per (workspace, client ref)". A customer ref and
    a job ref with the same client string would collide. Client ids are
    `${Date.now()}-${random}`, so a collision is unlikely but not
    impossible; the rebuild should key uniqueness on
    `(workspace_id, entity, client_ref)`.
16. **Orphaned rows on delete.** `deleteJob` leaves the job's
    `cost_recorded` ledger rows in place (ledger is append-only by design —
    the money trail stays, but the rows point at a deleted job id).
    `deletePhoto` leaves the stored blob behind. `removeMember` leaves the
    account row and all authored history. None of these are bugs per se;
    the rebuild should decide each explicitly.
17. **Overpayment is accepted.** `recordPayment` does not reject an amount
    above the balance; the returned balance is clamped at 0 while the full
    amount is recorded and the invoice flips to `paid`.
18. **Refund of a `draft` invoice is possible.** `recordRefund` only checks
    `paidSoFar > 0`; it does not check invoice status. A draft invoice with
    a recorded payment can be refunded.
19. **Two `getState` round-trips of provider names.** The client displays
    raw adapter names (`local_blobs`, `manual`, `draft_only`, `built_in`)
    in Setup — see §9, caveat 2.
20. **The walkthrough conflict is unresolved in code terms.** The parity
    review flags two opposite instructions on Cherylene's walkthrough
    (14 Nov: no walkthrough needed; 15 Nov: walkthrough is gating). Nothing
    in the code resolves this; it is a decision for Rob before workflow
    features (tasks, change orders, scheduling, portal, missed-call
    text-back) are built on assumed workflow. Recorded here so the rebuild
    does not silently assume an answer.

### 10.3 Things the parity review said were missing that are in fact present

- The review (written before Stage 1 landed) says job history, frozen
  snapshots, cancel/archive, refund flow, and offline job/customer creation
  are missing. **All five are present in the v2 code as read** — `job_events`
  (22 types), `documents` snapshots, `archiveJob`/`restoreJob`/`deleteJob`
  guard, `recordRefund`, and `pushCaptures` `customer`/`job` kinds with
  `sync_refs`. The review's Stage 1 list is done; do not re-spec it as new
  work. What is still genuinely missing is in §10.1.

---

## 11. Provider adapters (as built — preserve the pattern)

Defined at the top of `actions.ts` (lines 34–145); one `providers` object
`{storage, payments, sms, ai}` consumed by the actions. Swap = write one new
adapter object; no action or UI changes.

| Adapter | Interface | Current implementation | Swap-in later |
| --- | --- | --- | --- |
| Storage | `put(ctx, key, bytes, contentType)`, `getUrl(ctx, key)` | `localBlobStorage` (`local_blobs`) — artifact blobs; key `jobs/<jobId>/<ms>-<rand>.<ext>` | Supabase Storage |
| Payments | `record({amountCents, method}) → {providerRef}` | `manualPayments` (`manual`) — returns `providerRef: null`; payment recorded by hand | Stripe (PaymentIntent / Checkout) |
| SMS | `send({toPhone, message}) → {delivered, note}` | `draftSms` (`draft_only`) — always `delivered: false`; honest "stays a draft" note | Twilio / other SMS provider |
| Advisor ("AI" internally) | `extractLineItems(ctx, transcript) → {items[]}` | `inferenceAi` (`built_in`) — built-in model completion with a zod schema; prompt: *"Extract the billable line items the note actually mentions… Only include a unit price when the note states a dollar amount — never invent a price; use null when no price was stated. If the note mentions total hours worked without a rate, make one labor item with qty = hours and a null price."* | Same interface + one new method for Phase 2 estimate checks (see `ARCHITECTURE.md` §10) |

Extraction contract (must be preserved): output is always **drafts**;
drafts never count toward totals; a null price is stored as `0` with the UI
showing "no price was stated" and forcing a human to set it; if the call
fails, the note is saved and the user is told the drafts could not be
created; the Advisor can never approve, send, invoice, or charge.

---

## 12. Files not in the inventory (and why)

- `client/src/assets/logo-full.jpg`, `logo-mark.jpg` — brand assets; the
  rebuild reuses the same logo files (copied into `v2/public/`).
- `drizzle/meta/_journal.json` — migration journal (3 entries, sqlite
  dialect); the standalone uses fresh Supabase/Postgres migrations, not
  these files.
- `~/workspace/ts-spaces/contractor-corner/app.db` — **never read** (house
  rule: no sqlite/scripts against `app.db`). All inventory above comes from
  code, not data.
- v1 (`https://contractor-corner.vercel.app`, repo root `index.html`,
  commit `95d0ccf`) — frozen demo; not inventoried here beyond the
  contradictions in §10.2. Do not touch.

---

*Inventory prepared 2026-11-21 by Worker 1 (Stage 3). Branch
`standalone-v2` in `Darknezz-0/contractor-corner`, from main `95d0ccf`.*
