-- ICT371 Question 7: Water Meter Readings and Billing (PostgreSQL)

DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INT NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_reading_cust_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INT NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE NOT NULL,
    CONSTRAINT chk_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL
);

-- (b) Function -------------------------------------------------------------
-- First 10 units at K5, units above 10 at K8
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2) AS $$
DECLARE
    v_charge NUMERIC;
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION 'Consumption cannot be NULL';
    END IF;
    IF p_units < 0 THEN
        RAISE EXCEPTION 'Consumption cannot be negative (%)', p_units;
    END IF;

    IF p_units <= 10 THEN
        v_charge := p_units * 5;
    ELSE
        v_charge := 10 * 5 + (p_units - 10) * 8;
    END IF;
    RETURN ROUND(v_charge, 2);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_units NUMERIC;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date cannot be NULL';
    END IF;

    SELECT current_reading - previous_reading
      INTO v_units
      FROM readings
     WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Reading % does not exist', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_units), 0, p_due_on);
END;
$$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_check_reading()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_fn_check_reading();

-- Seed data ----------------------------------------------------------------
INSERT INTO customers (full_name) VALUES ('Chola Mumba'), ('Bwalya Zulu'), ('Natasha Lungu');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
 (1, '2026-09-01', 100, 100),   --  0 units
 (1, '2026-10-01', 100, 110),   -- 10 units
 (2, '2026-09-01', 200, 215),   -- 15 units
 (2, '2026-10-01', 215, 222),   --  7 units
 (3, '2026-09-01',  50,  75),   -- 25 units
 (3, '2026-10-01',  75,  85);   -- 10 units

CALL pr_generate_bill(1, '2026-10-15');
CALL pr_generate_bill(2, '2026-11-15');
CALL pr_generate_bill(3, '2026-10-15');
CALL pr_generate_bill(4, '2026-12-15');
CALL pr_generate_bill(5, '2026-10-20');
CALL pr_generate_bill(6, '2026-12-20');

-- Some payments
UPDATE bills SET amount_paid = charge WHERE reading_id = 2;  -- fully paid
UPDATE bills SET amount_paid = 40     WHERE reading_id = 3;  -- partly paid

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
  FROM bills b
  JOIN readings r  ON r.reading_id  = b.reading_id
  JOIN customers c ON c.customer_id = r.customer_id
 WHERE b.due_on < CURRENT_DATE
   AND b.amount_paid < b.charge;

-- (f) Index ----------------------------------------------------------------
-- Partial index: only unpaid bills are indexed, ordered by due date. Overdue searches
-- touch a small, shrinking set instead of every bill ever issued.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;

SET enable_seqscan = off;
EXPLAIN SELECT bill_id, due_on, charge - amount_paid AS outstanding
          FROM bills
         WHERE amount_paid < charge AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- (g) Snapshot procedure + schedule ----------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
      FROM bills
     WHERE amount_paid < charge
    ON CONFLICT (snapshot_date)
    DO UPDATE SET total_due = EXCLUDED.total_due;   -- replace, never add
END;
$$;

-- CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('daily-receivables', '30 0 * * *', $cron$CALL pr_refresh_receivables()$cron$);

-- Tests --------------------------------------------------------------------
SELECT fn_water_charge(0), fn_water_charge(10), fn_water_charge(15), fn_water_charge(25);  -- 0, 50, 90, 170
DO $$ BEGIN PERFORM fn_water_charge(-1);   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(NULL); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_generate_bill(1, '2026-12-31');   -- duplicate bill
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(999, '2026-12-31'); -- unknown reading
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Trigger: bad reading is rejected and not stored
DO $$ BEGIN
    INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
    VALUES (1, '2026-11-01', 110, 100);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_count FROM readings;   -- still 6

SELECT * FROM v_overdue_bills;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();                      -- rerun replaces, no double count
SELECT * FROM receivable_snapshot;
