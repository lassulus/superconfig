"""Push the Garmin samples of a Gadgetbridge database export to VictoriaMetrics."""

import argparse
import json
import os
import sqlite3
import shutil
import sys
import urllib.request

# table: (milliseconds per TIMESTAMP unit, {column: metric suffix}), names as
# greenDAO derives them from GBDaoGenerator.java.
TABLES = {
    "GARMIN_ACTIVITY_SAMPLE": (
        1000,
        {
            "HEART_RATE": "heart_rate",
            "STEPS": "steps",
            "RAW_INTENSITY": "intensity",
            "RAW_KIND": "activity_kind",
            "DISTANCE_CM": "distance_cm",
            "ACTIVE_CALORIES": "active_calories",
        },
    ),
    "GARMIN_STRESS_SAMPLE": (1, {"STRESS": "stress"}),
    "GARMIN_BODY_ENERGY_SAMPLE": (1, {"ENERGY": "body_energy"}),
    "GARMIN_SPO2_SAMPLE": (1, {"SPO2": "spo2"}),
    "GARMIN_HRV_VALUE_SAMPLE": (1, {"VALUE": "hrv"}),
    "GARMIN_HRV_SUMMARY_SAMPLE": (
        1,
        {
            "WEEKLY_AVERAGE": "hrv_weekly_average",
            "LAST_NIGHT_AVERAGE": "hrv_last_night_average",
            "LAST_NIGHT5_MIN_HIGH": "hrv_last_night_5min_high",
            "BASELINE_LOW_UPPER": "hrv_baseline_low_upper",
            "BASELINE_BALANCED_LOWER": "hrv_baseline_balanced_lower",
            "BASELINE_BALANCED_UPPER": "hrv_baseline_balanced_upper",
            "STATUS_NUM": "hrv_status",
        },
    ),
    "GARMIN_RESPIRATORY_RATE_SAMPLE": (1, {"RESPIRATORY_RATE": "respiratory_rate"}),
    "GARMIN_HEART_RATE_RESTING_SAMPLE": (1, {"HEART_RATE": "resting_heart_rate"}),
    "GARMIN_RESTING_METABOLIC_RATE_SAMPLE": (
        1,
        {"RESTING_METABOLIC_RATE": "resting_metabolic_rate"},
    ),
    "GARMIN_SLEEP_STAGE_SAMPLE": (1, {"STAGE": "sleep_stage"}),
    "GARMIN_SLEEP_STATS_SAMPLE": (1, {"SLEEP_SCORE": "sleep_score"}),
    "GARMIN_INTENSITY_MINUTES_SAMPLE": (
        1,
        {"MODERATE": "intensity_minutes_moderate", "VIGOROUS": "intensity_minutes_vigorous"},
    ),
}

# Metrics where 0 is a real value; for all others 0 means not measured.
ZERO_OK = {
    "steps",
    "intensity",
    "activity_kind",
    "distance_cm",
    "active_calories",
    "stress",
    "body_energy",
    "sleep_stage",
    "intensity_minutes_moderate",
    "intensity_minutes_vigorous",
}

BATCH = 50000


def valid(metric, value):
    if value is None or value < 0 or (value == 0 and metric not in ZERO_OK):
        return False
    return not (metric.endswith("heart_rate") and value >= 255)


def label(value):
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def samples(db, table, unit, columns, since):
    present = {row[1] for row in db.execute(f"PRAGMA table_info({table})")}
    columns = {c: m for c, m in columns.items() if c in present}
    if not columns:
        return
    query = (
        f"SELECT d.NAME, s.TIMESTAMP, {', '.join('s.' + c for c in columns)}"
        f" FROM {table} s JOIN DEVICE d ON d._id = s.DEVICE_ID"
        " WHERE s.TIMESTAMP > ? ORDER BY s.TIMESTAMP"
    )
    for device, ts, *values in db.execute(query, (since,)):
        for metric, value in zip(columns.values(), values):
            if valid(metric, value):
                line = f'gadgetbridge_{metric}{{device="{label(device)}"}} {value} {ts * unit}'
                yield ts, line


def push(url, lines):
    body = ("\n".join(lines) + "\n").encode()
    request = urllib.request.Request(f"{url}/api/v1/import/prometheus", data=body)
    urllib.request.urlopen(request).close()


def newest_file(directory):
    files = [
        e for e in os.scandir(directory) if e.is_file() and not e.name.startswith(".")
    ]
    return max(files, key=lambda e: e.stat().st_mtime).path if files else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", help="directory with the exported database")
    parser.add_argument("--url", required=True, help="VictoriaMetrics base URL")
    parser.add_argument("--state-dir", required=True)
    args = parser.parse_args()

    source = newest_file(args.directory)
    if source is None:
        print("no export yet")
        return
    state_file = os.path.join(args.state_dir, "state.json")
    copy = os.path.join(args.state_dir, "export.db")
    shutil.copyfile(source, copy)

    try:
        db = sqlite3.connect(f"file:{copy}?mode=ro", uri=True)
        ok = db.execute("PRAGMA quick_check").fetchone()[0] == "ok"
    except sqlite3.DatabaseError:
        ok = False
    if not ok:
        os.remove(copy)
        print(f"{source} is not a complete database (upload running?), skipping")
        return

    try:
        with open(state_file) as f:
            state = json.load(f)
    except FileNotFoundError:
        state = {}

    tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    for table, (unit, columns) in TABLES.items():
        if table not in tables:
            continue
        last = state.get(table, -1)
        batch = []
        count = 0
        for ts, line in samples(db, table, unit, columns, last):
            batch.append(line)
            last = max(last, ts)
            if len(batch) >= BATCH:
                push(args.url, batch)
                count += len(batch)
                batch = []
        if batch:
            push(args.url, batch)
            count += len(batch)
        state[table] = last
        print(f"{table}: {count} samples")
        with open(state_file + ".tmp", "w") as f:
            json.dump(state, f)
        os.replace(state_file + ".tmp", state_file)
    db.close()
    os.remove(copy)


if __name__ == "__main__":
    sys.exit(main())
