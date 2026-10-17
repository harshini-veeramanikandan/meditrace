# MediTrace - Counterfeit Medicine Detection System
BCSE302L Database Systems - Digital Assignment II

## Files
| File | What it is |
| --- | --- |
| `meditrace.sql` | Whole database: 13 tables, 7 indexes, 3 functions, 9 triggers, 9 procedures, 12 views, 1 event, DB users, and sample data: 8 manufacturers, 36 medicines, 30 pharmacies in 26 cities, 40 batches (980 serials), 401 scans over 6 weeks |
| `demo_queries.sql` | Live demo (Parts A-D): 6 verdicts, integrity errors, rollback, analysis queries, new features |
| `app.py` | Flask web app (13 pages, 3 roles) |
| `templates/`, `static/` | Pages, styles and bundled libraries (works offline; map tiles need internet) |
| `screenshots/` | Screenshots of every page |
| `tools/generate_sample_data.py` | Script that generated the synthetic sample data (fixed seed, same output every run) |

## Setup
1. MySQL Workbench: open `meditrace.sql`, click inside it once, Query > Execute (All or Selection).
2. VS Code: open this folder, your MySQL password is set in `app.py` (line 29).
3. Terminal: `pip install flask mysql-connector-python` then `python app.py`.
4. Browser: http://127.0.0.1:5000

## Demo logins
| Username | Password | Role |
| --- | --- | --- |
| admin | admin123 | Regulator (sees everything) |
| chennai | pharma123 | Pharmacist, Care Plus Pharmacy, Chennai |
| delhi | pharma123 | Pharmacist, Capital Medicos, Delhi |
| kolkata | pharma123 | Pharmacist, Howrah Drug House, Kolkata |
| inspector | admin123 | Second regulator (State Drug Inspector) |
| medilife | mfg123 | Manufacturer, Medilife Pharma Ltd |
| arogya | mfg123 | Manufacturer, Arogya Labs Pvt Ltd |

Patient portal (no login): http://127.0.0.1:5000/verify

To reset all data before a demo, run `meditrace.sql` again.
