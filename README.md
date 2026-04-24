# Trafikverket Körkortsprov Checker

Monitors available driving test times (körprov / kunskapsprov) on Trafikverket.
Detects free times AND newly available slots from cancellations.

## Setup

```bash
cd ~/trafikverket_checker
pip install -r requirements.txt
```

Edit `config.json` with your details:

```json
{
    "swedish_ssn": "19900101-1234",
    "exam_type": "Körprov",
    "locations": ["Sollentuna", "Järfälla", "Farsta"],
    "check_interval_seconds": 300,
    "date_from": "2026-04-13",
    "date_to": "2026-12-31"
}
```

- **swedish_ssn** — Your personnummer (YYYYMMDD-XXXX)
- **exam_type** — `Körprov` (driving test) or `Kunskapsprov` (theory test)
- **locations** — Filter by city names (empty list = all locations)
- **check_interval_seconds** — How often to check in watch mode
- **date_from / date_to** — Date range to search within

## Usage

### One-time scan
```bash
python checker.py
```
Shows all available times. Run again to see what changed (new/cancelled slots).

### Continuous monitoring (watch mode)
```bash
python checker.py --watch
```
Checks periodically and highlights:
- **NEW times** (green) — likely from cancellations, now available for booking
- **Removed times** (red) — recently booked by someone else

### Filter by location
```bash
python checker.py --locations Sollentuna Järfälla
python checker.py --watch -l Farsta
```

### Override exam type
```bash
python checker.py --exam Kunskapsprov
```

## How it works

Uses the same API as `fp.trafikverket.se/boka/` to query available occasion
bundles across all test locations in Sweden. Compares each scan to a saved
snapshot to detect changes — new slots appearing means someone cancelled
their booking.
