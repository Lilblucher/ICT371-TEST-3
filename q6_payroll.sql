-- =====================================================================
-- ICT371 Advanced Database
-- Question 6: Monthly Payroll Processing
-- DBMS: PostgreSQL
-- =====================================================================

DROP VIEW      IF EXISTS v_payroll_report;
DROP TABLE     IF EXISTS salary_audit;
DROP TABLE     IF EXISTS payroll;
DROP TABLE     IF EXISTS employees;
DROP PROCEDURE IF EXISTS pr_process_payroll(DATE);
DROP FUNCTION  IF EXISTS fn_net_pay(INT);
DROP FUNCTION  IF EXISTS fn_salary_audit();

-- =====================================================================
-- (a) Database: tables, keys, constraints
-- =====================================================================
CREATE TABLE employees (
    employee_id   SERIAL        PRIMARY KEY,
    full_name     VARCHAR(100)  NOT NULL,
    basic_salary  NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance     NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction     NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active        BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id   SERIAL        PRIMARY KEY,
    employee_id  INT           NOT NULL REFERENCES employees(employee_id),
    pay_month    DATE          NOT NULL
        CHECK (EXTRACT(DAY FROM pay_month) = 1),            -- first day of a month
    gross_pay    NUMERIC(12,2) NOT NULL,
    net_pay      NUMERIC(12,2) NOT NULL,
    CONSTRAINT uq_payroll_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id     SERIAL        PRIMARY KEY,
    employee_id  INT           NOT NULL REFERENCES employees(employee_id),
    old_salary   NUMERIC(12,2) NOT NULL,
    new_salary   NUMERIC(12,2) NOT NULL,
    changed_at   TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- =====================================================================
-- (b) Function: fn_net_pay
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic NUMERIC(12,2);
    v_allow NUMERIC(12,2);
    v_deduc NUMERIC(12,2);
    v_net   NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allow, v_deduc
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := (v_basic + v_allow) - v_deduc;

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_process_payroll (query FOR loop)
-- Existing rows are left unchanged (ON CONFLICT DO NOTHING).
-- Any exception (e.g. negative net pay) cancels the whole call, so no
-- partial payroll is saved.
-- =====================================================================
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    rec   RECORD;
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active = TRUE
        ORDER BY employee_id
    LOOP
        v_net := fn_net_pay(rec.employee_id);     -- fails the whole call if invalid

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, rec.basic_salary + rec.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- =====================================================================
-- (d) Trigger: AFTER UPDATE, logs actual basic_salary changes
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION fn_salary_audit();

-- =====================================================================
-- (a) continued: seed data
-- =====================================================================
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Mulenga Kapata',  8000.00, 1500.00, 1200.00, TRUE),
    ('Charity Mwewa',   6500.00, 1000.00,  900.00, TRUE),
    ('Joseph Lungu',    5000.00,  800.00,  700.00, TRUE),
    ('Agnes Mbewe',     7000.00, 1200.00, 1000.00, TRUE);   -- becomes inactive below

-- Two payroll months
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');

-- A salary change is logged by the trigger; an update that leaves the
-- salary the same is NOT logged.
UPDATE employees SET basic_salary = 8500.00 WHERE employee_id = 1;
UPDATE employees SET allowance    = 1500.00 WHERE employee_id = 1;   -- salary unchanged: no audit row
SELECT * FROM salary_audit;

-- Agnes leaves: she becomes inactive but her history stays
UPDATE employees SET active = FALSE WHERE employee_id = 4;

-- Reprocessing October leaves existing rows unchanged (employee 1 still
-- shows the OLD pay), and November skips the inactive employee.
CALL pr_process_payroll(DATE '2026-10-01');
CALL pr_process_payroll(DATE '2026-11-01');

SELECT fn_net_pay(1) AS net_pay_employee_1;     -- uses the new salary

-- Invalid calls (each fails on purpose):
-- CALL pr_process_payroll(DATE '2026-11-15');     -- not a month start
-- SELECT fn_net_pay(99);                          -- unknown employee
-- To see "whole call fails": add an employee with deduction larger than
-- salary + allowance, then CALL pr_process_payroll(DATE '2026-12-01');
-- no December rows are saved for anyone.

-- =====================================================================
-- (e) View: v_payroll_report
-- Inner join to employees (not filtered on active), so historical rows
-- of employees who later became inactive still appear.
-- =====================================================================
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- =====================================================================
-- (f) Index: reports filtered by pay_month across all employees
-- The existing unique index starts with employee_id, so it cannot be
-- used efficiently to search by pay_month alone. This index has
-- pay_month as its leading column, so it does not duplicate it.
-- =====================================================================
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

SET enable_seqscan = off;   -- tiny table: force the planner to show the index
EXPLAIN
SELECT *
FROM payroll
WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job: 02:00 on the 1st of every month, for the
-- previous month (first day of last month)
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'monthly-payroll',
    '0 2 1 * *',
    $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$
);

-- Inspect the job definition
SELECT jobid, jobname, schedule, command, active FROM cron.job;

-- Inspect the run history (newest first)
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
ORDER BY start_time DESC;
