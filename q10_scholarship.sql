-- ICT371 Question 10: Scholarship Application Assessment (PostgreSQL)

DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INT NOT NULL REFERENCES students(student_id),
    age_at_application INT NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE NOT NULL,
    status             VARCHAR(10) NOT NULL DEFAULT 'PENDING'
                       CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT NOW()
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark cannot be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative, got %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_app applications%ROWTYPE;
BEGIN
    SELECT * INTO v_app
      FROM applications
     WHERE application_id = p_application_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id;
    END IF;
    IF v_app.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status: %)',
                        p_application_id, v_app.status;
    END IF;

    UPDATE applications
       SET status = CASE
               WHEN fn_scholarship_eligible(v_app.age_at_application,
                                            v_app.monthly_income,
                                            v_app.average_mark)
               THEN 'APPROVED' ELSE 'REJECTED' END
     WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (NEW.application_id, OLD.status, NEW.status, NOW());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- Seed data ----------------------------------------------------------------
INSERT INTO students (student_number, full_name) VALUES
 ('S1001', 'Thandiwe Mulenga'),
 ('S1002', 'Kelvin Chisha'),
 ('S1003', 'Ruth Kabwe');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
 (1, 20, 2500.00, 82.50, '2026-11-01', 'PENDING'),   -- clearly qualifies
 (1, 18, 3000.00, 70.00, '2026-11-02', 'PENDING'),   -- lower boundaries: qualifies
 (2, 25, 1500.00, 75.00, '2026-11-03', 'PENDING'),   -- upper age boundary: qualifies
 (2, 17, 1000.00, 90.00, '2026-11-04', 'PENDING'),   -- too young: rejected
 (3, 22, 3000.01, 85.00, '2026-11-05', 'PENDING'),   -- income just over: rejected
 (3, 23, 2000.00, 69.99, '2026-11-06', 'PENDING');   -- mark just under: rejected

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
  FROM applications a
  JOIN students s ON s.student_id = a.student_id
 WHERE a.status = 'APPROVED';       -- income deliberately not exposed

-- (f) Index ----------------------------------------------------------------
-- status is an equality filter and submitted_on a range filter, so (status, submitted_on)
-- lets one index scan satisfy both conditions.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

SET enable_seqscan = off;
EXPLAIN SELECT * FROM applications
         WHERE status = 'PENDING'
           AND submitted_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;

-- (g) Batch procedure + schedule ---------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT application_id
               FROM applications
              WHERE status = 'PENDING'
              ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- Every Monday at 08:00
SELECT cron.schedule('weekly-assess-pending', '0 8 * * 1', $cron$CALL pr_assess_pending()$cron$);

-- Tests --------------------------------------------------------------------
SELECT fn_scholarship_eligible(18, 3000, 70);   -- true
SELECT fn_scholarship_eligible(26, 1000, 90);   -- false
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1, 1); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 80); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 100, 101); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

CALL pr_assess_application(1);                   -- approved
DO $$ BEGIN CALL pr_assess_application(1);      -- already assessed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(999);    -- unknown
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

CALL pr_assess_pending();                        -- processes applications 2-6
CALL pr_assess_pending();                        -- rerun: nothing to do

SELECT application_id, status FROM applications ORDER BY 1;   -- 1,2,3 APPROVED; 4,5,6 REJECTED
SELECT * FROM decision_audit ORDER BY audit_id;               -- exactly 6 rows
SELECT * FROM v_approved_applicants;
