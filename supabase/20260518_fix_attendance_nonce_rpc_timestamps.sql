-- Fix face attendance RPCs for attendance_records.check_in/check_out TIMESTAMPTZ columns.
ALTER TABLE attendance_records
    ADD COLUMN IF NOT EXISTS nonce UUID,
    ADD COLUMN IF NOT EXISTS nonce_used_at TIMESTAMPTZ;

CREATE UNIQUE INDEX IF NOT EXISTS attendance_records_nonce_key
    ON attendance_records (nonce);

CREATE OR REPLACE FUNCTION check_in_with_nonce(
    p_employee_id UUID,
    p_nonce UUID,
    p_timestamp TIMESTAMPTZ,
    p_note TEXT DEFAULT NULL
)
RETURNS attendance_records
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_attendance attendance_records%ROWTYPE;
    v_exists     BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM attendance_records ar
        WHERE ar.nonce = p_nonce
    ) INTO v_exists;

    IF v_exists THEN
        RAISE EXCEPTION 'Nonce already used - possible replay attack';
    END IF;

    SELECT * INTO v_attendance
    FROM attendance_records
    WHERE employee_id = p_employee_id
      AND date = p_timestamp::date
    FOR UPDATE;

    IF FOUND THEN
        UPDATE attendance_records
        SET
            check_in = COALESCE(check_in, p_timestamp),
            nonce = p_nonce,
            nonce_used_at = p_timestamp,
            updated_at = NOW()
        WHERE employee_id = p_employee_id
          AND date = p_timestamp::date
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
            p_timestamp::date,
            'face',
            'present',
            p_note,
            p_timestamp,
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

CREATE OR REPLACE FUNCTION check_out_with_nonce(
    p_employee_id UUID,
    p_nonce UUID,
    p_timestamp TIMESTAMPTZ
)
RETURNS attendance_records
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_attendance attendance_records%ROWTYPE;
    v_exists     BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM attendance_records ar
        WHERE ar.nonce = p_nonce
    ) INTO v_exists;

    IF v_exists THEN
        RAISE EXCEPTION 'Nonce already used - possible replay attack';
    END IF;

    SELECT * INTO v_attendance
    FROM attendance_records
    WHERE employee_id = p_employee_id
      AND date = p_timestamp::date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No attendance row for today - cannot check-out';
    END IF;

    UPDATE attendance_records
    SET
        check_out = p_timestamp,
        nonce = p_nonce,
        nonce_used_at = p_timestamp,
        updated_at = NOW()
    WHERE employee_id = p_employee_id
      AND date = p_timestamp::date
    RETURNING * INTO v_attendance;

    RETURN v_attendance;
END;
$$;
