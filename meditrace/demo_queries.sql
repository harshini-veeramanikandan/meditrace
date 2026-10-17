-- =====================================================================
--  MediTrace - LIVE DEMO + ANALYSIS QUERIES
--  Run meditrace.sql first. Then run these ONE AT A TIME:
--  put the cursor on a statement and press Ctrl+Enter.
-- =====================================================================
USE meditrace;

-- =====================================================================
-- PART A. THE SIX VERDICTS (each INSERT is checked by trg_verify_scan)
--         After each INSERT, run the SELECT below it to see the verdict.
-- =====================================================================

-- A1. GENUINE: a real strip sold for the first time in Chennai
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES ('PCM2026A-00001', 1, '2026-10-15 10:00:00');
SELECT scan_id, serial_no, verdict, reason FROM scan_log ORDER BY scan_id DESC LIMIT 1;

-- A2. COUNTERFEIT: a serial no manufacturer ever made
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES ('PCM2026A-55555', 1, '2026-10-15 10:05:00');
SELECT scan_id, serial_no, verdict, reason FROM scan_log ORDER BY scan_id DESC LIMIT 1;

-- A3. CLONED: the same genuine serial sold again
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES ('PCM2026A-00001', 1, '2026-10-15 10:30:00');
SELECT scan_id, serial_no, verdict, reason FROM scan_log ORDER BY scan_id DESC LIMIT 1;

-- A4. SUSPICIOUS: same serial in Delhi 2 hours after Chennai (1756 km)
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES ('PCM2026A-00001', 6, '2026-10-15 12:30:00');
SELECT scan_id, serial_no, verdict, distance_km, speed_kmph, reason FROM scan_log ORDER BY scan_id DESC LIMIT 1;

-- A5. RECALLED: a genuine strip from the recalled Metformin batch
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES ('MET2026C-00001', 1, '2026-10-15 13:00:00');
SELECT scan_id, serial_no, verdict, reason FROM scan_log ORDER BY scan_id DESC LIMIT 1;

-- A6. EXPIRED: a genuine strip past its expiry date
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES ('AMX2024X-00003', 1, '2026-10-15 13:10:00');
SELECT scan_id, serial_no, verdict, reason FROM scan_log ORDER BY scan_id DESC LIMIT 1;

-- A7. Every flagged scan raised an alert automatically (trg_scan_alert)
SELECT * FROM v_open_alerts ORDER BY alert_id DESC;

-- A8. Every status change was audited automatically (trg_serial_audit)
SELECT * FROM serial_audit WHERE serial_no = 'PCM2026A-00001';

-- A9. Full journey of one strip (procedure returning TWO result sets)
CALL sp_trace_serial('PCM2026A-00001');

-- =====================================================================
-- PART B. INTEGRITY PROTECTION (each of these SHOULD FAIL with an error)
-- =====================================================================

-- B1. Scan records cannot be edited (trg_scan_no_update)
UPDATE scan_log SET verdict = 'GENUINE' WHERE scan_id = 15;

-- B2. Scan records cannot be deleted (trg_scan_no_delete)
DELETE FROM scan_log WHERE scan_id = 15;

-- B3. A sold strip cannot be "unsold" (trg_serial_no_unsell)
UPDATE serial_registry SET status = 'UNSOLD' WHERE serial_no = 'PCM2026A-00001';

-- B4. TRANSACTION ROLLBACK: batch number already exists, so the whole
--     registration is rolled back and no serials are created
CALL sp_register_batch(1, 'PCM2026A', '2026-10-01', '2028-09-30', 50);
SELECT COUNT(*) AS pcm_serials_still FROM serial_registry WHERE serial_no LIKE 'PCM2026A-%';   -- still 25

-- B5. Validation through SIGNAL
CALL sp_register_batch(1, 'PCM2026Z', '2026-10-01', '2026-09-01', 10);   -- expiry before mfg

-- B6. CHECK constraint: price must be positive
INSERT INTO medicine (manufacturer_id, name, composition, category, mrp)
VALUES (1, 'Test', 'Test', 'OTHER', -5);

-- =====================================================================
-- PART C. ANALYSIS QUERIES (joins, subqueries, GROUP BY / HAVING, CTE,
--         window functions, self-join)
-- =====================================================================

-- C1. Serials that appeared in more than one city (GROUP BY + HAVING)
SELECT s.serial_no,
       COUNT(*)               AS times_scanned,
       COUNT(DISTINCT p.city) AS cities,
       GROUP_CONCAT(DISTINCT p.city ORDER BY p.city SEPARATOR ', ') AS city_list
  FROM scan_log s
  JOIN pharmacy p ON p.pharmacy_id = s.pharmacy_id
 GROUP BY s.serial_no
HAVING COUNT(DISTINCT p.city) > 1;

-- C2. Pharmacies with more flagged scans than the average pharmacy (nested subquery)
SELECT p.name, p.city, COUNT(*) AS flagged
  FROM scan_log s
  JOIN pharmacy p ON p.pharmacy_id = s.pharmacy_id
 WHERE s.verdict <> 'GENUINE'
 GROUP BY p.pharmacy_id, p.name, p.city
HAVING COUNT(*) > (SELECT AVG(cnt)
                     FROM (SELECT COUNT(*) AS cnt
                             FROM scan_log
                            WHERE verdict <> 'GENUINE'
                            GROUP BY pharmacy_id) AS per_pharmacy);

-- C3. Daily fraud trend with a running total (CTE + window SUM)
WITH daily AS (
  SELECT DATE(scan_time) AS scan_date,
         SUM(verdict IN ('COUNTERFEIT','CLONED','SUSPICIOUS')) AS fraud_today
    FROM scan_log
   GROUP BY DATE(scan_time)
)
SELECT scan_date, fraud_today,
       SUM(fraud_today) OVER (ORDER BY scan_date) AS fraud_running_total
  FROM daily
 ORDER BY scan_date;

-- C4. Recalled or expired strips still unsold in the market (unsafe stock)
SELECT b.batch_no, m.name AS medicine, b.expiry_date, b.is_recalled,
       COUNT(*) AS unsold_strips
  FROM serial_registry sr
  JOIN batch b    ON b.batch_id = sr.batch_id
  JOIN medicine m ON m.medicine_id = b.medicine_id
 WHERE sr.status = 'UNSOLD'
   AND (b.is_recalled = TRUE OR b.expiry_date < CURDATE())
 GROUP BY b.batch_no, m.name, b.expiry_date, b.is_recalled;

-- C5. Medicines that have never been sold (NOT EXISTS)
SELECT m.name, mf.name AS manufacturer
  FROM medicine m
  JOIN manufacturer mf ON mf.manufacturer_id = m.manufacturer_id
 WHERE NOT EXISTS (SELECT 1
                     FROM batch b
                     JOIN serial_registry sr ON sr.batch_id = b.batch_id
                    WHERE b.medicine_id = m.medicine_id
                      AND sr.status = 'SOLD');

-- C6. Each pharmacy's most recent scan (correlated subquery)
SELECT p.name, p.city, s.serial_no, s.scan_time, s.verdict
  FROM pharmacy p
  JOIN scan_log s ON s.pharmacy_id = p.pharmacy_id
 WHERE s.scan_time = (SELECT MAX(s2.scan_time)
                        FROM scan_log s2
                       WHERE s2.pharmacy_id = p.pharmacy_id)
 ORDER BY s.scan_time DESC;

-- C7. Distance between every pair of pharmacies (self-join + function)
SELECT a.city AS from_city, b.city AS to_city,
       ROUND(haversine_km(a.latitude, a.longitude, b.latitude, b.longitude)) AS km,
       ROUND(haversine_km(a.latitude, a.longitude, b.latitude, b.longitude) / 100, 1)
         AS min_hours_at_100kmph
  FROM pharmacy a
  JOIN pharmacy b ON a.pharmacy_id < b.pharmacy_id
 ORDER BY km DESC
 LIMIT 10;

-- C8. Ranked hotspots, pharmacy risk, brand impact (views)
SELECT * FROM v_city_hotspots ORDER BY fraud_rank;
CALL sp_update_risk_levels();                       -- cursor recomputes risk
SELECT * FROM v_pharmacy_risk ORDER BY risk_pct DESC;
SELECT * FROM v_manufacturer_impact ORDER BY copy_incidents DESC;
SELECT * FROM v_batch_status;

-- C9. Daily report for a date range (procedure)
CALL sp_fraud_report('2026-10-01', '2026-10-15');

-- C10. Show the least-privilege users (DCL)
SHOW GRANTS FOR 'pharmacy_app'@'localhost';
SHOW GRANTS FOR 'regulator'@'localhost';

-- C11. Proof that the index is used for the trigger's previous-scan lookup
EXPLAIN SELECT scan_time FROM scan_log
         WHERE serial_no = 'PCM2026A-00001' AND scan_time <= '2026-10-15 23:59:59'
         ORDER BY scan_time DESC LIMIT 1;

-- =====================================================================
-- PART D. NEW FEATURES: patients, complaints, roles, events
-- =====================================================================

-- D1. Patient verification: logs the check, returns details, never sells the strip
CALL sp_patient_verify('PCM2026A-00012', 'Chennai');   -- UNSOLD_GENUINE
CALL sp_patient_verify('PCM2026A-99999', 'Kolkata');   -- NOT_REGISTERED
CALL sp_patient_verify('AZI2026E-00003', 'Kolkata');   -- COPIES_DETECTED
SELECT * FROM patient_check ORDER BY check_id DESC LIMIT 5;

-- D2. A new complaint: the trigger decides the priority, not the patient
INSERT INTO complaint (serial_no, reporter_name, reporter_phone, city, description)
VALUES ('ATV2026D-88888', 'V. Kumar', '9000012345', 'Delhi', 'Cholesterol tablets look different');
SELECT complaint_id, serial_no, priority, status, serial_state FROM v_complaints ORDER BY complaint_id DESC LIMIT 1;   -- URGENT

-- D3. Complaint workflow rules (each of these SHOULD FAIL)
CALL sp_update_complaint(4, 'INVESTIGATING', NULL, 1);   -- closed complaint cannot reopen
CALL sp_update_complaint(1, 'RESOLVED', '', 1);           -- closing needs a resolution note
CALL sp_update_complaint(3, 'OPEN', NULL, 1);             -- cannot go back to OPEN

-- D4. Role rule (SHOULD FAIL): a pharmacist must belong to a pharmacy
INSERT INTO app_user (username, password_hash, full_name, role)
VALUES ('nobody', SHA2('x', 256), 'No Pharmacy', 'PHARMACIST');

-- D5. Passwords are never stored in plain text
SELECT username, role, password_hash FROM app_user;
SELECT username FROM app_user WHERE username = 'admin' AND password_hash = SHA2('admin123', 256);   -- login check

-- D6. Speed limit is data, not code (SHOULD FAIL, then succeed)
CALL sp_set_speed_limit(5);
CALL sp_set_speed_limit(100);

-- D7. Scheduled event and the full object inventory
SHOW EVENTS FROM meditrace;
SELECT TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION, EVENT_OBJECT_TABLE
  FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = 'meditrace';
SELECT ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = 'meditrace';

-- D8. Fraud map data: impossible-travel routes with both end points (LAG)
SELECT * FROM v_travel_anomalies;

-- D9. Resolving an alert needs a note, and an alert can only be resolved once
CALL sp_resolve_alert(2, '', 1);                                          -- SHOULD FAIL: needs a note
CALL sp_resolve_alert(2, 'Pharmacy inspected; stock seized', 1);          -- works
CALL sp_resolve_alert(2, 'Trying again', 1);                              -- SHOULD FAIL: already resolved
SELECT a.alert_id, a.severity, a.action_taken, u.full_name AS resolved_by, a.resolved_at
  FROM alert a JOIN app_user u ON u.user_id = a.resolved_by ORDER BY a.resolved_at DESC;
