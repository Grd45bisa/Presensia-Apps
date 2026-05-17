-- Ensure check-out RPC returns the updated attendance row.
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
