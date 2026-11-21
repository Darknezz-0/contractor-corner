# Contractor Corner — Supabase (Stage 3 standalone rebuild)

Production-ready PostgreSQL migrations for the standalone Contractor Corner
app (Next.js + Supabase + Stripe test mode, Vercel only). Written by Worker 2
from the Worker 1 spec (`v2/docs/ARCHITECTURE.md`, `v2/docs/INVENTORY.md`)
and the v2 source schema (`server/src/schema.ts`).

**Nothing here is applied to any live database.** No Supabase project for
Contractor Corner exists yet — see "Known blocker" below.

## Files

| File | Contents |
| --- | --- |
| `migrations/0001_core.sql` | Enums, all core tables (every v2 table except dead `members`, plus new `workspace_counters`), indexes, per-workspace EST-/INV- numbering, integrity triggers |
| `migrations/0002_rls.sql` | `private.current_workspace_id()` / `current_role()`, RLS on every table, auth sign-up trigger |
| `migrations/0003_storage.sql` | Private `job-photos` bucket + storage policies |
| `migrations/0004_advisor.sql` | Advisor Phase 1 tables + `sync_conflicts`, with RLS |
| `seed_test.sql` | TEST-ONLY seed (demo workspace, two test accounts, one test customer/job) — dev projects only, never production |

Table count: **25 tables** (20 core + 5 in 0004). Policy count: **61
policies** (58 on public tables + 3 on storage.objects), verified by
executing the migrations against local PostgreSQL 16. Enums: **24**
(16 core + 8 Advisor/sync-conflict). Indexes: 63 (including PKs and
unique indexes).

## How to apply

### Option A — Supabase SQL editor (recommended for the first project)

1. Create the project (see "Known blocker"). Open the Supabase dashboard →
   SQL Editor → New query.
2. Paste and run each migration **in order**: `0001_core.sql`,
   `0002_rls.sql`, `0003_storage.sql`, `0004_advisor.sql`. Each file is
   written to be re-runnable (CREATEs are guarded); if a file errors
   halfway, fix the cause and re-run that file — do not skip ahead.
3. Verify with the checks in "Verify it worked" below.
4. Optional, dev project only: create two Auth users, paste their UUIDs
   into `seed_test.sql`, and run it (see its header). Never run the seed
   on a production project.

### Option B — Supabase CLI (`supabase db push`)

1. In `v2/`, run `supabase init` (if not already) and `supabase link
   --project-ref <ref>` with the project ref from the dashboard.
2. Copy this folder's `migrations/` into `v2/supabase/migrations/` (the
   CLI expects that path) — or point the CLI at this folder if your setup
   already does.
3. Run `supabase db push`. The CLI records each file in
   `supabase_migrations.schema_migrations` and applies them in filename
   order.
4. The CLI path needs the database password (from the project settings);
   it never needs the service-role key.

Either way, migrations assume a **fresh project** (empty `public` schema
apart from what Supabase creates). Do not apply them on top of an existing
app database without reviewing the table list first.

## Env vars the app needs (NAMES ONLY — never values)

Values come from the Supabase dashboard / Stripe connector / Vercel project
settings. Never paste a real key into code, docs, or chat. The service-role
key is server-only: never `NEXT_PUBLIC_`, never in the browser bundle.

| Variable | Required | Where it comes from |
| --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | Yes | Supabase project URL — **needed from Rob** (see blocker) |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Yes | Supabase project anon key — **needed from Rob** |
| `SUPABASE_SERVICE_ROLE_KEY` | Yes | Supabase project service-role key — **needed from Rob** |
| `STRIPE_SECRET_KEY` | Yes (billing) | Stripe **test** secret key (`sk_test_…`), from the connected Stripe connector |
| `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY` | Yes (billing) | Stripe **test** publishable key (`pk_test_…`) |
| `STRIPE_WEBHOOK_SECRET` | Yes (billing) | Stripe test webhook secret (`whsec_…`) |
| `STRIPE_PRICE_ID` | Yes (billing) | Test price id for the $100/mo Contractor Corner plan |
| `NEXT_PUBLIC_APP_URL` | Yes | e.g. the Vercel deployment URL of `contractor-corner-v2` |
| `ADVISOR_MONTHLY_CEILING` | No | Optional; default 50 inference calls/business/month |
| `WORKSPACE_STORAGE_CAP_BYTES` | No | Optional; default 5 GB (5,368,709,120 bytes) |
| `NEXT_PUBLIC_FREE_JOB_LIMIT` | No | Optional; default 5 (only if the free-tier limit is enforced — undecided, see ARCHITECTURE.md §12.2) |

The app must refuse a `sk_live_` Stripe key at boot (fail fast) — live keys
are never introduced in this stage.

## What the seed file is for

`seed_test.sql` exists so the app worker can verify the quote-to-cash loop
on a throwaway/dev project without typing everything in by hand. It creates
one demo workspace ("Better Than Your Husband (TEST)"), two test accounts
(field + office), one test customer, one lead job, one approved line item
(2 × $75.00 = $150.00 quote), one $32.00 cost, and default Advisor
preferences. It creates **no** invoices, payments, ledger rows, documents or
alerts — those are created through the app to verify the flows end to end.
First numbers the app will mint: EST-1001 / INV-1001.

To use it: create two Auth users first, paste their UUIDs into the DECLARE
section, run it in the SQL editor as the project owner. It refuses to run
if those Auth users do not exist (which is also what stops it running
with the placeholder UUIDs still in place). Delete the seeded rows (or the
whole project) when done.

## Policy summary (what RLS actually enforces)

- **Every table is workspace-scoped**: a member only ever sees their own
  business's rows. A second business cannot see the first's rows.
- **Office-only**: invoice creation/updates, payment recording (including
  refunds), job deletes, line-item deletes, price-book versions, workspace
  settings, member role changes/removals, Advisor business preferences,
  answering Advisor alerts, resolving sync conflicts.
- **Field members can**: create/edit jobs and customers, move jobs along
  the stage machine, capture photos/voice notes/costs, draft line items
  and client texts, sync.
- **Draft approval is office-only** (the v2 gap, INVENTORY.md §10.1.1):
  enforced by the `line_items_approval_gate` trigger in 0001, because RLS
  cannot compare a row's old and new status in one clause. The server
  action's office check is the first layer; the trigger is the second.
- **Append-only**: `ledger_entries` has no UPDATE/DELETE policy for any
  role, plus a trigger that raises even for the service role. `job_events`
  cannot be UPDATEd by anyone (trigger); DELETE is blocked for direct
  clients by RLS and only possible through the service-role deleteJob path
  (zero invoices only). Corrections are new rows (`adjustment`), never edits.
- **Frozen**: `documents` rows cannot be UPDATEd (trigger); a frozen
  estimate/invoice's lines never change. Price books: only the `is_active`
  flip is allowed (activating a new version); every other change raises.
  Photos: caption-only updates. Costs/voice notes: no UPDATE at all.
- **Deletes that must fail**: a customer with jobs (FK RESTRICT), a job
  with invoices (FK RESTRICT — archive instead), an invoice with payments
  (FK RESTRICT). No child table cascades into invoices or payments.
- **Service-role-only** (no policy for authenticated, so only server code
  holding the service key can do it): ledger/event inserts, document
  inserts, sync_refs writes, outbox status changes, workspace creation,
  membership changes, counter reads.
- **Storage**: `job-photos` is private. SELECT/INSERT require the object
  path's first segment to be the caller's workspace id. Direct browser
  DELETE is office-only; app-mediated photo deletes go through the
  `deletePhoto` server action (service role), which deletes the Storage
  object, the photos row, and decrements `workspaces.storage_used_bytes`
  in one transaction — v2 orphaned the blob.

## Numbering (EST-/INV-)

v2 numbered estimates/invoices as `EST-/INV-` + (1001 + count of existing
rows) — a deleted document's number could be reused. The standalone uses
`workspace_counters` + `next_estimate_number(workspace_id)` /
`next_invoice_number(workspace_id)`: an atomic `UPDATE … SET seq = seq + 1
RETURNING` inside the same transaction as the document insert. First
numbers are still EST-1001 / INV-1001. A rolled-back transaction leaves a
harmless gap; numbers are never reused. A counters row is auto-created for
every workspace by trigger.

## Verify it worked

Run these in the SQL editor after applying 0001–0004 (as project owner):

```sql
-- 23 tables, RLS on for all of them
select count(*) from information_schema.tables
  where table_schema = 'public' and table_type = 'BASE TABLE';
select tablename, rowsecurity from pg_tables
  where schemaname = 'public' order by tablename;

-- ~50 table policies + 3 storage policies
select count(*) from pg_policies where schemaname in ('public', 'storage');

-- numbering works (replace 1 with a real workspace id after seeding)
select next_estimate_number(1), next_invoice_number(1);

-- bucket exists, private, 10 MB cap, image MIME allowlist
select id, public, file_size_limit, allowed_mime_types
  from storage.buckets where id = 'job-photos';
```

Then the app-level spot checks (ARCHITECTURE.md §15.10): sign in as the
field test user and confirm (a) a second business's rows are invisible,
(b) approving a draft line item via the API fails, (c) creating an invoice
via the API fails; sign in as office and confirm both succeed.

## Decisions / corrections vs the Worker 1 spec

These are the places where the spec was ambiguous, contradictory, or
unworkable as written, and what was decided. The app worker should follow
the decisions here, not re-litigate them silently — if one is wrong, change
it here first and note it.

1. **Advisor enums are native Postgres enums**, not text + CHECK. The spec
   (§4.1) says "advisor_* enums in §10" but §10.1 writes the columns as
   text with CHECKs. Native enums match the rest of the schema and are
   stricter; the values are identical.
2. **Advisor alert suppression**: the spec's `UNIQUE(workspace_id, job_id,
   check_type, document_id)` cannot work as written for checks with no
   frozen document (`document_id` NULL — NULLs are distinct in a unique
   index, so the constraint would never fire). Implemented as a partial
   unique index covering only document-bound alerts (`WHERE document_id
   IS NOT NULL`); suppression for document-less checks (unpaid invoices,
   cost overrun, drafts waiting) lives in app code, as the spec's §10.3
   already requires.
3. **Price-book activation**: the spec says price_books UPDATE "never",
   but activating a new version requires flipping the old version's
   `is_active` to false. Implemented as a trigger that permits
   `is_active`-only changes and raises on any other column change, plus a
   partial unique index guaranteeing at most one active version per
   workspace. Direct clients still cannot UPDATE at all (no policy);
   activation runs as the service role.
4. **Job stage machine**: the spec says transitions are "enforced in code,
   not RLS". A BEFORE UPDATE trigger (`enforce_job_status_transition`,
   machine ported verbatim from INVENTORY.md §6.1) is added as a second
   layer, so a bug or a direct SQL call can never move a job illegally.
   Legal transitions are unchanged.
5. **job_events DELETE**: the spec's RLS table says DELETE "never", but its
   own note says the deleteJob path deletes a job's documents (and, in v2,
   its events) when the job has zero invoices. Resolved: the trigger
   blocks UPDATE only; RLS blocks DELETE for direct clients; the
   service-role deleteJob path may delete event/document rows explicitly,
   and only for a zero-invoice job (the RESTRICT FKs make anything else
   fail). The ledger is the exception: its rows are never deleted by any
   path (trigger blocks UPDATE and DELETE even for the service role).
6. **Storage DELETE is office-only for direct browser deletes.** The spec
   §6 says storage DELETE is for "a member", the task brief says office
   can delete objects, and §5 says photos-row DELETE is any member. The
   split implemented: direct Storage deletes are office-only; the app's
   `deletePhoto` server action (service role) deletes the object for any
   member and is the only path the UI uses.
7. **Payments CHECK**: a `payment` row must have a positive amount and a
   `refund` row a negative amount (the spec states refunds are negative
   rows; the CHECK makes it a DB rule, not just a convention).
8. **Workspaces `subscription_status` stays plain text** (no CHECK): Stripe
   status strings evolve, and a CHECK written today would risk rejecting a
   legitimate webhook value. The app validates it in code.
9. **`advisor_account_preferences` SELECT is own-row only.** The spec's
   "account prefs: own row" is read literally — an office member cannot
   read a teammate's surfacing choice (it only changes highlighting).
10. **Timestamps**: `created_at`/`updated_at` added to the Advisor tables
    and `workspace_counters` (the spec's §10.1 column lists omit them);
    `jobs.updated_at` / `workspaces.updated_at` are maintained by trigger.
11. **`sync_refs.entity_id` has no FK** (it points at customers or jobs
    depending on `entity`) — kept as the spec/v2 have it, and documented
    on the table.

## Known blocker: no Supabase project exists yet

No Supabase project for Contractor Corner is known, and there is no
Supabase connector in Muse. Nothing in this folder is applied anywhere.
What the parent needs from Rob (via the secure flow, never in chat): a
Supabase project URL + anon key + service-role key, **or** a new free
project created in his Supabase dashboard. The app worker then sets the
env vars above (Vercel project settings for deploys, `.env.local` locally
— never commit a real `.env.local`) and applies these migrations to that
project.

Also blocked, separately: Vercel API access to the `precision-web-concepts`
team is 403-blocked pending Rob's re-auth, and Stripe is test-mode only in
this stage (see ARCHITECTURE.md §14).

## What remains (not this worker's job)

- Apply 0001–0004 to the real project once it exists; run the verify
  queries above.
- App worker: Supabase clients, auth + onboarding, core actions port
  (notably the server-action office checks, the numbering-function calls
  inside the issue/create transactions, the deletePhoto Storage delete +
  counter decrement, and the outbox/conflict flows).
- Do NOT merge `standalone-v2` into `main`, do not redirect the v1 domain,
  and do not message BTYH. The v1 demo stays live until the standalone is
  verified and Rob says to switch.
