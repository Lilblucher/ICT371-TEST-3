-- ICT371 Question 8: Transport Fleet Maintenance (PostgreSQL)

DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id             SERIAL PRIMARY KEY,
    registration           VARCHAR(20) NOT NULL UNIQUE,
    current_odometer       INT NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer  INT NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_le_current CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INT NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INT NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INT NOT NULL,
    flagged_on       DATE NOT NULL
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN AS $$
DECLARE
    v_km INT;
BEGIN
    SELECT current_odometer - last_service_odometer
      INTO v_km
      FROM vehicles
     WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle % does not exist', p_vehicle_id;
    END IF;
    RETURN v_km >= 5000;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure (does NOT touch vehicles; the trigger does) -----------------
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start and end odometer are required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Vehicle % does not exist', p_vehicle_id;
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS TRIGGER AS $$
DECLARE
    v_current INT;
BEGIN
    SELECT current_odometer
      INTO v_current
      FROM vehicles
     WHERE vehicle_id = NEW.vehicle_id
       FOR UPDATE;                                   -- lock row: no concurrent double update

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle % does not exist', NEW.vehicle_id;
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end (%) must exceed start (%)',
                        NEW.end_odometer, NEW.start_odometer;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Start odometer % does not match current odometer % for vehicle %',
                        NEW.start_odometer, v_current, NEW.vehicle_id;
    END IF;

    UPDATE vehicles
       SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_fn_trip_odometer();

-- Seed data ----------------------------------------------------------------
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
 ('ABC 1001', 20000, 18000),
 ('ABD 2002', 30000, 24000),
 ('ACE 3003', 15000, 11000);

CALL pr_record_trip(1, '2026-11-01', 20000, 20300);
CALL pr_record_trip(1, '2026-11-05', 20300, 20800);
CALL pr_record_trip(2, '2026-11-02', 30000, 30400);
CALL pr_record_trip(2, '2026-11-06', 30400, 31000);
CALL pr_record_trip(3, '2026-11-03', 15000, 15500);
CALL pr_record_trip(3, '2026-11-07', 15500, 16000);

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
  FROM vehicles
 WHERE current_odometer - last_service_odometer >= 5000;

-- (f) Index ----------------------------------------------------------------
-- Equality on vehicle_id first, then a range on trip_on: the ideal column order
-- for a B-tree, so one vehicle's date range is a single contiguous index scan.
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);

SET enable_seqscan = off;
EXPLAIN SELECT * FROM trips
         WHERE vehicle_id = 1
           AND trip_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;

-- (g) Alerts procedure + schedule -------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    -- insert new alerts / update km for existing ones (keeps original flagged_on)
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
      FROM vehicles
     WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id)
    DO UPDATE SET km_since_service = EXCLUDED.km_since_service;

    -- remove alerts for vehicles that are no longer due
    DELETE FROM service_alerts sa
     WHERE NOT EXISTS (
            SELECT 1 FROM vehicles v
             WHERE v.vehicle_id = sa.vehicle_id
               AND v.current_odometer - v.last_service_odometer >= 5000);
END;
$$;

-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- Every Monday at 06:00 (cron day-of-week 1 = Monday)
SELECT cron.schedule('weekly-service-alerts', '0 6 * * 1', $cron$CALL pr_refresh_service_alerts()$cron$);

-- Tests --------------------------------------------------------------------
SELECT vehicle_id, registration, current_odometer, fn_service_due(vehicle_id) AS due FROM vehicles ORDER BY 1;
-- expected: vehicle 1 false (2800 km), vehicle 2 true (7000 km), vehicle 3 true (exactly 5000 km)
SELECT * FROM v_service_due;

DO $$ BEGIN PERFORM fn_service_due(99); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, '2026-11-10', 20800, 20800);   -- end not greater than start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, '2026-11-10', 20000, 20900);   -- start does not match current
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(99, '2026-11-10', 1, 2);          -- unknown vehicle
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;                -- vehicles 2 and 3

-- Service vehicle 2, rerun: its alert is removed
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;                -- vehicle 3 only
