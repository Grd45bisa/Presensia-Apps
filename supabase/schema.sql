-- ============================================================
-- FaceWork Tracker — Complete Supabase Schema
-- Jalankan di: Supabase Dashboard → SQL Editor → New Query
-- Jalankan sekali dari atas ke bawah (urutan penting)
-- ============================================================


-- ============================================================
-- 1. TABEL PROFILES
--    Satu baris per karyawan, id = auth.uid()
-- ============================================================

CREATE TABLE IF NOT EXISTS profiles (
  id                     UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name              TEXT NOT NULL DEFAULT '',
  email                  TEXT NOT NULL DEFAULT '',
  avatar_url             TEXT,
  department             TEXT,
  position               TEXT,
  phone_number           TEXT,
  notifications_enabled  BOOLEAN NOT NULL DEFAULT TRUE,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Karyawan baca profil sendiri"
  ON profiles FOR SELECT
  USING (id = auth.uid());

CREATE POLICY "Karyawan buat profil sendiri"
  ON profiles FOR INSERT
  WITH CHECK (id = auth.uid());

CREATE POLICY "Karyawan update profil sendiri"
  ON profiles FOR UPDATE
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- Trigger: auto-update updated_at
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();


-- ============================================================
-- 2. TABEL WORK_SCHEDULE_SETTINGS
--    Satu baris per karyawan, upsert by employee_id
-- ============================================================

CREATE TABLE IF NOT EXISTS work_schedule_settings (
  employee_id                        UUID PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  off_days                           INT[]    NOT NULL DEFAULT '{6,7}',
  default_reminder_offsets_minutes   INT[]    NOT NULL DEFAULT '{15,5}',
  auto_mark_missing_attendance       BOOLEAN  NOT NULL DEFAULT TRUE,
  created_at                         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE work_schedule_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Karyawan baca settings sendiri"
  ON work_schedule_settings FOR SELECT
  USING (employee_id = auth.uid());

CREATE POLICY "Karyawan buat settings sendiri"
  ON work_schedule_settings FOR INSERT
  WITH CHECK (employee_id = auth.uid());

CREATE POLICY "Karyawan update settings sendiri"
  ON work_schedule_settings FOR UPDATE
  USING (employee_id = auth.uid())
  WITH CHECK (employee_id = auth.uid());

CREATE TRIGGER work_schedule_settings_updated_at
  BEFORE UPDATE ON work_schedule_settings
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();


-- ============================================================
-- 3. TABEL ATTENDANCE_RECORDS
--    Satu baris per karyawan per hari, UNIQUE(employee_id, date)
-- ============================================================

CREATE TYPE attendance_source AS ENUM ('face', 'manual');
CREATE TYPE attendance_status AS ENUM (
  'present', 'leave', 'sick', 'training',
  'meeting', 'holiday', 'otherException'
);

CREATE TABLE IF NOT EXISTS attendance_records (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id  UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  date         DATE NOT NULL,
  source       attendance_source NOT NULL DEFAULT 'manual',
  status       attendance_status NOT NULL DEFAULT 'present',
  check_in     TIMESTAMPTZ,
  check_out    TIMESTAMPTZ,
  note         TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT attendance_records_employee_date_unique UNIQUE (employee_id, date)
);

CREATE INDEX idx_attendance_employee_date
  ON attendance_records (employee_id, date DESC);

ALTER TABLE attendance_records ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Karyawan baca absensi sendiri"
  ON attendance_records FOR SELECT
  USING (employee_id = auth.uid());

CREATE POLICY "Karyawan buat absensi sendiri"
  ON attendance_records FOR INSERT
  WITH CHECK (employee_id = auth.uid());

CREATE POLICY "Karyawan update absensi sendiri"
  ON attendance_records FOR UPDATE
  USING (employee_id = auth.uid())
  WITH CHECK (employee_id = auth.uid());

CREATE POLICY "Karyawan hapus absensi sendiri"
  ON attendance_records FOR DELETE
  USING (employee_id = auth.uid());

CREATE TRIGGER attendance_records_updated_at
  BEFORE UPDATE ON attendance_records
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();


-- ============================================================
-- 4. TABEL PROJECTS
--    Daftar project/kategori pekerjaan per karyawan
-- ============================================================

CREATE TABLE IF NOT EXISTS projects (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id   UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  project_name  TEXT NOT NULL,
  color         TEXT NOT NULL DEFAULT '#1565C0',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_projects_employee
  ON projects (employee_id, project_name ASC);

ALTER TABLE projects ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Karyawan baca project sendiri"
  ON projects FOR SELECT
  USING (employee_id = auth.uid());

CREATE POLICY "Karyawan buat project sendiri"
  ON projects FOR INSERT
  WITH CHECK (employee_id = auth.uid());

CREATE POLICY "Karyawan update project sendiri"
  ON projects FOR UPDATE
  USING (employee_id = auth.uid())
  WITH CHECK (employee_id = auth.uid());

CREATE POLICY "Karyawan hapus project sendiri"
  ON projects FOR DELETE
  USING (employee_id = auth.uid());

CREATE TRIGGER projects_updated_at
  BEFORE UPDATE ON projects
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();


-- ============================================================
-- 5. TABEL WORKLOG_ENTRIES
--    Catatan pekerjaan harian per karyawan
-- ============================================================

CREATE TABLE IF NOT EXISTS worklog_entries (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id    UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  date           DATE NOT NULL,
  task_name      TEXT NOT NULL,
  project_name   TEXT NOT NULL,
  project_color  TEXT NOT NULL DEFAULT '#1565C0',
  start_time     TIMESTAMPTZ,
  end_time       TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_worklog_employee_date
  ON worklog_entries (employee_id, date DESC, start_time ASC);

ALTER TABLE worklog_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Karyawan baca worklog sendiri"
  ON worklog_entries FOR SELECT
  USING (employee_id = auth.uid());

CREATE POLICY "Karyawan buat worklog sendiri"
  ON worklog_entries FOR INSERT
  WITH CHECK (employee_id = auth.uid());

CREATE POLICY "Karyawan update worklog sendiri"
  ON worklog_entries FOR UPDATE
  USING (employee_id = auth.uid())
  WITH CHECK (employee_id = auth.uid());

CREATE POLICY "Karyawan hapus worklog sendiri"
  ON worklog_entries FOR DELETE
  USING (employee_id = auth.uid());

CREATE TRIGGER worklog_entries_updated_at
  BEFORE UPDATE ON worklog_entries
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();


-- ============================================================
-- 6. TABEL REMINDER_EVENTS
--    Kalender / event reminder per karyawan
-- ============================================================

CREATE TABLE IF NOT EXISTS reminder_events (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id               UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  title                     TEXT NOT NULL,
  description               TEXT,
  location                  TEXT,
  start_datetime            TIMESTAMPTZ NOT NULL,
  end_datetime              TIMESTAMPTZ,
  is_all_day                BOOLEAN NOT NULL DEFAULT FALSE,
  reminder_offsets_minutes  INT[] NOT NULL DEFAULT '{15}',
  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_reminder_employee_start
  ON reminder_events (employee_id, start_datetime ASC);

ALTER TABLE reminder_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Karyawan baca reminder sendiri"
  ON reminder_events FOR SELECT
  USING (employee_id = auth.uid());

CREATE POLICY "Karyawan buat reminder sendiri"
  ON reminder_events FOR INSERT
  WITH CHECK (employee_id = auth.uid());

CREATE POLICY "Karyawan update reminder sendiri"
  ON reminder_events FOR UPDATE
  USING (employee_id = auth.uid())
  WITH CHECK (employee_id = auth.uid());

CREATE POLICY "Karyawan hapus reminder sendiri"
  ON reminder_events FOR DELETE
  USING (employee_id = auth.uid());

CREATE TRIGGER reminder_events_updated_at
  BEFORE UPDATE ON reminder_events
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();


-- ============================================================
-- 7. TABEL ACTIVE_TIMERS
--    Menyimpan state timer yang sedang berjalan (1 per karyawan)
-- ============================================================

CREATE TABLE IF NOT EXISTS active_timers (
  employee_id  UUID PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  start_time   TIMESTAMPTZ NOT NULL,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE active_timers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Karyawan baca timer sendiri"
  ON active_timers FOR SELECT
  USING (employee_id = auth.uid());

CREATE POLICY "Karyawan buat timer sendiri"
  ON active_timers FOR INSERT
  WITH CHECK (employee_id = auth.uid());

CREATE POLICY "Karyawan update timer sendiri"
  ON active_timers FOR UPDATE
  USING (employee_id = auth.uid())
  WITH CHECK (employee_id = auth.uid());

CREATE POLICY "Karyawan hapus timer sendiri"
  ON active_timers FOR DELETE
  USING (employee_id = auth.uid());

CREATE TRIGGER active_timers_updated_at
  BEFORE UPDATE ON active_timers
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();


-- ============================================================
-- 8. TABEL FACE_EMBEDDINGS
--    Embedding wajah CNN (SFace 128-dim) — backup cloud
--    Data biometrik ini tidak pernah dikirim ke pihak ketiga.
-- ============================================================

CREATE TABLE IF NOT EXISTS face_embeddings (
  employee_id      UUID PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  embedding        TEXT NOT NULL,
  face_enrollment_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE face_embeddings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Karyawan baca embedding sendiri"
  ON face_embeddings FOR SELECT
  USING (employee_id = auth.uid());

CREATE POLICY "Karyawan simpan embedding sendiri"
  ON face_embeddings FOR INSERT
  WITH CHECK (employee_id = auth.uid());

CREATE POLICY "Karyawan update embedding sendiri"
  ON face_embeddings FOR UPDATE
  USING (employee_id = auth.uid())
  WITH CHECK (employee_id = auth.uid());

CREATE POLICY "Karyawan hapus embedding sendiri"
  ON face_embeddings FOR DELETE
  USING (employee_id = auth.uid());

CREATE TRIGGER face_embeddings_updated_at
  BEFORE UPDATE ON face_embeddings
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();


-- ============================================================
-- 8b. RPC CEK DUPLIKAT WAJAH ANTAR AKUN
--     Dipakai saat enrollment agar satu wajah tidak bisa
--     didaftarkan ke beberapa akun.
-- ============================================================

CREATE OR REPLACE FUNCTION embedding_min_distance(
  stored_embedding TEXT,
  query_embedding TEXT
)
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  stored_json JSONB := stored_embedding::JSONB;
  query_json JSONB := query_embedding::JSONB;
  stored_vectors JSONB;
  vector_json JSONB;
  best_distance DOUBLE PRECISION := NULL;
  current_distance DOUBLE PRECISION;
BEGIN
  IF jsonb_array_length(stored_json) = 0 OR jsonb_array_length(query_json) = 0 THEN
    RETURN NULL;
  END IF;

  IF jsonb_typeof(stored_json->0) = 'array' THEN
    stored_vectors := stored_json;
  ELSE
    stored_vectors := jsonb_build_array(stored_json);
  END IF;

  FOR vector_json IN SELECT value FROM jsonb_array_elements(stored_vectors)
  LOOP
    IF jsonb_array_length(vector_json) <> jsonb_array_length(query_json) THEN
      CONTINUE;
    END IF;

    SELECT sqrt(sum(power((s.value::TEXT)::DOUBLE PRECISION - (q.value::TEXT)::DOUBLE PRECISION, 2)))
    INTO current_distance
    FROM jsonb_array_elements(vector_json) WITH ORDINALITY AS s(value, ord)
    JOIN jsonb_array_elements(query_json) WITH ORDINALITY AS q(value, ord)
      ON s.ord = q.ord;

    IF current_distance IS NOT NULL
      AND (best_distance IS NULL OR current_distance < best_distance) THEN
      best_distance := current_distance;
    END IF;
  END LOOP;

  RETURN best_distance;
END;
$$;

CREATE OR REPLACE FUNCTION find_duplicate_face_owner(
  query_embedding TEXT,
  match_threshold DOUBLE PRECISION DEFAULT 0.78
)
RETURNS TABLE (
  employee_id UUID,
  distance DOUBLE PRECISION
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT fe.employee_id,
         embedding_min_distance(fe.embedding, query_embedding) AS distance
  FROM face_embeddings fe
  WHERE fe.employee_id <> auth.uid()
    AND embedding_min_distance(fe.embedding, query_embedding) <= match_threshold
  ORDER BY distance ASC
  LIMIT 1;
$$;


-- ============================================================
-- 9. ENABLE REALTIME
--    Aktifkan publikasi realtime untuk tabel yang disubscribe
--    oleh realtime_sync_service.dart
-- ============================================================

ALTER PUBLICATION supabase_realtime ADD TABLE attendance_records;
ALTER PUBLICATION supabase_realtime ADD TABLE worklog_entries;
ALTER PUBLICATION supabase_realtime ADD TABLE reminder_events;
ALTER PUBLICATION supabase_realtime ADD TABLE work_schedule_settings;
ALTER PUBLICATION supabase_realtime ADD TABLE profiles;
ALTER PUBLICATION supabase_realtime ADD TABLE projects;


-- ============================================================
-- 10. TRIGGER AUTO-CREATE PROFILE SAAT USER BARU DAFTAR
--     Opsional tapi direkomendasikan agar profile selalu ada
-- ============================================================

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO profiles (id, full_name, email)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)),
    NEW.email
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();
