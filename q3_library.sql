-- =====================================================================
-- ICT371 Advanced Database
-- Question 3: Library Returns and Overdue Fines
-- DBMS: PostgreSQL
-- =====================================================================

DROP VIEW      IF EXISTS v_overdue_loans;
DROP TABLE     IF EXISTS overdue_summary;
DROP TABLE     IF EXISTS loan_audit;
DROP TABLE     IF EXISTS loans;
DROP TABLE     IF EXISTS books;
DROP PROCEDURE IF EXISTS pr_return_loan(INT, DATE);
DROP PROCEDURE IF EXISTS pr_refresh_overdue(DATE);
DROP FUNCTION  IF EXISTS fn_loan_fine(INT, DATE);
DROP FUNCTION  IF EXISTS fn_loans_audit();

-- =====================================================================
-- (a) Database: tables, keys, constraints
-- =====================================================================
CREATE TABLE books (
    book_id  SERIAL        PRIMARY KEY,
    title    VARCHAR(150)  NOT NULL
);

CREATE TABLE loans (
    loan_id        SERIAL        PRIMARY KEY,
    book_id        INT           NOT NULL REFERENCES books(book_id),
    borrower_name  VARCHAR(100)  NOT NULL,
    borrowed_on    DATE          NOT NULL,
    due_on         DATE          NOT NULL,
    returned_on    DATE          NULL,
    fine_amount    NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrowed CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id          SERIAL     PRIMARY KEY,
    loan_id           INT        NOT NULL REFERENCES loans(loan_id),
    old_returned_on   DATE       NULL,
    new_returned_on   DATE       NULL,
    changed_at        TIMESTAMP  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
    snapshot_date  DATE           PRIMARY KEY,
    overdue_count  INT            NOT NULL DEFAULT 0,
    total_fine     NUMERIC(12,2)  NOT NULL DEFAULT 0
);

-- =====================================================================
-- (b) Function: fn_loan_fine
-- K2 per day after due date. A return on the due date = no fine.
-- If the loan was returned, fines stop at the earlier of p_as_of and
-- returned_on.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    IF v_returned IS NULL THEN
        v_end := p_as_of;
    ELSE
        v_end := LEAST(p_as_of, v_returned);
    END IF;

    RETURN 2 * GREATEST(v_end - v_due, 0);   -- date - date = whole days
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_return_loan
-- Return date and final fine are stored in ONE update statement.
-- (While that statement runs the row still has returned_on = NULL, so
-- fn_loan_fine uses p_returned_on as the end date.)
-- =====================================================================
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date must not be NULL';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrowed date %', p_returned_on, v_borrowed;
    END IF;

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = fn_loan_fine(p_loan_id, p_returned_on)
    WHERE loan_id = p_loan_id;
END;
$$;

-- =====================================================================
-- (d) Trigger: AFTER UPDATE row trigger, logs returned_on changes
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_loans_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION fn_loans_audit();

-- =====================================================================
-- (a) continued: seed data (three books, six loans)
-- All loans start open; returns go through the procedure so the
-- trigger records them.
-- =====================================================================
INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Clean Code');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Alice Mulenga',   DATE '2026-10-01', DATE '2026-10-15'),  -- open, overdue
    (2, 'Brian Tembo',     DATE '2026-11-20', DATE '2026-12-04'),  -- open, not yet due
    (3, 'Chola Zulu',      DATE '2026-10-01', DATE '2026-10-15'),  -- returned on time
    (1, 'Dalitso Phiri',   DATE '2026-09-01', DATE '2026-09-15'),  -- returned late
    (2, 'Esther Sakala',   DATE '2026-11-01', DATE '2026-11-10'),  -- open, overdue
    (3, 'Femi Daka',       DATE '2026-11-15', DATE '2026-11-29');  -- open, not yet due

CALL pr_return_loan(3, DATE '2026-10-14');   -- on time:   fine 0
CALL pr_return_loan(4, DATE '2026-09-20');   -- 5 days late: fine K10

-- Check the function
SELECT fn_loan_fine(1, DATE '2026-11-25') AS open_overdue_fine,    -- 41 days = K82
       fn_loan_fine(3, DATE '2026-12-31') AS on_time_returned_fine, -- 0
       fn_loan_fine(4, DATE '2026-12-31') AS late_returned_fine;    -- stops at return = K10

SELECT * FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;

-- Invalid calls (each fails on purpose):
-- CALL pr_return_loan(99, CURRENT_DATE);               -- unknown loan
-- CALL pr_return_loan(3,  CURRENT_DATE);               -- already returned
-- CALL pr_return_loan(1,  DATE '2026-09-01');          -- before borrowed_on

-- =====================================================================
-- (e) View: v_overdue_loans
-- =====================================================================
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans ORDER BY due_on;

-- =====================================================================
-- (f) Index: a given book's unreturned loans
-- Partial index: only unreturned rows are indexed, so it stays small.
-- =====================================================================
CREATE INDEX idx_loans_book_unreturned
    ON loans (book_id)
    WHERE returned_on IS NULL;

SET enable_seqscan = off;   -- tiny table: force the planner to show the index
EXPLAIN
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- Counts loans that are overdue and still unreturned as of p_as_of and
-- sums their fines. ON CONFLICT replaces the same snapshot_date.
-- =====================================================================
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)   -- still unreturned on that date
      AND due_on < p_as_of                                 -- and overdue
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);   -- rerun: same row replaced
SELECT * FROM overdue_summary;

-- Schedule daily at 00:10 for CURRENT_DATE (needs the pg_cron extension)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-overdue-summary',
    '10 0 * * *',
    $$CALL pr_refresh_overdue(CURRENT_DATE)$$
);

SELECT jobid, jobname, schedule, command FROM cron.job;
