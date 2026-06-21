-- ============================================================
-- Presensia — Infrastruktur Notifikasi & Kalender Libur
-- Jalankan di: Supabase Dashboard → SQL Editor → New Query
-- Mengandalkan package lokal terjadwal (tanpa Firebase/FCM)
-- ============================================================
--
-- Isi migrasi:
--   1. ALTER work_schedule_settings → jam pengingat per user
--   2. CREATE national_holidays      → kalender libur (admin)
--   3. CREATE push_messages          → antrian pengumuman admin
--   4. ENABLE REALTIME               → supaya sync saat app aktif
--   5. SEED libur nasional 2026
-- ============================================================


-- ============================================================
-- 1. ALTER work_schedule_settings — kolom jam pengingat
--    Disimpan per karyawan, sehingga tiap orang bisa atur jam
--    pengingat check-in / check-out / tracker sendiri.
-- ============================================================

ALTER TABLE public.work_schedule_settings
  ADD COLUMN IF NOT EXISTS check_in_reminder_time    TIME    NOT NULL DEFAULT '08:00',
  ADD COLUMN IF NOT EXISTS check_out_reminder_time   TIME    NOT NULL DEFAULT '17:00',
  ADD COLUMN IF NOT EXISTS tracker_reminder_time     TIME    NOT NULL DEFAULT '13:00',
  ADD COLUMN IF NOT EXISTS reminder_enabled          BOOLEAN NOT NULL DEFAULT TRUE;

-- Default reminder_enabled mengikuti notifications_enabled yang lama
UPDATE public.work_schedule_settings
   SET reminder_enabled = TRUE
 WHERE reminder_enabled IS NULL;


-- ============================================================
-- 2. TABEL national_holidays
--    Kalender libur nasional / cuti bersama. Diisi admin.
--    Dibaca semua user (karyawan) supaya pengingat presensi
--    otomatis diskip di hari libur.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.national_holidays (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  holiday_date  DATE NOT NULL,
  name          TEXT NOT NULL,
  description   TEXT,
  is_national   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT national_holidays_date_unique UNIQUE (holiday_date)
);

CREATE INDEX IF NOT EXISTS idx_national_holidays_date
  ON public.national_holidays (holiday_date);

ALTER TABLE public.national_holidays ENABLE ROW LEVEL SECURITY;

-- Semua karyawan bisa membaca daftar libur
DROP POLICY IF EXISTS "Semua user baca hari libur"
  ON public.national_holidays;
CREATE POLICY "Semua user baca hari libur"
  ON public.national_holidays FOR SELECT
  USING (TRUE);

-- Hanya admin yang boleh menambah/mengubah/menghapus libur
DROP POLICY IF EXISTS "Admin kelola hari libur"
  ON public.national_holidays;
CREATE POLICY "Admin kelola hari libur"
  ON public.national_holidays FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS national_holidays_updated_at
  ON public.national_holidays;
CREATE TRIGGER national_holidays_updated_at
  BEFORE UPDATE ON public.national_holidays
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


-- ============================================================
-- 3. TABEL push_messages
--    Antrian pengumuman / broadcast dari admin ke karyawan.
--    Karena tidak pakai FCM, pesan ini ditarik (pull) saat app
--    dibuka dan ditampilkan sebagai notifikasi sistem.
--    employee_id = NULL  → broadcast ke semua karyawan.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.push_messages (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id  UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
  title        TEXT NOT NULL,
  body         TEXT NOT NULL,
  category     TEXT NOT NULL DEFAULT 'system',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_push_messages_employee
  ON public.push_messages (employee_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_push_messages_created
  ON public.push_messages (created_at DESC);

ALTER TABLE public.push_messages ENABLE ROW LEVEL SECURITY;

-- Karyawan hanya membaca pesan miliknya atau broadcast (employee_id IS NULL)
DROP POLICY IF EXISTS "Karyawan baca pesan push sendiri"
  ON public.push_messages;
CREATE POLICY "Karyawan baca pesan push sendiri"
  ON public.push_messages FOR SELECT
  USING (employee_id = auth.uid() OR employee_id IS NULL);

-- Admin bisa membaca semua pesan
DROP POLICY IF EXISTS "Admin baca semua pesan push"
  ON public.push_messages;
CREATE POLICY "Admin baca semua pesan push"
  ON public.push_messages FOR SELECT
  USING (public.is_admin());

-- Hanya admin yang boleh membuat/menghapus pesan push
DROP POLICY IF EXISTS "Admin kelola pesan push"
  ON public.push_messages;
CREATE POLICY "Admin kelola pesan push"
  ON public.push_messages FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());


-- ============================================================
-- 4. ENABLE REALTIME
--    Supaya app otomatis sinkron saat tabel berubah (app aktif)
-- ============================================================

DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.national_holidays;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;

  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.push_messages;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;

  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.work_schedule_settings;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
END
$$;


-- ============================================================
-- 5. SEED LIBUR NASIONAL INDONESIA 2026
--    Berdasarkan SKB bersama 3 menteri (cuti bersama & libur
--    nasional). Tanggal disesuaikan ke kalender 2026.
--    Jalankan sekali; aman dijalankan ulang (ON CONFLICT).
-- ============================================================

INSERT INTO public.national_holidays (holiday_date, name, description, is_national) VALUES
  ('2026-01-01', 'Tahun Baru 2026 Masehi',                       'Libur nasional',                              TRUE),
  ('2026-02-09', "Isra Mikraj Nabi Muhammad SAW",                'Libur nasional',                              TRUE),
  ('2026-02-17', 'Tahun Baru Imlek 2577 Konghucu',              'Libur nasional',                              TRUE),
  ('2026-03-03', "Hari Suci Nyepi (Tahun Baru Saka 1948)",      'Libur nasional',                              TRUE),
  ('2026-03-20', 'Hari Raya Nyepi',                              'Cuti bersama (cek kebijakan)',                FALSE),
  ('2026-03-30', "Wafat Isa Almasih (Jumat Agung)",             'Libur nasional',                              TRUE),
  ('2026-03-31', "Cuti Bersama Wafat Isa Almasih",              'Cuti bersama',                                FALSE),
  ('2026-04-02', 'Cuti Bersama Idul Fitri 1447 H',              'Cuti bersama',                                FALSE),
  ('2026-04-03', 'Cuti Bersama Idul Fitri 1447 H',              'Cuti bersama',                                FALSE),
  ('2026-04-20', "Hari Raya Idul Fitri 1447 H",                 'Libur nasional',                              TRUE),
  ('2026-04-21', "Hari Raya Idul Fitri 1447 H (Hari ke-2)",     'Libur nasional',                              TRUE),
  ('2026-04-22', "Cuti Bersama Idul Fitri 1447 H",              'Cuti bersama',                                FALSE),
  ('2026-04-23', "Cuti Bersama Idul Fitri 1447 H",              'Cuti bersama',                                FALSE),
  ('2026-05-01', 'Hari Buruh Internasional',                    'Libur nasional',                              TRUE),
  ('2026-05-20', 'Hari Raya Waisak 2570 BE',                    'Libur nasional',                              TRUE),
  ('2026-05-29', "Kenaikan Isa Almasih",                        'Libur nasional',                              TRUE),
  ('2026-05-27', "Maulid Nabi Muhammad SAW",                    'Libur nasional',                              TRUE),
  ('2026-06-01', 'Hari Lahir Pancasila',                        'Libur nasional',                              TRUE),
  ('2026-08-17', 'Hari Kemerdekaan Republik Indonesia ke-81',   'Libur nasional',                              TRUE),
  ('2026-09-04', "Tahun Baru Islam 1448 H",                     'Libur nasional',                              TRUE),
  ('2026-10-26', "Maulid Nabi Muhammad SAW 1448 H",             'Libur nasional (cek penetapan resmi)',        TRUE),
  ('2026-12-25', "Hari Raya Natal",                             'Libur nasional',                              TRUE),
  ('2026-12-28', "Cuti Bersama Natal",                          'Cuti bersama',                                FALSE),
  ('2026-12-29', "Cuti Bersama Natal",                          'Cuti bersama',                                FALSE),
  ('2026-12-30', "Cuti Bersama Natal",                          'Cuti bersama',                                FALSE),
  ('2026-12-31', "Cuti Bersama Natal",                          'Cuti bersama',                                FALSE)
ON CONFLICT (holiday_date) DO UPDATE
SET name        = EXCLUDED.name,
    description = EXCLUDED.description,
    is_national = EXCLUDED.is_national;

-- ============================================================
-- CATATAN PENTING
-- 1. Tabel di atas bersifat ADDITIVE — tidak menghapus data lama.
-- 2. Jika belum punya akun admin, set dulu:
--      UPDATE public.profiles SET role = 'admin'
--      WHERE email = 'email-admin@domain.com';
-- 3. Tanggal cuti bersama & hari libur keagamaan bisa berubah
--    sesuai penetapan resmi — admin bisa edit via dashboard nanti.
-- ============================================================
