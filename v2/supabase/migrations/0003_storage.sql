-- Contractor Corner — Supabase migration 0003: private photo storage
-- Stage 3 standalone rebuild, Worker 2.
-- Implements the bucket design in v2/docs/ARCHITECTURE.md §6.
--
-- Bucket: `job-photos`, PRIVATE (no public access).
-- Paths: <workspace_id>/<job_id>/<uuid>.<ext> — the workspace segment
--   means a path alone proves tenancy. photos.blob_key stores this path;
--   photos.storage_provider = 'supabase_storage'.
-- Read path: the app mints 1-hour signed URLs server-side, never public
--   URLs. Signed URLs are never stored in the database.
-- Upload path: browser uploads directly with these storage policies
--   (preferred), falling back to a Route Handler if policy authoring
--   proves awkward in the app worker.
-- Validation: MIME allowlist image/jpeg, image/png, image/webp and a
--   10 MB per-file cap are enforced AT THE BUCKET (below) and again in
--   the app (Route Handler / server action, as v2 did). The client
--   resizes first (max edge 1400px, JPEG 0.82) — resized photos are
--   typically under 500 KB; the 10 MB cap is a guard, not a target.
-- Quota: per-workspace soft cap 5 GB (env WORKSPACE_STORAGE_CAP_BYTES),
--   enforced in app code against workspaces.storage_used_bytes.
--   Uploads beyond the cap are rejected with a plain-language error.
-- Delete: the app's deletePhoto deletes the Storage object AND the
--   photos row AND decrements the counter in one transaction — v2
--   orphaned the blob. The DELETE policy below is office-only for
--   direct browser deletes; the server action runs as the service role
--   (bypasses storage RLS), so a field member deleting a photo through
--   the app still removes the object. That is the intended split:
--   direct Storage deletes are office-only, app-mediated deletes go
--   through the server action for any member.
--
-- The resized upload IS the stored file (same as v2 — the phone never
-- uploads the full-size original). No original-file retention.

-- ---------------------------------------------------------------- bucket
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'job-photos',
  'job-photos',
  false,
  10485760, -- 10 MB per file
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ---------------------------------------------------------------- policies
-- storage.objects RLS is enabled by default in Supabase. Each policy
-- requires the object path's first segment to be the caller's workspace
-- id (as text), and the caller to be a member (current_workspace_id()
-- returns NULL for non-members, so the comparison fails closed).
-- storage.foldername(name) returns the path segments as text[]; [1] is
-- the first segment, i.e. <workspace_id>.

DROP POLICY IF EXISTS "job_photos_select_member" ON storage.objects;
CREATE POLICY "job_photos_select_member" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'job-photos'
    AND (storage.foldername(name))[1] = private.current_workspace_id()::text
  );

DROP POLICY IF EXISTS "job_photos_insert_member" ON storage.objects;
CREATE POLICY "job_photos_insert_member" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'job-photos'
    AND (storage.foldername(name))[1] = private.current_workspace_id()::text
  );

-- No UPDATE policy: stored objects are immutable (a re-upload is a new
-- object path; the photos row points at the new path).
-- DELETE: office only for direct browser deletes (see header note).
DROP POLICY IF EXISTS "job_photos_delete_office" ON storage.objects;
CREATE POLICY "job_photos_delete_office" ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'job-photos'
    AND (storage.foldername(name))[1] = private.current_workspace_id()::text
    AND private.current_role() = 'office'
  );
