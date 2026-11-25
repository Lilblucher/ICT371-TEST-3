-- =====================================================================
-- ICT371 Advanced Database
-- Question 2: University Fee Payments
-- DBMS: PostgreSQL
-- =====================================================================

-- Clean start so the script can be re-run safely
DROP VIEW      IF EXISTS v_fee_balances;
DROP TABLE     IF EXISTS daily_collections;
DROP TABLE     IF EXISTS payment_audit;
DROP TABLE     IF EXISTS payments;
DROP TABLE     IF EXISTS students;
DROP PROCEDURE IF EXISTS pr_receive_payment(INT, NUMERIC, DATE);
DROP PROCEDURE IF EXISTS pr_refresh_collections(DATE);
DROP FUNCTION  IF EXISTS fn_fee_balance(INT);
DROP FUNCTION  IF EXISTS fn_payments_audit();

-- =====================================================================
-- (a) Database: tables, keys, constraints
-- =====================================================================
CREATE TABLE students (
    student_id      SERIAL        PRIMARY KEY,
    student_number  VARCHAR(20)   NOT NULL UNIQUE,
    full_name       VARCHAR(100)  NOT NULL,
    fee_due         NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id  SERIAL        PRIMARY KEY,
    student_id  INT           NOT NULL REFERENCES students(student_id),
    amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on     DATE          NOT NULL
);

CREATE TABLE payment_audit (
    audit_id    SERIAL        PRIMARY KEY,
    payment_id  INT           NOT NULL REFERENCES payments(payment_id),
    student_id  INT           NOT NULL REFERENCES students(student_id),
    amount      NUMERIC(12,2) NOT NULL,
    logged_at   TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
    collection_date  DATE          PRIMARY KEY,
    payment_count    INT           NOT NULL DEFAULT 0,
    total_amount     NUMERIC(14,2) NOT NULL DEFAULT 0
);

-- =====================================================================
-- (b) Function: fn_fee_balance
-- COALESCE makes a student with no payments return the full fee.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee  NUMERIC(12,2);
    v_paid NUMERIC(14,2);
BEGIN
    SELECT fee_due INTO v_fee
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_receive_payment
-- Only inserts the payment. The audit row is written by the trigger.
-- fee_due is never changed.
-- =====================================================================
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INT,
    p_amount     NUMERIC,
    p_paid_on    DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount: % (must be greater than zero)', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date must not be NULL';
    END IF;

    -- Lock the student row so two payments cannot overpay at the same time
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % for student %',
                        p_amount, v_balance, p_student_id;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- =====================================================================
-- (d) Trigger: AFTER INSERT row trigger on payments
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_payments_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION fn_payments_audit();

-- =====================================================================
-- (a) continued: seed data
-- Students first, then payments through the procedure (trigger is
-- already installed, so every payment is audited automatically).
-- =====================================================================
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('MU2024001', 'Chanda Mwila',   5000.00),   -- partly paid
    ('MU2024002', 'Mutale Banda',   3000.00),   -- will be fully settled
    ('MU2024003', 'Natasha Phiri',  1500.00);   -- no payments yet

CALL pr_receive_payment(1, 1000.00, DATE '2026-11-18');
CALL pr_receive_payment(1, 1500.00, DATE '2026-11-20');
CALL pr_receive_payment(1,  500.00, DATE '2026-11-22');
CALL pr_receive_payment(2, 1000.00, DATE '2026-11-18');
CALL pr_receive_payment(2, 1000.00, DATE '2026-11-20');
CALL pr_receive_payment(2, 1000.00, DATE '2026-11-24');

-- Check the function (student 3 has no payments, so full fee is returned)
SELECT fn_fee_balance(1) AS balance_student_1,
       fn_fee_balance(2) AS balance_student_2,
       fn_fee_balance(3) AS balance_student_3;

SELECT * FROM payments      ORDER BY payment_id;
SELECT * FROM payment_audit ORDER BY audit_id;
SELECT student_id, fee_due FROM students ORDER BY student_id;  -- fee_due unchanged

-- Invalid calls (each fails on purpose; uncomment one at a time to test):
-- CALL pr_receive_payment(1, NULL,    CURRENT_DATE);   -- NULL amount
-- CALL pr_receive_payment(1, 0,       CURRENT_DATE);   -- zero amount
-- CALL pr_receive_payment(1, -50,     CURRENT_DATE);   -- negative amount
-- CALL pr_receive_payment(1, 99999,   CURRENT_DATE);   -- above balance
-- CALL pr_receive_payment(99, 100,    CURRENT_DATE);   -- unknown student

-- =====================================================================
-- (e) View: v_fee_balances (only students who still owe fees)
-- =====================================================================
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

-- Student 2 is fully settled, so should not appear
SELECT * FROM v_fee_balances ORDER BY student_number;

-- =====================================================================
-- (f) Index: composite (student_id, paid_on)
-- Equality column first (student_id), range column second (paid_on).
-- =====================================================================
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

-- Tiny table: turn seqscan off for this session only to show the index
SET enable_seqscan = off;
EXPLAIN
SELECT *
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN DATE '2026-11-18' AND DATE '2026-11-22';
RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- Upsert: a rerun replaces the day's row instead of adding to it.
-- =====================================================================
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day,
           COUNT(*),
           COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
        SET payment_count = EXCLUDED.payment_count,
            total_amount  = EXCLUDED.total_amount;
END;
$$;

-- Run twice for the same day: the result stays the same
CALL pr_refresh_collections(DATE '2026-11-18');
CALL pr_refresh_collections(DATE '2026-11-18');
SELECT * FROM daily_collections;

-- Schedule daily at 01:00 for the previous day (needs the pg_cron extension)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-daily-collections',
    '0 1 * * *',
    $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$
);

-- Inspect the job
SELECT jobid, jobname, schedule, command FROM cron.job;
