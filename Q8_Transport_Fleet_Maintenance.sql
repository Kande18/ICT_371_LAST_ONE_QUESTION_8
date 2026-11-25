-- =====================================================================
-- ICT371 Advanced Database | Question 8: Transport Fleet Maintenance
-- Target DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Run with:  psql -d your_database -f Q8_Transport_Fleet_Maintenance.sql
-- Service rule: due when current_odometer - last_service_odometer >= 5000 km.
-- =====================================================================

-- ---------------------------------------------------------------------
-- (a) Database and seed data (trips are loaded at the end through the procedure,
--     after the trigger is installed)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

CREATE TABLE vehicles (
    vehicle_id             SERIAL      PRIMARY KEY,
    registration           VARCHAR(20) NOT NULL UNIQUE,
    current_odometer       INTEGER     NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer  INTEGER     NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id         SERIAL  PRIMARY KEY,
    vehicle_id      INTEGER NOT NULL REFERENCES vehicles (vehicle_id),
    trip_on         DATE    NOT NULL,
    start_odometer  INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer    INTEGER NOT NULL CHECK (end_odometer   >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id        INTEGER PRIMARY KEY REFERENCES vehicles (vehicle_id),
    km_since_service  INTEGER NOT NULL,
    flagged_on        DATE    NOT NULL
);

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('BAE 1001', 20000, 14000),   -- 6000 km since service: already DUE
    ('BAE 2002', 30000, 27500),   -- 2500 km: not due
    ('BAE 3003',  8000,  3100);   -- 4900 km: not due yet, becomes due after trips

-- ---------------------------------------------------------------------
-- (b) Function fn_service_due
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
    v_service INTEGER;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_current, v_service
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_service) >= 5000;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure pr_record_trip (does NOT touch vehicles; the trigger does that)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INTEGER, p_trip_on DATE, p_start INTEGER, p_end INTEGER)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start and end odometer must not be NULL';
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: BEFORE INSERT on trips
--     Verifies start = vehicle's current odometer, rejects invalid mileage,
--     and updates current_odometer to the trip end exactly once.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
BEGIN
    -- Lock the vehicle row so two trips cannot start from the same odometer value
    SELECT current_odometer INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: start %, end % (end must exceed start)',
                        NEW.start_odometer, NEW.end_odometer;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Start odometer % does not match vehicle current odometer %',
                        NEW.start_odometer, v_current;
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_trip_odometer ON trips;
CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

-- ---------------------------------------------------------------------
-- (e) View: v_service_due
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

-- ---------------------------------------------------------------------
-- (f) Index for one vehicle's trips within a trip_on date range
--     Equality column (vehicle_id) first, range column (trip_on) second.
-- ---------------------------------------------------------------------
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_service_alerts
--     1) insert a missing alert / update km on an existing one (flagged_on keeps the
--        date the vehicle was first flagged)
--     2) remove alerts for vehicles that are no longer due
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id,
           current_odometer - last_service_odometer,
           CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id)
    DO UPDATE SET km_since_service = EXCLUDED.km_since_service;

    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1
        FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND v.current_odometer - v.last_service_odometer >= 5000
    );
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Every Monday at 06:00
SELECT cron.schedule(
    'fleet_refresh_service_alerts',
    '0 6 * * 1',
    $$CALL pr_refresh_service_alerts()$$
);

-- =====================================================================
-- DEMONSTRATION / TESTING
-- =====================================================================

-- (a) Six trips loaded through the procedure (each starts at the current odometer)
CALL pr_record_trip(1, CURRENT_DATE - 6, 20000, 20150);
CALL pr_record_trip(1, CURRENT_DATE - 3, 20150, 20400);
CALL pr_record_trip(2, CURRENT_DATE - 5, 30000, 30200);
CALL pr_record_trip(2, CURRENT_DATE - 2, 30200, 30700);
CALL pr_record_trip(3, CURRENT_DATE - 4, 8000,  8060);
CALL pr_record_trip(3, CURRENT_DATE - 1, 8060,  8200);   -- 8200 - 3100 = 5100 => due

SELECT * FROM vehicles ORDER BY vehicle_id;      -- odometers moved to the last trip end
SELECT * FROM trips ORDER BY trip_id;

-- (b)
SELECT fn_service_due(1) AS v1_due,    -- true
       fn_service_due(2) AS v2_due,    -- false
       fn_service_due(3) AS v3_due;    -- true
-- SELECT fn_service_due(99);          -- ERROR: Unknown vehicle_id

-- (c)/(d) Rejections (uncomment one at a time)
-- CALL pr_record_trip(1, CURRENT_DATE, 20400, 20400);   -- ERROR: end must exceed start
-- CALL pr_record_trip(1, CURRENT_DATE, 20000, 20500);   -- ERROR: start <> current odometer (trigger)
-- CALL pr_record_trip(99, CURRENT_DATE, 0, 10);         -- ERROR: unknown vehicle
-- INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
--   VALUES (2, CURRENT_DATE, 30700, 30600);             -- ERROR: invalid mileage (direct SQL)

-- (e)
SELECT * FROM v_service_due ORDER BY registration;       -- BAE 1001 (6400) and BAE 3003 (5100)

-- (f) EXPLAIN (seqscan disabled only because the demo table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT *
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Run the job; then simulate a service and run again (inside a transaction, rolled back)
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;        -- vehicles 1 and 3

BEGIN;
  UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 1;
  CALL pr_refresh_service_alerts();
  SELECT * FROM service_alerts ORDER BY vehicle_id;      -- alert for vehicle 1 removed
ROLLBACK;

SELECT jobid, jobname, schedule, command, active FROM cron.job;
