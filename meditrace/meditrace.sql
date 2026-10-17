-- =====================================================================
--  MediTrace: Counterfeit Medicine Detection System
--  BCSE302L Database Systems - Digital Assignment II
-- 
--  HOW TO RUN: open this file in MySQL Workbench and run the WHOLE
--  script with the lightning button (Ctrl+Shift+Enter).
--  Re-running it resets everything to clean sample data.
-- 
--  DBMS concepts used in this file
--   DDL ........ 13 tables, PK / FK / UNIQUE / CHECK / ENUM / DEFAULT
--   Indexes .... 7 secondary indexes for the hot queries
--   Functions .. haversine_km, fn_pharmacy_risk, fn_serial_status
--   Triggers ... 9 (fraud detection, alerts, append-only evidence,
--                no un-selling, status audit, role rules,
--                complaint priority, complaint workflow)
--   Procedures . 9 (transaction + rollback, SIGNAL errors, cursor loop,
--                multiple result sets, patient verification)
--   Views ...... 12 (joins, GROUP BY, window functions RANK / LAG /
--                ROW_NUMBER, derived tables, CASE)
--   Event ...... hourly risk refresh (event scheduler)
--   Security ... SHA-256 password hashes, 2 least-privilege DB users
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
  category          ENUM('ANALGESIC','ANTIBIOTIC','ANTIDIABETIC','CARDIAC','ANTIALLERGIC','ANTIVIRAL',
                         'ANTACID','VITAMIN','RESPIRATORY','NEURO','HORMONE','OTHER') NOT NULL,
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

-- People who log in to the web app (passwords stored as SHA-256 hashes)
CREATE TABLE app_user (
  user_id         INT AUTO_INCREMENT PRIMARY KEY,
  username        VARCHAR(30)  NOT NULL UNIQUE,
  password_hash   CHAR(64)     NOT NULL,
  full_name       VARCHAR(100) NOT NULL,
  role            ENUM('REGULATOR','PHARMACIST','MANUFACTURER') NOT NULL,
  pharmacy_id     INT NULL,      -- set only for pharmacists
  manufacturer_id INT NULL,      -- set only for manufacturers
  created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_login      DATETIME NULL,
  FOREIGN KEY (pharmacy_id)     REFERENCES pharmacy(pharmacy_id),
  FOREIGN KEY (manufacturer_id) REFERENCES manufacturer(manufacturer_id)
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
  scanned_by  INT NULL,                 -- app user who scanned (NULL = system import)
  FOREIGN KEY (pharmacy_id) REFERENCES pharmacy(pharmacy_id),
  FOREIGN KEY (scanned_by)  REFERENCES app_user(user_id)
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
  resolved_by INT NULL,                 -- officer who closed it
  action_taken VARCHAR(300) NULL,       -- what was done (stock seized, pharmacy warned...)
  FOREIGN KEY (scan_id)     REFERENCES scan_log(scan_id),
  FOREIGN KEY (pharmacy_id) REFERENCES pharmacy(pharmacy_id),
  FOREIGN KEY (resolved_by) REFERENCES app_user(user_id)
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

-- Complaints filed by patients about a strip they bought
CREATE TABLE complaint (
  complaint_id   INT AUTO_INCREMENT PRIMARY KEY,
  serial_no      VARCHAR(30)  NOT NULL,
  reporter_name  VARCHAR(100) NOT NULL,
  reporter_phone VARCHAR(15),
  city           VARCHAR(50)  NOT NULL,
  description    VARCHAR(500) NOT NULL,
  priority       ENUM('NORMAL','HIGH','URGENT') NOT NULL DEFAULT 'NORMAL',  -- set by trigger
  status         ENUM('OPEN','INVESTIGATING','RESOLVED','REJECTED') NOT NULL DEFAULT 'OPEN',
  resolution     VARCHAR(300),
  created_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     DATETIME NULL,
  handled_by     INT NULL,
  FOREIGN KEY (handled_by) REFERENCES app_user(user_id),
  CHECK (reporter_phone IS NULL OR CHAR_LENGTH(reporter_phone) = 10)
);

-- Every time a patient checks a strip on the public Verify page
CREATE TABLE patient_check (
  check_id   INT AUTO_INCREMENT PRIMARY KEY,
  serial_no  VARCHAR(30) NOT NULL,
  city       VARCHAR(50),
  checked_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  result     VARCHAR(30) NOT NULL
);

-- What each user did in the app
CREATE TABLE activity_log (
  log_id     INT AUTO_INCREMENT PRIMARY KEY,
  user_id    INT NULL,
  action     VARCHAR(50) NOT NULL,
  details    VARCHAR(300),
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES app_user(user_id)
);

-- =====================================================================
-- 2. INDEXES (speed up the queries the trigger runs on every scan)
-- =====================================================================
CREATE INDEX idx_scan_serial_time ON scan_log (serial_no, scan_time);  -- previous-scan lookup
CREATE INDEX idx_scan_verdict     ON scan_log (verdict);               -- dashboard counts
CREATE INDEX idx_pharmacy_city    ON pharmacy (city);                  -- hotspot grouping
CREATE INDEX idx_batch_expiry     ON batch (expiry_date);              -- expiry checks
CREATE INDEX idx_alert_open       ON alert (is_resolved, severity);    -- open alerts list
CREATE INDEX idx_complaint_status ON complaint (status, priority);     -- complaint queue
CREATE INDEX idx_check_serial     ON patient_check (serial_no);        -- repeat checks

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

-- What a patient should be told about a serial (read-only, never sells it)
CREATE FUNCTION fn_serial_status(p_serial VARCHAR(30))
RETURNS VARCHAR(20) READS SQL DATA
BEGIN
  DECLARE v_status   VARCHAR(10);
  DECLARE v_recalled BOOLEAN;
  DECLARE v_expiry   DATE;
  DECLARE v_copies   INT DEFAULT 0;

  SET v_status = (SELECT status FROM serial_registry WHERE serial_no = UPPER(p_serial));
  IF v_status IS NULL THEN
    RETURN 'NOT_REGISTERED';
  END IF;

  SET v_copies = (SELECT COUNT(*) FROM scan_log
                   WHERE serial_no = UPPER(p_serial)
                     AND verdict IN ('CLONED','SUSPICIOUS'));
  SET v_recalled = (SELECT b.is_recalled FROM serial_registry sr
                      JOIN batch b ON b.batch_id = sr.batch_id
                     WHERE sr.serial_no = UPPER(p_serial));
  SET v_expiry = (SELECT b.expiry_date FROM serial_registry sr
                    JOIN batch b ON b.batch_id = sr.batch_id
                   WHERE sr.serial_no = UPPER(p_serial));

  IF v_copies > 0 THEN RETURN 'COPIES_DETECTED'; END IF;
  IF v_recalled   THEN RETURN 'RECALLED';        END IF;
  IF v_expiry < CURDATE() THEN RETURN 'EXPIRED'; END IF;
  IF v_status = 'SOLD' THEN RETURN 'SOLD_GENUINE'; END IF;
  RETURN 'UNSOLD_GENUINE';
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

-- 4.7 Role rules: a pharmacist must belong to a pharmacy, a manufacturer
--     user to a manufacturer, and a regulator to neither
CREATE TRIGGER trg_user_role_check
BEFORE INSERT ON app_user
FOR EACH ROW
BEGIN
  IF NEW.role = 'PHARMACIST' AND (NEW.pharmacy_id IS NULL OR NEW.manufacturer_id IS NOT NULL) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A pharmacist must be linked to exactly one pharmacy';
  END IF;
  IF NEW.role = 'MANUFACTURER' AND (NEW.manufacturer_id IS NULL OR NEW.pharmacy_id IS NOT NULL) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A manufacturer user must be linked to exactly one manufacturer';
  END IF;
  IF NEW.role = 'REGULATOR' AND (NEW.pharmacy_id IS NOT NULL OR NEW.manufacturer_id IS NOT NULL) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A regulator cannot belong to a pharmacy or manufacturer';
  END IF;
END$$

-- 4.8 Complaint priority is decided by the database, not the patient
CREATE TRIGGER trg_complaint_priority
BEFORE INSERT ON complaint
FOR EACH ROW
BEGIN
  DECLARE v_state VARCHAR(20);
  SET NEW.serial_no = UPPER(TRIM(NEW.serial_no));
  SET v_state = fn_serial_status(NEW.serial_no);
  SET NEW.priority = CASE
                       WHEN v_state IN ('NOT_REGISTERED','COPIES_DETECTED') THEN 'URGENT'
                       WHEN v_state IN ('RECALLED','EXPIRED')               THEN 'HIGH'
                       ELSE 'NORMAL'
                     END;
  SET NEW.status = 'OPEN';
END$$

-- 4.9 Complaint workflow: OPEN -> INVESTIGATING -> RESOLVED / REJECTED,
--     and a closed complaint can never be reopened
CREATE TRIGGER trg_complaint_workflow
BEFORE UPDATE ON complaint
FOR EACH ROW
BEGIN
  IF OLD.status IN ('RESOLVED','REJECTED') AND NEW.status <> OLD.status THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A closed complaint cannot be reopened';
  END IF;
  IF OLD.status = 'INVESTIGATING' AND NEW.status = 'OPEN' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A complaint under investigation cannot go back to OPEN';
  END IF;
  IF NEW.status IN ('RESOLVED','REJECTED') AND (NEW.resolution IS NULL OR NEW.resolution = '') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Closing a complaint needs a resolution note';
  END IF;
  SET NEW.updated_at = NOW();
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

-- 5.4 Resolve an alert: who closed it and what action was taken ---------
CREATE PROCEDURE sp_resolve_alert(IN p_alert_id INT, IN p_action VARCHAR(300), IN p_user INT)
BEGIN
  DECLARE v_resolved BOOLEAN;
  SET v_resolved = (SELECT is_resolved FROM alert WHERE alert_id = p_alert_id);
  IF v_resolved IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No alert with that id';
  END IF;
  IF v_resolved THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This alert is already resolved';
  END IF;
  IF p_action IS NULL OR TRIM(p_action) = '' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Resolving an alert needs a note on the action taken';
  END IF;
  UPDATE alert
     SET is_resolved = TRUE, resolved_at = NOW(), resolved_by = p_user, action_taken = TRIM(p_action)
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

-- 5.7 Public patient verification: logs the check and returns the
--     strip's details WITHOUT selling it
CREATE PROCEDURE sp_patient_verify(IN p_serial VARCHAR(30), IN p_city VARCHAR(50))
BEGIN
  DECLARE v_result VARCHAR(20);
  SET v_result = fn_serial_status(p_serial);
  INSERT INTO patient_check (serial_no, city, result)
  VALUES (UPPER(TRIM(p_serial)), p_city, v_result);

  SELECT v.serial_no, v.result, m.name AS medicine, mf.name AS manufacturer,
         b.batch_no, b.mfg_date, b.expiry_date, b.recall_reason, sr.status, sr.sold_at,
         (SELECT COUNT(*) FROM scan_log s WHERE s.serial_no = v.serial_no) AS times_scanned,
         (SELECT COUNT(*) FROM patient_check pc WHERE pc.serial_no = v.serial_no) AS times_checked
    FROM (SELECT UPPER(TRIM(p_serial)) AS serial_no, v_result AS result) v
    LEFT JOIN serial_registry sr ON sr.serial_no = v.serial_no
    LEFT JOIN batch b            ON b.batch_id = sr.batch_id
    LEFT JOIN medicine m         ON m.medicine_id = b.medicine_id
    LEFT JOIN manufacturer mf    ON mf.manufacturer_id = m.manufacturer_id;
END$$

-- 5.8 Move a complaint through its workflow (trigger enforces the rules)
CREATE PROCEDURE sp_update_complaint(IN p_id INT, IN p_status VARCHAR(20),
                                     IN p_resolution VARCHAR(300), IN p_user INT)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM complaint WHERE complaint_id = p_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No complaint with that id';
  END IF;
  UPDATE complaint
     SET status = p_status,
         resolution = NULLIF(p_resolution, ''),
         handled_by = p_user
   WHERE complaint_id = p_id;
END$$

-- 5.9 Change the impossible-travel speed limit, with validation
CREATE PROCEDURE sp_set_speed_limit(IN p_kmph DECIMAL(10,2))
BEGIN
  IF p_kmph < 20 OR p_kmph > 1000 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Speed limit must be between 20 and 1000 km/h';
  END IF;
  UPDATE settings SET setting_value = p_kmph WHERE setting_key = 'max_speed_kmph';
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

-- 6.9 Day-by-day trend for the dashboard chart
CREATE VIEW v_daily_trend AS
SELECT DATE(scan_time) AS scan_date,
       COUNT(*)                                               AS total_scans,
       SUM(verdict = 'GENUINE')                               AS genuine,
       SUM(verdict IN ('COUNTERFEIT','CLONED','SUSPICIOUS'))  AS fraud,
       SUM(verdict IN ('RECALLED','EXPIRED'))                 AS unsafe_stock
  FROM scan_log
 GROUP BY DATE(scan_time);

-- 6.10 Impossible-travel routes with both end points (for the fraud map)
--      LAG pulls the previous scan's pharmacy into the same row
CREATE VIEW v_travel_anomalies AS
SELECT j.scan_id, j.serial_no, j.scan_time, j.distance_km, j.speed_kmph,
       j.from_city, j.from_lat, j.from_lon, j.to_city, j.to_lat, j.to_lon
  FROM (SELECT s.scan_id, s.serial_no, s.scan_time, s.verdict, s.distance_km, s.speed_kmph,
               p.city AS to_city, p.latitude AS to_lat, p.longitude AS to_lon,
               LAG(p.city)      OVER (PARTITION BY s.serial_no ORDER BY s.scan_time, s.scan_id) AS from_city,
               LAG(p.latitude)  OVER (PARTITION BY s.serial_no ORDER BY s.scan_time, s.scan_id) AS from_lat,
               LAG(p.longitude) OVER (PARTITION BY s.serial_no ORDER BY s.scan_time, s.scan_id) AS from_lon
          FROM scan_log s
          JOIN pharmacy p ON p.pharmacy_id = s.pharmacy_id) AS j
 WHERE j.verdict = 'SUSPICIOUS';

-- 6.11 Complaints with the name of the officer handling them
CREATE VIEW v_complaints AS
SELECT c.complaint_id, c.serial_no, c.reporter_name, c.reporter_phone, c.city,
       c.description, c.priority, c.status, c.resolution, c.created_at, c.updated_at,
       u.full_name AS handled_by_name,
       fn_serial_status(c.serial_no) AS serial_state
  FROM complaint c
  LEFT JOIN app_user u ON u.user_id = c.handled_by;

-- 6.12 Medicine catalogue with stock and fraud figures
CREATE VIEW v_medicine_catalogue AS
SELECT m.medicine_id, m.name, m.composition, m.category, m.mrp, m.needs_prescription,
       mf.manufacturer_id, mf.name AS manufacturer,
       COUNT(DISTINCT b.batch_id)   AS batches,
       COUNT(sr.serial_no)          AS serials,
       IFNULL(SUM(sr.status = 'SOLD'), 0) AS sold,
       (SELECT COUNT(*) FROM scan_log s
          JOIN serial_registry sr2 ON sr2.serial_no = s.serial_no
          JOIN batch b2 ON b2.batch_id = sr2.batch_id
         WHERE b2.medicine_id = m.medicine_id
           AND s.verdict IN ('CLONED','SUSPICIOUS')) AS copy_incidents
  FROM medicine m
  JOIN manufacturer mf ON mf.manufacturer_id = m.manufacturer_id
  LEFT JOIN batch b ON b.medicine_id = m.medicine_id
  LEFT JOIN serial_registry sr ON sr.batch_id = b.batch_id
 GROUP BY m.medicine_id, m.name, m.composition, m.category, m.mrp, m.needs_prescription,
          mf.manufacturer_id, mf.name;

-- =====================================================================
-- 7. SAMPLE DATA
--    8 manufacturers, 36 medicines, 30 pharmacies in 26 cities,
--    40 batches (~1,000 serials) and six weeks of scans (1 Sep - 14 Oct 2026).
--    Every verdict below is decided by the trigger, not typed in.
-- =====================================================================

INSERT INTO manufacturer (name, license_no, city, contact_email) VALUES
 ('Medilife Pharma Ltd', 'TN-MFG-2019-0412', 'Chennai', 'quality@medilife.example'),
 ('Arogya Labs Pvt Ltd', 'TS-MFG-2017-1188', 'Hyderabad', 'qa@arogyalabs.example'),
 ('Nirmal Healthcare Ltd', 'GJ-MFG-2015-0731', 'Ahmedabad', 'recall@nirmal.example'),
 ('Sanjeevani Biotech Pvt Ltd', 'MH-MFG-2018-2204', 'Pune', 'qa@sanjeevani.example'),
 ('Kaveri Remedies Ltd', 'KA-MFG-2016-0958', 'Bengaluru', 'quality@kaveri.example'),
 ('Ganga Lifesciences Ltd', 'WB-MFG-2014-0377', 'Kolkata', 'qc@gangalife.example'),
 ('Sahyadri Pharmaceuticals Ltd', 'MH-MFG-2012-1630', 'Mumbai', 'qa@sahyadri.example'),
 ('Vindhya Formulations Pvt Ltd', 'MP-MFG-2020-0145', 'Indore', 'quality@vindhya.example');

INSERT INTO medicine (manufacturer_id, name, composition, category, mrp, needs_prescription) VALUES
 (1, 'Paracetamol 500 mg', 'Paracetamol IP 500 mg', 'ANALGESIC', 25.50, FALSE),
 (1, 'Amoxicillin 250 mg', 'Amoxicillin Trihydrate IP 250 mg', 'ANTIBIOTIC', 68.00, TRUE),
 (2, 'Metformin 500 mg', 'Metformin Hydrochloride IP 500 mg', 'ANTIDIABETIC', 42.75, TRUE),
 (2, 'Atorvastatin 10 mg', 'Atorvastatin Calcium IP 10 mg', 'CARDIAC', 96.00, TRUE),
 (3, 'Azithromycin 500 mg', 'Azithromycin Dihydrate IP 500 mg', 'ANTIBIOTIC', 118.40, TRUE),
 (3, 'Cetirizine 10 mg', 'Cetirizine Hydrochloride IP 10 mg', 'ANTIALLERGIC', 18.00, FALSE),
 (1, 'Paracetamol 650 mg', 'Paracetamol IP 650 mg', 'ANALGESIC', 32.00, FALSE),
 (4, 'Ibuprofen 400 mg', 'Ibuprofen IP 400 mg', 'ANALGESIC', 28.50, FALSE),
 (4, 'Diclofenac 50 mg', 'Diclofenac Sodium IP 50 mg', 'ANALGESIC', 24.00, TRUE),
 (5, 'Aceclofenac 100 mg', 'Aceclofenac IP 100 mg', 'ANALGESIC', 58.00, TRUE),
 (5, 'Amoxicillin + Clavulanate 625 mg', 'Amoxicillin 500 mg + Potassium Clavulanate 125 mg', 'ANTIBIOTIC', 210.00, TRUE),
 (6, 'Ciprofloxacin 500 mg', 'Ciprofloxacin Hydrochloride IP 500 mg', 'ANTIBIOTIC', 72.00, TRUE),
 (6, 'Cefixime 200 mg', 'Cefixime IP 200 mg', 'ANTIBIOTIC', 112.00, TRUE),
 (7, 'Doxycycline 100 mg', 'Doxycycline Hyclate IP 100 mg', 'ANTIBIOTIC', 64.00, TRUE),
 (7, 'Glimepiride 2 mg', 'Glimepiride IP 2 mg', 'ANTIDIABETIC', 88.00, TRUE),
 (8, 'Sitagliptin 100 mg', 'Sitagliptin Phosphate 100 mg', 'ANTIDIABETIC', 245.00, TRUE),
 (2, 'Amlodipine 5 mg', 'Amlodipine Besylate IP 5 mg', 'CARDIAC', 36.00, TRUE),
 (8, 'Telmisartan 40 mg', 'Telmisartan IP 40 mg', 'CARDIAC', 94.00, TRUE),
 (5, 'Losartan 50 mg', 'Losartan Potassium IP 50 mg', 'CARDIAC', 61.00, TRUE),
 (4, 'Clopidogrel 75 mg', 'Clopidogrel Bisulphate IP 75 mg', 'CARDIAC', 118.00, TRUE),
 (1, 'Aspirin 75 mg', 'Acetylsalicylic Acid IP 75 mg', 'CARDIAC', 12.50, FALSE),
 (3, 'Levocetirizine 5 mg', 'Levocetirizine Dihydrochloride IP 5 mg', 'ANTIALLERGIC', 42.00, FALSE),
 (6, 'Montelukast 10 mg', 'Montelukast Sodium IP 10 mg', 'RESPIRATORY', 155.00, TRUE),
 (7, 'Fexofenadine 120 mg', 'Fexofenadine Hydrochloride IP 120 mg', 'ANTIALLERGIC', 138.00, FALSE),
 (8, 'Pantoprazole 40 mg', 'Pantoprazole Sodium IP 40 mg', 'ANTACID', 96.00, TRUE),
 (5, 'Omeprazole 20 mg', 'Omeprazole IP 20 mg', 'ANTACID', 48.00, FALSE),
 (4, 'Ondansetron 4 mg', 'Ondansetron Hydrochloride IP 4 mg', 'OTHER', 52.00, TRUE),
 (3, 'Vitamin D3 60000 IU', 'Cholecalciferol IP 60000 IU', 'VITAMIN', 95.00, FALSE),
 (6, 'Iron + Folic Acid', 'Ferrous Ascorbate 100 mg + Folic Acid 1.5 mg', 'VITAMIN', 120.00, FALSE),
 (7, 'Salbutamol 4 mg', 'Salbutamol Sulphate IP 4 mg', 'RESPIRATORY', 18.00, TRUE),
 (2, 'Levothyroxine 50 mcg', 'Levothyroxine Sodium IP 50 mcg', 'HORMONE', 135.00, TRUE),
 (8, 'Oseltamivir 75 mg', 'Oseltamivir Phosphate IP 75 mg', 'ANTIVIRAL', 520.00, TRUE),
 (1, 'Acyclovir 400 mg', 'Acyclovir IP 400 mg', 'ANTIVIRAL', 98.00, TRUE),
 (4, 'Sertraline 50 mg', 'Sertraline Hydrochloride IP 50 mg', 'NEURO', 86.00, TRUE),
 (5, 'Gabapentin 300 mg', 'Gabapentin IP 300 mg', 'NEURO', 165.00, TRUE),
 (7, 'B-Complex with Vitamin C', 'Vitamin B-Complex with Ascorbic Acid', 'VITAMIN', 35.00, FALSE);

INSERT INTO pharmacy (name, license_no, city, latitude, longitude) VALUES
 ('Care Plus Pharmacy', 'TN-RX-1001', 'Chennai', 13.082700, 80.270700),
 ('Sri Ram Medicals', 'TN-RX-1002', 'Vellore', 12.916500, 79.132500),
 ('Green Cross Pharmacy', 'KA-RX-2001', 'Bengaluru', 12.971600, 77.594600),
 ('LifeLine Chemists', 'TS-RX-3001', 'Hyderabad', 17.385000, 78.486700),
 ('City Health Store', 'MH-RX-4001', 'Mumbai', 19.076000, 72.877700),
 ('Capital Medicos', 'DL-RX-5001', 'Delhi', 28.613900, 77.209000),
 ('Howrah Drug House', 'WB-RX-6001', 'Kolkata', 22.572600, 88.363900),
 ('Kovai Medicals', 'TN-RX-1003', 'Coimbatore', 11.016800, 76.955800),
 ('Meenakshi Pharmacy', 'TN-RX-1004', 'Madurai', 9.925200, 78.119800),
 ('Deccan Wellness', 'MH-RX-4002', 'Pune', 18.520400, 73.856700),
 ('T. Nagar Medicals', 'TN-RX-1005', 'Chennai', 13.041800, 80.234100),
 ('Rockfort Pharmacy', 'TN-RX-1006', 'Tiruchirappalli', 10.790500, 78.704700),
 ('Salem City Chemists', 'TN-RX-1007', 'Salem', 11.664300, 78.146000),
 ('Koramangala Care', 'KA-RX-2002', 'Bengaluru', 12.935200, 77.624500),
 ('Mysore Medical Hall', 'KA-RX-2003', 'Mysuru', 12.295800, 76.639400),
 ('Krishna Medicals', 'AP-RX-7001', 'Vijayawada', 16.506200, 80.648000),
 ('Vizag Health Point', 'AP-RX-7002', 'Visakhapatnam', 17.686800, 83.218500),
 ('Marine Drive Pharmacy', 'KL-RX-8001', 'Kochi', 9.931200, 76.267300),
 ('Capital City Chemists', 'KL-RX-8002', 'Thiruvananthapuram', 8.524100, 76.936600),
 ('Andheri Wellness', 'MH-RX-4003', 'Mumbai', 19.113600, 72.869700),
 ('Sabarmati Medicos', 'GJ-RX-9001', 'Ahmedabad', 23.022500, 72.571400),
 ('Pink City Pharmacy', 'RJ-RX-9101', 'Jaipur', 26.912400, 75.787300),
 ('Karol Bagh Chemists', 'DL-RX-5002', 'Delhi', 28.651900, 77.190900),
 ('Hazratganj Medical Store', 'UP-RX-9201', 'Lucknow', 26.846700, 80.946200),
 ('Kalinga Drug House', 'OD-RX-9301', 'Bhubaneswar', 20.296100, 85.824500),
 ('Brahmaputra Pharmacy', 'AS-RX-9401', 'Guwahati', 26.144500, 91.736200),
 ('Gandhi Maidan Medicals', 'BR-RX-9501', 'Patna', 25.594100, 85.137600),
 ('Sector 17 Chemists', 'CH-RX-9601', 'Chandigarh', 30.733300, 76.779400),
 ('Lake City Pharmacy', 'MP-RX-9701', 'Bhopal', 23.259900, 77.412600),
 ('Orange City Medicals', 'MH-RX-4004', 'Nagpur', 21.145800, 79.088200);

-- App users (demo passwords; only SHA-256 hashes are stored)
--   admin     / admin123   regulator: sees everything
--   inspector / admin123   second regulator (state drug inspector)
--   chennai   / pharma123  pharmacist at Care Plus Pharmacy, Chennai
--   delhi     / pharma123  pharmacist at Capital Medicos, Delhi
--   kolkata   / pharma123  pharmacist at Howrah Drug House, Kolkata
--   medilife  / mfg123     manufacturer user for Medilife Pharma Ltd
--   arogya    / mfg123     manufacturer user for Arogya Labs Pvt Ltd
INSERT INTO app_user (username, password_hash, full_name, role, pharmacy_id, manufacturer_id) VALUES
 ('admin',     SHA2('admin123', 256),  'Drug Control Officer',    'REGULATOR',    NULL, NULL),
 ('chennai',   SHA2('pharma123', 256), 'R. Lakshmi (Care Plus)',  'PHARMACIST',   1,    NULL),
 ('delhi',     SHA2('pharma123', 256), 'A. Verma (Capital)',      'PHARMACIST',   6,    NULL),
 ('medilife',  SHA2('mfg123', 256),    'Medilife QA Desk',        'MANUFACTURER', NULL, 1),
 ('inspector', SHA2('admin123', 256),  'State Drug Inspector',    'REGULATOR',    NULL, NULL),
 ('kolkata',   SHA2('pharma123', 256), 'S. Banerjee (Howrah)',    'PHARMACIST',   7,    NULL),
 ('arogya',    SHA2('mfg123', 256),    'Arogya Quality Cell',     'MANUFACTURER', NULL, 2);

-- Batches: each CALL saves the batch and its serials in one transaction
CALL sp_register_batch(1, 'PCM2026A', '2026-06-01', '2028-05-31', 25);
CALL sp_register_batch(2, 'AMX2026B', '2026-07-15', '2027-07-14', 15);
CALL sp_register_batch(3, 'MET2026C', '2026-08-01', '2028-07-31', 15);
CALL sp_register_batch(4, 'ATV2026D', '2026-05-10', '2028-05-09', 15);
CALL sp_register_batch(5, 'AZI2026E', '2026-09-01', '2027-08-31', 15);
CALL sp_register_batch(6, 'CTZ2026F', '2026-04-01', '2026-12-31', 15);
CALL sp_register_batch(2, 'AMX2024X', '2024-09-01', '2026-08-31', 10);
CALL sp_register_batch(7, 'PSX2026G', '2026-05-20', '2028-04-30', 40);
CALL sp_register_batch(8, 'IBU2026H', '2026-06-11', '2028-05-31', 35);
CALL sp_register_batch(9, 'DCL2026R', '2026-06-05', '2028-05-31', 30);
CALL sp_register_batch(10, 'ACF2026J', '2026-07-02', '2028-06-30', 25);
CALL sp_register_batch(11, 'AMC2026K', '2026-07-18', '2027-12-31', 30);
CALL sp_register_batch(12, 'CPF2026K', '2026-05-25', '2028-04-30', 30);
CALL sp_register_batch(13, 'CFX2024Y', '2024-09-16', '2026-09-15', 25);
CALL sp_register_batch(14, 'DOX2026L', '2026-06-20', '2028-05-31', 25);
CALL sp_register_batch(15, 'GLM2026M', '2026-05-02', '2028-04-30', 30);
CALL sp_register_batch(16, 'SIT2026N', '2026-07-10', '2028-06-30', 20);
CALL sp_register_batch(17, 'AML2026P', '2026-04-15', '2028-03-31', 35);
CALL sp_register_batch(18, 'TEL2026Q', '2026-06-01', '2028-05-31', 30);
CALL sp_register_batch(19, 'LOS2026S', '2026-05-12', '2028-04-30', 25);
CALL sp_register_batch(20, 'CLP2026T', '2026-06-25', '2028-05-31', 25);
CALL sp_register_batch(21, 'ASP2025U', '2025-01-02', '2026-12-31', 30);
CALL sp_register_batch(22, 'LCZ2026V', '2026-07-01', '2028-06-30', 25);
CALL sp_register_batch(23, 'MTK2026W', '2026-06-14', '2028-05-31', 25);
CALL sp_register_batch(24, 'FEX2026X', '2026-05-30', '2028-04-30', 20);
CALL sp_register_batch(25, 'PAN2026Y', '2026-07-07', '2028-06-30', 35);
CALL sp_register_batch(26, 'OMP2026Z', '2026-06-03', '2028-05-31', 25);
CALL sp_register_batch(27, 'OND2025S', '2024-12-01', '2026-11-30', 20);
CALL sp_register_batch(28, 'VTD2026A', '2026-08-05', '2028-07-31', 25);
CALL sp_register_batch(29, 'IFA2026B', '2026-07-21', '2028-06-30', 25);
CALL sp_register_batch(30, 'SAL2025T', '2025-01-10', '2026-12-15', 20);
CALL sp_register_batch(31, 'LTX2026C', '2026-06-09', '2028-05-31', 20);
CALL sp_register_batch(32, 'OSL2026D', '2026-08-12', '2028-07-31', 15);
CALL sp_register_batch(33, 'ACV2026E', '2026-07-28', '2028-06-30', 20);
CALL sp_register_batch(34, 'SRT2026F', '2026-06-17', '2028-05-31', 20);
CALL sp_register_batch(35, 'GBP2026G', '2026-05-08', '2028-04-30', 20);
CALL sp_register_batch(36, 'BCX2024Z', '2024-09-01', '2026-08-31', 20);
CALL sp_register_batch(1, 'PCM2026H', '2026-08-20', '2028-07-31', 40);
CALL sp_register_batch(3, 'MET2026J', '2026-09-01', '2028-08-31', 30);
CALL sp_register_batch(5, 'AZI2026K', '2026-08-25', '2027-08-31', 30);

-- Scans before the recalls on 3 Oct 2026
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES
 ('AMC2026K-00029',  2, '2026-09-01 12:38:00'),
 ('LCZ2026V-00011', 18, '2026-09-01 13:50:00'),
 ('ACF2026J-00020', 25, '2026-09-01 19:41:00'),
 ('LOS2026S-00004', 21, '2026-09-01 20:12:00'),
 ('DCL2026R-00005', 28, '2026-09-01 21:12:00'),
 ('IFA2026B-00013', 14, '2026-09-02 09:35:00'),
 ('PCM2026H-00038', 16, '2026-09-02 11:56:00'),
 ('CFX2024Y-00004', 13, '2026-09-02 14:28:00'),
 ('CFX2024Y-00013', 18, '2026-09-02 15:01:00'),
 ('MTK2026W-00025', 28, '2026-09-02 15:38:00'),
 ('GBP2026G-00007', 19, '2026-09-02 20:09:00'),
 ('FEX2026X-00009',  3, '2026-09-02 20:38:00'),
 ('MET2026C-96117', 26, '2026-09-02 21:18:00'),
 ('TEL2026Q-00025', 14, '2026-09-02 21:39:00'),
 ('TEL2026Q-00025', 30, '2026-09-02 22:39:00'),
 ('IFA2026B-00022',  9, '2026-09-03 10:07:00'),
 ('ACF2026J-00012',  8, '2026-09-03 10:20:00'),
 ('PCM2026H-00039',  8, '2026-09-03 11:22:00'),
 ('TEL2026Q-91503',  5, '2026-09-03 13:53:00'),
 ('ACF2026J-00025',  7, '2026-09-03 17:56:00'),
 ('PSX2026G-00007',  8, '2026-09-03 19:33:00'),
 ('AMX2026B-90344', 26, '2026-09-03 19:50:00'),
 ('AML2026P-91952', 20, '2026-09-04 08:15:00'),
 ('CPF2026K-00001', 19, '2026-09-04 08:34:00'),
 ('FEX2026X-00012', 12, '2026-09-04 09:04:00'),
 ('PSX2026G-00030',  6, '2026-09-04 11:11:00'),
 ('SAL2025T-00012', 14, '2026-09-04 12:56:00'),
 ('AML2026P-00019',  3, '2026-09-04 13:50:00'),
 ('PCM2026H-00028',  2, '2026-09-04 15:09:00'),
 ('ACF2026J-00017', 17, '2026-09-04 17:50:00'),
 ('AMC2026K-00002', 23, '2026-09-04 19:41:00'),
 ('GBP2026G-00005',  7, '2026-09-05 08:31:00'),
 ('CPF2026K-94390',  7, '2026-09-05 12:17:00'),
 ('LOS2026S-00016', 22, '2026-09-05 16:56:00'),
 ('PSX2026G-00021',  3, '2026-09-05 19:01:00'),
 ('SAL2025T-00009',  5, '2026-09-05 19:40:00'),
 ('ASP2025U-00029', 16, '2026-09-05 20:01:00'),
 ('DCL2026R-00004', 25, '2026-09-05 21:15:00'),
 ('FEX2026X-00004', 17, '2026-09-06 08:07:00'),
 ('IFA2026B-00020', 15, '2026-09-06 08:09:00');
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES
 ('LOS2026S-00012', 27, '2026-09-06 08:40:00'),
 ('CFX2024Y-00001',  7, '2026-09-06 08:56:00'),
 ('OMP2026Z-00005', 24, '2026-09-06 10:32:00'),
 ('PAN2026Y-00022', 11, '2026-09-06 10:48:00'),
 ('MTK2026W-00023',  3, '2026-09-06 10:53:00'),
 ('GBP2026G-00001',  3, '2026-09-06 11:06:00'),
 ('IFA2026B-00006', 11, '2026-09-06 12:05:00'),
 ('CFX2024Y-00019',  9, '2026-09-06 12:18:00'),
 ('CLP2026T-00002',  5, '2026-09-06 14:15:00'),
 ('PSX2026G-00003', 15, '2026-09-06 14:15:00'),
 ('CLP2026T-00025', 24, '2026-09-06 14:26:00'),
 ('GBP2026G-00013', 20, '2026-09-06 21:47:00'),
 ('CLP2026T-00006', 17, '2026-09-07 09:11:00'),
 ('CLP2026T-96863',  7, '2026-09-07 11:25:00'),
 ('SRT2026F-00017',  3, '2026-09-07 14:02:00'),
 ('AMC2026K-00012',  7, '2026-09-07 15:26:00'),
 ('AMC2026K-00023',  6, '2026-09-07 15:56:00'),
 ('MET2026C-95136',  5, '2026-09-07 16:42:00'),
 ('CFX2024Y-00012', 29, '2026-09-07 17:54:00'),
 ('DOX2026L-00014', 27, '2026-09-07 20:29:00'),
 ('LOS2026S-00016', 23, '2026-09-07 21:56:00'),
 ('PCM2026H-00007', 11, '2026-09-08 08:43:00'),
 ('PSX2026G-00008', 15, '2026-09-08 08:47:00'),
 ('FEX2026X-00020', 18, '2026-09-08 11:11:00'),
 ('IFA2026B-00015', 15, '2026-09-08 12:00:00'),
 ('ACF2026J-00015', 10, '2026-09-08 14:03:00'),
 ('FEX2026X-00005', 17, '2026-09-08 15:25:00'),
 ('FEX2026X-00013', 15, '2026-09-08 15:37:00'),
 ('AZI2026K-00004', 10, '2026-09-08 18:31:00'),
 ('PAN2026Y-00025', 30, '2026-09-08 21:15:00'),
 ('IFA2026B-00005', 26, '2026-09-09 09:49:00'),
 ('IBU2026H-00024',  9, '2026-09-09 12:07:00'),
 ('AMC2026K-00030', 11, '2026-09-09 12:45:00'),
 ('TEL2026Q-00030', 22, '2026-09-09 12:53:00'),
 ('PCM2026H-00002',  6, '2026-09-09 13:52:00'),
 ('GBP2026G-00003', 26, '2026-09-09 15:00:00'),
 ('GLM2026M-00017',  5, '2026-09-09 15:45:00'),
 ('CFX2024Y-00002', 12, '2026-09-09 21:20:00'),
 ('SIT2026N-00002',  6, '2026-09-09 21:21:00'),
 ('CFX2024Y-00002', 22, '2026-09-09 22:20:00');
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES
 ('BCX2024Z-00010', 10, '2026-09-10 08:58:00'),
 ('LTX2026C-00002', 30, '2026-09-10 09:17:00'),
 ('IFA2026B-00007',  6, '2026-09-10 11:44:00'),
 ('CFX2024Y-00001', 25, '2026-09-10 15:56:00'),
 ('TEL2026Q-00014', 15, '2026-09-10 18:31:00'),
 ('AZI2026K-00002',  7, '2026-09-10 19:42:00'),
 ('BCX2024Z-00017', 27, '2026-09-10 21:45:00'),
 ('PCMX8145-72903', 24, '2026-09-11 10:06:00'),
 ('CPF2026K-00022', 26, '2026-09-11 11:10:00'),
 ('DCL2026R-00016', 26, '2026-09-11 12:00:00'),
 ('GLM2026M-00005',  3, '2026-09-11 13:10:00'),
 ('CFX2024Y-00021',  3, '2026-09-11 14:13:00'),
 ('IFA2026B-00025', 15, '2026-09-11 14:20:00'),
 ('SAL2025T-00001',  2, '2026-09-11 14:22:00'),
 ('PSX2026G-00020',  3, '2026-09-11 18:50:00'),
 ('PSX2026G-00038', 14, '2026-09-11 21:38:00'),
 ('DCL2026R-98073', 27, '2026-09-11 21:58:00'),
 ('SRT2026F-00006', 12, '2026-09-12 08:57:00'),
 ('OND2025S-00006',  2, '2026-09-12 14:19:00'),
 ('CFX2024Y-00003', 14, '2026-09-12 19:35:00'),
 ('PCMX5289-41593', 20, '2026-09-12 21:11:00'),
 ('OMP2026Z-00022', 17, '2026-09-12 21:16:00'),
 ('PSX2026G-00029', 18, '2026-09-12 21:16:00'),
 ('OSL2026D-00015',  8, '2026-09-12 21:47:00'),
 ('LOS2026S-00014', 29, '2026-09-13 09:57:00'),
 ('MTK2026W-00012',  1, '2026-09-13 10:21:00'),
 ('MET2026J-00005', 15, '2026-09-13 11:21:00'),
 ('MET2026J-00006', 29, '2026-09-13 12:17:00'),
 ('ACV2026E-00005', 11, '2026-09-13 12:32:00'),
 ('LTX2026C-00005',  3, '2026-09-13 12:52:00'),
 ('AMC2026K-00021', 11, '2026-09-13 13:09:00'),
 ('ACV2026E-00005', 20, '2026-09-13 13:32:00'),
 ('DOX2026L-00024',  6, '2026-09-13 13:38:00'),
 ('AMC2026K-00015', 26, '2026-09-13 15:32:00'),
 ('CPF2026K-00019', 15, '2026-09-13 15:56:00'),
 ('OND2025S-00013', 10, '2026-09-13 16:55:00'),
 ('GLM2026M-00021', 15, '2026-09-13 17:02:00'),
 ('MET2026J-00027', 29, '2026-09-13 19:51:00'),
 ('IFA2026B-00014', 23, '2026-09-13 20:44:00'),
 ('IBU2026H-00033', 13, '2026-09-13 21:09:00');
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES
 ('IFA2026B-00020',  9, '2026-09-14 08:09:00'),
 ('OMP2026Z-00018', 13, '2026-09-14 14:10:00'),
 ('XKP3111-34852', 16, '2026-09-14 14:22:00'),
 ('LOS2026S-00012',  7, '2026-09-14 14:40:00'),
 ('SAL2025T-00017', 18, '2026-09-15 08:48:00'),
 ('AML2026P-90221',  5, '2026-09-15 10:04:00'),
 ('BCX2024Z-00003', 14, '2026-09-15 13:23:00'),
 ('IFA2026B-00008',  4, '2026-09-15 14:21:00'),
 ('SRT2026F-00013', 22, '2026-09-15 14:28:00'),
 ('PSX2026G-00035', 26, '2026-09-15 14:29:00'),
 ('SIT2026N-00015', 30, '2026-09-15 15:04:00'),
 ('FEX2026X-00018', 23, '2026-09-15 15:19:00'),
 ('ACV2026E-00001', 28, '2026-09-15 18:29:00'),
 ('MTK2026W-00010',  8, '2026-09-15 21:33:00'),
 ('SIT2026N-00004', 18, '2026-09-16 08:52:00'),
 ('CLP2026T-00022',  8, '2026-09-16 09:45:00'),
 ('LOS2026S-00013', 29, '2026-09-16 10:40:00'),
 ('OMP2026Z-00001', 26, '2026-09-16 12:13:00'),
 ('AML2026P-00014', 25, '2026-09-16 13:41:00'),
 ('DCL2026R-00030',  1, '2026-09-16 15:11:00'),
 ('OSL2026D-00011',  7, '2026-09-16 15:40:00'),
 ('MTK2026W-00011',  2, '2026-09-16 16:24:00'),
 ('IFA2026B-00002', 10, '2026-09-16 18:45:00'),
 ('IFA2026B-00002', 22, '2026-09-16 19:45:00'),
 ('AMC2026K-00004', 12, '2026-09-16 21:13:00'),
 ('IBU2026H-00014',  3, '2026-09-17 09:28:00'),
 ('CFX2024Y-00017', 15, '2026-09-17 10:26:00'),
 ('ACV2026E-92121', 27, '2026-09-17 11:23:00'),
 ('DCL2026R-00023', 25, '2026-09-17 13:32:00'),
 ('GBP2026G-00018', 17, '2026-09-17 17:08:00'),
 ('AZI2026K-00023',  2, '2026-09-17 21:10:00'),
 ('CPF2026K-00011', 18, '2026-09-17 21:45:00'),
 ('MET2026J-00027', 22, '2026-09-17 21:51:00'),
 ('ASP2025U-00022', 24, '2026-09-18 08:37:00'),
 ('IBU2026H-00003', 30, '2026-09-18 10:07:00'),
 ('ACV2026E-00018', 16, '2026-09-18 11:49:00'),
 ('AMC2026K-00014', 22, '2026-09-18 12:21:00'),
 ('PSX2026G-00008',  9, '2026-09-18 13:47:00'),
 ('VTD2026A-00010', 10, '2026-09-18 14:43:00'),
 ('OND2025S-00015', 17, '2026-09-18 15:02:00');
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES
 ('CLP2026T-00020', 16, '2026-09-18 17:24:00'),
 ('GBP2026G-00014', 14, '2026-09-18 19:37:00'),
 ('SRT2026F-00017',  9, '2026-09-18 20:02:00'),
 ('CFX2024Y-00016',  4, '2026-09-18 20:44:00'),
 ('VTD2026A-00008', 18, '2026-09-18 21:05:00'),
 ('LCZ2026V-00025', 18, '2026-09-19 08:19:00'),
 ('AMC2026K-00005', 20, '2026-09-19 09:07:00'),
 ('MTK2026W-00021', 14, '2026-09-19 11:44:00'),
 ('OMP2026Z-00017',  8, '2026-09-19 12:01:00'),
 ('DOX2026L-00020', 13, '2026-09-19 13:05:00'),
 ('OMP2026Z-00004',  3, '2026-09-19 13:19:00'),
 ('OND2025S-00012', 15, '2026-09-19 16:26:00'),
 ('TEL2026Q-00030', 28, '2026-09-19 19:53:00'),
 ('GBP2026G-00006',  2, '2026-09-20 08:47:00'),
 ('ASP2025U-00014',  7, '2026-09-20 09:51:00'),
 ('PSX2026G-00034', 22, '2026-09-20 10:07:00'),
 ('GLM2026M-00026', 14, '2026-09-20 10:34:00'),
 ('CLP2026T-00004', 18, '2026-09-20 11:44:00'),
 ('OND2025S-00016',  5, '2026-09-20 14:46:00'),
 ('PAN2026Y-90129',  7, '2026-09-20 15:20:00'),
 ('LCZ2026V-00022',  2, '2026-09-20 15:26:00'),
 ('AMX2024X-96889', 20, '2026-09-20 17:47:00'),
 ('GBP2026G-00019', 30, '2026-09-20 19:06:00'),
 ('CPF2026K-00016', 10, '2026-09-20 20:58:00'),
 ('OSL2026D-00001', 30, '2026-09-20 21:57:00'),
 ('OMP2026Z-00022', 17, '2026-09-21 00:16:00'),
 ('OND2025S-00009',  5, '2026-09-21 08:19:00'),
 ('AMC2026K-00001', 19, '2026-09-21 09:01:00'),
 ('OND2025S-00008',  9, '2026-09-21 10:22:00'),
 ('SIT2026N-00009', 28, '2026-09-21 11:06:00'),
 ('DOX2026L-00015',  3, '2026-09-21 15:26:00'),
 ('DCL2026R-00030',  1, '2026-09-21 21:11:00'),
 ('OND2025S-00002', 15, '2026-09-21 21:42:00'),
 ('IFA2026B-00009',  8, '2026-09-22 09:24:00'),
 ('SAL2025T-00015', 13, '2026-09-22 10:32:00'),
 ('IBU2026H-00015', 12, '2026-09-22 10:49:00'),
 ('PSX2026G-00001', 12, '2026-09-22 12:07:00'),
 ('ASP2025U-00030', 26, '2026-09-22 13:40:00'),
 ('XKP7350-68855',  6, '2026-09-22 14:43:00'),
 ('PSX2026G-00001', 21, '2026-09-22 15:07:00');
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES
 ('OSL2026D-00011', 27, '2026-09-22 16:40:00'),
 ('LCZ2026V-00024',  1, '2026-09-22 17:34:00'),
 ('LTX2026C-00001', 25, '2026-09-22 18:01:00'),
 ('SRT2026F-00016', 21, '2026-09-22 18:42:00'),
 ('AMX2026B-99721',  7, '2026-09-22 20:55:00'),
 ('AML2026P-00008', 24, '2026-09-22 21:06:00'),
 ('TEL2026Q-00003', 13, '2026-09-22 21:18:00'),
 ('OSL2026D-00012',  2, '2026-09-23 08:14:00'),
 ('LOS2026S-00021',  4, '2026-09-23 09:16:00'),
 ('CFX2024Y-00008', 29, '2026-09-23 10:06:00'),
 ('FEX2026X-00010', 14, '2026-09-23 10:54:00'),
 ('AML2026P-00023', 29, '2026-09-23 11:17:00'),
 ('GBP2026G-00016', 16, '2026-09-23 12:24:00'),
 ('IFA2026B-00018',  8, '2026-09-23 16:02:00'),
 ('SAL2025T-00007', 12, '2026-09-23 17:59:00'),
 ('AZI2026K-00026',  3, '2026-09-23 21:17:00'),
 ('QRT6058-81560', 24, '2026-09-23 21:31:00'),
 ('LTX2026C-00011',  2, '2026-09-24 09:54:00'),
 ('CLP2026T-00018', 20, '2026-09-24 10:02:00'),
 ('SRT2026F-00009',  3, '2026-09-24 10:56:00'),
 ('ASP2025U-00008', 12, '2026-09-24 11:14:00'),
 ('CLP2026T-00018', 12, '2026-09-24 11:32:00'),
 ('VTD2026A-00022', 12, '2026-09-24 12:53:00'),
 ('OMP2026Z-00012', 28, '2026-09-24 13:02:00'),
 ('AMC2026K-00009',  8, '2026-09-24 13:17:00'),
 ('SIT2026N-00016', 18, '2026-09-24 16:56:00'),
 ('GBP2026G-00008', 15, '2026-09-24 21:53:00'),
 ('CPF2026K-00005', 14, '2026-09-25 09:15:00'),
 ('PCM2026H-00030', 29, '2026-09-25 21:33:00'),
 ('PCM2026H-00030', 12, '2026-09-25 23:03:00'),
 ('OSL2026D-00005', 13, '2026-09-26 08:35:00'),
 ('FEX2026X-00001',  8, '2026-09-26 08:38:00'),
 ('LTX2026C-00006', 18, '2026-09-26 09:22:00'),
 ('GLM2026M-00028', 11, '2026-09-26 10:35:00'),
 ('SAL2025T-94561', 26, '2026-09-26 11:15:00'),
 ('OSL2026D-00005', 10, '2026-09-26 11:35:00'),
 ('ACF2026J-00016', 22, '2026-09-26 14:47:00'),
 ('DCL2026R-00021',  8, '2026-09-26 14:49:00'),
 ('CPF2026K-00026', 15, '2026-09-26 19:25:00'),
 ('CPF2026K-90592', 27, '2026-09-26 19:58:00');
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES
 ('IFA2026B-00011', 15, '2026-09-26 21:39:00'),
 ('LCZ2026V-00017', 21, '2026-09-27 08:57:00'),
 ('VTD2026A-00025', 11, '2026-09-27 09:23:00'),
 ('GBP2026G-00020', 30, '2026-09-27 14:33:00'),
 ('PAN2026Y-00006', 24, '2026-09-27 15:05:00'),
 ('MTK2026W-93524', 23, '2026-09-27 17:20:00'),
 ('MTK2026W-00007', 28, '2026-09-28 08:39:00'),
 ('CLP2026T-00007',  5, '2026-09-28 08:55:00'),
 ('AMC2026K-00007', 28, '2026-09-28 09:40:00'),
 ('SAL2025T-00019', 21, '2026-09-28 11:18:00'),
 ('GBP2026G-90124', 20, '2026-09-28 11:26:00'),
 ('AMC2026K-00027', 23, '2026-09-28 12:02:00'),
 ('CPF2026K-00005', 15, '2026-09-28 12:15:00'),
 ('MTK2026W-00018',  8, '2026-09-28 15:13:00'),
 ('PSX2026G-00027', 12, '2026-09-28 15:38:00'),
 ('OMP2026Z-00006', 28, '2026-09-28 17:32:00'),
 ('SRT2026F-00014',  4, '2026-09-28 20:28:00'),
 ('SRT2026F-00014', 14, '2026-09-28 23:28:00'),
 ('MET2026J-00023', 18, '2026-09-29 09:52:00'),
 ('MET2026J-00015', 12, '2026-09-29 12:17:00'),
 ('LOS2026S-00022', 17, '2026-09-29 15:22:00'),
 ('SRT2026F-00011', 19, '2026-09-29 16:49:00'),
 ('GLM2026M-00007', 20, '2026-09-29 21:17:00'),
 ('ACF2026J-00024', 21, '2026-09-30 08:52:00'),
 ('LCZ2026V-00021', 17, '2026-09-30 10:56:00'),
 ('PSX2026G-00010', 28, '2026-09-30 12:03:00'),
 ('XKP4256-98584', 16, '2026-09-30 12:29:00'),
 ('AML2026P-00032', 11, '2026-09-30 12:51:00'),
 ('BCX2024Z-00018', 23, '2026-09-30 13:33:00'),
 ('PSX2026G-00004', 25, '2026-09-30 13:58:00'),
 ('GLM2026M-00028', 12, '2026-09-30 14:35:00'),
 ('MTK2026W-00016', 13, '2026-09-30 14:46:00'),
 ('VTD2026A-00022', 19, '2026-09-30 16:53:00'),
 ('OND2025S-00015', 17, '2026-09-30 17:02:00'),
 ('SRT2026F-00002', 28, '2026-09-30 19:33:00'),
 ('PCM2026A-00003',  2, '2026-10-01 09:15:00'),
 ('PCM2026A-00004',  3, '2026-10-01 11:40:00'),
 ('LOS2026S-00024',  1, '2026-10-01 11:44:00'),
 ('TEL2026Q-00001', 13, '2026-10-01 12:44:00'),
 ('ACF2026J-00009', 13, '2026-10-01 13:18:00');
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES
 ('ACF2026J-00009',  6, '2026-10-01 17:18:00'),
 ('DCL2026R-00008',  6, '2026-10-01 17:27:00'),
 ('OMP2026Z-00025', 30, '2026-10-01 17:38:00'),
 ('LTX2026C-00013',  4, '2026-10-01 18:54:00'),
 ('LTX2026C-00013', 26, '2026-10-01 20:24:00'),
 ('SIT2026N-00017', 20, '2026-10-01 21:01:00'),
 ('AML2026P-00025', 30, '2026-10-01 21:20:00'),
 ('LOS2026S-00010',  4, '2026-10-02 09:09:00'),
 ('ASP2025U-00005', 14, '2026-10-02 09:19:00'),
 ('AMX2026B-00002',  4, '2026-10-02 10:05:00'),
 ('SAL2025T-00013', 27, '2026-10-02 10:59:00'),
 ('SAL2025T-00013',  9, '2026-10-02 11:59:00'),
 ('OND2025S-00010',  5, '2026-10-02 12:38:00'),
 ('FEX2026X-00019', 17, '2026-10-02 12:54:00'),
 ('ACV2026E-00004', 28, '2026-10-02 15:08:00'),
 ('AMC2026K-00024', 11, '2026-10-02 16:01:00'),
 ('IFA2026B-00018', 15, '2026-10-02 16:02:00'),
 ('ATV2026D-00001',  5, '2026-10-02 16:20:00'),
 ('CLP2026T-00011', 12, '2026-10-02 16:48:00'),
 ('PSX2026G-00015',  9, '2026-10-02 17:03:00');

-- Three batches recalled on 3 Oct 2026; later scans of them are blocked
CALL sp_recall_batch('MET2026C', 'Failed dissolution test in quality audit');
CALL sp_recall_batch('DCL2026R', 'Mislabelled strength: 75 mg printed as 50 mg');
CALL sp_recall_batch('CPF2026K', 'Particulate contamination found by state drug laboratory');

-- Scans after the recalls
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES
 ('AZI2026E-00003',  8, '2026-10-03 12:10:00'),
 ('AML2026P-00018', 26, '2026-10-03 14:25:00'),
 ('OMP2026Z-00003',  9, '2026-10-03 14:35:00'),
 ('AZI2026E-00003',  7, '2026-10-03 15:00:00'),
 ('CPF2026K-00024', 26, '2026-10-03 16:03:00'),
 ('AZI2026K-00012', 13, '2026-10-03 17:07:00'),
 ('AZI2026K-00012', 17, '2026-10-03 18:37:00'),
 ('PCM2026A-00005',  9, '2026-10-03 18:45:00'),
 ('IBU2026H-00020', 28, '2026-10-03 20:37:00'),
 ('PAN2026Y-00010', 18, '2026-10-03 21:34:00'),
 ('ZNM4700-34769', 23, '2026-10-04 08:33:00'),
 ('CTZ2026F-00001',  1, '2026-10-04 08:50:00'),
 ('CFX2024Y-00011', 16, '2026-10-04 09:04:00'),
 ('ATV2026D-00002', 10, '2026-10-04 09:30:00'),
 ('CPF2026K-00030', 25, '2026-10-04 09:33:00'),
 ('ATV2026D-00002',  6, '2026-10-04 12:00:00'),
 ('PCM2026A-00006',  1, '2026-10-04 13:00:00'),
 ('DOX2026L-00011',  3, '2026-10-04 14:57:00'),
 ('OSL2026D-00002', 19, '2026-10-04 17:28:00'),
 ('PCMX8354-90948',  6, '2026-10-05 09:03:00'),
 ('LOS2026S-00001',  9, '2026-10-05 09:57:00'),
 ('AZI2026E-00004',  6, '2026-10-05 10:00:00'),
 ('AML2026P-97608', 24, '2026-10-05 10:09:00'),
 ('MET2026J-99385', 16, '2026-10-05 13:04:00'),
 ('LCZ2026V-00009',  3, '2026-10-05 13:12:00'),
 ('ATV2026D-00003',  6, '2026-10-05 15:30:00'),
 ('MET2026J-00002',  8, '2026-10-05 16:33:00'),
 ('CTZ2026F-00002',  2, '2026-10-05 17:10:00'),
 ('LCZ2026V-00002', 27, '2026-10-05 21:32:00'),
 ('SAL2025T-00006',  2, '2026-10-05 21:33:00'),
 ('IFA2026B-92880', 27, '2026-10-06 08:56:00'),
 ('DCL2026R-00022', 20, '2026-10-06 09:45:00'),
 ('XKP2138-07173',  7, '2026-10-06 10:21:00'),
 ('CFX2024Y-00005',  6, '2026-10-06 10:45:00'),
 ('PCM2026A-99999',  7, '2026-10-06 12:00:00'),
 ('XYZ1234-00001',  7, '2026-10-06 12:30:00'),
 ('MET2026J-00022', 28, '2026-10-06 13:27:00'),
 ('VTD2026A-00009', 26, '2026-10-06 15:39:00'),
 ('ACF2026J-00007', 26, '2026-10-06 15:50:00'),
 ('TEL2026Q-00001', 18, '2026-10-06 20:44:00');
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES
 ('PSX2026G-00040', 10, '2026-10-07 09:47:00'),
 ('ATV2026D-88888',  6, '2026-10-07 11:00:00'),
 ('GBP2026G-00002',  8, '2026-10-07 13:09:00'),
 ('PCM2026A-00007',  8, '2026-10-07 14:25:00'),
 ('MTK2026W-00006',  6, '2026-10-07 14:35:00'),
 ('PSX2026G-00032', 10, '2026-10-07 15:17:00'),
 ('PSX2026G-00033', 29, '2026-10-07 16:34:00'),
 ('DCL2026R-00028',  2, '2026-10-07 18:14:00'),
 ('BCX2024Z-00016', 10, '2026-10-07 18:54:00'),
 ('CTZ2026F-96066', 24, '2026-10-07 21:51:00'),
 ('GBP2026G-00004', 30, '2026-10-07 21:59:00'),
 ('SIT2026N-00014', 10, '2026-10-08 08:55:00'),
 ('OND2025S-00004',  6, '2026-10-08 09:10:00'),
 ('SAL2025T-00011',  2, '2026-10-08 15:08:00'),
 ('AZI2026E-77777',  7, '2026-10-08 17:15:00'),
 ('ACF2026J-99269', 27, '2026-10-09 08:21:00'),
 ('GBP2026G-00015',  1, '2026-10-09 10:44:00'),
 ('SRT2026F-00008', 23, '2026-10-09 11:37:00'),
 ('FEX2026X-00016', 16, '2026-10-09 12:23:00'),
 ('AMX2026B-00002',  4, '2026-10-09 14:00:00'),
 ('OND2025S-00019', 30, '2026-10-09 20:10:00'),
 ('ASP2025U-00025', 15, '2026-10-09 21:56:00'),
 ('PCM2026A-00004',  3, '2026-10-10 10:00:00'),
 ('OSL2026D-00006',  4, '2026-10-10 10:47:00'),
 ('CTZ2026F-00003',  9, '2026-10-10 12:40:00'),
 ('AMC2026K-00003',  4, '2026-10-10 20:51:00'),
 ('OND2025S-00017', 16, '2026-10-11 08:10:00'),
 ('LOS2026S-00017',  7, '2026-10-11 08:57:00'),
 ('ATV2026D-00001', 10, '2026-10-11 09:00:00'),
 ('TEL2026Q-00029', 29, '2026-10-11 13:49:00'),
 ('AZI2026K-00019', 15, '2026-10-11 14:19:00'),
 ('CPF2026K-00018', 21, '2026-10-11 14:38:00'),
 ('DCL2026R-00018', 27, '2026-10-11 14:55:00'),
 ('DCL2026R-00009', 19, '2026-10-12 10:52:00'),
 ('MET2026C-00005',  1, '2026-10-12 11:00:00'),
 ('DCL2026R-00015', 18, '2026-10-12 11:15:00'),
 ('LCZ2026V-00009',  8, '2026-10-12 13:12:00'),
 ('CTZ2026F-96496', 24, '2026-10-12 13:33:00'),
 ('CFX2024Y-00006', 24, '2026-10-12 14:36:00'),
 ('CPF2026K-00008', 29, '2026-10-12 14:46:00');
INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES
 ('MET2026C-00006',  8, '2026-10-12 16:00:00'),
 ('LOS2026S-00009', 12, '2026-10-12 16:59:00'),
 ('IFA2026B-90703', 27, '2026-10-12 19:31:00'),
 ('FEX2026X-00017', 13, '2026-10-12 19:56:00'),
 ('ASP2025U-99009',  7, '2026-10-12 21:03:00'),
 ('AMC2026K-00016', 21, '2026-10-12 21:53:00'),
 ('OSL2026D-00004',  8, '2026-10-13 08:32:00'),
 ('SAL2025T-00018', 28, '2026-10-13 08:59:00'),
 ('MTK2026W-00015', 13, '2026-10-13 09:58:00'),
 ('AMX2024X-00001',  9, '2026-10-13 10:30:00'),
 ('AMX2024X-00002',  7, '2026-10-13 12:00:00'),
 ('OSL2026D-00008', 11, '2026-10-13 12:57:00'),
 ('TEL2026Q-00009', 22, '2026-10-13 14:12:00'),
 ('PCM2026H-00014', 24, '2026-10-13 14:17:00'),
 ('MET2026J-00028', 21, '2026-10-13 15:30:00'),
 ('PCM2026H-00016', 24, '2026-10-13 18:29:00'),
 ('CPF2026K-00023', 18, '2026-10-13 20:31:00'),
 ('SRT2026F-00015',  2, '2026-10-13 20:50:00'),
 ('IFA2026B-00019', 14, '2026-10-13 21:46:00'),
 ('AMX2026B-00005',  5, '2026-10-14 11:20:00'),
 ('IBU2026H-00002', 11, '2026-10-14 12:23:00');

CALL sp_update_risk_levels();

-- Officers have already acted on some alerts
CALL sp_resolve_alert(1,  'Pharmacy inspected; supplier invoice traced to an unlicensed wholesaler', 1);
CALL sp_resolve_alert(3,  'Counterfeit stock seized (14 strips); case referred to the district drug controller', 5);
CALL sp_resolve_alert(6,  'Strip returned by patient; manufacturer confirmed the code was copied', 1);
CALL sp_resolve_alert(10, 'Pharmacy warned; staff retrained on scanning every strip at sale', 5);
CALL sp_resolve_alert(15, 'Batch quarantined at the distributor warehouse', 1);
CALL sp_resolve_alert(22, 'Expired strips destroyed in presence of the drug inspector', 5);
CALL sp_resolve_alert(31, 'Show-cause notice issued to the pharmacy licence holder', 1);
CALL sp_resolve_alert(40, 'Investigation closed: same counter scanned twice by mistake, no fraud', 1);

-- Patient complaints (priority is set by trg_complaint_priority)
INSERT INTO complaint (serial_no, reporter_name, reporter_phone, city, description, created_at) VALUES
 ('PCM2026A-99999', 'S. Priya', '9632433998', 'Kolkata', 'Tablets crumble and taste chalky, strip print looks blurred', '2026-10-06 18:20:00'),
 ('MET2026C-00005', 'K. Arjun', '9710995157', 'Chennai', 'Pharmacy sold this to my father; heard the batch is recalled', '2026-10-12 19:05:00'),
 ('AZI2026E-00003', 'M. Fathima', '9637879861', 'Kolkata', 'Same serial number as the strip my neighbour bought in another city', '2026-10-04 09:40:00'),
 ('CTZ2026F-00001', 'D. Rahul', NULL, 'Chennai', 'Packaging colour different from usual, want to confirm it is real', '2026-10-05 12:15:00'),
 ('IFA2026B-90703', 'A. Nandini', '9303363916', 'Patna', 'Hologram missing on the strip, batch number font looks different', '2026-10-13 14:31:00'),
 ('MET2026J-99385', 'R. Vignesh', '9604173784', 'Vijayawada', 'Hologram missing on the strip, batch number font looks different', '2026-10-06 16:04:00'),
 ('XKP3111-34852', 'P. Kavya', '9204708562', 'Vijayawada', 'Tablets crumble and taste chalky, strip print looks blurred', '2026-09-14 22:22:00'),
 ('CTZ2026F-96066', 'J. Thomas', '9623476844', 'Lucknow', 'Bought from a roadside stall at half price, foil feels thin', '2026-10-08 23:51:00'),
 ('CLP2026T-96863', 'N. Ayesha', NULL, 'Kolkata', 'No effect after three days, packaging spelling mistakes', '2026-09-07 16:25:00'),
 ('SAL2025T-00013', 'G. Suresh', '9848852843', 'Madurai', 'Serial already shows as sold when I check it online', '2026-10-02 18:59:00'),
 ('OMP2026Z-00022', 'L. Meera', '9534004158', 'Visakhapatnam', 'Serial already shows as sold when I check it online', '2026-09-22 02:16:00'),
 ('TEL2026Q-00025', 'T. Imran', '9333174959', 'Nagpur', 'Serial already shows as sold when I check it online', '2026-09-03 12:39:00'),
 ('IFA2026B-00018', 'B. Divya', '9418605803', 'Mysuru', 'Same serial number as the strip my neighbour bought in another city', '2026-10-03 14:02:00'),
 ('CFX2024Y-00008', 'V. Karthik', NULL, 'Bhopal', 'Strip sold to me last week is past its expiry date', '2026-09-24 04:06:00'),
 ('BCX2024Z-00017', 'H. Sneha', '9450308963', 'Patna', 'Strip sold to me last week is past its expiry date', '2026-09-11 09:45:00'),
 ('OSL2026D-00015', 'C. Joseph', '9261543861', 'Coimbatore', 'Just want to be sure this strip is genuine before giving it to my child', '2026-09-13 12:47:00'),
 ('AML2026P-00023', 'E. Ritu', '9561589129', 'Bhopal', 'Just want to be sure this strip is genuine before giving it to my child', '2026-09-24 00:17:00');

CALL sp_update_complaint(3, 'INVESTIGATING', NULL, 5);
CALL sp_update_complaint(4, 'RESOLVED', 'Serial verified genuine; new packaging design since Sept 2026', 1);
CALL sp_update_complaint(5, 'INVESTIGATING', NULL, 1);
CALL sp_update_complaint(6, 'RESOLVED', 'Confirmed counterfeit; stock seized and pharmacy notified', 5);
CALL sp_update_complaint(7, 'INVESTIGATING', NULL, 1);
CALL sp_update_complaint(9, 'REJECTED', 'Duplicate of an earlier complaint for the same strip', 1);
CALL sp_update_complaint(10, 'INVESTIGATING', NULL, 5);
CALL sp_update_complaint(11, 'RESOLVED', 'Cloned code confirmed; manufacturer issued replacement strips', 1);
CALL sp_update_complaint(14, 'RESOLVED', 'Strip withdrawn; customer refunded by the pharmacy', 1);
CALL sp_update_complaint(16, 'RESOLVED', 'Strip verified genuine through the registry', 5);

-- Patients checking strips on the public Verify page
INSERT INTO patient_check (serial_no, city, checked_at, result) VALUES
 ('AML2026P-00023', 'Delhi', '2026-09-30 19:10:00', fn_serial_status('AML2026P-00023')),
 ('FEX2026X-00012', 'Lucknow', '2026-09-11 15:08:00', fn_serial_status('FEX2026X-00012')),
 ('TEL2026Q-00030', 'Visakhapatnam', '2026-09-11 18:31:00', fn_serial_status('TEL2026Q-00030')),
 ('CLP2026T-00018', 'Bengaluru', '2026-10-01 12:35:00', fn_serial_status('CLP2026T-00018')),
 ('CLP2026T-00022', 'Salem', '2026-09-28 20:40:00', fn_serial_status('CLP2026T-00022')),
 ('GBP2026G-00015', 'Madurai', '2026-09-22 21:28:00', fn_serial_status('GBP2026G-00015')),
 ('DOX2026L-00024', 'Patna', '2026-09-19 11:04:00', fn_serial_status('DOX2026L-00024')),
 ('GLM2026M-00021', 'Delhi', '2026-10-08 13:51:00', fn_serial_status('GLM2026M-00021')),
 ('LOS2026S-00014', 'Tiruchirappalli', '2026-10-02 21:18:00', fn_serial_status('LOS2026S-00014')),
 ('LOS2026S-00022', 'Mumbai', '2026-09-07 15:02:00', fn_serial_status('LOS2026S-00022')),
 ('CPF2026K-00026', 'Bhubaneswar', '2026-09-03 15:48:00', fn_serial_status('CPF2026K-00026')),
 ('MTK2026W-00006', 'Ahmedabad', '2026-10-10 18:54:00', fn_serial_status('MTK2026W-00006')),
 ('IBU2026H-00020', 'Patna', '2026-09-28 11:04:00', fn_serial_status('IBU2026H-00020')),
 ('AZI2026K-00002', 'Pune', '2026-10-11 11:32:00', fn_serial_status('AZI2026K-00002')),
 ('PSX2026G-00001', 'Mumbai', '2026-09-22 18:53:00', fn_serial_status('PSX2026G-00001')),
 ('TEL2026Q-00001', 'Thiruvananthapuram', '2026-09-04 10:05:00', fn_serial_status('TEL2026Q-00001')),
 ('CLP2026T-00007', 'Ahmedabad', '2026-09-11 13:07:00', fn_serial_status('CLP2026T-00007')),
 ('DCL2026R-00021', 'Vijayawada', '2026-09-27 17:31:00', fn_serial_status('DCL2026R-00021')),
 ('AMC2026K-00012', 'Visakhapatnam', '2026-09-09 12:51:00', fn_serial_status('AMC2026K-00012')),
 ('IFA2026B-00013', 'Chennai', '2026-10-14 13:35:00', fn_serial_status('IFA2026B-00013')),
 ('PCMX8354-90948', 'Ahmedabad', '2026-10-14 09:35:00', fn_serial_status('PCMX8354-90948')),
 ('SAL2025T-00018', 'Mumbai', '2026-09-03 19:40:00', fn_serial_status('SAL2025T-00018')),
 ('PCM2026A-00005', 'Bhopal', '2026-10-03 12:12:00', fn_serial_status('PCM2026A-00005')),
 ('AML2026P-00008', 'Visakhapatnam', '2026-09-23 14:23:00', fn_serial_status('AML2026P-00008')),
 ('AMC2026K-00004', 'Pune', '2026-09-10 08:40:00', fn_serial_status('AMC2026K-00004')),
 ('SIT2026N-00015', 'Pune', '2026-09-28 15:24:00', fn_serial_status('SIT2026N-00015')),
 ('CFX2024Y-00017', 'Guwahati', '2026-09-18 12:04:00', fn_serial_status('CFX2024Y-00017')),
 ('AMX2026B-99721', 'Chennai', '2026-09-27 12:31:00', fn_serial_status('AMX2026B-99721')),
 ('AZI2026K-00012', 'Mysuru', '2026-09-09 21:06:00', fn_serial_status('AZI2026K-00012')),
 ('AMC2026K-00014', 'Bengaluru', '2026-10-07 09:50:00', fn_serial_status('AMC2026K-00014')),
 ('AML2026P-91952', 'Kolkata', '2026-10-08 15:30:00', fn_serial_status('AML2026P-91952')),
 ('SAL2025T-00017', 'Visakhapatnam', '2026-09-10 10:34:00', fn_serial_status('SAL2025T-00017')),
 ('OSL2026D-00005', 'Guwahati', '2026-10-14 11:50:00', fn_serial_status('OSL2026D-00005')),
 ('CFX2024Y-00021', 'Guwahati', '2026-09-13 13:10:00', fn_serial_status('CFX2024Y-00021')),
 ('TEL2026Q-00025', 'Bhopal', '2026-10-14 11:30:00', fn_serial_status('TEL2026Q-00025')),
 ('CLP2026T-00020', 'Madurai', '2026-10-10 16:21:00', fn_serial_status('CLP2026T-00020')),
 ('IFA2026B-00018', 'Madurai', '2026-09-16 14:17:00', fn_serial_status('IFA2026B-00018')),
 ('PCM2026A-00004', 'Lucknow', '2026-10-12 08:03:00', fn_serial_status('PCM2026A-00004')),
 ('AML2026P-90221', 'Kolkata', '2026-09-16 12:12:00', fn_serial_status('AML2026P-90221')),
 ('ACF2026J-00015', 'Coimbatore', '2026-09-11 08:56:00', fn_serial_status('ACF2026J-00015')),
 ('AZI2026K-00026', 'Salem', '2026-09-13 09:59:00', fn_serial_status('AZI2026K-00026')),
 ('DCL2026R-00028', 'Bhubaneswar', '2026-09-23 21:10:00', fn_serial_status('DCL2026R-00028')),
 ('ACF2026J-00020', 'Tiruchirappalli', '2026-09-26 08:53:00', fn_serial_status('ACF2026J-00020')),
 ('PAN2026Y-00006', 'Madurai', '2026-09-24 17:35:00', fn_serial_status('PAN2026Y-00006')),
 ('GBP2026G-00006', 'Pune', '2026-09-10 16:24:00', fn_serial_status('GBP2026G-00006')),
 ('SRT2026F-00014', 'Bhopal', '2026-09-16 21:49:00', fn_serial_status('SRT2026F-00014')),
 ('AZI2026E-00003', 'Bhopal', '2026-10-06 21:07:00', fn_serial_status('AZI2026E-00003')),
 ('IBU2026H-00015', 'Kochi', '2026-10-13 12:06:00', fn_serial_status('IBU2026H-00015')),
 ('AMX2024X-96889', 'Coimbatore', '2026-10-14 16:37:00', fn_serial_status('AMX2024X-96889')),
 ('LOS2026S-00012', 'Vijayawada', '2026-09-17 09:45:00', fn_serial_status('LOS2026S-00012')),
 ('CFX2024Y-00008', 'Hyderabad', '2026-09-24 11:03:00', fn_serial_status('CFX2024Y-00008')),
 ('DCL2026R-00018', 'Salem', '2026-10-11 08:22:00', fn_serial_status('DCL2026R-00018')),
 ('IBU2026H-00003', 'Pune', '2026-10-04 21:16:00', fn_serial_status('IBU2026H-00003')),
 ('ACF2026J-00009', 'Kolkata', '2026-09-24 15:43:00', fn_serial_status('ACF2026J-00009')),
 ('ACF2026J-00017', 'Chandigarh', '2026-10-04 11:24:00', fn_serial_status('ACF2026J-00017')),
 ('OMP2026Z-00006', 'Kochi', '2026-10-14 20:10:00', fn_serial_status('OMP2026Z-00006')),
 ('LOS2026S-00010', 'Chennai', '2026-09-06 09:31:00', fn_serial_status('LOS2026S-00010')),
 ('BCX2024Z-00018', 'Nagpur', '2026-10-01 17:16:00', fn_serial_status('BCX2024Z-00018')),
 ('DCL2026R-00016', 'Patna', '2026-09-04 17:13:00', fn_serial_status('DCL2026R-00016')),
 ('ACF2026J-00007', 'Visakhapatnam', '2026-09-13 12:41:00', fn_serial_status('ACF2026J-00007')),
 ('PCM2026A-00003', 'Coimbatore', '2026-09-11 12:05:00', fn_serial_status('PCM2026A-00003')),
 ('PCM2026A-99999', 'Bhopal', '2026-09-09 12:14:00', fn_serial_status('PCM2026A-99999')),
 ('AZI2026E-00003', 'Vellore', '2026-09-23 21:26:00', fn_serial_status('AZI2026E-00003')),
 ('MET2026C-00005', 'Tiruchirappalli', '2026-09-22 13:30:00', fn_serial_status('MET2026C-00005'));

INSERT INTO activity_log (user_id, action, details, created_at) VALUES
 (1, 'LOGIN',            'admin signed in',                                                    '2026-10-03 09:00:00'),
 (1, 'RECALL_BATCH',     'Recalled MET2026C: Failed dissolution test in quality audit',        '2026-10-03 09:05:00'),
 (1, 'RECALL_BATCH',     'Recalled DCL2026R: Mislabelled strength: 75 mg printed as 50 mg',    '2026-10-03 09:07:00'),
 (5, 'RECALL_BATCH',     'Recalled CPF2026K: Particulate contamination found by state drug laboratory', '2026-10-03 09:12:00'),
 (4, 'REGISTER_BATCH',   'PCM2026H with 40 serials',                                           '2026-08-20 11:30:00'),
 (7, 'REGISTER_BATCH',   'MET2026J with 30 serials',                                           '2026-09-01 10:15:00'),
 (1, 'SET_SPEED_LIMIT',  '100 km/h',                                                           '2026-09-01 08:00:00'),
 (5, 'UPDATE_COMPLAINT', 'Complaint #6 -> RESOLVED',                                           '2026-10-10 16:40:00'),
 (1, 'UPDATE_COMPLAINT', 'Complaint #3 -> INVESTIGATING',                                      '2026-10-14 10:00:00'),
 (1, 'UPDATE_COMPLAINT', 'Complaint #4 -> RESOLVED',                                           '2026-10-14 10:05:00');


-- =====================================================================
-- 8. SCHEDULED EVENT: refresh pharmacy risk levels every hour
--    (runs only when the event scheduler is ON:
--     SET GLOBAL event_scheduler = ON;)
-- =====================================================================
CREATE EVENT ev_hourly_risk_refresh
  ON SCHEDULE EVERY 1 HOUR
  DO CALL sp_update_risk_levels();

-- =====================================================================
-- 9. USERS AND PRIVILEGES (DCL) - least privilege
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

-- Done. Open demo_queries.sql for the live demo and analysis queries.
