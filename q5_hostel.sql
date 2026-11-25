-- =====================================================================
-- ICT371 Advanced Database
-- Question 5: Hostel Room Allocation
-- DBMS: PostgreSQL
-- =====================================================================

DROP VIEW      IF EXISTS v_room_occupancy;
DROP TABLE     IF EXISTS occupancy_snapshot;
DROP TABLE     IF EXISTS allocations;
DROP TABLE     IF EXISTS rooms;
DROP TABLE     IF EXISTS students;
DROP PROCEDURE IF EXISTS pr_allocate_room(INT, INT, DATE);
DROP PROCEDURE IF EXISTS pr_refresh_occupancy();
DROP FUNCTION  IF EXISTS fn_free_beds(INT);
DROP FUNCTION  IF EXISTS fn_check_allocation();

-- =====================================================================
-- (a) Database: tables, keys, constraints
-- =====================================================================
CREATE TABLE students (
    student_id      SERIAL       PRIMARY KEY,
    student_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name       VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id      SERIAL      PRIMARY KEY,
    room_number  VARCHAR(10) NOT NULL UNIQUE,
    capacity     INT         NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id  SERIAL      PRIMARY KEY,
    student_id     INT         NOT NULL REFERENCES students(student_id),
    room_id        INT         NOT NULL REFERENCES rooms(room_id),
    allocated_on   DATE        NOT NULL,
    released_on    DATE        NULL,
    status         VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    -- ACTIVE needs released_on NULL; ENDED needs a release date
    CONSTRAINT chk_status_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL)
    ),
    CONSTRAINT chk_release_after_allocation CHECK (
        released_on IS NULL OR released_on >= allocated_on
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date  DATE NOT NULL,
    room_id        INT  NOT NULL REFERENCES rooms(room_id),
    occupied_beds  INT  NOT NULL,
    free_beds      INT  NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

-- =====================================================================
-- (b) Function: fn_free_beds (only ACTIVE allocations use beds)
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INT;
    v_active   INT;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$;

-- =====================================================================
-- (d) Trigger (created before the procedure so direct SQL is always
-- protected). BEFORE INSERT OR UPDATE row trigger.
-- It locks the room row so two people cannot take the last bed at once,
-- and it excludes the row being updated when counting others.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_check_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INT;
    v_others   INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT capacity INTO v_capacity
        FROM rooms
        WHERE room_id = NEW.room_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
        END IF;

        -- One ACTIVE allocation per student
        IF EXISTS (
            SELECT 1 FROM allocations
            WHERE student_id = NEW.student_id
              AND status = 'ACTIVE'
              AND allocation_id IS DISTINCT FROM NEW.allocation_id
        ) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        -- Capacity check
        SELECT COUNT(*) INTO v_others
        FROM allocations
        WHERE room_id = NEW.room_id
          AND status = 'ACTIVE'
          AND allocation_id IS DISTINCT FROM NEW.allocation_id;

        IF v_others >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_allocation
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION fn_check_allocation();

-- =====================================================================
-- (c) Procedure: pr_allocate_room
-- Gives clear messages up front; the trigger still guards direct SQL.
-- =====================================================================
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INT,
    p_room_id      INT,
    p_allocated_on DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date must not be NULL';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- =====================================================================
-- (a) continued: seed data
-- R101 will be full, R102 partly occupied, R103 empty.
-- =====================================================================
INSERT INTO students (student_number, full_name) VALUES
    ('MU2024101', 'Bwalya Kunda'),
    ('MU2024102', 'Mwansa Chola'),
    ('MU2024103', 'Tendai Moyo'),
    ('MU2024104', 'Lubono Siame'),
    ('MU2024105', 'Njavwa Zulu'),
    ('MU2024106', 'Kasonde Mpundu');

INSERT INTO rooms (room_number, capacity) VALUES
    ('R101', 2),
    ('R102', 3),
    ('R103', 2);

-- History: Lubono lived in R101 earlier (ENDED, takes no bed)
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 1, DATE '2026-02-01', DATE '2026-06-30', 'ENDED');

CALL pr_allocate_room(1, 1, DATE '2026-09-01');   -- R101 now 1/2
CALL pr_allocate_room(2, 1, DATE '2026-09-01');   -- R101 now 2/2 (full)
CALL pr_allocate_room(3, 2, DATE '2026-09-02');   -- R102 1/3
CALL pr_allocate_room(5, 2, DATE '2026-09-03');   -- R102 2/3

SELECT fn_free_beds(1) AS r101_free,   -- 0
       fn_free_beds(2) AS r102_free,   -- 1
       fn_free_beds(3) AS r103_free;   -- 2

SELECT * FROM allocations ORDER BY allocation_id;

-- Invalid calls and direct SQL (each fails on purpose):
-- CALL pr_allocate_room(6, 1, CURRENT_DATE);        -- room full
-- CALL pr_allocate_room(1, 3, CURRENT_DATE);        -- student already ACTIVE
-- CALL pr_allocate_room(99, 3, CURRENT_DATE);       -- unknown student
-- CALL pr_allocate_room(6, 99, CURRENT_DATE);       -- unknown room
-- INSERT INTO allocations (student_id, room_id, allocated_on, status)
-- VALUES (6, 1, CURRENT_DATE, 'ACTIVE');            -- trigger blocks direct SQL

-- =====================================================================
-- (e) View: v_room_occupancy (LEFT JOIN keeps rooms with no allocations)
-- =====================================================================
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)               AS occupied_beds,
       r.capacity - COUNT(a.allocation_id)  AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_id;

-- =====================================================================
-- (f) Index: ACTIVE allocations by room_id
-- Partial index covering only ACTIVE rows (the rows that count beds).
-- =====================================================================
CREATE INDEX idx_allocations_active_room
    ON allocations (room_id)
    WHERE status = 'ACTIVE';

SET enable_seqscan = off;   -- tiny table: force the planner to show the index
EXPLAIN
SELECT allocation_id, student_id
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';
RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- One row per (date, room); ON CONFLICT replaces values on a rerun.
-- =====================================================================
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE,
           r.room_id,
           COUNT(a.allocation_id),
           r.capacity - COUNT(a.allocation_id)
    FROM rooms r
    LEFT JOIN allocations a
           ON a.room_id = r.room_id AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
        SET occupied_beds = EXCLUDED.occupied_beds,
            free_beds     = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();   -- rerun: same rows replaced
SELECT * FROM occupancy_snapshot ORDER BY room_id;

-- Schedule daily at 23:55 (needs the pg_cron extension)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-hostel-occupancy',
    '55 23 * * *',
    $$CALL pr_refresh_occupancy()$$
);

SELECT jobid, jobname, schedule, command FROM cron.job;
