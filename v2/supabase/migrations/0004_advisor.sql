-- Contractor Corner — Supabase migration 0004: Advisor (Phase 1) + sync conflicts
-- Stage 3 standalone rebuild, Worker 2.
-- Implements v2/docs/ARCHITECTURE.md §7.1 (sync_conflicts) and §10
-- (Advisor Phase 1: rules-only checks, ZERO inference calls, zero added
-- running cost). No inference provider is wired here; Phase 2 adds one
-- method to the existing Advisor provider interface and needs no schema
-- change.
--
-- Naming: the feature is "Advisor" in any user-visible string (Rob,
-- 2026-11-16). These table/column names are internal, but no user-facing
-- label in the app may say "AI" — the questionnaire, Setup section and
-- alert wording all say Advisor.
--
-- Tables:
--  * advisor_business_preferences — one row per business (the trimmed
--    questionnaire answers + master off switch). Office only to change.
--  * advisor_account_preferences — one row per account (personal
--    surfacing only — changes highlighting, never whether an alert
--    exists). Each account edits only their own row.
--  * advisor_alerts — the suppression memory. Read-only for members:
--    "Review" links to the relevant job section; the Advisor gets no
--    edit action. Answering an alert is a business-level act (office
--    only) and is recorded in job_events as advisor_alert_answered.
--  * advisor_usage_monthly — the usage counter. Phase 1 makes zero
--    inference calls, so inference_calls stays at 0; the table exists
--    now so Phase 2's ceiling check has somewhere to live. Ceiling
--    default 50 calls/business/month (env ADVISOR_MONTHLY_CEILING).
--  * sync_conflicts — one row per offline-vs-server clash that needs a
--    human decision (job detail edits / status changes only; field
--    captures that only append — voice notes, photos, costs, notes —
--    never conflict, and money fields are office-wins, so no queued
--    capture ever writes them). Office resolves by picking Keep office
--    version or Apply field change.

-- ---------------------------------------------------------------- enums
DO $$ BEGIN
  CREATE TYPE advisor_check_type_enum AS ENUM
    ('forgotten_expenses', 'missing_material_labour', 'unpaid_invoices',
     'cost_overrun', 'low_margin', 'drafts_waiting');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
-- The five Phase 1 checks (§10.2) plus drafts_waiting, which v2 already
-- surfaces as a follow-up and is kept as an alert source.

DO $$ BEGIN
  CREATE TYPE advisor_severity_enum AS ENUM ('high', 'medium', 'low');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE advisor_alert_state_enum AS ENUM
    ('open', 'reviewed', 'accounted_for', 'dismissed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE advisor_proactiveness_enum AS ENUM
    ('conservative', 'balanced', 'detailed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE advisor_surfacing_enum AS ENUM
    ('important_only', 'important_and_savers', 'everything');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE sync_conflict_kind_enum AS ENUM ('status_change', 'job_edit');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE sync_conflict_state_enum AS ENUM ('open', 'resolved');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE sync_conflict_resolution_enum AS ENUM ('kept_office', 'applied_field');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ---------------------------------------------------------------- tables
CREATE TABLE IF NOT EXISTS public.advisor_business_preferences (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL UNIQUE REFERENCES public.workspaces (id) ON DELETE CASCADE,
  check_forgotten_expenses boolean NOT NULL DEFAULT true,
  check_missing_material_labour boolean NOT NULL DEFAULT true,
  check_unpaid_invoices boolean NOT NULL DEFAULT true,
  check_cost_overrun boolean NOT NULL DEFAULT true,
  check_low_margin boolean NOT NULL DEFAULT true,
  margin_floor_percent integer NOT NULL DEFAULT 20 CHECK (margin_floor_percent >= 0 AND margin_floor_percent <= 100),
  overrun_threshold_percent integer NOT NULL DEFAULT 100 CHECK (overrun_threshold_percent >= 0),
  proactiveness advisor_proactiveness_enum NOT NULL DEFAULT 'balanced',
  advisor_enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.advisor_business_preferences IS
  'One row per business. Set once by the business owner during creation (questionnaire), editable later in Setup by office only. Turning advisor_enabled off stops all checks AND hides all alerts.';

CREATE TABLE IF NOT EXISTS public.advisor_account_preferences (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  account_id uuid NOT NULL UNIQUE REFERENCES public.accounts (id) ON DELETE CASCADE,
  surfacing advisor_surfacing_enum NOT NULL DEFAULT 'important_only',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, account_id)
);
COMMENT ON TABLE public.advisor_account_preferences IS
  'One row per account. Personal surfacing only — it changes highlighting, never whether an alert exists. Editable by the account themselves in Setup.';

CREATE TABLE IF NOT EXISTS public.advisor_alerts (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  job_id bigint REFERENCES public.jobs (id) ON DELETE SET NULL,
  check_type advisor_check_type_enum NOT NULL,
  document_id bigint REFERENCES public.documents (id) ON DELETE SET NULL,
  severity advisor_severity_enum NOT NULL,
  state advisor_alert_state_enum NOT NULL DEFAULT 'open',
  figures jsonb NOT NULL DEFAULT '{}'::jsonb,
  message text NOT NULL CHECK (message <> ''),
  answered_by uuid REFERENCES public.accounts (id) ON DELETE SET NULL,
  answered_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.advisor_alerts IS
  'The suppression memory. Suppression is keyed to the frozen document: same job + same check + same document version, once answered, is never raised again (partial unique index below). A re-issued estimate is a new document version, so the check may run once on it. Alerts are read-only: Review links to the relevant job section. Wording is always a question, never an accusation, and every alert says what was checked. figures holds the numbers the alert was raised from — a figure comes from the job, the price book, or the ledger, or it is not stated.';

-- Suppression, document-bound alerts only: same job + same check + same
-- frozen document version can exist once. (document_id IS NULL rows —
-- unpaid-invoice / cost-overrun / drafts-waiting checks, which have no
-- frozen document — are deliberately NOT covered by a unique index:
-- they may legitimately re-raise after the underlying figures change,
-- and suppression for them lives in app code.)
CREATE UNIQUE INDEX IF NOT EXISTS advisor_alerts_suppression_idx
  ON public.advisor_alerts (workspace_id, job_id, check_type, document_id)
  WHERE document_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.advisor_usage_monthly (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  month text NOT NULL CHECK (month ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  inference_calls integer NOT NULL DEFAULT 0 CHECK (inference_calls >= 0),
  ceiling integer NOT NULL DEFAULT 50 CHECK (ceiling >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, month)
);
COMMENT ON TABLE public.advisor_usage_monthly IS
  'The usage counter. Phase 1 makes ZERO inference calls, so inference_calls stays at 0 — it exists now so Phase 2''s ceiling check has somewhere to live. Ceiling default 50 calls/business/month (tunable via env ADVISOR_MONTHLY_CEILING); hitting it turns inference off while rules keep running. month is YYYY-MM.';

CREATE TABLE IF NOT EXISTS public.sync_conflicts (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id bigint NOT NULL REFERENCES public.workspaces (id) ON DELETE CASCADE,
  job_id bigint REFERENCES public.jobs (id) ON DELETE SET NULL,
  outbox_id bigint REFERENCES public.sync_outbox (id) ON DELETE SET NULL,
  kind sync_conflict_kind_enum NOT NULL,
  field_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  server_value jsonb NOT NULL DEFAULT '{}'::jsonb,
  state sync_conflict_state_enum NOT NULL DEFAULT 'open',
  resolved_by uuid REFERENCES public.accounts (id) ON DELETE SET NULL,
  resolution sync_conflict_resolution_enum,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  CHECK (state <> 'resolved' OR (resolution IS NOT NULL AND resolved_by IS NOT NULL AND resolved_at IS NOT NULL)),
  CHECK (state = 'resolved' OR resolution IS NULL)
);
COMMENT ON TABLE public.sync_conflicts IS
  'One row per offline-vs-server clash needing a human decision. A queued status_change / job edit whose server state moved since the capture was queued is marked failed AND lands here (never silently overwritten, never silently failed). An office member resolves each one: Keep office version (discards the field change) or Apply field change (applies it through the normal status machine / edit path, logging a job_events row with the resolver''s name). Resolution writes the outcome here and marks the outbox row applied (if applied) or leaves it failed with the resolution noted.';

-- ---------------------------------------------------------------- indexes
CREATE INDEX IF NOT EXISTS advisor_alerts_workspace_state_idx
  ON public.advisor_alerts (workspace_id, state);
CREATE INDEX IF NOT EXISTS advisor_alerts_job_id_idx
  ON public.advisor_alerts (job_id);
CREATE INDEX IF NOT EXISTS sync_conflicts_workspace_state_idx
  ON public.sync_conflicts (workspace_id, state);
CREATE INDEX IF NOT EXISTS sync_conflicts_job_id_idx
  ON public.sync_conflicts (job_id);
CREATE INDEX IF NOT EXISTS advisor_usage_monthly_workspace_idx
  ON public.advisor_usage_monthly (workspace_id, month);

-- ---------------------------------------------------------------- triggers
DROP TRIGGER IF EXISTS advisor_business_preferences_touch_updated_at
  ON public.advisor_business_preferences;
CREATE TRIGGER advisor_business_preferences_touch_updated_at
  BEFORE UPDATE ON public.advisor_business_preferences
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

DROP TRIGGER IF EXISTS advisor_account_preferences_touch_updated_at
  ON public.advisor_account_preferences;
CREATE TRIGGER advisor_account_preferences_touch_updated_at
  BEFORE UPDATE ON public.advisor_account_preferences
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

DROP TRIGGER IF EXISTS advisor_usage_monthly_touch_updated_at
  ON public.advisor_usage_monthly;
CREATE TRIGGER advisor_usage_monthly_touch_updated_at
  BEFORE UPDATE ON public.advisor_usage_monthly
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- ---------------------------------------------------------------- RLS
ALTER TABLE public.advisor_business_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.advisor_account_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.advisor_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.advisor_usage_monthly ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sync_conflicts ENABLE ROW LEVEL SECURITY;

-- Grants for these tables (0002's blanket grant ran before they existed).
GRANT SELECT, INSERT, UPDATE, DELETE ON
  public.advisor_business_preferences,
  public.advisor_account_preferences,
  public.advisor_alerts,
  public.advisor_usage_monthly,
  public.sync_conflicts
  TO anon, authenticated, service_role;

-- Business preferences: anyone in the workspace may read; only office
-- may insert/update (set by the owner at creation, editable in Setup).
-- DELETE: never.
DROP POLICY IF EXISTS advisor_business_preferences_select_member
  ON public.advisor_business_preferences;
CREATE POLICY advisor_business_preferences_select_member
  ON public.advisor_business_preferences
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS advisor_business_preferences_insert_office
  ON public.advisor_business_preferences;
CREATE POLICY advisor_business_preferences_insert_office
  ON public.advisor_business_preferences
  FOR INSERT TO authenticated
  WITH CHECK (workspace_id = private.current_workspace_id() AND private.current_role() = 'office');

DROP POLICY IF EXISTS advisor_business_preferences_update_office
  ON public.advisor_business_preferences;
CREATE POLICY advisor_business_preferences_update_office
  ON public.advisor_business_preferences
  FOR UPDATE TO authenticated
  USING (workspace_id = private.current_workspace_id() AND private.current_role() = 'office')
  WITH CHECK (workspace_id = private.current_workspace_id() AND private.current_role() = 'office');

-- Account preferences: each account sees and edits ONLY their own row.
-- (An office member has no business reading a teammate's surfacing
-- choice; the row changes highlighting, never whether an alert exists.)
DROP POLICY IF EXISTS advisor_account_preferences_select_own
  ON public.advisor_account_preferences;
CREATE POLICY advisor_account_preferences_select_own
  ON public.advisor_account_preferences
  FOR SELECT TO authenticated
  USING (account_id = auth.uid());

DROP POLICY IF EXISTS advisor_account_preferences_insert_own
  ON public.advisor_account_preferences;
CREATE POLICY advisor_account_preferences_insert_own
  ON public.advisor_account_preferences
  FOR INSERT TO authenticated
  WITH CHECK (account_id = auth.uid() AND workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS advisor_account_preferences_update_own
  ON public.advisor_account_preferences;
CREATE POLICY advisor_account_preferences_update_own
  ON public.advisor_account_preferences
  FOR UPDATE TO authenticated
  USING (account_id = auth.uid())
  WITH CHECK (account_id = auth.uid() AND workspace_id = private.current_workspace_id());

-- Alerts: anyone in the workspace may read; only the server creates
-- them (no INSERT policy); only office may answer one (state /
-- answered_by / answered_at); DELETE: never — alerts are answered,
-- not deleted.
DROP POLICY IF EXISTS advisor_alerts_select_member ON public.advisor_alerts;
CREATE POLICY advisor_alerts_select_member ON public.advisor_alerts
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS advisor_alerts_update_office ON public.advisor_alerts;
CREATE POLICY advisor_alerts_update_office ON public.advisor_alerts
  FOR UPDATE TO authenticated
  USING (workspace_id = private.current_workspace_id() AND private.current_role() = 'office')
  WITH CHECK (workspace_id = private.current_workspace_id() AND private.current_role() = 'office');

-- Usage: anyone in the workspace may read (Setup shows it); only the
-- server increments it (no INSERT/UPDATE policies); DELETE: never.
DROP POLICY IF EXISTS advisor_usage_monthly_select_member
  ON public.advisor_usage_monthly;
CREATE POLICY advisor_usage_monthly_select_member
  ON public.advisor_usage_monthly
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

-- Sync conflicts: anyone in the workspace may read (Setup sync screen
-- surfaces open conflicts); only the server creates them (no INSERT
-- policy); only office may resolve one (UPDATE); DELETE: never.
DROP POLICY IF EXISTS sync_conflicts_select_member ON public.sync_conflicts;
CREATE POLICY sync_conflicts_select_member ON public.sync_conflicts
  FOR SELECT TO authenticated
  USING (workspace_id = private.current_workspace_id());

DROP POLICY IF EXISTS sync_conflicts_update_office ON public.sync_conflicts;
CREATE POLICY sync_conflicts_update_office ON public.sync_conflicts
  FOR UPDATE TO authenticated
  USING (workspace_id = private.current_workspace_id() AND private.current_role() = 'office')
  WITH CHECK (workspace_id = private.current_workspace_id() AND private.current_role() = 'office');
