-- ICT371 Question 9: Farmer Cooperative Maize Deliveries (PostgreSQL)

DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
    weight_kg    NUMERIC(12,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10,2) NOT NULL,      -- set by trigger
    total_value  NUMERIC(14,2) NOT NULL,      -- set by trigger
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(14,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC AS $$
DECLARE
    v_rate NUMERIC;
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL';
    END IF;

    v_rate := CASE p_grade WHEN 'A' THEN 5.00 WHEN 'B' THEN 4.00 WHEN 'C' THEN 3.00 END;

    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade: %', p_grade;
    END IF;
    RETURN v_rate;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- (d) Trigger (installed before any data is loaded) ---------------------------
CREATE OR REPLACE FUNCTION trg_fn_delivery_price()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_delivery_price
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_fn_delivery_price();

-- (c) Procedure (supplies basic fields only; trigger fills rate and value) ---
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade TEXT, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_farmer_id IS NULL OR p_grade IS NULL OR p_weight IS NULL OR p_date IS NULL THEN
        RAISE EXCEPTION 'All delivery inputs are required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Farmer % does not exist', p_farmer_id;
    END IF;
    IF p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', p_weight;
    END IF;
    PERFORM fn_maize_rate(p_grade);   -- rejects unsupported grade with a clear message

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- Seed data ----------------------------------------------------------------
INSERT INTO farmers (farmer_number, full_name) VALUES
 ('F001', 'Joseph Kunda'),
 ('F002', 'Esther Chanda'),
 ('F003', 'Moses Sakala');

-- Three unpaid deliveries through the procedure
CALL pr_receive_delivery(1, 'A', 200.00, '2026-11-20');
CALL pr_receive_delivery(2, 'B', 150.50, '2026-11-20');
CALL pr_receive_delivery(1, 'C', 300.00, '2026-11-21');

-- Three paid deliveries by direct SQL (trigger still prices them;
-- rate and value are placeholders overwritten by the trigger)
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid) VALUES
 (2, 'A', 100.00, 0, 0, '2026-11-18', TRUE),
 (3, 'B', 250.00, 0, 0, '2026-11-19', TRUE),
 (3, 'C',  80.25, 0, 0, '2026-11-21', TRUE);

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0) AS amount_due
  FROM farmers f
  LEFT JOIN deliveries d
         ON d.farmer_id = f.farmer_id
        AND d.is_paid = FALSE
 GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- (f) Index ----------------------------------------------------------------
-- Equality column (farmer_id) first, range column (delivered_on) second.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

SET enable_seqscan = off;
EXPLAIN SELECT * FROM deliveries
         WHERE farmer_id = 1
           AND delivered_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;

-- (g) Summary procedure + schedule ------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
      FROM deliveries
     WHERE delivered_on = p_day
    ON CONFLICT (purchase_date)
    DO UPDATE SET total_weight = EXCLUDED.total_weight,
                  total_value  = EXCLUDED.total_value;   -- replace, never add
END;
$$;

-- CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('daily-purchases', '30 1 * * *',
       $cron$CALL pr_refresh_purchases((CURRENT_DATE - 1))$cron$);

-- Tests --------------------------------------------------------------------
SELECT delivery_id, farmer_id, grade, weight_kg, unit_rate, total_value, is_paid FROM deliveries ORDER BY 1;
SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

DO $$ BEGIN PERFORM fn_maize_rate('D');  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_maize_rate(NULL); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);   -- unknown farmer
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);    -- bad weight
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
            VALUES (1, 'A', 0, 99, 99, CURRENT_DATE);               -- direct SQL, zero weight
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

CALL pr_refresh_purchases('2026-11-21');
CALL pr_refresh_purchases('2026-11-21');                            -- rerun: same totals
SELECT * FROM daily_purchases;                                      -- 380.25 kg, 1140 + 240.75 = 1140.75
