-- =====================================================================
--  MediTrace: Counterfeit Medicine Detection System
--  BCSE302L Database Systems - Digital Assignment II
--
--  HOW TO RUN: open this file in MySQL Workbench and run the WHOLE
--  script with the lightning button (Ctrl+Shift+Enter).
--  Re-running it resets everything to clean sample data.
--
--  DBMS concepts used in this file
--   DDL ........ 9 tables, PK / FK / UNIQUE / CHECK / ENUM / DEFAULT
--   Indexes .... 5 secondary indexes for the hot queries
--   Function ... haversine_km (distance), fn_pharmacy_risk
--   Triggers ... 6 (fraud detection, alerts, append-only evidence,
--                no un-selling, status audit)
--   Procedures . 6 (transaction + rollback, SIGNAL errors, cursor loop,
--                multiple result sets)
--   Views ...... 8 (joins, GROUP BY, window functions RANK / LAG /
--                ROW_NUMBER, CASE)
--   DCL ........ 2 least-privilege users with GRANT
-- =====================================================================

DROP DATABASE IF EXISTS meditrace;
CREATE DATABASE meditrace;
USE meditrace;

-- =====================================================================
-- 1. TABLES (DDL)
-- =====================================================================

CREATE TABLE manufacturer (
  manufacturer_id INT AUTO_INCREMENT PRIMARY KEY,
  name            VARCHAR(100) NOT NULL,
  license_no      VARCHAR(30)  NOT NULL UNIQUE,
  city            VARCHAR(50)  NOT NULL,
  contact_email   VARCHAR(100)
);

CREATE TABLE medicine (
  medicine_id       INT AUTO_INCREMENT PRIMARY KEY,
  manufacturer_id   INT NOT NULL,
  name              VARCHAR(100) NOT NULL,
  composition       VARCHAR(200) NOT NULL,
  category          ENUM('ANALGESIC','ANTIBIOTIC','ANTIDIABETIC','CARDIAC','ANTIALLERGIC','OTHER') NOT NULL,
  mrp               DECIMAL(8,2) NOT NULL CHECK (mrp > 0),
  needs_prescription BOOLEAN NOT NULL DEFAULT FALSE,
  FOREIGN KEY (manufacturer_id) REFERENCES manufacturer(manufacturer_id)
);

CREATE TABLE batch (
  batch_id      INT AUTO_INCREMENT PRIMARY KEY,
  medicine_id   INT NOT NULL,
  batch_no      VARCHAR(20) NOT NULL UNIQUE,
  mfg_date      DATE NOT NULL,
  expiry_date   DATE NOT NULL,
  is_recalled   BOOLEAN NOT NULL DEFAULT FALSE,
  recall_reason VARCHAR(200),
  recalled_at   DATETIME,
  FOREIGN KEY (medicine_id) REFERENCES medicine(medicine_id),
  CHECK (expiry_date > mfg_date)
);

CREATE TABLE serial_registry (
  serial_no VARCHAR(30) PRIMARY KEY,
  batch_id  INT NOT NULL,
  status    ENUM('UNSOLD','SOLD') NOT NULL DEFAULT 'UNSOLD',
  sold_at   DATETIME NULL,
  FOREIGN KEY (batch_id) REFERENCES batch(batch_id)
);

CREATE TABLE pharmacy (
  pharmacy_id INT AUTO_INCREMENT PRIMARY KEY,
  name        VARCHAR(100) NOT NULL,
  license_no  VARCHAR(30)  NOT NULL UNIQUE,
  city        VARCHAR(50)  NOT NULL,
  latitude    DECIMAL(9,6) NOT NULL CHECK (latitude  BETWEEN -90  AND 90),
  longitude   DECIMAL(9,6) NOT NULL CHECK (longitude BETWEEN -180 AND 180),
  risk_level  ENUM('LOW','MEDIUM','HIGH') NOT NULL DEFAULT 'LOW'
);

CREATE TABLE scan_log (
  scan_id     INT AUTO_INCREMENT PRIMARY KEY,
  serial_no   VARCHAR(30) NOT NULL,     -- NOT a foreign key on purpose:
                                        -- fake serials must be logged as evidence
  pharmacy_id INT NOT NULL,
  scan_time   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  verdict     ENUM('GENUINE','COUNTERFEIT','CLONED','SUSPICIOUS','RECALLED','EXPIRED'),
  reason      VARCHAR(255),
  distance_km DECIMAL(8,1) NULL,        -- distance from the previous scan
  speed_kmph  DECIMAL(9,1) NULL,        -- speed needed to cover that distance
  FOREIGN KEY (pharmacy_id) REFERENCES pharmacy(pharmacy_id)
);

CREATE TABLE alert (
  alert_id    INT AUTO_INCREMENT PRIMARY KEY,
  scan_id     INT NOT NULL UNIQUE,
  pharmacy_id INT NOT NULL,
  severity    ENUM('MEDIUM','HIGH','CRITICAL') NOT NULL,
  message     VARCHAR(300) NOT NULL,
  created_at  DATETIME NOT NULL,
  is_resolved BOOLEAN NOT NULL DEFAULT FALSE,
  resolved_at DATETIME NULL,
  FOREIGN KEY (scan_id)     REFERENCES scan_log(scan_id),
  FOREIGN KEY (pharmacy_id) REFERENCES pharmacy(pharmacy_id)
);

CREATE TABLE serial_audit (
  audit_id   INT AUTO_INCREMENT PRIMARY KEY,
  serial_no  VARCHAR(30) NOT NULL,
  old_status VARCHAR(10),
  new_status VARCHAR(10),
  changed_at DATETIME NOT NULL,
  changed_by VARCHAR(100) NOT NULL,
  FOREIGN KEY (serial_no) REFERENCES serial_registry(serial_no)
);

CREATE TABLE settings (
  setting_key   VARCHAR(30) PRIMARY KEY,
  setting_value DECIMAL(10,2) NOT NULL,
  description   VARCHAR(200)
);

INSERT INTO settings VALUES
 ('max_speed_kmph', 100, 'Max realistic road speed; faster travel between scans = cloned code');

-- =====================================================================
-- 2. INDEXES (speed up the queries the trigger runs on every scan)
-- =====================================================================
CREATE INDEX idx_scan_serial_time ON scan_log (serial_no, scan_time);  -- previous-scan lookup
CREATE INDEX idx_scan_verdict     ON scan_log (verdict);               -- dashboard counts
CREATE INDEX idx_pharmacy_city    ON pharmacy (city);                  -- hotspot grouping
CREATE INDEX idx_batch_expiry     ON batch (expiry_date);              -- expiry checks
CREATE INDEX idx_alert_open       ON alert (is_resolved, severity);    -- open alerts list

DELIMITER $$

-- =====================================================================
-- 3. FUNCTIONS
-- =====================================================================

-- Great-circle distance in km between two lat/long points (Haversine)
CREATE FUNCTION haversine_km(lat1 DECIMAL(9,6), lon1 DECIMAL(9,6),
                             lat2 DECIMAL(9,6), lon2 DECIMAL(9,6))
RETURNS DOUBLE DETERMINISTIC
BEGIN
  RETURN 2 * 6371 * ASIN(SQRT(
           POWER(SIN(RADIANS(lat2 - lat1) / 2), 2) +
           COS(RADIANS(lat1)) * COS(RADIANS(lat2)) *
           POWER(SIN(RADIANS(lon2 - lon1) / 2), 2)));
END$$

-- Share of a pharmacy's scans that were flagged (0 - 100)
CREATE FUNCTION fn_pharmacy_risk(p_id INT)
RETURNS DECIMAL(5,1) READS SQL DATA
BEGIN
  DECLARE v_total INT DEFAULT 0;
  DECLARE v_flag  INT DEFAULT 0;
  SELECT COUNT(*), IFNULL(SUM(verdict <> 'GENUINE'), 0)
    INTO v_total, v_flag
    FROM scan_log WHERE pharmacy_id = p_id;
  IF v_total = 0 THEN
    RETURN 0;
  END IF;
  RETURN ROUND(100 * v_flag / v_total, 1);
END$$

-- =====================================================================
-- 4. TRIGGERS
-- =====================================================================

-- 4.1 THE CORE: verify every scan before it is saved ------------------
CREATE TRIGGER trg_verify_scan
BEFORE INSERT ON scan_log
FOR EACH ROW
BEGIN
  DECLARE v_status        VARCHAR(10);
  DECLARE v_recalled      BOOLEAN;
  DECLARE v_recall_reason VARCHAR(200);
  DECLARE v_expiry        DATE;
  DECLARE v_no_prev       INT DEFAULT 0;
  DECLARE v_prev_time     DATETIME;
  DECLARE v_prev_lat, v_prev_lon, v_cur_lat, v_cur_lon DECIMAL(9,6);
  DECLARE v_prev_city, v_cur_city VARCHAR(50);
  DECLARE v_dist, v_hours, v_limit DOUBLE DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_no_prev = 1;

  IF NEW.scan_time IS NULL THEN SET NEW.scan_time = NOW(); END IF;
  SET NEW.serial_no = UPPER(TRIM(NEW.serial_no));

  -- facts about the serial (NULL if it was never registered)
  SET v_status = (SELECT status FROM serial_registry
                   WHERE serial_no = NEW.serial_no);
  SET v_recalled = (SELECT b.is_recalled FROM serial_registry sr
                      JOIN batch b ON b.batch_id = sr.batch_id
                     WHERE sr.serial_no = NEW.serial_no);
  SET v_recall_reason = (SELECT b.recall_reason FROM serial_registry sr
                           JOIN batch b ON b.batch_id = sr.batch_id
                          WHERE sr.serial_no = NEW.serial_no);
  SET v_expiry = (SELECT b.expiry_date FROM serial_registry sr
                    JOIN batch b ON b.batch_id = sr.batch_id
                   WHERE sr.serial_no = NEW.serial_no);
  SET v_limit = (SELECT setting_value FROM settings
                  WHERE setting_key = 'max_speed_kmph');

  SELECT latitude, longitude, city INTO v_cur_lat, v_cur_lon, v_cur_city
    FROM pharmacy WHERE pharmacy_id = NEW.pharmacy_id;

  -- the previous scan of the same serial (if any)
  SET v_no_prev = 0;
  SELECT s.scan_time, p.latitude, p.longitude, p.city
    INTO v_prev_time, v_prev_lat, v_prev_lon, v_prev_city
    FROM scan_log s JOIN pharmacy p ON p.pharmacy_id = s.pharmacy_id
   WHERE s.serial_no = NEW.serial_no
     AND s.scan_time <= NEW.scan_time
   ORDER BY s.scan_time DESC, s.scan_id DESC
   LIMIT 1;

  IF v_status IS NULL THEN
    -- CHECK 1: serial never registered by any manufacturer
    SET NEW.verdict = 'COUNTERFEIT';
    SET NEW.reason  = 'Serial number not registered by any manufacturer';
  ELSE
    IF v_no_prev = 0 THEN
      SET v_dist  = haversine_km(v_prev_lat, v_prev_lon, v_cur_lat, v_cur_lon);
      SET v_hours = TIMESTAMPDIFF(SECOND, v_prev_time, NEW.scan_time) / 3600;
      SET NEW.distance_km = ROUND(v_dist, 1);
      SET NEW.speed_kmph  = CASE WHEN v_hours > 0 THEN ROUND(v_dist / v_hours, 1) END;
    END IF;

    IF v_no_prev = 0 AND v_dist > 1 AND v_dist > v_limit * v_hours THEN
      -- CHECK 2: same strip in two places faster than any vehicle
      --          (speed = dist / hours > limit, written without division)
      SET NEW.verdict = 'SUSPICIOUS';
      SET NEW.reason  = CONCAT('Impossible travel: ', ROUND(v_dist), ' km from ',
                               v_prev_city, ' to ', v_cur_city, ' in ',
                               ROUND(v_hours, 1), ' h',
                               IFNULL(CONCAT(' (', ROUND(NEW.speed_kmph), ' km/h)'),
                                      ' (same moment)'));
    ELSEIF v_status = 'SOLD' THEN
      -- CHECK 3: a genuine code that was already sold once
      SET NEW.verdict = 'CLONED';
      SET NEW.reason  = 'Serial already sold earlier - code has been copied';
    ELSEIF v_recalled THEN
      -- CHECK 4: genuine strip, but its batch has been recalled
      SET NEW.verdict = 'RECALLED';
      SET NEW.reason  = CONCAT('Batch recalled: ', IFNULL(v_recall_reason, 'no reason given'));
    ELSEIF DATE(NEW.scan_time) > v_expiry THEN
      -- CHECK 5: genuine strip, but past its expiry date
      SET NEW.verdict = 'EXPIRED';
      SET NEW.reason  = CONCAT('Expired on ', DATE_FORMAT(v_expiry, '%d %b %Y'));
    ELSE
      -- passed every check: first genuine sale
      SET NEW.verdict = 'GENUINE';
      SET NEW.reason  = 'Verified genuine, first sale';
      UPDATE serial_registry
         SET status = 'SOLD', sold_at = NEW.scan_time
       WHERE serial_no = NEW.serial_no;
    END IF;
  END IF;
END$$

-- 4.2 Raise an alert automatically for every flagged scan -------------
CREATE TRIGGER trg_scan_alert
AFTER INSERT ON scan_log
FOR EACH ROW
BEGIN
  IF NEW.verdict <> 'GENUINE' THEN
    INSERT INTO alert (scan_id, pharmacy_id, severity, message, created_at)
    VALUES (NEW.scan_id, NEW.pharmacy_id,
            CASE NEW.verdict
              WHEN 'COUNTERFEIT' THEN 'CRITICAL'
              WHEN 'SUSPICIOUS'  THEN 'CRITICAL'
              WHEN 'CLONED'      THEN 'HIGH'
              WHEN 'RECALLED'    THEN 'HIGH'
              ELSE 'MEDIUM'
            END,
            CONCAT(NEW.verdict, ' - ', NEW.serial_no, ': ', NEW.reason),
            NEW.scan_time);
  END IF;
END$$

-- 4.3 / 4.4 Scan records are legal evidence: append-only ---------------
CREATE TRIGGER trg_scan_no_update
BEFORE UPDATE ON scan_log
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'scan_log is append-only: scan records are evidence and cannot be edited';
END$$

CREATE TRIGGER trg_scan_no_delete
BEFORE DELETE ON scan_log
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'scan_log is append-only: scan records are evidence and cannot be deleted';
END$$

-- 4.5 A sold strip can never be marked unsold again ---------------------
CREATE TRIGGER trg_serial_no_unsell
BEFORE UPDATE ON serial_registry
FOR EACH ROW
BEGIN
  IF OLD.status = 'SOLD' AND NEW.status = 'UNSOLD' THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'A sold serial cannot be reset to UNSOLD';
  END IF;
END$$

-- 4.6 Audit every status change of a serial -----------------------------
CREATE TRIGGER trg_serial_audit
AFTER UPDATE ON serial_registry
FOR EACH ROW
BEGIN
  IF NOT (OLD.status <=> NEW.status) THEN
    INSERT INTO serial_audit (serial_no, old_status, new_status, changed_at, changed_by)
    VALUES (NEW.serial_no, OLD.status, NEW.status, NOW(), CURRENT_USER());
  END IF;
END$$

-- =====================================================================
-- 5. STORED PROCEDURES
-- =====================================================================

-- 5.1 Register a batch and generate its serials (TRANSACTION) ----------
--     Either the batch and ALL its serials are saved, or nothing is.
CREATE PROCEDURE sp_register_batch(IN p_medicine_id INT, IN p_batch_no VARCHAR(20),
                                   IN p_mfg DATE, IN p_exp DATE, IN p_count INT)
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE v_batch_id INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  IF p_count < 1 OR p_count > 10000 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Strip count must be between 1 and 10000';
  END IF;
  IF p_exp <= p_mfg THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Expiry date must be after manufacturing date';
  END IF;

  START TRANSACTION;
    INSERT INTO batch (medicine_id, batch_no, mfg_date, expiry_date)
    VALUES (p_medicine_id, UPPER(p_batch_no), p_mfg, p_exp);
    SET v_batch_id = LAST_INSERT_ID();
    WHILE i <= p_count DO
      INSERT INTO serial_registry (serial_no, batch_id)
      VALUES (CONCAT(UPPER(p_batch_no), '-', LPAD(i, 5, '0')), v_batch_id);
      SET i = i + 1;
    END WHILE;
  COMMIT;
END$$

-- 5.2 Recall a batch ----------------------------------------------------
CREATE PROCEDURE sp_recall_batch(IN p_batch_no VARCHAR(20), IN p_reason VARCHAR(200))
BEGIN
  IF NOT EXISTS (SELECT 1 FROM batch WHERE batch_no = UPPER(p_batch_no)) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No batch with that number';
  END IF;
  UPDATE batch
     SET is_recalled = TRUE, recall_reason = p_reason, recalled_at = NOW()
   WHERE batch_no = UPPER(p_batch_no);
END$$

-- 5.3 Recompute every pharmacy's risk level (CURSOR) --------------------
CREATE PROCEDURE sp_update_risk_levels()
BEGIN
  DECLARE v_done INT DEFAULT 0;
  DECLARE v_id   INT;
  DECLARE v_risk DECIMAL(5,1);
  DECLARE cur_pharmacy CURSOR FOR SELECT pharmacy_id FROM pharmacy;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

  OPEN cur_pharmacy;
  read_loop: LOOP
    FETCH cur_pharmacy INTO v_id;
    IF v_done = 1 THEN
      LEAVE read_loop;
    END IF;
    SET v_risk = fn_pharmacy_risk(v_id);
    UPDATE pharmacy
       SET risk_level = CASE WHEN v_risk >= 50 THEN 'HIGH'
                             WHEN v_risk >= 20 THEN 'MEDIUM'
                             ELSE 'LOW' END
     WHERE pharmacy_id = v_id;
  END LOOP;
  CLOSE cur_pharmacy;
END$$

-- 5.4 Mark an alert as resolved ------------------------------------------
CREATE PROCEDURE sp_resolve_alert(IN p_alert_id INT)
BEGIN
  UPDATE alert SET is_resolved = TRUE, resolved_at = NOW()
   WHERE alert_id = p_alert_id;
END$$

-- 5.5 Full history of one serial (returns TWO result sets) --------------
CREATE PROCEDURE sp_trace_serial(IN p_serial VARCHAR(30))
BEGIN
  SELECT sr.serial_no, m.name AS medicine, mf.name AS manufacturer,
         b.batch_no, b.mfg_date, b.expiry_date, b.is_recalled,
         sr.status, sr.sold_at
    FROM serial_registry sr
    JOIN batch b         ON b.batch_id = sr.batch_id
    JOIN medicine m      ON m.medicine_id = b.medicine_id
    JOIN manufacturer mf ON mf.manufacturer_id = m.manufacturer_id
   WHERE sr.serial_no = UPPER(p_serial);

  SELECT * FROM v_scan_journey
   WHERE serial_no = UPPER(p_serial)
   ORDER BY scan_seq;
END$$

-- 5.6 Daily fraud report for a date range --------------------------------
CREATE PROCEDURE sp_fraud_report(IN p_from DATE, IN p_to DATE)
BEGIN
  SELECT DATE(scan_time) AS scan_date,
         COUNT(*) AS total_scans,
         SUM(verdict = 'GENUINE') AS genuine,
         SUM(verdict IN ('COUNTERFEIT','CLONED','SUSPICIOUS')) AS fraud,
         SUM(verdict IN ('RECALLED','EXPIRED')) AS unsafe_stock
    FROM scan_log
   WHERE DATE(scan_time) BETWEEN p_from AND p_to
   GROUP BY DATE(scan_time)
   ORDER BY scan_date;
END$$

DELIMITER ;

-- =====================================================================
-- 6. VIEWS
-- =====================================================================

-- 6.1 Every scan of a serial in order, with where it came from (window functions)
CREATE VIEW v_scan_journey AS
SELECT s.serial_no,
       ROW_NUMBER() OVER (PARTITION BY s.serial_no ORDER BY s.scan_time, s.scan_id) AS scan_seq,
       s.scan_id, s.scan_time, p.name AS pharmacy, p.city,
       LAG(p.city) OVER (PARTITION BY s.serial_no ORDER BY s.scan_time, s.scan_id) AS from_city,
       s.distance_km, s.speed_kmph, s.verdict, s.reason
  FROM scan_log s
  JOIN pharmacy p ON p.pharmacy_id = s.pharmacy_id;

-- 6.2 Every non-genuine scan
CREATE VIEW v_flagged_scans AS
SELECT s.scan_id, s.serial_no, p.name AS pharmacy, p.city, s.scan_time,
       s.verdict, s.reason, s.distance_km, s.speed_kmph
  FROM scan_log s
  JOIN pharmacy p ON p.pharmacy_id = s.pharmacy_id
 WHERE s.verdict <> 'GENUINE';

-- 6.3 Fraud by city, ranked (RANK window function over an aggregate)
CREATE VIEW v_city_hotspots AS
SELECT RANK() OVER (ORDER BY SUM(s.verdict IN ('COUNTERFEIT','CLONED','SUSPICIOUS')) DESC) AS fraud_rank,
       p.city,
       COUNT(*)                                AS total_scans,
       SUM(s.verdict = 'COUNTERFEIT')          AS counterfeit,
       SUM(s.verdict = 'CLONED')               AS cloned,
       SUM(s.verdict = 'SUSPICIOUS')           AS suspicious,
       SUM(s.verdict IN ('RECALLED','EXPIRED')) AS unsafe_stock,
       ROUND(100 * SUM(s.verdict IN ('COUNTERFEIT','CLONED','SUSPICIOUS')) / COUNT(*), 1) AS fraud_pct
  FROM scan_log s
  JOIN pharmacy p ON p.pharmacy_id = s.pharmacy_id
 GROUP BY p.city;

-- 6.4 Pharmacy risk (uses the stored function)
CREATE VIEW v_pharmacy_risk AS
SELECT p.pharmacy_id, p.name, p.city, p.license_no,
       COUNT(s.scan_id)                      AS total_scans,
       IFNULL(SUM(s.verdict <> 'GENUINE'), 0) AS flagged,
       fn_pharmacy_risk(p.pharmacy_id)       AS risk_pct,
       p.risk_level
  FROM pharmacy p
  LEFT JOIN scan_log s ON s.pharmacy_id = p.pharmacy_id
 GROUP BY p.pharmacy_id, p.name, p.city, p.license_no, p.risk_level;

-- 6.5 Stock status of every batch
CREATE VIEW v_batch_status AS
SELECT b.batch_id, b.batch_no, m.name AS medicine, mf.name AS manufacturer,
       b.mfg_date, b.expiry_date,
       DATEDIFF(b.expiry_date, CURDATE()) AS days_to_expiry,
       COUNT(sr.serial_no)            AS total_serials,
       SUM(sr.status = 'SOLD')        AS sold,
       SUM(sr.status = 'UNSOLD')      AS unsold,
       b.is_recalled, b.recall_reason,
       CASE WHEN b.is_recalled                               THEN 'RECALLED'
            WHEN b.expiry_date < CURDATE()                   THEN 'EXPIRED'
            WHEN DATEDIFF(b.expiry_date, CURDATE()) <= 90    THEN 'EXPIRING SOON'
            ELSE 'ACTIVE' END        AS batch_state
  FROM batch b
  JOIN medicine m       ON m.medicine_id = b.medicine_id
  JOIN manufacturer mf  ON mf.manufacturer_id = m.manufacturer_id
  LEFT JOIN serial_registry sr ON sr.batch_id = b.batch_id
 GROUP BY b.batch_id, b.batch_no, m.name, mf.name, b.mfg_date, b.expiry_date,
          b.is_recalled, b.recall_reason;

-- 6.6 Which brands are being copied the most
CREATE VIEW v_manufacturer_impact AS
SELECT mf.name AS manufacturer, m.name AS medicine,
       COUNT(*)                      AS copy_incidents,
       SUM(s.verdict = 'CLONED')     AS cloned,
       SUM(s.verdict = 'SUSPICIOUS') AS suspicious
  FROM scan_log s
  JOIN serial_registry sr ON sr.serial_no = s.serial_no
  JOIN batch b            ON b.batch_id = sr.batch_id
  JOIN medicine m         ON m.medicine_id = b.medicine_id
  JOIN manufacturer mf    ON mf.manufacturer_id = m.manufacturer_id
 WHERE s.verdict IN ('CLONED','SUSPICIOUS')
 GROUP BY mf.name, m.name;

-- 6.7 Alerts still waiting for action
CREATE VIEW v_open_alerts AS
SELECT a.alert_id, a.severity, a.message, a.created_at,
       p.name AS pharmacy, p.city
  FROM alert a
  JOIN pharmacy p ON p.pharmacy_id = a.pharmacy_id
 WHERE a.is_resolved = FALSE;

-- 6.8 Overall numbers for the dashboard
CREATE VIEW v_summary AS
SELECT COUNT(*)                         AS total_scans,
       SUM(verdict = 'GENUINE')         AS genuine,
       SUM(verdict = 'COUNTERFEIT')     AS counterfeit,
       SUM(verdict = 'CLONED')          AS cloned,
       SUM(verdict = 'SUSPICIOUS')      AS suspicious,
       SUM(verdict = 'RECALLED')        AS recalled,
       SUM(verdict = 'EXPIRED')         AS expired
  FROM scan_log;

-- =====================================================================
-- 7. SAMPLE DATA
-- =====================================================================

INSERT INTO manufacturer (name, license_no, city, contact_email) VALUES
 ('Medilife Pharma Ltd',     'TN-MFG-2019-0412', 'Chennai',   'quality@medilife.example'),
 ('Arogya Labs Pvt Ltd',     'TS-MFG-2017-1188', 'Hyderabad', 'qa@arogyalabs.example'),
 ('Nirmal Healthcare Ltd',   'GJ-MFG-2015-0731', 'Ahmedabad', 'recall@nirmal.example');

INSERT INTO medicine (manufacturer_id, name, composition, category, mrp, needs_prescription) VALUES
 (1, 'Paracetamol 500 mg',  'Paracetamol IP 500 mg',               'ANALGESIC',    25.50, FALSE),
 (1, 'Amoxicillin 250 mg',  'Amoxicillin Trihydrate IP 250 mg',    'ANTIBIOTIC',   68.00, TRUE),
 (2, 'Metformin 500 mg',    'Metformin Hydrochloride IP 500 mg',   'ANTIDIABETIC', 42.75, TRUE),
 (2, 'Atorvastatin 10 mg',  'Atorvastatin Calcium IP 10 mg',       'CARDIAC',      96.00, TRUE),
 (3, 'Azithromycin 500 mg', 'Azithromycin Dihydrate IP 500 mg',    'ANTIBIOTIC',  118.40, TRUE),
 (3, 'Cetirizine 10 mg',    'Cetirizine Hydrochloride IP 10 mg',   'ANTIALLERGIC', 18.00, FALSE);

INSERT INTO pharmacy (name, license_no, city, latitude, longitude) VALUES
 ('Care Plus Pharmacy',   'TN-RX-1001', 'Chennai',    13.082700, 80.270700),
 ('Sri Ram Medicals',     'TN-RX-1002', 'Vellore',    12.916500, 79.132500),
 ('Green Cross Pharmacy', 'KA-RX-2001', 'Bengaluru',  12.971600, 77.594600),
 ('LifeLine Chemists',    'TS-RX-3001', 'Hyderabad',  17.385000, 78.486700),
 ('City Health Store',    'MH-RX-4001', 'Mumbai',     19.076000, 72.877700),
 ('Capital Medicos',      'DL-RX-5001', 'Delhi',      28.613900, 77.209000),
 ('Howrah Drug House',    'WB-RX-6001', 'Kolkata',    22.572600, 88.363900),
 ('Kovai Medicals',       'TN-RX-1003', 'Coimbatore', 11.016800, 76.955800),
 ('Meenakshi Pharmacy',   'TN-RX-1004', 'Madurai',     9.925200, 78.119800),
 ('Deccan Wellness',      'MH-RX-4002', 'Pune',       18.520400, 73.856700);

CALL sp_register_batch(1, 'PCM2026A', '2026-06-01', '2028-05-31', 25);
CALL sp_register_batch(2, 'AMX2026B', '2026-07-15', '2027-07-14', 15);
CALL sp_register_batch(3, 'MET2026C', '2026-08-01', '2028-07-31', 15);
CALL sp_register_batch(4, 'ATV2026D', '2026-05-10', '2028-05-09', 15);
CALL sp_register_batch(5, 'AZI2026E', '2026-09-01', '2027-08-31', 15);
CALL sp_register_batch(6, 'CTZ2026F', '2026-04-01', '2026-12-31', 15);
CALL sp_register_batch(2, 'AMX2024X', '2024-09-01', '2026-08-31', 10);   -- already expired

CALL sp_recall_batch('MET2026C', 'Failed dissolution test in quality audit');

-- Two weeks of scan history (the trigger fills in every verdict)
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES
 ('PCM2026A-00003',  2, '2026-10-01 09:15:00'),   -- genuine, Vellore
 ('PCM2026A-00004',  3, '2026-10-01 11:40:00'),   -- genuine, Bengaluru
 ('AMX2026B-00002',  4, '2026-10-02 10:05:00'),   -- genuine, Hyderabad
 ('ATV2026D-00001',  5, '2026-10-02 16:20:00'),   -- genuine, Mumbai
 ('AZI2026E-00003',  8, '2026-10-03 12:10:00'),   -- genuine, Coimbatore
 ('AZI2026E-00003',  7, '2026-10-03 15:00:00'),   -- SUSPICIOUS: Coimbatore -> Kolkata in 3 h
 ('PCM2026A-00005',  9, '2026-10-03 18:45:00'),   -- genuine, Madurai
 ('CTZ2026F-00001',  1, '2026-10-04 08:50:00'),   -- genuine, Chennai
 ('ATV2026D-00002', 10, '2026-10-04 09:30:00'),   -- genuine, Pune
 ('ATV2026D-00002',  6, '2026-10-04 12:00:00'),   -- SUSPICIOUS: Pune -> Delhi in 2.5 h
 ('PCM2026A-00006',  1, '2026-10-04 13:00:00'),   -- genuine, Chennai
 ('AZI2026E-00004',  6, '2026-10-05 10:00:00'),   -- genuine, Delhi
 ('ATV2026D-00003',  6, '2026-10-05 15:30:00'),   -- genuine, Delhi
 ('CTZ2026F-00002',  2, '2026-10-05 17:10:00'),   -- genuine, Vellore
 ('PCM2026A-99999',  7, '2026-10-06 12:00:00'),   -- COUNTERFEIT, Kolkata
 ('XYZ1234-00001',   7, '2026-10-06 12:30:00'),   -- COUNTERFEIT, Kolkata
 ('ATV2026D-88888',  6, '2026-10-07 11:00:00'),   -- COUNTERFEIT, Delhi
 ('PCM2026A-00007',  8, '2026-10-07 14:25:00'),   -- genuine, Coimbatore
 ('AZI2026E-77777',  7, '2026-10-08 17:15:00'),   -- COUNTERFEIT, Kolkata
 ('AMX2026B-00002',  4, '2026-10-09 14:00:00'),   -- CLONED, Hyderabad
 ('PCM2026A-00004',  3, '2026-10-10 10:00:00'),   -- CLONED, Bengaluru
 ('CTZ2026F-00003',  9, '2026-10-10 12:40:00'),   -- genuine, Madurai
 ('ATV2026D-00001', 10, '2026-10-11 09:00:00'),   -- CLONED: Mumbai -> Pune 9 days later
 ('MET2026C-00005',  1, '2026-10-12 11:00:00'),   -- RECALLED, Chennai
 ('MET2026C-00006',  8, '2026-10-12 16:00:00'),   -- RECALLED, Coimbatore
 ('AMX2024X-00001',  9, '2026-10-13 10:30:00'),   -- EXPIRED, Madurai
 ('AMX2024X-00002',  7, '2026-10-13 12:00:00'),   -- EXPIRED, Kolkata
 ('AMX2026B-00005',  5, '2026-10-14 11:20:00');   -- genuine, Mumbai

CALL sp_update_risk_levels();

-- =====================================================================
-- 8. USERS AND PRIVILEGES (DCL) - least privilege
--    The pharmacy app may only record scans and read results.
--    The regulator may only read the reporting views.
--    (If your MySQL refuses CREATE USER, skip this section - the
--     project still works with your root login.)
-- =====================================================================
DROP USER IF EXISTS 'pharmacy_app'@'localhost';
DROP USER IF EXISTS 'regulator'@'localhost';
CREATE USER 'pharmacy_app'@'localhost' IDENTIFIED BY 'Scan@Pharma2026';
CREATE USER 'regulator'@'localhost'    IDENTIFIED BY 'Audit@Reg2026';

GRANT SELECT, INSERT ON meditrace.scan_log   TO 'pharmacy_app'@'localhost';
GRANT SELECT         ON meditrace.pharmacy   TO 'pharmacy_app'@'localhost';

GRANT SELECT ON meditrace.v_city_hotspots       TO 'regulator'@'localhost';
GRANT SELECT ON meditrace.v_flagged_scans       TO 'regulator'@'localhost';
GRANT SELECT ON meditrace.v_pharmacy_risk       TO 'regulator'@'localhost';
GRANT SELECT ON meditrace.v_manufacturer_impact TO 'regulator'@'localhost';
GRANT SELECT ON meditrace.v_open_alerts         TO 'regulator'@'localhost';
GRANT EXECUTE ON PROCEDURE meditrace.sp_fraud_report TO 'regulator'@'localhost';
FLUSH PRIVILEGES;
SELECT COUNT(*) FROM meditrace.scan_log;
SELECT * FROM meditrace.scan_log;


-- Done. Open demo_queries.sql for the live demo and analysis queries.
