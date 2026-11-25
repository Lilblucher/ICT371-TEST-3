-- =====================================================================
-- ICT371 Advanced Database
-- Question 4: Clinic Appointment Scheduling
-- DBMS: PostgreSQL
-- =====================================================================

DROP VIEW      IF EXISTS v_today_appointments;
DROP TABLE     IF EXISTS clinic_summary;
DROP TABLE     IF EXISTS appointments;
DROP TABLE     IF EXISTS doctors;
DROP TABLE     IF EXISTS patients;
DROP PROCEDURE IF EXISTS pr_book_appointment(INT, INT, DATE, TIME);
DROP PROCEDURE IF EXISTS pr_refresh_clinic_summary(DATE);
DROP FUNCTION  IF EXISTS fn_daily_load(INT, DATE);
DROP FUNCTION  IF EXISTS fn_check_slot_clash();

-- =====================================================================
-- (a) Database: tables, keys, constraints
-- =====================================================================
CREATE TABLE patients (
    patient_id  SERIAL        PRIMARY KEY,
    full_name   VARCHAR(100)  NOT NULL
);

CREATE TABLE doctors (
    doctor_id   SERIAL        PRIMARY KEY,
    full_name   VARCHAR(100)  NOT NULL
);

CREATE TABLE appointments (
    appointment_id   SERIAL       PRIMARY KEY,
    patient_id       INT          NOT NULL REFERENCES patients(patient_id),
    doctor_id        INT          NOT NULL REFERENCES doctors(doctor_id),
    appointment_day  DATE         NOT NULL,
    slot_time        TIME         NOT NULL
        CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00')),
    status           VARCHAR(10)  NOT NULL DEFAULT 'BOOKED'
        CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE  PRIMARY KEY,
    booked_count    INT   NOT NULL DEFAULT 0,
    attended_count  INT   NOT NULL DEFAULT 0,
    cancelled_count INT   NOT NULL DEFAULT 0
);

-- =====================================================================
-- (b) Function: fn_daily_load
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INT;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count          -- COUNT returns 0 when nothing matches
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_book_appointment
-- =====================================================================
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INT,
    p_doctor_id  INT,
    p_day        DATE,
    p_slot       TIME
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL OR p_slot IS NULL THEN
        RAISE EXCEPTION 'Day and slot must not be NULL';
    END IF;

    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book a past date: %', p_day;
    END IF;

    IF p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;

    -- The trigger will reject a clash with another non-cancelled appointment
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- =====================================================================
-- (d) Trigger: BEFORE INSERT OR UPDATE row trigger, rejects clashes
-- On UPDATE the row being changed is excluded from the clash search.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_check_slot_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1
            FROM appointments a
            WHERE a.doctor_id       = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time       = NEW.slot_time
              AND a.status         <> 'CANCELLED'
              AND a.appointment_id IS DISTINCT FROM NEW.appointment_id
        ) THEN
            RAISE EXCEPTION 'Clash: doctor % already has an appointment on % at %',
                            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_slot_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION fn_check_slot_clash();

-- Extra safety against two simultaneous bookings: the database itself
-- refuses duplicates among non-cancelled rows.
CREATE UNIQUE INDEX uq_active_slot
    ON appointments (doctor_id, appointment_day, slot_time)
    WHERE status <> 'CANCELLED';

-- =====================================================================
-- (a) continued: seed data
-- Past appointments are inserted directly (the procedure refuses past
-- dates). Current and future ones go through the procedure.
-- =====================================================================
INSERT INTO patients (full_name) VALUES
    ('Grace Chileshe'), ('Peter Mumba'), ('Ruth Lungu');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Kabwe'), ('Dr. Nyirenda'), ('Dr. Zimba');

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE - 2, '09:00', 'ATTENDED'),
    (2, 1, CURRENT_DATE - 1, '10:00', 'CANCELLED'),
    (3, 2, CURRENT_DATE - 1, '09:00', 'ATTENDED');

CALL pr_book_appointment(1, 1, CURRENT_DATE,     '09:00');
CALL pr_book_appointment(2, 2, CURRENT_DATE,     '10:00');
CALL pr_book_appointment(3, 3, CURRENT_DATE + 1, '11:00');

SELECT * FROM appointments ORDER BY appointment_id;

-- Function checks
SELECT fn_daily_load(1, CURRENT_DATE)      AS dr1_today,       -- 1
       fn_daily_load(1, CURRENT_DATE - 1)  AS dr1_yesterday,   -- 0 (cancelled one not counted)
       fn_daily_load(3, CURRENT_DATE + 30) AS dr3_empty_day;   -- 0

-- Invalid calls (each fails on purpose):
-- CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00');        -- clash (trigger)
-- CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00');    -- past date
-- CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '13:00');    -- unsupported slot
-- CALL pr_book_appointment(99, 1, CURRENT_DATE + 1, '09:00');   -- unknown patient
-- CALL pr_book_appointment(1, 99, CURRENT_DATE + 1, '09:00');   -- unknown doctor

-- =====================================================================
-- (e) View: v_today_appointments (no patient IDs or other patient data)
-- =====================================================================
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time;

-- =====================================================================
-- (f) Index: non-unique, (appointment_day, doctor_id)
-- =====================================================================
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);

SET enable_seqscan = off;   -- tiny table: force the planner to show the index
EXPLAIN
SELECT appointment_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;
RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- =====================================================================
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count    = EXCLUDED.booked_count,
            attended_count  = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);   -- rerun: row replaced
SELECT * FROM clinic_summary;

-- Schedule daily at 01:00 for the previous day (needs the pg_cron extension)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-clinic-summary',
    '0 1 * * *',
    $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$
);

SELECT jobid, jobname, schedule, command FROM cron.job;
