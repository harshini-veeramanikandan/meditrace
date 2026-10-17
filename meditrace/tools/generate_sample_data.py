"""
MediTrace sample-data generator (section 7 of meditrace.sql).

The dataset is synthetic: manufacturer and pharmacy names are fictional,
medicine compositions are real generic drugs, city coordinates are real.
Scans are simulated with a fixed random seed, so the output is identical
every run. Verdicts are NOT generated here: the MySQL trigger decides them.

Usage:  python generate_sample_data.py > section7.sql
"""
import random
from datetime import datetime, timedelta
from math import radians, sin, cos, asin, sqrt

random.seed(2026)

MANUFACTURERS = [
    ("Medilife Pharma Ltd", "TN-MFG-2019-0412", "Chennai", "quality@medilife.example"),
    ("Arogya Labs Pvt Ltd", "TS-MFG-2017-1188", "Hyderabad", "qa@arogyalabs.example"),
    ("Nirmal Healthcare Ltd", "GJ-MFG-2015-0731", "Ahmedabad", "recall@nirmal.example"),
    ("Sanjeevani Biotech Pvt Ltd", "MH-MFG-2018-2204", "Pune", "qa@sanjeevani.example"),
    ("Kaveri Remedies Ltd", "KA-MFG-2016-0958", "Bengaluru", "quality@kaveri.example"),
    ("Ganga Lifesciences Ltd", "WB-MFG-2014-0377", "Kolkata", "qc@gangalife.example"),
    ("Sahyadri Pharmaceuticals Ltd", "MH-MFG-2012-1630", "Mumbai", "qa@sahyadri.example"),
    ("Vindhya Formulations Pvt Ltd", "MP-MFG-2020-0145", "Indore", "quality@vindhya.example"),
]

# (manufacturer_id, name, composition, category, mrp, rx, code)
MEDICINES = [
    (1, "Paracetamol 500 mg", "Paracetamol IP 500 mg", "ANALGESIC", 25.50, 0, "PCM"),
    (1, "Amoxicillin 250 mg", "Amoxicillin Trihydrate IP 250 mg", "ANTIBIOTIC", 68.00, 1, "AMX"),
    (2, "Metformin 500 mg", "Metformin Hydrochloride IP 500 mg", "ANTIDIABETIC", 42.75, 1, "MET"),
    (2, "Atorvastatin 10 mg", "Atorvastatin Calcium IP 10 mg", "CARDIAC", 96.00, 1, "ATV"),
    (3, "Azithromycin 500 mg", "Azithromycin Dihydrate IP 500 mg", "ANTIBIOTIC", 118.40, 1, "AZI"),
    (3, "Cetirizine 10 mg", "Cetirizine Hydrochloride IP 10 mg", "ANTIALLERGIC", 18.00, 0, "CTZ"),
    (1, "Paracetamol 650 mg", "Paracetamol IP 650 mg", "ANALGESIC", 32.00, 0, "PSX"),
    (4, "Ibuprofen 400 mg", "Ibuprofen IP 400 mg", "ANALGESIC", 28.50, 0, "IBU"),
    (4, "Diclofenac 50 mg", "Diclofenac Sodium IP 50 mg", "ANALGESIC", 24.00, 1, "DCL"),
    (5, "Aceclofenac 100 mg", "Aceclofenac IP 100 mg", "ANALGESIC", 58.00, 1, "ACF"),
    (5, "Amoxicillin + Clavulanate 625 mg", "Amoxicillin 500 mg + Potassium Clavulanate 125 mg", "ANTIBIOTIC", 210.00, 1, "AMC"),
    (6, "Ciprofloxacin 500 mg", "Ciprofloxacin Hydrochloride IP 500 mg", "ANTIBIOTIC", 72.00, 1, "CPF"),
    (6, "Cefixime 200 mg", "Cefixime IP 200 mg", "ANTIBIOTIC", 112.00, 1, "CFX"),
    (7, "Doxycycline 100 mg", "Doxycycline Hyclate IP 100 mg", "ANTIBIOTIC", 64.00, 1, "DOX"),
    (7, "Glimepiride 2 mg", "Glimepiride IP 2 mg", "ANTIDIABETIC", 88.00, 1, "GLM"),
    (8, "Sitagliptin 100 mg", "Sitagliptin Phosphate 100 mg", "ANTIDIABETIC", 245.00, 1, "SIT"),
    (2, "Amlodipine 5 mg", "Amlodipine Besylate IP 5 mg", "CARDIAC", 36.00, 1, "AML"),
    (8, "Telmisartan 40 mg", "Telmisartan IP 40 mg", "CARDIAC", 94.00, 1, "TEL"),
    (5, "Losartan 50 mg", "Losartan Potassium IP 50 mg", "CARDIAC", 61.00, 1, "LOS"),
    (4, "Clopidogrel 75 mg", "Clopidogrel Bisulphate IP 75 mg", "CARDIAC", 118.00, 1, "CLP"),
    (1, "Aspirin 75 mg", "Acetylsalicylic Acid IP 75 mg", "CARDIAC", 12.50, 0, "ASP"),
    (3, "Levocetirizine 5 mg", "Levocetirizine Dihydrochloride IP 5 mg", "ANTIALLERGIC", 42.00, 0, "LCZ"),
    (6, "Montelukast 10 mg", "Montelukast Sodium IP 10 mg", "RESPIRATORY", 155.00, 1, "MTK"),
    (7, "Fexofenadine 120 mg", "Fexofenadine Hydrochloride IP 120 mg", "ANTIALLERGIC", 138.00, 0, "FEX"),
    (8, "Pantoprazole 40 mg", "Pantoprazole Sodium IP 40 mg", "ANTACID", 96.00, 1, "PAN"),
    (5, "Omeprazole 20 mg", "Omeprazole IP 20 mg", "ANTACID", 48.00, 0, "OMP"),
    (4, "Ondansetron 4 mg", "Ondansetron Hydrochloride IP 4 mg", "OTHER", 52.00, 1, "OND"),
    (3, "Vitamin D3 60000 IU", "Cholecalciferol IP 60000 IU", "VITAMIN", 95.00, 0, "VTD"),
    (6, "Iron + Folic Acid", "Ferrous Ascorbate 100 mg + Folic Acid 1.5 mg", "VITAMIN", 120.00, 0, "IFA"),
    (7, "Salbutamol 4 mg", "Salbutamol Sulphate IP 4 mg", "RESPIRATORY", 18.00, 1, "SAL"),
    (2, "Levothyroxine 50 mcg", "Levothyroxine Sodium IP 50 mcg", "HORMONE", 135.00, 1, "LTX"),
    (8, "Oseltamivir 75 mg", "Oseltamivir Phosphate IP 75 mg", "ANTIVIRAL", 520.00, 1, "OSL"),
    (1, "Acyclovir 400 mg", "Acyclovir IP 400 mg", "ANTIVIRAL", 98.00, 1, "ACV"),
    (4, "Sertraline 50 mg", "Sertraline Hydrochloride IP 50 mg", "NEURO", 86.00, 1, "SRT"),
    (5, "Gabapentin 300 mg", "Gabapentin IP 300 mg", "NEURO", 165.00, 1, "GBP"),
    (7, "B-Complex with Vitamin C", "Vitamin B-Complex with Ascorbic Acid", "VITAMIN", 35.00, 0, "BCX"),
]

PHARMACIES = [
    ("Care Plus Pharmacy", "TN-RX-1001", "Chennai", 13.082700, 80.270700),
    ("Sri Ram Medicals", "TN-RX-1002", "Vellore", 12.916500, 79.132500),
    ("Green Cross Pharmacy", "KA-RX-2001", "Bengaluru", 12.971600, 77.594600),
    ("LifeLine Chemists", "TS-RX-3001", "Hyderabad", 17.385000, 78.486700),
    ("City Health Store", "MH-RX-4001", "Mumbai", 19.076000, 72.877700),
    ("Capital Medicos", "DL-RX-5001", "Delhi", 28.613900, 77.209000),
    ("Howrah Drug House", "WB-RX-6001", "Kolkata", 22.572600, 88.363900),
    ("Kovai Medicals", "TN-RX-1003", "Coimbatore", 11.016800, 76.955800),
    ("Meenakshi Pharmacy", "TN-RX-1004", "Madurai", 9.925200, 78.119800),
    ("Deccan Wellness", "MH-RX-4002", "Pune", 18.520400, 73.856700),
    ("T. Nagar Medicals", "TN-RX-1005", "Chennai", 13.041800, 80.234100),
    ("Rockfort Pharmacy", "TN-RX-1006", "Tiruchirappalli", 10.790500, 78.704700),
    ("Salem City Chemists", "TN-RX-1007", "Salem", 11.664300, 78.146000),
    ("Koramangala Care", "KA-RX-2002", "Bengaluru", 12.935200, 77.624500),
    ("Mysore Medical Hall", "KA-RX-2003", "Mysuru", 12.295800, 76.639400),
    ("Krishna Medicals", "AP-RX-7001", "Vijayawada", 16.506200, 80.648000),
    ("Vizag Health Point", "AP-RX-7002", "Visakhapatnam", 17.686800, 83.218500),
    ("Marine Drive Pharmacy", "KL-RX-8001", "Kochi", 9.931200, 76.267300),
    ("Capital City Chemists", "KL-RX-8002", "Thiruvananthapuram", 8.524100, 76.936600),
    ("Andheri Wellness", "MH-RX-4003", "Mumbai", 19.113600, 72.869700),
    ("Sabarmati Medicos", "GJ-RX-9001", "Ahmedabad", 23.022500, 72.571400),
    ("Pink City Pharmacy", "RJ-RX-9101", "Jaipur", 26.912400, 75.787300),
    ("Karol Bagh Chemists", "DL-RX-5002", "Delhi", 28.651900, 77.190900),
    ("Hazratganj Medical Store", "UP-RX-9201", "Lucknow", 26.846700, 80.946200),
    ("Kalinga Drug House", "OD-RX-9301", "Bhubaneswar", 20.296100, 85.824500),
    ("Brahmaputra Pharmacy", "AS-RX-9401", "Guwahati", 26.144500, 91.736200),
    ("Gandhi Maidan Medicals", "BR-RX-9501", "Patna", 25.594100, 85.137600),
    ("Sector 17 Chemists", "CH-RX-9601", "Chandigarh", 30.733300, 76.779400),
    ("Lake City Pharmacy", "MP-RX-9701", "Bhopal", 23.259900, 77.412600),
    ("Orange City Medicals", "MH-RX-4004", "Nagpur", 21.145800, 79.088200),
]

# original 7 batches first (kept for the demo), then one or more per new medicine
# (medicine_id, batch_no, mfg, expiry, count)
BATCHES = [
    (1, "PCM2026A", "2026-06-01", "2028-05-31", 25),
    (2, "AMX2026B", "2026-07-15", "2027-07-14", 15),
    (3, "MET2026C", "2026-08-01", "2028-07-31", 15),
    (4, "ATV2026D", "2026-05-10", "2028-05-09", 15),
    (5, "AZI2026E", "2026-09-01", "2027-08-31", 15),
    (6, "CTZ2026F", "2026-04-01", "2026-12-31", 15),
    (2, "AMX2024X", "2024-09-01", "2026-08-31", 10),
]
extra = {
    "PSX": [("PSX2026G", "2026-05-20", "2028-04-30", 40)],
    "IBU": [("IBU2026H", "2026-06-11", "2028-05-31", 35)],
    "DCL": [("DCL2026R", "2026-06-05", "2028-05-31", 30)],          # recalled
    "ACF": [("ACF2026J", "2026-07-02", "2028-06-30", 25)],
    "AMC": [("AMC2026K", "2026-07-18", "2027-12-31", 30)],
    "CPF": [("CPF2026K", "2026-05-25", "2028-04-30", 30)],          # recalled
    "CFX": [("CFX2024Y", "2024-09-16", "2026-09-15", 25)],          # expires mid-period
    "DOX": [("DOX2026L", "2026-06-20", "2028-05-31", 25)],
    "GLM": [("GLM2026M", "2026-05-02", "2028-04-30", 30)],
    "SIT": [("SIT2026N", "2026-07-10", "2028-06-30", 20)],
    "AML": [("AML2026P", "2026-04-15", "2028-03-31", 35)],
    "TEL": [("TEL2026Q", "2026-06-01", "2028-05-31", 30)],
    "LOS": [("LOS2026S", "2026-05-12", "2028-04-30", 25)],
    "CLP": [("CLP2026T", "2026-06-25", "2028-05-31", 25)],
    "ASP": [("ASP2025U", "2025-01-02", "2026-12-31", 30)],          # expiring soon
    "LCZ": [("LCZ2026V", "2026-07-01", "2028-06-30", 25)],
    "MTK": [("MTK2026W", "2026-06-14", "2028-05-31", 25)],
    "FEX": [("FEX2026X", "2026-05-30", "2028-04-30", 20)],
    "PAN": [("PAN2026Y", "2026-07-07", "2028-06-30", 35)],
    "OMP": [("OMP2026Z", "2026-06-03", "2028-05-31", 25)],
    "OND": [("OND2025S", "2024-12-01", "2026-11-30", 20)],          # expiring soon
    "VTD": [("VTD2026A", "2026-08-05", "2028-07-31", 25)],
    "IFA": [("IFA2026B", "2026-07-21", "2028-06-30", 25)],
    "SAL": [("SAL2025T", "2025-01-10", "2026-12-15", 20)],          # expiring soon
    "LTX": [("LTX2026C", "2026-06-09", "2028-05-31", 20)],
    "OSL": [("OSL2026D", "2026-08-12", "2028-07-31", 15)],
    "ACV": [("ACV2026E", "2026-07-28", "2028-06-30", 20)],
    "SRT": [("SRT2026F", "2026-06-17", "2028-05-31", 20)],
    "GBP": [("GBP2026G", "2026-05-08", "2028-04-30", 20)],
    "BCX": [("BCX2024Z", "2024-09-01", "2026-08-31", 20)],          # already expired
}
code_to_id = {m[6]: i + 1 for i, m in enumerate(MEDICINES)}
for code, rows in extra.items():
    for b in rows:
        BATCHES.append((code_to_id[code], *b))
# a second batch for popular medicines
BATCHES += [
    (code_to_id["PCM"], "PCM2026H", "2026-08-20", "2028-07-31", 40),
    (code_to_id["MET"], "MET2026J", "2026-09-01", "2028-08-31", 30),
    (code_to_id["AZI"], "AZI2026K", "2026-08-25", "2027-08-31", 30),
]

RECALLS = [("MET2026C", "Failed dissolution test in quality audit"),
           ("DCL2026R", "Mislabelled strength: 75 mg printed as 50 mg"),
           ("CPF2026K", "Particulate contamination found by state drug laboratory")]
RECALL_TIME = datetime(2026, 10, 3, 0, 0)
EXPIRY = {b[1]: datetime.strptime(b[3], "%Y-%m-%d") for b in BATCHES}

# original 28 scans (kept exactly, the report and demo refer to them)
ORIGINAL = [
    ("PCM2026A-00003", 2, "2026-10-01 09:15:00"), ("PCM2026A-00004", 3, "2026-10-01 11:40:00"),
    ("AMX2026B-00002", 4, "2026-10-02 10:05:00"), ("ATV2026D-00001", 5, "2026-10-02 16:20:00"),
    ("AZI2026E-00003", 8, "2026-10-03 12:10:00"), ("AZI2026E-00003", 7, "2026-10-03 15:00:00"),
    ("PCM2026A-00005", 9, "2026-10-03 18:45:00"), ("CTZ2026F-00001", 1, "2026-10-04 08:50:00"),
    ("ATV2026D-00002", 10, "2026-10-04 09:30:00"), ("ATV2026D-00002", 6, "2026-10-04 12:00:00"),
    ("PCM2026A-00006", 1, "2026-10-04 13:00:00"), ("AZI2026E-00004", 6, "2026-10-05 10:00:00"),
    ("ATV2026D-00003", 6, "2026-10-05 15:30:00"), ("CTZ2026F-00002", 2, "2026-10-05 17:10:00"),
    ("PCM2026A-99999", 7, "2026-10-06 12:00:00"), ("XYZ1234-00001", 7, "2026-10-06 12:30:00"),
    ("ATV2026D-88888", 6, "2026-10-07 11:00:00"), ("PCM2026A-00007", 8, "2026-10-07 14:25:00"),
    ("AZI2026E-77777", 7, "2026-10-08 17:15:00"), ("AMX2026B-00002", 4, "2026-10-09 14:00:00"),
    ("PCM2026A-00004", 3, "2026-10-10 10:00:00"), ("CTZ2026F-00003", 9, "2026-10-10 12:40:00"),
    ("ATV2026D-00001", 10, "2026-10-11 09:00:00"), ("MET2026C-00005", 1, "2026-10-12 11:00:00"),
    ("MET2026C-00006", 8, "2026-10-12 16:00:00"), ("AMX2024X-00001", 9, "2026-10-13 10:30:00"),
    ("AMX2024X-00002", 7, "2026-10-13 12:00:00"), ("AMX2026B-00005", 5, "2026-10-14 11:20:00"),
]


def km(a, b):
    la1, lo1, la2, lo2 = map(radians, [PHARMACIES[a - 1][3], PHARMACIES[a - 1][4], PHARMACIES[b - 1][3], PHARMACIES[b - 1][4]])
    return 2 * 6371 * asin(sqrt(sin((la2 - la1) / 2) ** 2 + cos(la1) * cos(la2) * sin((lo2 - lo1) / 2) ** 2))


START, END = datetime(2026, 9, 1, 8, 0), datetime(2026, 10, 14, 21, 0)


def rand_time(lo=START, hi=END):
    t = lo + timedelta(seconds=random.randint(0, int((hi - lo).total_seconds())))
    t = t.replace(second=0)
    if t.hour < 8:
        t = t.replace(hour=8 + t.hour)
    if t.hour > 21:
        t = t.replace(hour=21)
    return t


# serial pools for NEW batches only (the original 7 stay clean for the demo)
pool = {}
for med, bno, mfg, exp, n in BATCHES[7:]:
    pool[bno] = [f"{bno}-{i:05d}" for i in range(1, n + 1)]
    random.shuffle(pool[bno])

south = [1, 2, 3, 8, 9, 11, 12, 13, 14, 15, 18, 19]
weights = [3 if i in south else 2 for i in range(1, 31)]
events, sold = [], []   # (serial, pharmacy, time, planned)

active = [b[1] for b in BATCHES[7:] if b[1] not in ("DCL2026R", "CPF2026K", "CFX2024Y", "BCX2024Z")]
for _ in range(265):
    bno = random.choice(active)
    if not pool[bno]:
        continue
    s, ph, t = pool[bno].pop(), random.choices(range(1, 31), weights)[0], rand_time()
    events.append((s, ph, t, "GENUINE")); sold.append((s, ph, t))
for bno in ("DCL2026R", "CPF2026K"):                     # sold before the recall, blocked after
    for _ in range(7):
        s = pool[bno].pop(); ph = random.choices(range(1, 31), weights)[0]
        t = rand_time(START, RECALL_TIME - timedelta(hours=2)); events.append((s, ph, t, "GENUINE")); sold.append((s, ph, t))
    for _ in range(5):
        events.append((pool[bno].pop(), random.randint(1, 30), rand_time(RECALL_TIME + timedelta(hours=10)), "RECALLED"))
for _ in range(8):                                         # cefixime: fine until 15 Sep, expired after
    s = pool["CFX2024Y"].pop(); ph = random.choices(range(1, 31), weights)[0]
    t = rand_time(START, datetime(2026, 9, 14, 20)); events.append((s, ph, t, "GENUINE")); sold.append((s, ph, t))
for _ in range(6):
    events.append((pool["CFX2024Y"].pop(), random.randint(1, 30), rand_time(datetime(2026, 9, 17)), "EXPIRED"))
for _ in range(5):
    events.append((pool["BCX2024Z"].pop(), random.randint(1, 30), rand_time(), "EXPIRED"))

hot = [7, 7, 7, 27, 27, 24, 24, 26, 6, 23, 5, 20, 16]
prefixes = [b[1] for b in BATCHES]
for i in range(34):                                        # counterfeits cluster in hotspots
    if i % 4 == 0:
        s = f"{random.choice(['XKP', 'QRT', 'ZNM', 'PCMX'])}{random.randint(1000, 9999)}-{random.randint(1, 99999):05d}"
    else:
        s = f"{random.choice(prefixes)}-{random.randint(90000, 99998):05d}"
    events.append((s, random.choice(hot), rand_time(), "COUNTERFEIT"))

random.shuffle(sold)
used = set()
far_pairs = 0
for s, ph, t in sold:                                      # impossible travel
    if far_pairs >= 13:
        break
    hours = random.choice([1, 1.5, 2, 2.5, 3, 4])
    t2 = t + timedelta(hours=hours)
    cands = [p for p in range(1, 31) if km(ph, p) > 100 * hours + 150]
    if not cands or t2 > END:
        continue
    p2 = random.choice(cands)
    events.append((s, p2, t2.replace(second=0), "SUSPICIOUS")); used.add(s); far_pairs += 1
clones = 0
for s, ph, t in sold:                                      # same code sold again days later
    if clones >= 18 or s in used:
        continue
    t2 = t + timedelta(days=random.randint(2, 12), hours=random.randint(0, 8))
    if t2 > END:
        continue
    p2 = random.choice([p for p in range(1, 31) if km(ph, p) < 500] or [ph])
    events.append((s, p2, t2.replace(second=0), "CLONED")); used.add(s); clones += 1

for s, ph, t in ORIGINAL:
    events.append((s, ph, datetime.strptime(t, "%Y-%m-%d %H:%M:%S"), "ORIGINAL"))
events.sort(key=lambda e: e[2])
before = [e for e in events if e[2] < RECALL_TIME]
after = [e for e in events if e[2] >= RECALL_TIME]


def scan_rows(evts):
    rows = [f" ('{s}', {ph:>2}, '{t:%Y-%m-%d %H:%M:%S}')" for s, ph, t, _ in evts]
    out = []
    for i in range(0, len(rows), 40):
        out.append("INSERT INTO scan_log (serial_no, pharmacy_id, scan_time) VALUES\n" + ",\n".join(rows[i:i + 40]) + ";")
    return "\n".join(out)


def sql_str(v):
    return "NULL" if v is None else "'" + str(v).replace("'", "''") + "'"


# patient checks
check_serials = [e[0] for e in random.sample(events, 60)] + ["PCM2026A-00003", "PCM2026A-99999", "AZI2026E-00003", "MET2026C-00005"]
cities = sorted({p[2] for p in PHARMACIES})
checks = []
for s in check_serials:
    checks.append(f" ('{s}', '{random.choice(cities)}', '{rand_time(datetime(2026, 9, 3)):%Y-%m-%d %H:%M:%S}', fn_serial_status('{s}'))")

# complaints
fakes = [e for e in events if e[3] == "COUNTERFEIT"]
susp = [e for e in events if e[3] == "SUSPICIOUS"]
clon = [e for e in events if e[3] == "CLONED"]
rec = [e for e in events if e[3] in ("RECALLED", "EXPIRED")]
gen = [e for e in events if e[3] == "GENUINE"]
names = ["S. Priya", "K. Arjun", "M. Fathima", "D. Rahul", "A. Nandini", "R. Vignesh", "P. Kavya", "J. Thomas",
         "N. Ayesha", "G. Suresh", "L. Meera", "T. Imran", "B. Divya", "V. Karthik", "H. Sneha", "C. Joseph",
         "E. Ritu", "F. Anand"]
texts = {
    "fake": ["Tablets crumble and taste chalky, strip print looks blurred",
             "Hologram missing on the strip, batch number font looks different",
             "Bought from a roadside stall at half price, foil feels thin",
             "No effect after three days, packaging spelling mistakes"],
    "copy": ["Same serial number as the strip my neighbour bought in another city",
             "Pharmacy gave two strips with the exact same serial number",
             "Serial already shows as sold when I check it online"],
    "unsafe": ["Pharmacy sold this to my father; heard the batch is recalled",
               "Strip sold to me last week is past its expiry date"],
    "ok": ["Packaging colour different from usual, want to confirm it is real",
           "Just want to be sure this strip is genuine before giving it to my child"],
}
pick = ([("PCM2026A-99999", "Kolkata", texts["fake"][0], "2026-10-06 18:20:00"),
         ("MET2026C-00005", "Chennai", texts["unsafe"][0], "2026-10-12 19:05:00"),
         ("AZI2026E-00003", "Kolkata", texts["copy"][0], "2026-10-04 09:40:00"),
         ("CTZ2026F-00001", "Chennai", texts["ok"][0], "2026-10-05 12:15:00")]
        + [(e[0], PHARMACIES[e[1] - 1][2], random.choice(texts["fake"]), e[2] + timedelta(hours=random.randint(3, 30))) for e in random.sample(fakes, 5)]
        + [(e[0], PHARMACIES[e[1] - 1][2], random.choice(texts["copy"]), e[2] + timedelta(hours=random.randint(3, 30))) for e in random.sample(susp + clon, 4)]
        + [(e[0], PHARMACIES[e[1] - 1][2], texts["unsafe"][1], e[2] + timedelta(hours=random.randint(3, 30))) for e in random.sample(rec, 2)]
        + [(e[0], PHARMACIES[e[1] - 1][2], texts["ok"][1], e[2] + timedelta(hours=random.randint(3, 30))) for e in random.sample(gen, 2)])
complaints = []
for i, (s, city, d, t) in enumerate(pick):
    phone = None if i % 5 == 3 else f"9{random.randint(100000000, 999999999)}"
    tt = t if isinstance(t, str) else min(t, END).strftime("%Y-%m-%d %H:%M:%S")
    complaints.append(f" ('{s}', '{names[i]}', {sql_str(phone)}, '{city}', {sql_str(d)}, '{tt}')")
updates = [(3, "INVESTIGATING", None), (4, "RESOLVED", "Serial verified genuine; new packaging design since Sept 2026"),
           (5, "INVESTIGATING", None), (6, "RESOLVED", "Confirmed counterfeit; stock seized and pharmacy notified"),
           (7, "INVESTIGATING", None), (9, "REJECTED", "Duplicate of an earlier complaint for the same strip"),
           (10, "INVESTIGATING", None), (11, "RESOLVED", "Cloned code confirmed; manufacturer issued replacement strips"),
           (14, "RESOLVED", "Strip withdrawn; customer refunded by the pharmacy"),
           (16, "RESOLVED", "Strip verified genuine through the registry")]

out = []
out.append("""-- =====================================================================
-- 7. SAMPLE DATA
--    8 manufacturers, 36 medicines, 30 pharmacies in 26 cities,
--    40 batches (~1,000 serials) and six weeks of scans (1 Sep - 14 Oct 2026).
--    Every verdict below is decided by the trigger, not typed in.
-- =====================================================================
""")
out.append("INSERT INTO manufacturer (name, license_no, city, contact_email) VALUES\n" +
           ",\n".join(f" ({sql_str(a)}, {sql_str(b)}, {sql_str(c)}, {sql_str(d)})" for a, b, c, d in MANUFACTURERS) + ";\n")
out.append("INSERT INTO medicine (manufacturer_id, name, composition, category, mrp, needs_prescription) VALUES\n" +
           ",\n".join(f" ({m}, {sql_str(n)}, {sql_str(c)}, '{cat}', {p:.2f}, {'TRUE' if rx else 'FALSE'})" for m, n, c, cat, p, rx, _ in MEDICINES) + ";\n")
out.append("INSERT INTO pharmacy (name, license_no, city, latitude, longitude) VALUES\n" +
           ",\n".join(f" ({sql_str(n)}, '{l}', {sql_str(c)}, {la:.6f}, {lo:.6f})" for n, l, c, la, lo in PHARMACIES) + ";\n")
out.append("""-- App users (demo passwords; only SHA-256 hashes are stored)
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
""")
out.append("-- Batches: each CALL saves the batch and its serials in one transaction\n" +
           "\n".join(f"CALL sp_register_batch({m}, '{b}', '{mf}', '{ex}', {n});" for m, b, mf, ex, n in BATCHES) + "\n")
out.append("-- Scans before the recalls on 3 Oct 2026\n" + scan_rows(before) + "\n")
out.append("-- Three batches recalled on 3 Oct 2026; later scans of them are blocked\n" +
           "\n".join(f"CALL sp_recall_batch('{b}', {sql_str(r)});" for b, r in RECALLS) + "\n")
out.append("-- Scans after the recalls\n" + scan_rows(after) + "\n")
out.append("CALL sp_update_risk_levels();\n")
out.append("""-- Officers have already acted on some alerts
CALL sp_resolve_alert(1,  'Pharmacy inspected; supplier invoice traced to an unlicensed wholesaler', 1);
CALL sp_resolve_alert(3,  'Counterfeit stock seized (14 strips); case referred to the district drug controller', 5);
CALL sp_resolve_alert(6,  'Strip returned by patient; manufacturer confirmed the code was copied', 1);
CALL sp_resolve_alert(10, 'Pharmacy warned; staff retrained on scanning every strip at sale', 5);
CALL sp_resolve_alert(15, 'Batch quarantined at the distributor warehouse', 1);
CALL sp_resolve_alert(22, 'Expired strips destroyed in presence of the drug inspector', 5);
CALL sp_resolve_alert(31, 'Show-cause notice issued to the pharmacy licence holder', 1);
CALL sp_resolve_alert(40, 'Investigation closed: same counter scanned twice by mistake, no fraud', 1);
""")
out.append("-- Patient complaints (priority is set by trg_complaint_priority)\n"
           "INSERT INTO complaint (serial_no, reporter_name, reporter_phone, city, description, created_at) VALUES\n" +
           ",\n".join(complaints) + ";\n")
out.append("\n".join(f"CALL sp_update_complaint({c}, '{s}', {sql_str(r)}, {1 if i % 3 else 5});" for i, (c, s, r) in enumerate(updates)) + "\n")
out.append("-- Patients checking strips on the public Verify page\n"
           "INSERT INTO patient_check (serial_no, city, checked_at, result) VALUES\n" + ",\n".join(checks) + ";\n")
out.append("""INSERT INTO activity_log (user_id, action, details, created_at) VALUES
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
""")
print("\n".join(out))
import sys
counts = {}
for e in events:
    counts[e[3]] = counts.get(e[3], 0) + 1
print(counts, sum(n for *_, n in BATCHES), len(BATCHES), file=sys.stderr)
