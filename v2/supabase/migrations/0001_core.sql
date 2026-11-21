-- Contractor Corner — Supabase migration 0001: core schema
-- Stage 3 standalone rebuild, Worker 2.
-- Source: v2 schema (server/src/schema.ts, 19 tables) as mapped in
-- v2/docs/ARCHITECTURE.md §4.1 and v2/docs/INVENTORY.md.
--
-- Apply order: 0001_core, 0002_rls, 0003_storage, 0004_advisor.
-- Run in a FRESH Supabase project via the SQL editor (or `supabase db push`).
-- Idempotent where Postgres allows it (enums via DO blocks, IF NOT EXISTS
-- elsewhere); re-running on an existing database is safe for the CREATEs,
-- but the trigger/function CREATE OR REPLACE statements will overwrite.
--
-- Naming: the feature is "Advisor" in any user-visible string (Rob,
-- 2026-11-16). No "AI" appears in this file except inside code comments
-- about internal naming, which users never see.
--
-- Decisions / corrections vs the Worker 1 spec (see README for the list):
--  * `members` table is DROPPED (dead in v2) — never created here.
--  * `workspace` renamed to `workspaces`; `accounts.id` is uuid (Auth id).
--  * Date-ish text columns become real types: jobs.scheduled_date date,
--    invoices.issued_date/due_date date, payments.paid_date date.
--  * line_items.qty real -> numeric; price_books.is_active int -> boolean.
--  * sync_outbox.payload_json / documents.lines_json text -> jsonb.
--  * sync_refs unique key is (workspace_id, entity, client_ref) — v2
--    omitted `entity` (INVENTORY.md §10.2.15).
--  * Append-only ledger_entries, frozen documents and frozen price-book
--    versions are enforced by TRIGGERS here (they bind even the service
--    role, which bypasses RLS), not by RLS alone. job_events rows cannot
--    be UPDATED by anyone (trigger); they can only be DELETEd through the
--    service-role deleteJob path, which requires zero invoices.
--  * Job deletes never cascade to invoices/payments: every child FK to
--    jobs/invoices is ON DELETE RESTRICT, so a delete with money attached
--    fails loudly; the app archives instead. Ledger rows keep their money
--    trail via ON DELETE SET NULL on their job/invoice links.
--  * Per-workspace EST-/INV- numbering uses workspace_counters + the
--    next_estimate_number() / next_invoice_number() functions below
--    (atomic UPDATE ... RETURNING, never count-based, numbers never reused).

-- ---------------------------------------------------------------- enums
-- DO blocks: CREATE TYPE has no IF NOT EXISTS, so guard with a check.

DO $$ BEGIN
  CREATE TYPE role_enum AS ENUM ('field', 'office');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE job_status_enum AS ENUM
    ('lead', 'quoted', 'scheduled', 'in_progress', 'done', 'invoiced', 'paid', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE line_kind_enum AS ENUM ('labor', 'material', 'other');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE line_source_enum AS ENUM ('manual', 'voice_draft', 'price_book');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE line_status_enum AS ENUM ('draft', 'approved');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE photo_kind_enum AS ENUM ('before', 'after', 'receipt', 'site');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE invoice_status_enum AS ENUM ('draft', 'sent', 'paid', 'overdue');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE payment_kind_enum AS ENUM ('payment', 'refund');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE ledger_type_enum AS ENUM
    ('invoice_issued', 'payment_received', 'cost_recorded', 'refund', 'adjustment');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE sync_kind_enum AS ENUM
    ('voice_note', 'photo', 'cost', 'status_change', 'note', 'customer', 'job');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE sync_status_enum AS ENUM ('pending', 'applied', 'failed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE job_event_type_enum AS ENUM
    ('created', 'edited', 'stage_changed', 'item_added', 'item_edited',
     'item_approved', 'item_rejected', 'item_removed', 'cost_added',
     'cost_removed', 'note_added', 'photo_added', 'estimate_issued',
     'invoice_issued', 'invoice_sent', 'invoice_status', 'payment_recorded',
     'refund_recorded', 'text_drafted', 'text_sent', 'archived', 'restored',
     'advisor_alert_answered');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
-- NOTE: the 22 v2 event types (INVENTORY.md §6.3) plus
-- 'advisor_alert_answered' (ARCHITECTURE.md §10.1) = 23 values.

DO $$ BEGIN
  CREATE TYPE document_kind_enum AS ENUM ('estimate', 'invoice');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE sync_entity_enum AS ENUM ('customer', 'job');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE update_kind_enum AS ENUM
    ('estimate', 'en_route', 'milestone', 'payment', 'custom');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE update_status_enum AS ENUM ('draft', 'sent');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ---------------------------------------------------------------- tables
-- Money is integer cents everywhere. Timestamps are timestamptz.
-- PKs are bigint GENERATED ALWAYS AS IDENTITY, except accounts.id which is
-- the Supabase Auth user uuid (accounts.id REFERENCES auth.users(id)).

CREATE TABLE IF NOT EXISTS public.accounts (
  id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  display_name text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.accounts IS
  'One row per signed-in account. id is the Supabase Auth user id. Created by the trigger on auth.users (0002_rls.sql) or by the sign-up server action.';

CREATE TABLE IF NOT EXISTS public.workspaces (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  business_name text NOT NULL DEFAULT '',
  trade text NOT NULL DEFAULT '',
  owner_account_id uuid REFERENCES public.accounts (id) ON DELETE SET NULL,
  invite_code text NOT NULL DEFAULT '',
  storage_used_bytes bigint NOT NULL DEFAULT 0 CHECK (storage_used_bytes >= 0),
  stripe_customer_id text,
  stripe_subscription_id text,
  subscription_status text,
  subscription_current_period_end timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.workspaces IS
  'One row per contractor business (tenant). storage_used_bytes is the running total of photos.size_bytes; the app increments it on upload and decrements it on delete (single transaction with the photos row). Stripe columns are the contractor''s own subscription only (test mode in this stage); customer card payments are Stage 4.';

CREATE TABLE IF NOT EXISTS public.memberships (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id uuid NOT NULL UNIQUE REFERENCES public.accounts (id) ON DELETE CASCADE,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  role role_enum NOT NULL DEFAULT 'field',
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, account_id)
);
COMMENT ON TABLE public.memberships IS
  'Which business an account belongs to, and their role in it. An account belongs to at most one business in this build (account_id UNIQUE).';

-- members table: intentionally NOT created. Dead in v2; dropped per spec.

CREATE TABLE IF NOT EXISTS public.workspace_counters (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL UNIQUE REFERENCES public.workspaces (id) ON DELETE CASCADE,
  estimate_seq bigint NOT NULL DEFAULT 1000 CHECK (estimate_seq >= 1000),
  invoice_seq bigint NOT NULL DEFAULT 1000 CHECK (invoice_seq >= 1000),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.workspace_counters IS
  'Per-workspace EST-/INV- numbering state. First numbers are EST-1001 / INV-1001 to match v2. A row is auto-created for every workspace by a trigger (below). Numbers are minted only through next_estimate_number() / next_invoice_number(), which increment inside the same transaction as the document insert — never count-based, so a deleted document''s number is never reused.';

CREATE TABLE IF NOT EXISTS public.customers (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  name text NOT NULL CHECK (name <> ''),
  phone text NOT NULL DEFAULT '',
  email text NOT NULL DEFAULT '',
  address text NOT NULL DEFAULT '',
  notes text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.jobs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  customer_id bigint NOT NULL REFERENCES public.customers (id) ON DELETE RESTRICT,
  title text NOT NULL CHECK (title <> ''),
  description text NOT NULL DEFAULT '',
  address text NOT NULL DEFAULT '',
  status job_status_enum NOT NULL DEFAULT 'lead',
  scheduled_date date,
  archived_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.jobs IS
  'archived_at set = archived (kept for the money trail, hidden from working lists). Null = active. customer_id is RESTRICT: a customer with jobs cannot be deleted.';

CREATE TABLE IF NOT EXISTS public.line_items (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  job_id bigint NOT NULL REFERENCES public.jobs (id) ON DELETE RESTRICT,
  description text NOT NULL CHECK (description <> ''),
  qty numeric NOT NULL DEFAULT 1 CHECK (qty > 0 AND qty <= 100000),
  unit_price_cents integer NOT NULL DEFAULT 0 CHECK (unit_price_cents >= 0),
  kind line_kind_enum NOT NULL DEFAULT 'labor',
  source line_source_enum NOT NULL DEFAULT 'manual',
  status line_status_enum NOT NULL DEFAULT 'approved',
  price_book_version integer,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.costs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  job_id bigint NOT NULL REFERENCES public.jobs (id) ON DELETE RESTRICT,
  description text NOT NULL CHECK (description <> ''),
  amount_cents integer NOT NULL DEFAULT 0 CHECK (amount_cents >= 0),
  kind line_kind_enum NOT NULL DEFAULT 'material',
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.costs IS
  'Costs are corrected by delete + an offsetting ledger adjustment, never by editing the row (no UPDATE policy in 0002).';

CREATE TABLE IF NOT EXISTS public.photos (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  job_id bigint NOT NULL REFERENCES public.jobs (id) ON DELETE RESTRICT,
  blob_key text NOT NULL,
  storage_provider text NOT NULL DEFAULT 'supabase_storage',
  kind photo_kind_enum NOT NULL DEFAULT 'site',
  caption text NOT NULL DEFAULT '',
  size_bytes bigint NOT NULL DEFAULT 0 CHECK (size_bytes >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.photos IS
  'blob_key is the Supabase Storage object path <workspace_id>/<job_id>/<uuid>.<ext> in the private job-photos bucket (0003_storage.sql). size_bytes feeds workspaces.storage_used_bytes. Only caption may change after insert (trigger below).';

CREATE TABLE IF NOT EXISTS public.voice_notes (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  job_id bigint NOT NULL REFERENCES public.jobs (id) ON DELETE RESTRICT,
  transcript text NOT NULL,
  member_name text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.voice_notes IS
  'Notes are history: never updated or deleted (no UPDATE/DELETE policies in 0002).';

CREATE TABLE IF NOT EXISTS public.invoices (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  job_id bigint NOT NULL REFERENCES public.jobs (id) ON DELETE RESTRICT,
  number text NOT NULL,
  total_cents integer NOT NULL DEFAULT 0 CHECK (total_cents >= 0),
  status invoice_status_enum NOT NULL DEFAULT 'draft',
  issued_date date,
  due_date date,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, number)
);

CREATE TABLE IF NOT EXISTS public.payments (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  invoice_id bigint NOT NULL REFERENCES public.invoices (id) ON DELETE RESTRICT,
  amount_cents integer NOT NULL,
  kind payment_kind_enum NOT NULL DEFAULT 'payment',
  method text NOT NULL DEFAULT 'cash',
  provider text NOT NULL DEFAULT 'manual',
  provider_ref text,
  paid_date date NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((kind = 'payment' AND amount_cents > 0) OR (kind = 'refund' AND amount_cents < 0))
);
COMMENT ON TABLE public.payments IS
  'A refund is a payment row with kind refund and a NEGATIVE amount, so an invoice''s paid total is always just the sum of its payment rows. provider_ref will hold the Stripe PaymentIntent id in Stage 4; it stays null while payments are manual.';

CREATE TABLE IF NOT EXISTS public.ledger_entries (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  job_id bigint REFERENCES public.jobs (id) ON DELETE SET NULL,
  invoice_id bigint REFERENCES public.invoices (id) ON DELETE SET NULL,
  type ledger_type_enum NOT NULL,
  amount_cents integer NOT NULL,
  note text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.ledger_entries IS
  'Append-only money ledger. Rows are only ever inserted — never updated or deleted (no UPDATE/DELETE policies in 0002 AND a trigger below that raises even for the service role). Sign: money in is positive, money out (costs) is negative. job_id/invoice_id are SET NULL on delete so the money trail survives a job delete; the row itself is never removed. Corrections are new adjustment rows, never edits.';

CREATE TABLE IF NOT EXISTS public.price_books (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  version integer NOT NULL CHECK (version >= 1),
  name text NOT NULL DEFAULT '',
  is_active boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, version)
);
COMMENT ON TABLE public.price_books IS
  'Versioned price books: one row per version. The active version prices new quotes; older versions are frozen history. Editing prices creates a NEW version — rows are never edited (trigger below allows only the is_active flip that activates a new version) and never deleted.';

CREATE TABLE IF NOT EXISTS public.price_book_items (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  price_book_id bigint NOT NULL REFERENCES public.price_books (id) ON DELETE RESTRICT,
  description text NOT NULL CHECK (description <> ''),
  unit text NOT NULL DEFAULT 'each',
  unit_price_cents integer NOT NULL DEFAULT 0 CHECK (unit_price_cents >= 0),
  kind line_kind_enum NOT NULL DEFAULT 'labor',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.sync_outbox (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  client_id text NOT NULL,
  kind sync_kind_enum NOT NULL,
  payload_json jsonb NOT NULL,
  status sync_status_enum NOT NULL DEFAULT 'pending',
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  applied_at timestamptz,
  UNIQUE (workspace_id, client_id)
);
COMMENT ON TABLE public.sync_outbox IS
  'Offline-first sync outbox (server-side mirror of the device queue). client_id is client-generated; a retry with the same (workspace_id, client_id) never double-applies — already-applied rows are skipped.';

CREATE TABLE IF NOT EXISTS public.job_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  job_id bigint NOT NULL REFERENCES public.jobs (id) ON DELETE RESTRICT,
  account_id uuid REFERENCES public.accounts (id) ON DELETE SET NULL,
  actor_name text NOT NULL DEFAULT '',
  type job_event_type_enum NOT NULL,
  detail text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.job_events IS
  'Append-only job history: one row per thing that happened to a job, with who did it and when. Rows are never updated or deleted (no UPDATE/DELETE policies in 0002 AND a trigger below). Exception, by design: the v2 deleteJob path hard-deletes a job''s events together with the job, but only when the job has zero invoices — that path runs as the service role through the app, which deletes the event rows explicitly first (the RESTRICT FK below forces that order). The trigger blocks UPDATE/DELETE issued directly against this table by any other path.';

CREATE TABLE IF NOT EXISTS public.documents (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  job_id bigint NOT NULL REFERENCES public.jobs (id) ON DELETE RESTRICT,
  invoice_id bigint REFERENCES public.invoices (id) ON DELETE RESTRICT,
  kind document_kind_enum NOT NULL,
  number text NOT NULL,
  lines_json jsonb NOT NULL DEFAULT '[]'::jsonb,
  total_cents integer NOT NULL DEFAULT 0 CHECK (total_cents >= 0),
  issued_by_name text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, number)
);
COMMENT ON TABLE public.documents IS
  'Frozen issued documents. When an estimate or invoice is issued, its lines are copied here verbatim (jsonb) and NEVER change afterwards — editing the job''s live line items later cannot rewrite what the customer was already given. UPDATE is blocked by a trigger below; DELETE is blocked for direct clients by RLS (0002) and is only possible through the service-role job-delete path, which requires zero invoices.';

CREATE TABLE IF NOT EXISTS public.sync_refs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  client_ref text NOT NULL,
  entity sync_entity_enum NOT NULL,
  entity_id bigint NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, entity, client_ref)
);
COMMENT ON TABLE public.sync_refs IS
  'Offline-creation references: maps a client-generated ref to the real server id so a later queued capture (e.g. a job for that new customer) can resolve its ref even in a different sync batch. entity_id is intentionally NOT a foreign key — it points at customers or jobs depending on entity. Unique key includes entity (v2 omitted it).';

CREATE TABLE IF NOT EXISTS public.client_updates (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  job_id bigint NOT NULL REFERENCES public.jobs (id) ON DELETE RESTRICT,
  kind update_kind_enum NOT NULL DEFAULT 'custom',
  message text NOT NULL,
  channel text NOT NULL DEFAULT 'sms_draft',
  status update_status_enum NOT NULL DEFAULT 'draft',
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.client_updates IS
  'Client texts. channel is the provider name (draft_only while texting is draft-only); status only becomes sent when a text is actually delivered, or via the manual "I sent it from my own phone" path.';

-- ---------------------------------------------------------------- indexes
-- v2 had almost none. These cover the N+1 reads the app actually does
-- (ARCHITECTURE.md §4.3), plus the dashboard / Money-tab lookups.

CREATE INDEX IF NOT EXISTS jobs_workspace_id_desc_idx
  ON public.jobs (workspace_id, id DESC);
CREATE INDEX IF NOT EXISTS line_items_job_id_idx
  ON public.line_items (job_id);
CREATE INDEX IF NOT EXISTS costs_job_id_idx
  ON public.costs (job_id);
CREATE INDEX IF NOT EXISTS photos_job_id_idx
  ON public.photos (job_id);
CREATE INDEX IF NOT EXISTS voice_notes_job_id_idx
  ON public.voice_notes (job_id);
CREATE INDEX IF NOT EXISTS invoices_job_id_idx
  ON public.invoices (job_id);
CREATE INDEX IF NOT EXISTS invoices_workspace_status_idx
  ON public.invoices (workspace_id, status);
CREATE INDEX IF NOT EXISTS payments_invoice_id_idx
  ON public.payments (invoice_id);
CREATE INDEX IF NOT EXISTS payments_workspace_paid_date_idx
  ON public.payments (workspace_id, paid_date DESC);
CREATE INDEX IF NOT EXISTS ledger_entries_workspace_id_desc_idx
  ON public.ledger_entries (workspace_id, id DESC);
CREATE INDEX IF NOT EXISTS ledger_entries_workspace_type_idx
  ON public.ledger_entries (workspace_id, type);
CREATE INDEX IF NOT EXISTS job_events_job_id_desc_idx
  ON public.job_events (job_id, id DESC);
CREATE INDEX IF NOT EXISTS documents_job_id_idx
  ON public.documents (job_id);
CREATE INDEX IF NOT EXISTS client_updates_job_id_idx
  ON public.client_updates (job_id);
CREATE INDEX IF NOT EXISTS customers_workspace_name_idx
  ON public.customers (workspace_id, name);
CREATE INDEX IF NOT EXISTS price_books_workspace_version_desc_idx
  ON public.price_books (workspace_id, version DESC);
-- At most one ACTIVE price-book version per workspace. The trigger below
-- only ever flips is_active; this index makes "two actives" impossible.
CREATE UNIQUE INDEX IF NOT EXISTS price_books_one_active_per_workspace_idx
  ON public.price_books (workspace_id) WHERE is_active;
CREATE INDEX IF NOT EXISTS price_book_items_price_book_id_idx
  ON public.price_book_items (price_book_id);
CREATE INDEX IF NOT EXISTS sync_outbox_workspace_status_idx
  ON public.sync_outbox (workspace_id, status);
CREATE INDEX IF NOT EXISTS sync_refs_workspace_entity_idx
  ON public.sync_refs (workspace_id, entity);

-- ---------------------------------------------------------------- functions
-- Per-workspace EST-/INV- numbering. Call inside the SAME transaction as
-- the documents/invoices insert, from the server action (service role).
-- The UPDATE ... RETURNING is atomic: two concurrent issuers cannot get
-- the same number, and a rolled-back transaction leaves a harmless gap
-- (numbers are never reused, gaps are acceptable; v2's count-based scheme
-- reused numbers after a delete, which this fixes).

CREATE OR REPLACE FUNCTION public.next_estimate_number(p_workspace_id bigint)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_seq bigint;
BEGIN
  UPDATE public.workspace_counters
     SET estimate_seq = estimate_seq + 1,
         updated_at = now()
   WHERE workspace_id = p_workspace_id
  RETURNING estimate_seq INTO v_seq;
  IF v_seq IS NULL THEN
    RAISE EXCEPTION 'no workspace_counters row for workspace %', p_workspace_id;
  END IF;
  RETURN 'EST-' || v_seq::text;
END;
$$;

CREATE OR REPLACE FUNCTION public.next_invoice_number(p_workspace_id bigint)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_seq bigint;
BEGIN
  UPDATE public.workspace_counters
     SET invoice_seq = invoice_seq + 1,
         updated_at = now()
   WHERE workspace_id = p_workspace_id
  RETURNING invoice_seq INTO v_seq;
  IF v_seq IS NULL THEN
    RAISE EXCEPTION 'no workspace_counters row for workspace %', p_workspace_id;
  END IF;
  RETURN 'INV-' || v_seq::text;
END;
$$;

COMMENT ON FUNCTION public.next_estimate_number(bigint) IS
  'Mints the next estimate number for a workspace (EST-1001, EST-1002, ...). Must be called in the same transaction as the documents insert. SECURITY DEFINER so it works regardless of the caller''s RLS context; minting a number alone creates nothing — the invoice/document insert is still office-gated.';
COMMENT ON FUNCTION public.next_invoice_number(bigint) IS
  'Mints the next invoice number for a workspace (INV-1001, INV-1002, ...). Same contract as next_estimate_number().';

-- Generic updated_at maintenance.
CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS workspaces_touch_updated_at ON public.workspaces;
CREATE TRIGGER workspaces_touch_updated_at
  BEFORE UPDATE ON public.workspaces
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

DROP TRIGGER IF EXISTS jobs_touch_updated_at ON public.jobs;
CREATE TRIGGER jobs_touch_updated_at
  BEFORE UPDATE ON public.jobs
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

DROP TRIGGER IF EXISTS workspace_counters_touch_updated_at ON public.workspace_counters;
CREATE TRIGGER workspace_counters_touch_updated_at
  BEFORE UPDATE ON public.workspace_counters
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- One counters row per workspace, created automatically.
CREATE OR REPLACE FUNCTION public.create_workspace_counters()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.workspace_counters (workspace_id)
  VALUES (NEW.id)
  ON CONFLICT (workspace_id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS workspaces_create_counters ON public.workspaces;
CREATE TRIGGER workspaces_create_counters
  AFTER INSERT ON public.workspaces
  FOR EACH ROW EXECUTE FUNCTION public.create_workspace_counters();

-- Job stage machine (INVENTORY.md §6.1, ported verbatim). The spec says
-- transitions are enforced in code, not RLS — this trigger is the second
-- layer, so a bug or a direct SQL call can never move a job illegally.
-- Same-status updates (no real move) are allowed through.
CREATE OR REPLACE FUNCTION public.enforce_job_status_transition()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_allowed boolean := false;
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;
  v_allowed := CASE OLD.status
    WHEN 'lead'        THEN NEW.status IN ('quoted', 'scheduled', 'cancelled')
    WHEN 'quoted'      THEN NEW.status IN ('scheduled', 'lead', 'cancelled')
    WHEN 'scheduled'   THEN NEW.status IN ('in_progress', 'quoted', 'cancelled')
    WHEN 'in_progress' THEN NEW.status IN ('done', 'scheduled')
    WHEN 'done'        THEN NEW.status IN ('invoiced', 'in_progress')
    WHEN 'invoiced'    THEN NEW.status IN ('paid', 'done')
    WHEN 'paid'        THEN NEW.status IN ('invoiced')
    WHEN 'cancelled'   THEN NEW.status IN ('lead')
    ELSE false
  END;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'illegal job status transition: % -> %', OLD.status, NEW.status
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS jobs_enforce_status_transition ON public.jobs;
CREATE TRIGGER jobs_enforce_status_transition
  BEFORE UPDATE OF status ON public.jobs
  FOR EACH ROW EXECUTE FUNCTION public.enforce_job_status_transition();

-- Append-only enforcement. These triggers bind EVERYONE, including the
-- service role (RLS does not apply to the service role, so RLS alone
-- would leave a hole for server-side code). A genuine correction is a new
-- compensating row (ledger type 'adjustment'), never an edit.
-- The table name is passed as a trigger argument (TG_ARGV[0]): trigger
-- functions cannot declare parameters.
CREATE OR REPLACE FUNCTION public.prevent_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION '% rows are append-only and cannot be %', TG_ARGV[0], TG_OP
    USING ERRCODE = 'insufficient_privilege';
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS ledger_entries_append_only ON public.ledger_entries;
CREATE TRIGGER ledger_entries_append_only
  BEFORE UPDATE OR DELETE ON public.ledger_entries
  FOR EACH ROW EXECUTE FUNCTION public.prevent_mutation('ledger_entries');

DROP TRIGGER IF EXISTS job_events_append_only ON public.job_events;
CREATE TRIGGER job_events_append_only
  BEFORE UPDATE ON public.job_events
  FOR EACH ROW EXECUTE FUNCTION public.prevent_mutation('job_events');
-- NOTE on job_events DELETE: UPDATE is blocked by the trigger above;
-- DELETE is blocked for direct clients by RLS (no DELETE policy in
-- 0002). The trigger deliberately does NOT block DELETE, because the
-- v2 deleteJob path hard-deletes a job's events together with the job —
-- but only when the job has zero invoices, and only through the
-- service-role server action, which deletes the event rows explicitly
-- first (the RESTRICT FK on job_events.job_id forces that order).
-- Deleting a job with invoices is impossible at the DB level:
-- invoices.job_id is ON DELETE RESTRICT, so the delete fails loudly and
-- the app must archive instead. Never add a CASCADE here.

-- Frozen documents: lines_json / total never change after insert.
CREATE OR REPLACE FUNCTION public.prevent_document_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'documents are frozen once issued and cannot be updated'
    USING ERRCODE = 'insufficient_privilege';
END;
$$;

DROP TRIGGER IF EXISTS documents_frozen ON public.documents;
CREATE TRIGGER documents_frozen
  BEFORE UPDATE ON public.documents
  FOR EACH ROW EXECUTE FUNCTION public.prevent_document_update();

-- Frozen price books: only the is_active flip (activating a new version)
-- may change a price_books row. Everything else is frozen history.
CREATE OR REPLACE FUNCTION public.enforce_price_book_frozen()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.workspace_id IS DISTINCT FROM NEW.workspace_id
     OR OLD.version IS DISTINCT FROM NEW.version
     OR OLD.name IS DISTINCT FROM NEW.name
     OR OLD.created_at IS DISTINCT FROM NEW.created_at THEN
    RAISE EXCEPTION 'price_books rows are frozen; create a new version instead'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS price_books_frozen ON public.price_books;
CREATE TRIGGER price_books_frozen
  BEFORE UPDATE ON public.price_books
  FOR EACH ROW EXECUTE FUNCTION public.enforce_price_book_frozen();

CREATE OR REPLACE FUNCTION public.prevent_price_book_delete()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'price_books rows are frozen history and cannot be deleted'
    USING ERRCODE = 'insufficient_privilege';
END;
$$;

DROP TRIGGER IF EXISTS price_books_no_delete ON public.price_books;
CREATE TRIGGER price_books_no_delete
  BEFORE DELETE ON public.price_books
  FOR EACH ROW EXECUTE FUNCTION public.prevent_price_book_delete();

DROP TRIGGER IF EXISTS price_book_items_frozen ON public.price_book_items;
CREATE TRIGGER price_book_items_frozen
  BEFORE UPDATE OR DELETE ON public.price_book_items
  FOR EACH ROW EXECUTE FUNCTION public.prevent_mutation('price_book_items');

-- Photos: only the caption may change after insert (blob_key, job,
-- kind, size are the stored record of what was captured).
CREATE OR REPLACE FUNCTION public.enforce_photo_caption_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.workspace_id IS DISTINCT FROM NEW.workspace_id
     OR OLD.job_id IS DISTINCT FROM NEW.job_id
     OR OLD.blob_key IS DISTINCT FROM NEW.blob_key
     OR OLD.storage_provider IS DISTINCT FROM NEW.storage_provider
     OR OLD.kind IS DISTINCT FROM NEW.kind
     OR OLD.size_bytes IS DISTINCT FROM NEW.size_bytes
     OR OLD.created_at IS DISTINCT FROM NEW.created_at THEN
    RAISE EXCEPTION 'photos are immutable except for the caption'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS photos_caption_only ON public.photos;
CREATE TRIGGER photos_caption_only
  BEFORE UPDATE ON public.photos
  FOR EACH ROW EXECUTE FUNCTION public.enforce_photo_caption_only();

-- Draft approval gate (ARCHITECTURE.md §5 CHANGE). RLS alone cannot
-- express "old status was draft AND new status is approved", so the
-- trigger enforces it. It only fires for real (JWT) callers: when the
-- server action runs as the service role, auth.uid() is NULL and the
-- server action's own office check is the gate (the port of v2's
-- requireOffice, extended to draft approval).
-- SECURITY DEFINER with a locked search_path: the gate must not depend
-- on the caller's grants (it reads auth.uid() and private.current_role()).
-- Depends on private.current_role() from 0002_rls.sql; plpgsql resolves
-- that reference at first execution, so 0002 must be applied before any
-- line-item update runs — migrations always run in order.
CREATE OR REPLACE FUNCTION public.enforce_line_item_approval()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF OLD.status = 'draft' AND NEW.status = 'approved'
     AND auth.uid() IS NOT NULL
     AND private.current_role() IS DISTINCT FROM 'office' THEN
    RAISE EXCEPTION 'approving a draft line item is an office job'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS line_items_approval_gate ON public.line_items;
CREATE TRIGGER line_items_approval_gate
  BEFORE UPDATE ON public.line_items
  FOR EACH ROW EXECUTE FUNCTION public.enforce_line_item_approval();
