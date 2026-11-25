-- =====================================================================
-- ICT371 Advanced Database
-- Question 1: Pharmacy Stock and Daily Sales
-- DBMS: PostgreSQL
-- =====================================================================

-- Clean start so the script can be re-run safely
DROP VIEW      IF EXISTS v_low_stock;
DROP TABLE     IF EXISTS daily_sales;
DROP TABLE     IF EXISTS stock_audit;
DROP TABLE     IF EXISTS sales;
DROP TABLE     IF EXISTS medicines;
DROP PROCEDURE IF EXISTS pr_record_sale(INT, INT, DATE);
DROP PROCEDURE IF EXISTS pr_refresh_sales(DATE);
DROP FUNCTION  IF EXISTS fn_sale_value(INT, INT);
DROP FUNCTION  IF EXISTS fn_medicines_stock_audit();

-- =====================================================================
-- (a) Database: tables, keys, constraints
-- =====================================================================
CREATE TABLE medicines (
    medicine_id    SERIAL        PRIMARY KEY,
    medicine_name  VARCHAR(100)  NOT NULL,
    unit_price     NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),   -- positive prices
    stock_qty      INT           NOT NULL CHECK (stock_qty >= 0)    -- non-negative stock
);

CREATE TABLE sales (
    sale_id      SERIAL        PRIMARY KEY,
    medicine_id  INT           NOT NULL REFERENCES medicines(medicine_id),
    quantity     INT           NOT NULL CHECK (quantity > 0),
    unit_price   NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),     -- price at time of sale
    sold_on      DATE          NOT NULL
);

CREATE TABLE stock_audit (
    audit_id     SERIAL       PRIMARY KEY,
    medicine_id  INT          NOT NULL REFERENCES medicines(medicine_id),
    old_qty      INT          NOT NULL,
    new_qty      INT          NOT NULL,
    changed_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date    DATE          PRIMARY KEY,
    total_qty     INT           NOT NULL DEFAULT 0,
    total_amount  NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- =====================================================================
-- (b) Function: fn_sale_value
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_record_sale
-- Any RAISE EXCEPTION aborts the whole CALL, so an invalid sale leaves
-- both medicines and sales unchanged.
-- =====================================================================
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INT,
    p_quantity    INT,
    p_sold_on     DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INT;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date must not be NULL';
    END IF;

    -- Lock the medicine row so two sales cannot oversell at the same time
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: requested %, available %',
                        p_medicine_id, p_quantity, v_stock;
    END IF;

    -- Store the CURRENT price in the sale
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    -- Deduct stock exactly once
    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- =====================================================================
-- (d) Trigger: AFTER UPDATE row trigger on medicines
-- Logs OLD and NEW stock only when stock_qty actually changes.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_medicines_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION fn_medicines_stock_audit();

-- =====================================================================
-- (a) continued: seed data
-- Medicines are inserted directly; sales go through the procedure.
-- =====================================================================
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.00,  30),
    ('Ibuprofen 400mg',   4.00,  15);

CALL pr_record_sale(1, 20, DATE '2026-11-20');
CALL pr_record_sale(2,  5, DATE '2026-11-20');
CALL pr_record_sale(3,  4, DATE '2026-11-21');
CALL pr_record_sale(1, 10, DATE '2026-11-22');
CALL pr_record_sale(2, 20, DATE '2026-11-23');
CALL pr_record_sale(3,  3, DATE '2026-11-24');

-- Check the function and look at the results
SELECT fn_sale_value(1, 4) AS sale_value_example;
SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;

-- Proof that an invalid sale changes nothing (this CALL fails on purpose):
-- CALL pr_record_sale(3, 9999, CURRENT_DATE);   -- insufficient stock
-- SELECT * FROM medicines;                      -- stock is unchanged

-- =====================================================================
-- (e) View: v_low_stock
-- =====================================================================
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_name,
       unit_price,
       stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- Query after a sale: a sale that drops Ibuprofen below 10 puts it in the view
CALL pr_record_sale(3, 5, CURRENT_DATE);
SELECT * FROM v_low_stock;

-- =====================================================================
-- (f) Index: one medicine's sales within a sold_on date range
-- Equality column first (medicine_id), range column second (sold_on).
-- =====================================================================
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);

-- The table is tiny, so PostgreSQL may prefer a full scan. Turning seqscan
-- off for this session only shows that the index is usable.
SET enable_seqscan = off;
EXPLAIN
SELECT *
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN DATE '2026-11-20' AND DATE '2026-11-24';
RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- pr_refresh_sales replaces (not adds to) the day's totals, so a rerun
-- cannot duplicate or double-count.
-- =====================================================================
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty    = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

-- Run it twice for the same day: the result stays the same
CALL pr_refresh_sales(DATE '2026-11-20');
CALL pr_refresh_sales(DATE '2026-11-20');
SELECT * FROM daily_sales;

-- Schedule daily at 00:15 for the previous day (needs the pg_cron extension)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-daily-sales',
    '15 0 * * *',
    $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$
);

-- Inspect the job
SELECT jobid, jobname, schedule, command FROM cron.job;
