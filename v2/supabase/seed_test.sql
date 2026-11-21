-- Contractor Corner — TEST-ONLY seed data
-- Stage 3 standalone rebuild, Worker 2.
--
-- ⚠️  NEVER apply this to a production project. Local verification only,
--     on a throwaway/dev Supabase project. It creates fake business data
--     (a demo workspace, two test accounts, one test customer/job) so the
--     app worker can click through the quote-to-cash loop without typing
--     everything in by hand. Delete the seeded rows (or the whole project)
--     when done.
--
-- PREREQUISITES (do these first, in order):
--  1. Apply migrations 0001–0004 to the dev project.
--  2. Create TWO users in the Supabase dashboard (Authentication → Users):
--       - office test user  (e.g. office-test@example.com)
--       - field test user   (e.g. field-test@example.com)
--     or sign them up through the app's sign-up page.
--  3. Paste each user's Auth UUID below, replacing the two placeholder
--     values in the DECLARE section. The accounts rows reference
--     auth.users, so made-up UUIDs will FAIL — the guard below stops the
--     script and tells you which one is missing.
--  4. Run this file in the Supabase SQL editor while signed in as the
--     project owner (postgres role). It bypasses RLS, which is required:
--     the memberships/workspaces rows cannot be created as an ordinary
--     member. Do NOT run it as an anon/authenticated app user.
--
-- After seeding, sign in to the app as the office test user: you should
-- see one business ("Better Than Your Husband (TEST)"), one customer
-- (Linda Whitaker — TEST), one job (lead), one approved line item, and
-- default Advisor preferences. The field test user should see the same
-- business as a field member.

DO $$
DECLARE
  -- TODO: replace these two values with the real Auth UUIDs from
  -- Authentication → Users (step 2–3 above). Keep the single quotes.
  v_office uuid := '11111111-1111-1111-1111-111111111111'; -- office test user (Cherylene's stand-in: office role, business owner)
  v_field  uuid := '22222222-2222-2222-2222-222222222222'; -- field test user (Jeremy's stand-in: field role)
  v_workspace_id bigint;
  v_customer_id bigint;
  v_job_id bigint;
BEGIN
  -- Guard: refuse if the Auth users do not exist yet. This also catches
  -- the placeholder UUIDs still being in place (no auth.users row can
  -- ever have those ids), so there is no separate placeholder check to
  -- keep in sync — the message below names the missing UUID.
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = v_office) THEN
    RAISE EXCEPTION 'seed_test.sql: no auth.users row for the office UUID % — create that user first (see header steps 2-3)', v_office;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = v_field) THEN
    RAISE EXCEPTION 'seed_test.sql: no auth.users row for the field UUID % — create that user first (see header steps 2-3)', v_field;
  END IF;

  -- 1. Demo workspace (owner = office test user). The workspace_counters
  -- row (EST-/INV- numbering) is auto-created by the trigger in 0001.
  -- invite_code is a clearly-fake TEST value.
  -- Re-runnable: if the TEST workspace already exists (from an earlier
  -- run), reuse it instead of creating a duplicate.
  SELECT id INTO v_workspace_id FROM public.workspaces
  WHERE business_name = 'Better Than Your Husband (TEST)';
  IF v_workspace_id IS NULL THEN
    INSERT INTO public.workspaces (business_name, trade, owner_account_id, invite_code)
    VALUES ('Better Than Your Husband (TEST)', 'handyman', v_office, 'TEST-JOIN-1234')
    RETURNING id INTO v_workspace_id;
  END IF;

  -- 2. Test accounts + memberships. The handle_new_user trigger (0002)
  -- normally creates accounts rows at sign-up; these inserts cover the
  -- case where the users were created in the dashboard before the
  -- trigger existed. ON CONFLICT keeps re-runs safe.
  INSERT INTO public.accounts (id, display_name)
  VALUES (v_office, 'Test Office'), (v_field, 'Test Field')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  INSERT INTO public.memberships (account_id, workspace_id, role)
  VALUES (v_office, v_workspace_id, 'office')
  ON CONFLICT (account_id) DO NOTHING;

  INSERT INTO public.memberships (account_id, workspace_id, role)
  VALUES (v_field, v_workspace_id, 'field')
  ON CONFLICT (account_id) DO NOTHING;

  -- 3. Test customer + job. Re-runnable: reuse existing rows by name.
  SELECT id INTO v_customer_id FROM public.customers
  WHERE workspace_id = v_workspace_id AND name = 'Linda Whitaker (TEST)';
  IF v_customer_id IS NULL THEN
    INSERT INTO public.customers (workspace_id, name, phone, email, address, notes)
    VALUES (v_workspace_id, 'Linda Whitaker (TEST)', '913-555-0100', 'test-linda@example.com',
            '123 Test Street, Kansas City, MO', 'TEST-ONLY customer — not a real person.')
    RETURNING id INTO v_customer_id;
  END IF;

  SELECT id INTO v_job_id FROM public.jobs
  WHERE workspace_id = v_workspace_id AND title = 'Test job — fix leaking tap (TEST)';
  IF v_job_id IS NULL THEN
    INSERT INTO public.jobs (workspace_id, customer_id, title, description, address, status)
    VALUES (v_workspace_id, v_customer_id, 'Test job — fix leaking tap (TEST)',
            'TEST-ONLY job for local verification.',
            '123 Test Street, Kansas City, MO', 'lead')
    RETURNING id INTO v_job_id;
  END IF;

  -- 4. One approved line item + one cost (quote math to eyeball).
  -- Re-runnable: skip when a line with the same description exists.
  IF NOT EXISTS (SELECT 1 FROM public.line_items
                 WHERE job_id = v_job_id AND description = 'Labour — tap repair (TEST)') THEN
    INSERT INTO public.line_items (workspace_id, job_id, description, qty, unit_price_cents, kind, source, status)
    VALUES (v_workspace_id, v_job_id, 'Labour — tap repair (TEST)', 2, 7500, 'labor', 'manual', 'approved');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.costs
                 WHERE job_id = v_job_id AND description = 'Replacement tap cartridge (TEST)') THEN
    INSERT INTO public.costs (workspace_id, job_id, description, amount_cents, kind)
    VALUES (v_workspace_id, v_job_id, 'Replacement tap cartridge (TEST)', 3200, 'material');
  END IF;

  -- 5. Default Advisor preferences (as the questionnaire would set them).
  INSERT INTO public.advisor_business_preferences (workspace_id)
  VALUES (v_workspace_id)
  ON CONFLICT (workspace_id) DO NOTHING;

  INSERT INTO public.advisor_account_preferences (workspace_id, account_id, surfacing)
  VALUES (v_workspace_id, v_office, 'important_only')
  ON CONFLICT (account_id) DO NOTHING;

  INSERT INTO public.advisor_account_preferences (workspace_id, account_id, surfacing)
  VALUES (v_workspace_id, v_field, 'important_only')
  ON CONFLICT (account_id) DO NOTHING;

  RAISE NOTICE 'seed_test.sql done: workspace %, customer %, job %', v_workspace_id, v_customer_id, v_job_id;
END $$;

-- What you should see after running this:
-- workspaces: 1 TEST business, owner = office test user.
-- memberships: office test user = office, field test user = field.
-- customers: Linda Whitaker (TEST). jobs: 1 lead job.
-- line_items: 1 approved labour line, 2 × $75.00 = $150.00 quote.
-- costs: 1 material cost, $32.00. Advisor prefs: defaults (all five
-- checks on, Balanced, Important only, Advisor enabled).
-- No invoices, payments, ledger rows, documents or alerts are seeded:
-- create those through the app to verify the flows end to end.
-- First numbers the app will mint: EST-1001 / INV-1001.
