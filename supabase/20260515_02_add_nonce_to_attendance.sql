-- Add nonce and timestamp columns to attendance_records for replay protection
ALTER TABLE attendance_records
    ADD COLUMN IF NOT EXISTS nonce UUID,
    ADD COLUMN IF NOT EXISTS nonce_used_at TIMESTAMPTZ;

-- Ensure we have a unique index on nonce to detect replays
CREATE UNIQUE INDEX IF NOT EXISTS attendance_records_nonce_key ON attendance_records (nonce);

-- ==== RPC: verify duplicate face owner (re‑use from earlier)
CREATE OR REPLACE FUNCTION find_duplicate_face_owner(
  query_embedding TEXT,
  match_threshold DOUBLE PRECISION DEFAULT 0.37
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

-- ==== RPC: insert attendance with nonce (face‑check‑in)
CREATE OR REPLACE FUNCTION check_in_with_nonce(
    p_employee_id UUID,
    p_nonce UUID,
    p_timestamp TIMESTAMPTZ,
    p_note TEXT DEFAULT NULL
)
RETURNS attendance_records
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_attendance attendance_records%ROWTYPE;
    v_exists     BOOLEAN;
BEGIN
    -- 1️⃣ Replay guard – if the nonce already exists, reject
    SELECT EXISTS (
        SELECT 1
        FROM attendance_records ar
        WHERE ar.nonce = p_nonce
    ) INTO v_exists;
    IF v_exists THEN
        RAISE EXCEPTION 'Nonce already used – possible replay attack';
    END IF;

    -- 2️⃣ Upsert attendance record (fill check_in if empty)
    SELECT * INTO v_attendance
    FROM attendance_records
    WHERE employee_id = p_employee_id
      AND date = DATE(p_timestamp)
    FOR UPDATE;

    IF FOUND THEN
        UPDATE attendance_records
        SET
            check_in = COALESCE(check_in, TIME(p_timestamp)),
            nonce = p_nonce,
            nonce_used_at = p_timestamp,
            updated_at = NOW()
        WHERE employee_id = p_employee_id
          AND date = DATE(p_timestamp)
        RETURNING * INTO v_attendance;
    ELSE
        INSERT INTO attendance_records (
            employee_id,
            date,
            source,
            status,
            note,
            check_in,
            nonce,
            nonce_used_at,
            created_at,
            updated_at
        ) VALUES (
            p_employee_id,
            DATE(p_timestamp),
            'face',
            'present',
            p_note,
            TIME(p_timestamp),
            p_nonce,
            p_timestamp,
            NOW(),
            NOW()
        )
        RETURNING * INTO v_attendance;
    END IF;

    RETURN v_attendance;
END;
$$;

-- ==== RPC: update attendance with nonce (face‑check‑out)
CREATE OR REPLACE FUNCTION check_out_with_nonce(
    p_employee_id UUID,
    p_nonce UUID,
    p_timestamp TIMESTAMPTZ
)
RETURNS attendance_records
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_attendance attendance_records%ROWTYPE;
    v_exists     BOOLEAN;
BEGIN
    -- 1️⃣ Replay guard
    SELECT EXISTS (
        SELECT 1
        FROM attendance_records ar
        WHERE ar.nonce = p_nonce
    ) INTO v_exists;
    IF v_exists THEN
        RAISE EXCEPTION 'Nonce already used – possible replay attack';
    END IF;

    -- 2️⃣ Fetch today's record (must already exist → we have already checked‑in)
    SELECT * INTO v_attendance
    FROM attendance_records
    WHERE employee_id = p_employee_id
      AND date = DATE(p_timestamp)
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No attendance row for today – cannot check‑out';
    END IF;

    -- 3️⃣ Set check_out and refresh nonce metadata
    UPDATE attendance_records
    SET
        check_out = TIME(p_timestamp),
        nonce = p_nonce,
        nonce_used_at = p_timestamp,
        updated_at = NOW()
    WHERE employee_id = p_employee_id
      AND date = DATE(p_timestamp)
    RETURNING * INTO v_attendance;
END;
$$;