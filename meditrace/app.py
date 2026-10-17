"""
MediTrace: Counterfeit Medicine Detection System
Flask web app for BCSE302L Database Systems - Digital Assignment II

The app never decides a verdict. It only INSERTs a scan; the MySQL
trigger trg_verify_scan runs every fraud check inside the database.

Run:  python app.py      then open  http://127.0.0.1:5000
Demo logins:  admin / admin123   chennai / pharma123
              delhi / pharma123  medilife / mfg123
"""
import csv
import io
import os
import time
from datetime import date, datetime, timedelta
from decimal import Decimal
from functools import wraps

import mysql.connector
from mysql.connector import pooling
from flask import (Flask, Response, flash, g, redirect, render_template, request,
                   session, url_for)

# ---- CHANGE THIS to your MySQL Workbench password ----
DB_CONFIG = {
    "host": os.environ.get("DB_HOST", "127.0.0.1"),   # 127.0.0.1, not localhost: avoids a slow IPv6 lookup on Windows
    "user": os.environ.get("DB_USER", "root"),
    "password": os.environ.get("DB_PASSWORD", "Havepr_2006"),
    "database": "meditrace",
}

app = Flask(__name__)
app.secret_key = "meditrace-da2-secret"
app.config["SEND_FILE_MAX_AGE_DEFAULT"] = 3600   # browser caches CSS/JS/fonts for an hour

VERDICTS = ["GENUINE", "COUNTERFEIT", "CLONED", "SUSPICIOUS", "RECALLED", "EXPIRED"]


# =====================================================================
# Database helpers
# =====================================================================
_pool = None


def db():
    """Connections come from a pool that stays open, so pages never wait for a new
    MySQL handshake. One pooled connection is used per page request."""
    global _pool
    if "db" not in g:
        if _pool is None:
            _pool = pooling.MySQLConnectionPool(pool_name="meditrace", pool_size=10,
                                                autocommit=True, **DB_CONFIG)
        g.db = _pool.get_connection()
    return g.db


@app.before_request
def start_timer():
    g.t0 = time.perf_counter()
    g.nq = 0


@app.teardown_appcontext
def close_db(exc):
    conn = g.pop("db", None)
    if conn is not None:
        conn.close()          # returns the connection to the pool


@app.context_processor
def page_stats():
    return {"page_ms": lambda: round((time.perf_counter() - g.get("t0", time.perf_counter())) * 1000),
            "page_queries": lambda: g.get("nq", 0)}


def q(sql, params=(), one=False):
    """SELECT -> list of dicts (or one dict)."""
    g.nq = g.get("nq", 0) + 1
    cur = db().cursor(dictionary=True, buffered=True)
    try:
        cur.execute(sql, params)
        rows = cur.fetchall()
    finally:
        cur.close()
    if one:
        return rows[0] if rows else None
    return rows


def run(sql, params=()):
    """INSERT / UPDATE / CALL without result sets -> last insert id."""
    g.nq = g.get("nq", 0) + 1
    cur = db().cursor(buffered=True)
    try:
        cur.execute(sql, params)
        return cur.lastrowid
    finally:
        cur.close()


def plain(rows):
    """Make rows safe for JSON (charts / maps)."""
    def conv(v):
        if isinstance(v, Decimal):
            return float(v)
        if isinstance(v, (datetime, date)):
            return v.isoformat()
        return v
    if isinstance(rows, dict):
        return {k: conv(v) for k, v in rows.items()}
    return [{k: conv(v) for k, v in r.items()} for r in rows]


def log(action, details=""):
    try:
        run("INSERT INTO activity_log (user_id, action, details) VALUES (%s, %s, %s)",
            (session.get("uid"), action, details[:300]))
    except mysql.connector.Error:
        pass


# =====================================================================
# Auth
# =====================================================================
HOME = {"REGULATOR": "overview", "PHARMACIST": "scan", "MANUFACTURER": "batches"}


def login_required(*roles):
    def deco(view):
        @wraps(view)
        def wrapper(*args, **kwargs):
            if "uid" not in session:
                return redirect(url_for("login", next=request.path))
            if roles and session.get("role") not in roles:
                flash("Your role does not have access to that page.", "warning")
                return redirect(url_for("home"))
            return view(*args, **kwargs)
        return wrapper
    return deco


NAV = [
    ("Operations", [
        ("overview", "Overview", "bi-grid-1x2", ("REGULATOR",)),
        ("scan", "Scan strip", "bi-upc-scan", ("REGULATOR", "PHARMACIST")),
        ("trace", "Trace", "bi-signpost-split", ("REGULATOR", "PHARMACIST", "MANUFACTURER")),
        ("alerts", "Alerts", "bi-bell", ("REGULATOR", "PHARMACIST")),
    ]),
    ("Supply chain", [
        ("batches", "Batches", "bi-box-seam", ("REGULATOR", "MANUFACTURER")),
        ("medicines", "Medicines", "bi-capsule", ("REGULATOR", "MANUFACTURER")),
        ("pharmacies", "Pharmacies", "bi-shop", ("REGULATOR",)),
    ]),
    ("Public", [
        ("complaints", "Complaints", "bi-chat-left-text", ("REGULATOR",)),
        ("verify", "Patient portal", "bi-patch-check", ("REGULATOR", "PHARMACIST", "MANUFACTURER")),
    ]),
    ("Database", [
        ("querylab", "Query Lab", "bi-terminal", ("REGULATOR",)),
        ("audit", "Audit trail", "bi-journal-text", ("REGULATOR",)),
        ("system", "System", "bi-cpu", ("REGULATOR",)),
    ]),
]


@app.context_processor
def inject_globals():
    ctx = {"nav": NAV, "user": None, "open_alerts": 0, "bell": [], "open_complaints": 0}
    if "uid" in session:
        ctx["user"] = {"name": session["name"], "role": session["role"],
                       "initials": "".join(p[0] for p in session["name"].split()[:2]).upper()}
        try:
            if session["role"] == "MANUFACTURER":
                return ctx   # manufacturers do not see pharmacy alerts
            where, params = "", ()
            if session["role"] == "PHARMACIST":
                where, params = "AND a.pharmacy_id = %s", (session["pharmacy_id"],)
            ctx["open_alerts"] = q(f"SELECT COUNT(*) AS n FROM alert a WHERE a.is_resolved = FALSE {where}",
                                   params, one=True)["n"]
            ctx["bell"] = q(f"""SELECT a.alert_id, a.severity, a.message, a.created_at, p.city
                                  FROM alert a JOIN pharmacy p ON p.pharmacy_id = a.pharmacy_id
                                 WHERE a.is_resolved = FALSE {where}
                                 ORDER BY a.created_at DESC LIMIT 5""", params)
            ctx["open_complaints"] = q("SELECT COUNT(*) AS n FROM complaint WHERE status IN ('OPEN','INVESTIGATING')",
                                       one=True)["n"]
        except mysql.connector.Error:
            pass
    return ctx


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        user = q("""SELECT * FROM app_user
                     WHERE username = %s AND password_hash = SHA2(%s, 256)""",
                 (request.form["username"].strip(), request.form["password"]), one=True)
        if not user:
            flash("Wrong username or password.", "danger")
            return redirect(url_for("login"))
        session.clear()
        session.update(uid=user["user_id"], name=user["full_name"], role=user["role"],
                       username=user["username"], pharmacy_id=user["pharmacy_id"],
                       manufacturer_id=user["manufacturer_id"])
        run("UPDATE app_user SET last_login = NOW() WHERE user_id = %s", (user["user_id"],))
        log("LOGIN", f"{user['username']} signed in")
        nxt = request.args.get("next")
        return redirect(nxt if nxt and nxt.startswith("/") else url_for("home"))
    stats = q("SELECT * FROM v_summary", one=True)
    return render_template("login.html", stats=stats)


@app.route("/logout")
def logout():
    log("LOGOUT", session.get("username", ""))
    session.clear()
    return redirect(url_for("login"))


@app.route("/")
def home():
    if "uid" not in session:
        return redirect(url_for("login"))
    return redirect(url_for(HOME[session["role"]]))


# =====================================================================
# Overview (regulator dashboard)
# =====================================================================
@app.route("/overview")
@login_required("REGULATOR")
def overview():
    run("CALL sp_update_risk_levels()")   # cursor-based procedure refreshes risk levels
    s = q("SELECT * FROM v_summary", one=True)
    total = s["total_scans"] or 0
    fraud = (s["counterfeit"] or 0) + (s["cloned"] or 0) + (s["suspicious"] or 0)
    unsafe = (s["recalled"] or 0) + (s["expired"] or 0)
    kpis = {
        "total": total,
        "genuine_rate": round(100 * (s["genuine"] or 0) / total, 1) if total else 0,
        "fraud": fraud, "unsafe": unsafe,
        "checks": q("SELECT COUNT(*) AS n FROM patient_check", one=True)["n"],
        "serials": q("SELECT COUNT(*) AS n FROM serial_registry", one=True)["n"],
    }
    return render_template(
        "overview.html", s=s, kpis=kpis,
        trend=plain(q("SELECT * FROM v_daily_trend ORDER BY scan_date")),
        cities=plain(q("SELECT * FROM v_city_hotspots ORDER BY fraud_rank, city")),
        pharmacies=plain(q("""SELECT r.*, p.latitude, p.longitude FROM v_pharmacy_risk r
                               JOIN pharmacy p ON p.pharmacy_id = r.pharmacy_id""")),
        anomalies=plain(q("SELECT * FROM v_travel_anomalies")),
        recent=q("""SELECT s.scan_id, s.serial_no, p.city, s.scan_time, s.verdict
                      FROM scan_log s JOIN pharmacy p ON p.pharmacy_id = s.pharmacy_id
                     ORDER BY s.scan_id DESC LIMIT 7"""),
        alerts=q("""SELECT * FROM v_open_alerts
                     ORDER BY FIELD(severity,'CRITICAL','HIGH','MEDIUM'), created_at DESC LIMIT 6"""),
        brands=q("SELECT * FROM v_manufacturer_impact ORDER BY copy_incidents DESC LIMIT 5"),
        sev=q("""SELECT severity, COUNT(*) AS n FROM alert WHERE is_resolved = FALSE
                  GROUP BY severity"""),
    )


# =====================================================================
# Scan
# =====================================================================
CHECKS = [
    ("Registered by a manufacturer", "serial exists in serial_registry", "COUNTERFEIT"),
    ("Possible travel time", "distance / hours <= speed limit", "SUSPICIOUS"),
    ("Not sold before", "status is still UNSOLD", "CLONED"),
    ("Batch not recalled", "batch.is_recalled = FALSE", "RECALLED"),
    ("Within expiry date", "scan date <= expiry_date", "EXPIRED"),
]


def check_states(verdict):
    """pass / fail / skip for each of the 5 trigger checks."""
    fail_at = next((i for i, c in enumerate(CHECKS) if c[2] == verdict), None)
    out = []
    for i, (name, desc, _) in enumerate(CHECKS):
        state = "pass" if fail_at is None or i < fail_at else ("fail" if i == fail_at else "skip")
        out.append({"name": name, "desc": desc, "state": state})
    return out


def do_scan(serial, pharmacy_id, scan_time):
    scan_id = run("""INSERT INTO scan_log (serial_no, pharmacy_id, scan_time, scanned_by)
                     VALUES (%s, %s, %s, %s)""",
                  (serial.strip().upper(), pharmacy_id, scan_time, session.get("uid")))
    return q("""SELECT s.*, p.name AS pharmacy, p.city
                  FROM scan_log s JOIN pharmacy p ON p.pharmacy_id = s.pharmacy_id
                 WHERE s.scan_id = %s""", (scan_id,), one=True)


@app.route("/scan", methods=["GET", "POST"])
@login_required("REGULATOR", "PHARMACIST")
def scan():
    result = checks = prev = None
    bulk = None
    fixed = session["role"] == "PHARMACIST"
    if request.method == "POST":
        pharmacy_id = session["pharmacy_id"] if fixed else int(request.form["pharmacy_id"])
        raw = request.form.get("scan_time")
        base_time = datetime.strptime(raw, "%Y-%m-%dT%H:%M") if raw else datetime.now().replace(microsecond=0)
        if request.form.get("mode") == "bulk":
            serials = [s.strip() for s in request.form.get("serials", "").splitlines() if s.strip()][:200]
            bulk = [do_scan(s, pharmacy_id, base_time + timedelta(minutes=i)) for i, s in enumerate(serials)]
            log("BULK_SCAN", f"{len(bulk)} strips at pharmacy {pharmacy_id}")
        else:
            t0 = time.perf_counter()
            result = do_scan(request.form["serial_no"], pharmacy_id, base_time)
            result["ms"] = round((time.perf_counter() - t0) * 1000, 1)
            checks = check_states(result["verdict"])
            prev = q("""SELECT * FROM v_scan_journey WHERE serial_no = %s AND scan_id < %s
                         ORDER BY scan_seq DESC LIMIT 1""", (result["serial_no"], result["scan_id"]), one=True)
            log("SCAN", f"{result['serial_no']} -> {result['verdict']}")

    where, params = "", ()
    if fixed:
        where, params = "WHERE s.pharmacy_id = %s", (session["pharmacy_id"],)
    recent = q(f"""SELECT s.scan_id, s.serial_no, p.city, s.scan_time, s.verdict
                     FROM scan_log s JOIN pharmacy p ON p.pharmacy_id = s.pharmacy_id {where}
                    ORDER BY s.scan_id DESC LIMIT 8""", params)
    mix = q(f"""SELECT verdict, COUNT(*) AS n FROM scan_log s {where} GROUP BY verdict""", params)
    pharmacies = q("SELECT pharmacy_id, name, city FROM pharmacy ORDER BY city")
    my_pharmacy = q("SELECT * FROM pharmacy WHERE pharmacy_id = %s", (session["pharmacy_id"],), one=True) if fixed else None
    limit = q("SELECT setting_value FROM settings WHERE setting_key = 'max_speed_kmph'", one=True)["setting_value"]
    return render_template("scan.html", result=result, checks=checks, prev=prev, bulk=bulk,
                           recent=recent, mix={r["verdict"]: r["n"] for r in mix},
                           pharmacies=pharmacies, fixed=fixed, my_pharmacy=my_pharmacy,
                           limit=limit, sample=["PCM2026A-00001", "PCM2026A-55555", "MET2026C-00001",
                                                "AMX2024X-00003", "ATV2026D-00004", "AZI2026E-00005"])


# =====================================================================
# Trace
# =====================================================================
@app.route("/trace")
@login_required()
def trace():
    serial = request.args.get("serial", "").strip().upper()
    data = {}
    if serial:
        data["details"] = q("""SELECT sr.serial_no, m.name AS medicine, m.category, m.mrp, mf.name AS manufacturer,
                                      b.batch_no, b.mfg_date, b.expiry_date, b.is_recalled, b.recall_reason,
                                      sr.status, sr.sold_at, fn_serial_status(sr.serial_no) AS state
                                 FROM serial_registry sr
                                 JOIN batch b ON b.batch_id = sr.batch_id
                                 JOIN medicine m ON m.medicine_id = b.medicine_id
                                 JOIN manufacturer mf ON mf.manufacturer_id = m.manufacturer_id
                                WHERE sr.serial_no = %s""", (serial,), one=True)
        data["journey"] = plain(q("""SELECT j.*, p.latitude, p.longitude
                                       FROM v_scan_journey j JOIN scan_log s ON s.scan_id = j.scan_id
                                       JOIN pharmacy p ON p.pharmacy_id = s.pharmacy_id
                                      WHERE j.serial_no = %s ORDER BY j.scan_seq""", (serial,)))
        data["audit"] = q("SELECT * FROM serial_audit WHERE serial_no = %s ORDER BY audit_id", (serial,))
        data["checks"] = q("SELECT * FROM patient_check WHERE serial_no = %s ORDER BY checked_at DESC", (serial,))
        data["complaints"] = q("SELECT * FROM v_complaints WHERE serial_no = %s", (serial,))
    examples = ["PCM2026A-00001", "AZI2026E-00003", "ATV2026D-00002", "MET2026C-00005", "PCM2026A-99999"]
    return render_template("trace.html", serial=serial, examples=examples, **data)


# =====================================================================
# Alerts
# =====================================================================
def alert_filter():
    sev = request.args.get("severity", "")
    status = request.args.get("status", "open")
    search = request.args.get("q", "").strip()
    conds, params = [], []
    if session["role"] == "PHARMACIST":
        conds.append("a.pharmacy_id = %s"); params.append(session["pharmacy_id"])
    if sev:
        conds.append("a.severity = %s"); params.append(sev)
    if status == "open":
        conds.append("a.is_resolved = FALSE")
    elif status == "resolved":
        conds.append("a.is_resolved = TRUE")
    if search:
        conds.append("(a.message LIKE %s OR p.city LIKE %s OR p.name LIKE %s)"); params += [f"%{search}%"] * 3
    where = ("WHERE " + " AND ".join(conds)) if conds else ""
    rows = q(f"""SELECT a.*, p.name AS pharmacy, p.city, u.full_name AS resolved_by_name FROM alert a
                   JOIN pharmacy p ON p.pharmacy_id = a.pharmacy_id
                   LEFT JOIN app_user u ON u.user_id = a.resolved_by {where}
                  ORDER BY a.is_resolved, FIELD(a.severity,'CRITICAL','HIGH','MEDIUM'), a.created_at DESC""",
             tuple(params))
    return rows, {"severity": sev, "status": status, "q": search}


@app.route("/alerts")
@login_required("REGULATOR", "PHARMACIST")
def alerts():
    rows, f = alert_filter()
    counts = {r["severity"]: r["n"] for r in q(
        "SELECT severity, COUNT(*) AS n FROM alert WHERE is_resolved = FALSE GROUP BY severity")}
    return render_template("alerts.html", rows=rows, f=f, counts=counts)


@app.route("/alerts/<int:alert_id>/resolve", methods=["POST"])
@login_required("REGULATOR", "PHARMACIST")
def resolve_alert(alert_id):
    action = request.form.get("action_taken", "").strip()
    try:
        run("CALL sp_resolve_alert(%s, %s, %s)", (alert_id, action, session["uid"]))
        log("RESOLVE_ALERT", f"Alert #{alert_id}: {action}")
        flash(f"Alert #{alert_id} resolved: {action}", "success")
    except mysql.connector.Error as e:
        flash(f"Database refused this: {e.msg}", "danger")
    return redirect(request.referrer or url_for("alerts"))


@app.route("/alerts.csv")
@login_required("REGULATOR", "PHARMACIST")
def alerts_csv():
    rows, _ = alert_filter()
    return csv_response(rows, "meditrace_alerts.csv")


def csv_response(rows, filename):
    buf = io.StringIO()
    if rows:
        w = csv.DictWriter(buf, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    return Response(buf.getvalue(), mimetype="text/csv",
                    headers={"Content-Disposition": f"attachment; filename={filename}"})


@app.route("/scans.csv")
@login_required("REGULATOR")
def scans_csv():
    return csv_response(q("""SELECT s.scan_id, s.serial_no, p.name AS pharmacy, p.city, s.scan_time,
                                    s.verdict, s.reason, s.distance_km, s.speed_kmph
                               FROM scan_log s JOIN pharmacy p ON p.pharmacy_id = s.pharmacy_id
                              ORDER BY s.scan_id"""), "meditrace_scans.csv")


# =====================================================================
# Complaints
# =====================================================================
@app.route("/complaints", methods=["GET", "POST"])
@login_required("REGULATOR")
def complaints():
    if request.method == "POST":
        cid = int(request.form["complaint_id"])
        status = request.form["status"]
        try:
            run("CALL sp_update_complaint(%s, %s, %s, %s)",
                (cid, status, request.form.get("resolution", "").strip(), session["uid"]))
            log("UPDATE_COMPLAINT", f"Complaint #{cid} -> {status}")
            flash(f"Complaint #{cid} moved to {status}.", "success")
        except mysql.connector.Error as e:
            flash(f"Database refused this: {e.msg}", "danger")
        return redirect(url_for("complaints"))
    rows = q("SELECT * FROM v_complaints ORDER BY FIELD(priority,'URGENT','HIGH','NORMAL'), created_at DESC")
    cols = {s: [r for r in rows if r["status"] == s] for s in ["OPEN", "INVESTIGATING", "RESOLVED", "REJECTED"]}
    return render_template("complaints.html", cols=cols, total=len(rows))


# =====================================================================
# Patient portal (public, no login)
# =====================================================================
STATE_INFO = {
    "UNSOLD_GENUINE": ("Genuine strip", "This serial is registered by its manufacturer and has not been sold yet.", "GENUINE", "bi-patch-check-fill"),
    "SOLD_GENUINE": ("Genuine strip", "This serial is registered and was sold once through a pharmacy. No copies have been detected.", "GENUINE", "bi-patch-check-fill"),
    "NOT_REGISTERED": ("Do not use: not registered", "No manufacturer ever made a strip with this serial. It is very likely counterfeit. Please report it below.", "COUNTERFEIT", "bi-x-octagon-fill"),
    "COPIES_DETECTED": ("Warning: copies detected", "This genuine serial has been scanned in more than one place. Some strips carrying it are fake copies.", "SUSPICIOUS", "bi-exclamation-triangle-fill"),
    "RECALLED": ("Do not use: batch recalled", "The manufacturer has recalled this batch. Return it to the pharmacy.", "RECALLED", "bi-arrow-counterclockwise"),
    "EXPIRED": ("Do not use: expired", "This strip is past its expiry date.", "EXPIRED", "bi-hourglass-bottom"),
}


@app.route("/verify", methods=["GET", "POST"])
def verify():
    result = None
    serial = (request.values.get("serial") or "").strip().upper()
    city = (request.values.get("city") or "").strip()
    if serial:
        state = q("SELECT fn_serial_status(%s) AS s", (serial,), one=True)["s"]
        run("INSERT INTO patient_check (serial_no, city, result) VALUES (%s, %s, %s)", (serial, city or None, state))
        details = q("""SELECT m.name AS medicine, mf.name AS manufacturer, b.batch_no, b.mfg_date, b.expiry_date,
                              b.recall_reason, sr.status
                         FROM serial_registry sr JOIN batch b ON b.batch_id = sr.batch_id
                         JOIN medicine m ON m.medicine_id = b.medicine_id
                         JOIN manufacturer mf ON mf.manufacturer_id = m.manufacturer_id
                        WHERE sr.serial_no = %s""", (serial,), one=True)
        title, text, tone, icon = STATE_INFO[state]
        result = {"state": state, "title": title, "text": text, "tone": tone, "icon": icon, "details": details,
                  "checked": q("SELECT COUNT(*) AS n FROM patient_check WHERE serial_no = %s", (serial,), one=True)["n"]}
    stats = q("""SELECT COUNT(*) AS checks, SUM(result IN ('NOT_REGISTERED','COPIES_DETECTED')) AS fakes,
                        COUNT(DISTINCT city) AS cities FROM patient_check""", one=True)
    return render_template("verify.html", serial=serial, city=city, result=result, stats=stats)


@app.route("/verify/complaint", methods=["POST"])
def file_complaint():
    f = request.form
    try:
        cid = run("""INSERT INTO complaint (serial_no, reporter_name, reporter_phone, city, description)
                     VALUES (%s, %s, %s, %s, %s)""",
                  (f["serial"], f["name"].strip(), f.get("phone", "").strip() or None,
                   f["city"].strip(), f["description"].strip()))
        pr = q("SELECT priority FROM complaint WHERE complaint_id = %s", (cid,), one=True)["priority"]
        flash(f"Complaint #{cid} filed. The database marked it {pr} priority. A drug control officer will review it.", "success")
    except mysql.connector.Error as e:
        flash(f"Could not file complaint: {e.msg}", "danger")
    return redirect(url_for("verify", serial=f["serial"], city=f.get("city", "")))


# =====================================================================
# Batches + QR labels
# =====================================================================
@app.route("/batches", methods=["GET", "POST"])
@login_required("REGULATOR", "MANUFACTURER")
def batches():
    mid = session.get("manufacturer_id")
    if request.method == "POST":
        action = request.form.get("action")
        try:
            batch_no = request.form["batch_no"].strip().upper()
            if action == "register":
                run("CALL sp_register_batch(%s, %s, %s, %s, %s)",
                    (int(request.form["medicine_id"]), batch_no, request.form["mfg_date"],
                     request.form["expiry_date"], int(request.form["count"])))
                log("REGISTER_BATCH", f"{batch_no} with {request.form['count']} serials")
                flash(f"Batch {batch_no} registered with {request.form['count']} serials ({batch_no}-00001 onwards).", "success")
            elif action == "recall":
                run("CALL sp_recall_batch(%s, %s)", (batch_no, request.form["reason"].strip()))
                log("RECALL_BATCH", f"{batch_no}: {request.form['reason'].strip()}")
                flash(f"Batch {batch_no} recalled. Every future scan of it will be flagged RECALLED.", "warning")
        except mysql.connector.Error as e:
            flash(f"Database refused this: {e.msg}", "danger")
        return redirect(url_for("batches"))

    mf_where, params = ("WHERE mf.manufacturer_id = %s", (mid,)) if mid else ("", ())
    medicines = q(f"""SELECT m.medicine_id, m.name, mf.name AS manufacturer FROM medicine m
                        JOIN manufacturer mf ON mf.manufacturer_id = m.manufacturer_id {mf_where}
                       ORDER BY m.name""", params)
    bwhere = ("WHERE manufacturer = (SELECT name FROM manufacturer WHERE manufacturer_id = %s)", (mid,)) if mid else ("", ())
    rows = q(f"SELECT * FROM v_batch_status {bwhere[0]} ORDER BY batch_id DESC", bwhere[1])
    states = {}
    for r in rows:
        states[r["batch_state"]] = states.get(r["batch_state"], 0) + 1
    return render_template("batches.html", medicines=medicines, batches=rows, states=states)


@app.route("/batches/<batch_no>/labels")
@login_required("REGULATOR", "MANUFACTURER")
def labels(batch_no):
    b = q("SELECT * FROM v_batch_status WHERE batch_no = %s", (batch_no.upper(),), one=True)
    if not b:
        flash("No such batch.", "warning")
        return redirect(url_for("batches"))
    serials = q("""SELECT sr.serial_no, sr.status FROM serial_registry sr JOIN batch bt ON bt.batch_id = sr.batch_id
                    WHERE bt.batch_no = %s ORDER BY sr.serial_no LIMIT 60""", (batch_no.upper(),))
    return render_template("labels.html", b=b, serials=serials)


# =====================================================================
# Medicines
# =====================================================================
CATEGORY_ICON = {"ANALGESIC": "bi-bandaid", "ANTIBIOTIC": "bi-virus", "ANTIDIABETIC": "bi-droplet-half",
                 "CARDIAC": "bi-heart-pulse", "ANTIALLERGIC": "bi-flower1", "ANTIVIRAL": "bi-shield-plus",
                 "ANTACID": "bi-cup-hot", "VITAMIN": "bi-sun", "RESPIRATORY": "bi-wind", "NEURO": "bi-activity",
                 "HORMONE": "bi-thermometer-half", "OTHER": "bi-capsule"}


@app.route("/medicines", methods=["GET", "POST"])
@login_required("REGULATOR", "MANUFACTURER")
def medicines():
    mid = session.get("manufacturer_id")
    if request.method == "POST":
        f = request.form
        try:
            run("""INSERT INTO medicine (manufacturer_id, name, composition, category, mrp, needs_prescription)
                   VALUES (%s, %s, %s, %s, %s, %s)""",
                (mid or int(f["manufacturer_id"]), f["name"].strip(), f["composition"].strip(), f["category"],
                 f["mrp"], 1 if f.get("needs_prescription") else 0))
            log("ADD_MEDICINE", f["name"].strip())
            flash(f"{f['name'].strip()} added to the catalogue.", "success")
        except mysql.connector.Error as e:
            flash(f"Database refused this: {e.msg}", "danger")
        return redirect(url_for("medicines"))
    where, params = ("WHERE manufacturer_id = %s", (mid,)) if mid else ("", ())
    rows = q(f"SELECT * FROM v_medicine_catalogue {where} ORDER BY name", params)
    makers = q("SELECT manufacturer_id, name FROM manufacturer ORDER BY name")
    return render_template("medicines.html", rows=rows, makers=makers, icons=CATEGORY_ICON,
                           categories=list(CATEGORY_ICON))


# =====================================================================
# Pharmacies
# =====================================================================
@app.route("/pharmacies", methods=["GET", "POST"])
@login_required("REGULATOR")
def pharmacies():
    if request.method == "POST":
        f = request.form
        try:
            run("""INSERT INTO pharmacy (name, license_no, city, latitude, longitude)
                   VALUES (%s, %s, %s, %s, %s)""",
                (f["name"].strip(), f["license_no"].strip().upper(), f["city"].strip(), f["latitude"], f["longitude"]))
            log("ADD_PHARMACY", f["name"].strip())
            flash(f"{f['name'].strip()} added.", "success")
        except mysql.connector.Error as e:
            flash(f"Database refused this: {e.msg}", "danger")
        return redirect(url_for("pharmacies"))
    run("CALL sp_update_risk_levels()")
    rows = plain(q("""SELECT r.*, p.latitude, p.longitude,
                             (SELECT MAX(scan_time) FROM scan_log s WHERE s.pharmacy_id = p.pharmacy_id) AS last_scan
                        FROM v_pharmacy_risk r JOIN pharmacy p ON p.pharmacy_id = r.pharmacy_id
                       ORDER BY r.risk_pct DESC, r.total_scans DESC"""))
    return render_template("pharmacies.html", rows=rows)


# =====================================================================
# Query Lab: predefined analysis queries, shown with their SQL
# =====================================================================
QUERIES = [
    ("hotspots", "Fraud hotspots ranked", "View + RANK() window",
     "SELECT * FROM v_city_hotspots ORDER BY fraud_rank, city"),
    ("multi_city", "Serials seen in more than one city", "GROUP BY + HAVING",
     """SELECT s.serial_no, COUNT(*) AS times_scanned, COUNT(DISTINCT p.city) AS cities,
       GROUP_CONCAT(DISTINCT p.city ORDER BY p.city SEPARATOR ', ') AS city_list
  FROM scan_log s
  JOIN pharmacy p ON p.pharmacy_id = s.pharmacy_id
 GROUP BY s.serial_no
HAVING COUNT(DISTINCT p.city) > 1"""),
    ("above_avg", "Pharmacies above the average flag count", "Nested subquery in HAVING",
     """SELECT p.name, p.city, COUNT(*) AS flagged
  FROM scan_log s
  JOIN pharmacy p ON p.pharmacy_id = s.pharmacy_id
 WHERE s.verdict <> 'GENUINE'
 GROUP BY p.pharmacy_id, p.name, p.city
HAVING COUNT(*) > (SELECT AVG(cnt) FROM (SELECT COUNT(*) AS cnt FROM scan_log
                    WHERE verdict <> 'GENUINE' GROUP BY pharmacy_id) AS per_pharmacy)"""),
    ("trend", "Daily fraud with running total", "CTE + SUM() OVER",
     """WITH daily AS (
  SELECT DATE(scan_time) AS scan_date,
         SUM(verdict IN ('COUNTERFEIT','CLONED','SUSPICIOUS')) AS fraud_today
    FROM scan_log
   GROUP BY DATE(scan_time)
)
SELECT scan_date, fraud_today,
       SUM(fraud_today) OVER (ORDER BY scan_date) AS fraud_running_total
  FROM daily
 ORDER BY scan_date"""),
    ("unsafe", "Unsafe stock still unsold", "Multi-table JOIN + filter",
     """SELECT b.batch_no, m.name AS medicine, b.expiry_date, b.is_recalled, COUNT(*) AS unsold_strips
  FROM serial_registry sr
  JOIN batch b    ON b.batch_id = sr.batch_id
  JOIN medicine m ON m.medicine_id = b.medicine_id
 WHERE sr.status = 'UNSOLD'
   AND (b.is_recalled = TRUE OR b.expiry_date < CURDATE())
 GROUP BY b.batch_no, m.name, b.expiry_date, b.is_recalled"""),
    ("never_sold", "Medicines never sold", "NOT EXISTS",
     """SELECT m.name, mf.name AS manufacturer
  FROM medicine m
  JOIN manufacturer mf ON mf.manufacturer_id = m.manufacturer_id
 WHERE NOT EXISTS (SELECT 1 FROM batch b
                     JOIN serial_registry sr ON sr.batch_id = b.batch_id
                    WHERE b.medicine_id = m.medicine_id AND sr.status = 'SOLD')"""),
    ("latest", "Each pharmacy's latest scan", "Correlated subquery",
     """SELECT p.name, p.city, s.serial_no, s.scan_time, s.verdict
  FROM pharmacy p
  JOIN scan_log s ON s.pharmacy_id = p.pharmacy_id
 WHERE s.scan_time = (SELECT MAX(s2.scan_time) FROM scan_log s2
                       WHERE s2.pharmacy_id = p.pharmacy_id)
 ORDER BY s.scan_time DESC"""),
    ("distances", "Longest pharmacy-to-pharmacy distances", "Self-join + stored function",
     """SELECT a.city AS from_city, b.city AS to_city,
       ROUND(haversine_km(a.latitude, a.longitude, b.latitude, b.longitude)) AS km,
       ROUND(haversine_km(a.latitude, a.longitude, b.latitude, b.longitude) / 100, 1) AS min_hours_at_100kmph
  FROM pharmacy a
  JOIN pharmacy b ON a.pharmacy_id < b.pharmacy_id
 ORDER BY km DESC
 LIMIT 10"""),
    ("routes", "Impossible-travel routes", "Derived table + LAG()",
     "SELECT serial_no, scan_time, from_city, to_city, distance_km, speed_kmph FROM v_travel_anomalies"),
    ("brands", "Most-copied brands", "5-table JOIN view",
     "SELECT * FROM v_manufacturer_impact ORDER BY copy_incidents DESC"),
    ("catalogue", "Medicine catalogue with stock", "LEFT JOIN + aggregate + scalar subquery",
     "SELECT name, manufacturer, category, mrp, batches, serials, sold, copy_incidents FROM v_medicine_catalogue"),
    ("patient", "What patients found", "GROUP BY on public checks",
     """SELECT result, COUNT(*) AS checks, COUNT(DISTINCT serial_no) AS serials,
       GROUP_CONCAT(DISTINCT city SEPARATOR ', ') AS cities
  FROM patient_check
 GROUP BY result
 ORDER BY checks DESC"""),
    ("complaints", "Complaint queue by priority", "View using a stored function",
     """SELECT priority, status, COUNT(*) AS complaints
  FROM v_complaints
 GROUP BY priority, status
 ORDER BY FIELD(priority, 'URGENT', 'HIGH', 'NORMAL'), status"""),
    ("explain", "Index used by the trigger", "EXPLAIN",
     """EXPLAIN SELECT scan_time FROM scan_log
 WHERE serial_no = 'PCM2026A-00001' AND scan_time <= '2026-10-15 23:59:59'
 ORDER BY scan_time DESC LIMIT 1"""),
]

SQL_KEYWORDS = ["SELECT", "FROM", "JOIN", "LEFT JOIN", "WHERE", "GROUP BY", "HAVING", "ORDER BY", "LIMIT",
                "WITH", "AS", "ON", "AND", "OR", "NOT EXISTS", "OVER", "EXPLAIN", "COUNT", "SUM", "AVG", "MAX",
                "DISTINCT", "IN", "ROUND", "GROUP_CONCAT", "SEPARATOR", "DESC"]


@app.route("/querylab")
@login_required("REGULATOR")
def querylab():
    key = request.args.get("q", QUERIES[0][0])
    item = next((x for x in QUERIES if x[0] == key), QUERIES[0])
    t0 = time.perf_counter()
    try:
        rows, error = q(item[3]), None
    except mysql.connector.Error as e:
        rows, error = [], e.msg
    ms = round((time.perf_counter() - t0) * 1000, 1)
    return render_template("querylab.html", queries=QUERIES, item=item, rows=rows, error=error, ms=ms)


# =====================================================================
# Audit + System
# =====================================================================
@app.route("/audit")
@login_required("REGULATOR")
def audit():
    return render_template(
        "audit.html",
        activity=q("""SELECT l.*, u.full_name, u.role FROM activity_log l
                        LEFT JOIN app_user u ON u.user_id = l.user_id ORDER BY l.log_id DESC LIMIT 100"""),
        serial_audit=q("SELECT * FROM serial_audit ORDER BY audit_id DESC LIMIT 100"),
        checks=q("SELECT * FROM patient_check ORDER BY checked_at DESC LIMIT 100"),
        users=q("SELECT user_id, username, full_name, role, last_login, created_at FROM app_user ORDER BY user_id"),
    )


@app.route("/system", methods=["GET", "POST"])
@login_required("REGULATOR")
def system():
    if request.method == "POST":
        try:
            run("CALL sp_set_speed_limit(%s)", (request.form["max_speed"],))
            log("SET_SPEED_LIMIT", f"{request.form['max_speed']} km/h")
            flash(f"Speed limit set to {request.form['max_speed']} km/h. The trigger uses it from the next scan.", "success")
        except mysql.connector.Error as e:
            flash(f"Database refused this: {e.msg}", "danger")
        return redirect(url_for("system"))
    db = DB_CONFIG["database"]
    tables = q("""SELECT TABLE_NAME AS name FROM information_schema.TABLES
                   WHERE TABLE_SCHEMA = %s AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME""", (db,))
    for t in tables:
        t["rows"] = q(f"SELECT COUNT(*) AS n FROM `{t['name']}`", one=True)["n"]
    return render_template(
        "system.html",
        settings=q("SELECT * FROM settings"),
        tables=tables,
        triggers=q("""SELECT TRIGGER_NAME AS name, ACTION_TIMING AS timing, EVENT_MANIPULATION AS event,
                             EVENT_OBJECT_TABLE AS tbl FROM information_schema.TRIGGERS
                       WHERE TRIGGER_SCHEMA = %s ORDER BY EVENT_OBJECT_TABLE, ACTION_TIMING""", (db,)),
        routines=q("""SELECT ROUTINE_NAME AS name, ROUTINE_TYPE AS type FROM information_schema.ROUTINES
                       WHERE ROUTINE_SCHEMA = %s ORDER BY ROUTINE_TYPE, ROUTINE_NAME""", (db,)),
        views=q("""SELECT TABLE_NAME AS name FROM information_schema.VIEWS
                    WHERE TABLE_SCHEMA = %s ORDER BY TABLE_NAME""", (db,)),
        indexes=q("""SELECT TABLE_NAME AS tbl, INDEX_NAME AS name,
                            GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ', ') AS cols,
                            MAX(NON_UNIQUE) AS non_unique
                       FROM information_schema.STATISTICS
                      WHERE TABLE_SCHEMA = %s AND INDEX_NAME <> 'PRIMARY'
                      GROUP BY TABLE_NAME, INDEX_NAME ORDER BY TABLE_NAME, INDEX_NAME""", (db,)),
        events=q("""SELECT EVENT_NAME AS name, INTERVAL_VALUE AS every, INTERVAL_FIELD AS unit, STATUS AS status
                      FROM information_schema.EVENTS WHERE EVENT_SCHEMA = %s""", (db,)),
    )


@app.errorhandler(mysql.connector.Error)
def database_error(e):
    """Friendly page instead of a traceback when the database is not set up."""
    code = getattr(e, "errno", None)
    if code in (1054, 1146, 1049, 1305):
        tip = ("Your MySQL database is older than this app or missing. In MySQL Workbench, open "
               "<b>meditrace.sql</b> from this folder and run the whole script (Query &rarr; Execute All), "
               "then refresh this page.")
    elif code == 1045:
        tip = "MySQL rejected the password. Open <b>app.py</b>, fix the password on line 29, save, and refresh."
    elif code in (2003, 2005):
        tip = "MySQL is not running. Press Win+R, type <b>services.msc</b>, start <b>MySQL80</b>, then refresh."
    else:
        tip = "Check the terminal running <b>python app.py</b> for details."
    html = f"""<!doctype html><html data-bs-theme="dark"><head><meta charset="utf-8"><title>Database problem</title>
      <link rel="stylesheet" href="{url_for('static', filename='vendor/bootstrap/bootstrap.min.css')}">
      <link rel="stylesheet" href="{url_for('static', filename='css/app.css')}"></head>
      <body><div class="container py-5" style="max-width:720px"><div class="panel">
      <h3 class="fw-bold text-danger">Database problem</h3><p class="mono small">MySQL error {code}: {e.msg}</p>
      <p>{tip}</p><a class="btn btn-accent" href="{url_for('home')}">Try again</a></div></div></body></html>"""
    return html, 500


@app.template_filter("dt")
def fmt_dt(v):
    if isinstance(v, str):
        try:
            v = datetime.fromisoformat(v)
        except ValueError:
            return v
    if isinstance(v, datetime):
        return v.strftime("%d %b %Y, %H:%M")
    if isinstance(v, date):
        return v.strftime("%d %b %Y")
    return v or "-"


if __name__ == "__main__":
    app.run(debug=True, threaded=True)
