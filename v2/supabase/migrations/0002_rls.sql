-- Contractor Corner — Supabase migration 0002: row-level security
-- Stage 3 standalone rebuild, Worker 2.
-- Implements the RLS design in v2/docs/ARCHITECTURE.md §5.
--
-- Rules of the design:
--  * RLS is enabled on EVERY business table. The service role bypasses
--    RLS entirely, so anything marked "server actions only" below is
--    enforced by simply having NO policy for the authenticated role —
--    only server code holding the service-role key can do it.
--  * Two SECURITY DEFINER helpers in a `private` schema read the caller's
--    workspace/role from memberships. They run with search_path locked
--    down and fully-qualified names.
--  * Office-only: invoice creation, payment recording, refunds, job
--    delete, draft line-item approval (trigger in 0001 + policy here),
--    price-book versions, workspace settings, member management.
--  * Field members can: create/edit jobs and customers, change job status
--    along the machine (trigger in 0001), capture photos/voice notes/
--    costs, draft line items and client texts, and sync.
--  * Append-only: ledger_entries and job_events have NO UPDATE/DELETE
--    policies for any role (and triggers in 0001 block UPDATE outright).
--  * A field member calling an office action gets the same plain-language
--    error v2 used ("That's an office job — ...") — the server action
--    raises it; RLS is the second layer that makes the direct-API call
--    fail too.
--
-- NOTE on `accounts` inserts: a trigger on auth.users (below) creates the
-- public.accounts row at sign-up. If the managed project ever refuses a
-- trigger on auth.users, delete that trigger block and create the
-- accounts row in the sign-up server action instead (service role).

-- ---------------------------------------------------------------- helpers
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO authenticated, service_role;

-- Returns the caller's workspace id, or NULL (not a member / no session).
CREATE OR REPLACE FUNCTION private.current_workspace_id()
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $$
  SELECT workspace_id FROM public.memberships
  WHERE account_id = auth.uid()
  LIMIT 1;
$$;

-- Returns the caller's role ('field' / 'office') in that workspace, or NULL.
CREATE OR REPLACE FUNCTION private.current_role()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $$
  SELECT role::text FROM public.memberships
  WHERE account_id = auth.uid()
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION private.current_workspace_id() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.current_role() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.current_workspace_id() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.current_role() TO authenticated, service_role;

-- New account row on sign-up (service-role trigger on the auth schema).
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.accounts (id, display_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data ->> 'display_name', ''))
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ---------------------------------------------------------------- RLS on
ALTER TABLE public.workspaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workspace_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.line_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.costs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.voice_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.price_books ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.price_book_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sync_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.job_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sync_refs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_updates ENABLE ROW LEVEL SECURITY;

-- Grants: policies below decide what each role may actually do. The anon
-- role gets the same grants because the browser client uses the anon key;
-- without a session auth.uid() is NULL and every policy fails closed.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO anon, authenticated, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.next_estimate_number(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.next_invoice_number(bigint) TO authenticated, service_role;

-- ---------------------------------------------------------------- workspaces
-- INSERT: none — only via the createBusiness server action (service role).
-- DELETE: never.
DROP POLICY IF EXISTS workspaces_select_member ON public.workspaces;
CREATE POLICY workspaces_select_member ON public.workspaces
  FOR SELECT TO authenticated
  USING (id = private.current_workspace_id());

DROP POLICY IF EXISTS workspaces_update_office ON public.workspaces;
CREATE POLICY workspaces_update_office ON public.workspaces
  FOR UPDATE TO authenticated
  USING (id = private.current_workspace_id() AND private.current_role() = 'office')
  WITH CHECK (id = private.current_workspace_id() AND private.current_role() = 'office');

-- ---------------------------------------------------------------- accounts
-- INSERT: none — trigger on auth.users (above). DELETE: never (cascade
-- from auth.users when the Auth user is deleted).
DROP POLICY IF EXISTS accounts_select_own ON public.accounts;
CREATE POLICY accounts_select_own ON public.accounts
  FOR SELECT TO authenticated
  USING (id = auth.uid());

DROP POLICY IF EXISTS accounts_update_own ON public.accounts;
CREATE POLICY accounts_update_own ON public.accounts
  FOR UPDATE TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- ---------------------------------------------------------------- memberships
-- INSERT: none — server actions only (join-by-code / invite flows).
-- UPDATE/DELETE: office only. DELETE also blocks removing the workspace
-- owner and removing yourself (the server action enforces the same).
DROP POLICY IF EXISTS memberships_select_own_workspace ON public.memberships;
CREATE POLICY memberships_select_own_workspace ON public.memberships
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS memberships_update_office ON public.memberships;
CREATE POLICY memberships_update_office ON public.memberships
  FOR UPDATE TO authenticated
  USING (workspace_id = private.current_workspace_id() AND private.current_role() = 'office')
  WITH CHECK (workspace_id = private.current_workspace_id() AND private.current_role() = 'office');

DROP POLICY IF EXISTS memberships_delete_office ON public.memberships;
CREATE POLICY memberships_delete_office ON public.memberships
  FOR DELETE TO authenticated
  USING (workspace_id = private.current_workspace_id()
         AND private.current_role() = 'office'
         AND account_id <> auth.uid()
         AND account_id <> (SELECT owner_account_id FROM public.workspaces WHERE id = workspace_id));

-- ---------------------------------------------------------------- workspace_counters
-- No policies at all: only the SECURITY DEFINER numbering functions
-- (0001) touch this table, and only the service role may read it.
-- SELECT: none for authenticated (numbers come from the functions).

-- ---------------------------------------------------------------- customers
-- DELETE is any member at the RLS layer, but a customer WITH jobs cannot
-- be deleted at all: jobs.customer_id is ON DELETE RESTRICT (0001).
DROP POLICY IF EXISTS customers_select_member ON public.customers;
CREATE POLICY customers_select_member ON public.customers
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS customers_insert_member ON public.customers;
CREATE POLICY customers_insert_member ON public.customers
  FOR INSERT TO authenticated
  WITH CHECK (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS customers_update_member ON public.customers;
CREATE POLICY customers_update_member ON public.customers
  FOR UPDATE TO authenticated
  USING (workspace_id = private.current_workspace_id())
  WITH CHECK (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS customers_delete_member ON public.customers;
CREATE POLICY customers_delete_member ON public.customers
  FOR DELETE TO authenticated
  USING (workspace_id = private.current_workspace_id());

-- ---------------------------------------------------------------- jobs
-- DELETE: office only, and only when the job has zero invoices — the
-- invoices.job_id RESTRICT FK (0001) makes that a hard DB rule, so the
-- app must archive instead. Status moves are any member, bounded by the
-- transition trigger in 0001.
DROP POLICY IF EXISTS jobs_select_member ON public.jobs;
CREATE POLICY jobs_select_member ON public.jobs
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS jobs_insert_member ON public.jobs;
CREATE POLICY jobs_insert_member ON public.jobs
  FOR INSERT TO authenticated
  WITH CHECK (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS jobs_update_member ON public.jobs;
CREATE POLICY jobs_update_member ON public.jobs
  FOR UPDATE TO authenticated
  USING (workspace_id = private.current_workspace_id())
  WITH CHECK (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS jobs_delete_office ON public.jobs;
CREATE POLICY jobs_delete_office ON public.jobs
  FOR DELETE TO authenticated
  USING (workspace_id = private.current_workspace_id() AND private.current_role() = 'office');

-- ---------------------------------------------------------------- line_items
-- UPDATE: any member at the RLS layer. The draft->approved gate lives in
-- the trigger in 0001 (RLS cannot see both the old and the new row's
-- status in one clause). DELETE: office only — deleting an approved item
-- changes money, and deleting a draft is the reject path (both office).
DROP POLICY IF EXISTS line_items_select_member ON public.line_items;
CREATE POLICY line_items_select_member ON public.line_items
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS line_items_insert_member ON public.line_items;
CREATE POLICY line_items_insert_member ON public.line_items
  FOR INSERT TO authenticated
  WITH CHECK (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS line_items_update_member ON public.line_items;
CREATE POLICY line_items_update_member ON public.line_items
  FOR UPDATE TO authenticated
  USING (workspace_id = private.current_workspace_id())
  WITH CHECK (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS line_items_delete_office ON public.line_items;
CREATE POLICY line_items_delete_office ON public.line_items
  FOR DELETE TO authenticated
  USING (workspace_id = private.current_workspace_id() AND private.current_role() = 'office');

-- ---------------------------------------------------------------- costs
-- UPDATE: never (a cost is corrected by delete + ledger adjustment).
-- DELETE: any member; the server action appends the offsetting ledger row.
DROP POLICY IF EXISTS costs_select_member ON public.costs;
CREATE POLICY costs_select_member ON public.costs
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS costs_insert_member ON public.costs;
CREATE POLICY costs_insert_member ON public.costs
  FOR INSERT TO authenticated
  WITH CHECK (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS costs_delete_member ON public.costs;
CREATE POLICY costs_delete_member ON public.costs
  FOR DELETE TO authenticated
  USING (workspace_id = private.current_workspace_id());

-- ---------------------------------------------------------------- photos
-- UPDATE: any member (the trigger in 0001 allows caption-only changes).
-- DELETE: any member at the RLS layer; the server action also deletes the
-- Storage object and decrements workspaces.storage_used_bytes (v2
-- orphaned the blob — fixed in the app, see 0003_storage.sql).
DROP POLICY IF EXISTS photos_select_member ON public.photos;
CREATE POLICY photos_select_member ON public.photos
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS photos_insert_member ON public.photos;
CREATE POLICY photos_insert_member ON public.photos
  FOR INSERT TO authenticated
  WITH CHECK (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS photos_update_member ON public.photos;
CREATE POLICY photos_update_member ON public.photos
  FOR UPDATE TO authenticated
  USING (workspace_id = private.current_workspace_id())
  WITH CHECK (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS photos_delete_member ON public.photos;
CREATE POLICY photos_delete_member ON public.photos
  FOR DELETE TO authenticated
  USING (workspace_id = private.current_workspace_id());

-- ---------------------------------------------------------------- voice_notes
-- UPDATE/DELETE: never. Notes are history.
DROP POLICY IF EXISTS voice_notes_select_member ON public.voice_notes;
CREATE POLICY voice_notes_select_member ON public.voice_notes
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS voice_notes_insert_member ON public.voice_notes;
CREATE POLICY voice_notes_insert_member ON public.voice_notes
  FOR INSERT TO authenticated
  WITH CHECK (workspace_id = private.current_workspace_id());

-- ---------------------------------------------------------------- invoices
-- INSERT/UPDATE: office only. UPDATE covers status draft/sent/overdue;
-- 'paid' is never set directly — it is derived by the payment flow in
-- code (service role). DELETE: never.
DROP POLICY IF EXISTS invoices_select_member ON public.invoices;
CREATE POLICY invoices_select_member ON public.invoices
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS invoices_insert_office ON public.invoices;
CREATE POLICY invoices_insert_office ON public.invoices
  FOR INSERT TO authenticated
  WITH CHECK (workspace_id = private.current_workspace_id() AND private.current_role() = 'office');

DROP POLICY IF EXISTS invoices_update_office ON public.invoices;
CREATE POLICY invoices_update_office ON public.invoices
  FOR UPDATE TO authenticated
  USING (workspace_id = private.current_workspace_id() AND private.current_role() = 'office')
  WITH CHECK (workspace_id = private.current_workspace_id() AND private.current_role() = 'office');

-- ---------------------------------------------------------------- payments
-- INSERT: office only (covers refunds too — a refund is a negative
-- payment row, also office only). UPDATE/DELETE: never.
DROP POLICY IF EXISTS payments_select_member ON public.payments;
CREATE POLICY payments_select_member ON public.payments
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS payments_insert_office ON public.payments;
CREATE POLICY payments_insert_office ON public.payments
  FOR INSERT TO authenticated
  WITH CHECK (workspace_id = private.current_workspace_id() AND private.current_role() = 'office');

-- ---------------------------------------------------------------- ledger_entries
-- INSERT: none for authenticated — server actions only (service role).
-- UPDATE/DELETE: never for anyone (trigger in 0001 as well).
DROP POLICY IF EXISTS ledger_entries_select_member ON public.ledger_entries;
CREATE POLICY ledger_entries_select_member ON public.ledger_entries
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

-- ---------------------------------------------------------------- price_books / price_book_items
-- INSERT: office only. UPDATE/DELETE: none for authenticated — a new
-- version is created instead, and the is_active flip that activates it
-- runs as the service role (the trigger in 0001 permits is_active-only
-- changes and nothing else).
DROP POLICY IF EXISTS price_books_select_member ON public.price_books;
CREATE POLICY price_books_select_member ON public.price_books
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS price_books_insert_office ON public.price_books;
CREATE POLICY price_books_insert_office ON public.price_books
  FOR INSERT TO authenticated
  WITH CHECK (workspace_id = private.current_workspace_id() AND private.current_role() = 'office');

DROP POLICY IF EXISTS price_book_items_select_member ON public.price_book_items;
CREATE POLICY price_book_items_select_member ON public.price_book_items
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS price_book_items_insert_office ON public.price_book_items;
CREATE POLICY price_book_items_insert_office ON public.price_book_items
  FOR INSERT TO authenticated
  WITH CHECK (workspace_id = private.current_workspace_id() AND private.current_role() = 'office');

-- ---------------------------------------------------------------- sync_outbox
-- INSERT: any member (server-action path). UPDATE/DELETE: none for
-- authenticated — the server action marks rows applied/failed.
DROP POLICY IF EXISTS sync_outbox_select_member ON public.sync_outbox;
CREATE POLICY sync_outbox_select_member ON public.sync_outbox
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS sync_outbox_insert_member ON public.sync_outbox;
CREATE POLICY sync_outbox_insert_member ON public.sync_outbox
  FOR INSERT TO authenticated
  WITH CHECK (workspace_id = private.current_workspace_id());

-- ---------------------------------------------------------------- job_events
-- INSERT: none for authenticated — server actions only. UPDATE/DELETE:
-- never for anyone (trigger in 0001 blocks UPDATE; DELETE only via the
-- service-role deleteJob path, zero invoices only).
DROP POLICY IF EXISTS job_events_select_member ON public.job_events;
CREATE POLICY job_events_select_member ON public.job_events
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

-- ---------------------------------------------------------------- documents
-- INSERT/UPDATE/DELETE: none for authenticated — server actions only.
-- UPDATE is also blocked by the frozen-document trigger in 0001; DELETE
-- is only possible through the service-role deleteJob path.
DROP POLICY IF EXISTS documents_select_member ON public.documents;
CREATE POLICY documents_select_member ON public.documents
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

-- ---------------------------------------------------------------- sync_refs
-- INSERT/UPDATE/DELETE: none for authenticated — server actions only.
DROP POLICY IF EXISTS sync_refs_select_member ON public.sync_refs;
CREATE POLICY sync_refs_select_member ON public.sync_refs
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

-- ---------------------------------------------------------------- client_updates
-- Any member: draft, send (via the flows), mark sent, delete.
DROP POLICY IF EXISTS client_updates_select_member ON public.client_updates;
CREATE POLICY client_updates_select_member ON public.client_updates
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS client_updates_insert_member ON public.client_updates;
CREATE POLICY client_updates_insert_member ON public.client_updates
  FOR INSERT TO authenticated
  WITH CHECK (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS client_updates_update_member ON public.client_updates;
CREATE POLICY client_updates_update_member ON public.client_updates
  FOR UPDATE TO authenticated
  USING (workspace_id = private.current_workspace_id())
  WITH CHECK (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS client_updates_delete_member ON public.client_updates;
CREATE POLICY client_updates_delete_member ON public.client_updates
  FOR DELETE TO authenticated
  USING (workspace_id = private.current_workspace_id());
