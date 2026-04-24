#!/usr/bin/env python3
"""
Trafikverket Körkortsprov Availability Checker

Monitors available driving test times on Trafikverket and detects
newly available slots (including cancelled bookings that free up).

Usage:
    python checker.py                  # One-time scan of all locations
    python checker.py --watch          # Continuous monitoring mode
    python checker.py --locations Sollentuna Järfälla  # Filter by location name
"""

import argparse
import json
import time
import sys
from datetime import datetime
from pathlib import Path

from rich.console import Console
from rich.table import Table
from rich.live import Live
from rich.panel import Panel

from api import TrafikverketAPI

console = Console()

PROJECT_DIR = Path(__file__).parent
CONFIG_PATH = PROJECT_DIR / "config.json"
LOCATIONS_PATH = PROJECT_DIR / "data" / "valid_locations.json"
SNAPSHOT_PATH = PROJECT_DIR / "data" / "last_snapshot.json"


def load_config() -> dict:
    with open(CONFIG_PATH, "r") as f:
        return json.load(f)


def load_location_ids() -> dict:
    with open(LOCATIONS_PATH, "r") as f:
        return json.load(f)


def save_snapshot(times: list[dict]):
    with open(SNAPSHOT_PATH, "w") as f:
        json.dump(times, f, indent=2, ensure_ascii=False)


def load_snapshot() -> list[dict]:
    if SNAPSHOT_PATH.exists():
        with open(SNAPSHOT_PATH, "r") as f:
            return json.load(f)
    return []


def make_key(t: dict) -> str:
    return f"{t['date']}|{t['time']}|{t['location']}|{t['name']}"


def filter_by_date(times: list[dict], date_from: str, date_to: str) -> list[dict]:
    return [
        t for t in times
        if date_from <= t["date"] <= date_to
    ]


def filter_by_location_name(times: list[dict], names: list[str]) -> list[dict]:
    if not names:
        return times
    names_lower = [n.lower() for n in names]
    return [t for t in times if t["location"].lower() in names_lower]


def build_table(times: list[dict], title: str = "Lediga provtider") -> Table:
    table = Table(title=title, show_lines=True)
    table.add_column("Datum", style="cyan", no_wrap=True)
    table.add_column("Tid", style="green", no_wrap=True)
    table.add_column("Plats", style="yellow")
    table.add_column("Prov", style="magenta")
    table.add_column("Kostnad", style="red", no_wrap=True)

    for t in times:
        table.add_row(t["date"], t["time"], t["location"], t["name"], t["cost"])

    return table


def scan_all(api: TrafikverketAPI, location_ids: list[int]) -> list[dict]:
    """Scan all location IDs and return combined list of available times."""
    all_times = []
    total = len(location_ids)

    for i, loc_id in enumerate(location_ids, 1):
        try:
            console.print(
                f"  Scanning location {i}/{total} (ID: {loc_id})...",
                end="\r",
            )
            times = api.get_available_times(loc_id)
            all_times.extend(times)
        except Exception as e:
            console.print(f"  [dim]Error for location {loc_id}: {e}[/dim]")
        time.sleep(0.5)  # Be polite to the server

    console.print(f"  Scanned {total} locations, found {len(all_times)} available slots.")
    return all_times


def detect_changes(current: list[dict], previous: list[dict]):
    """Find newly added and removed times compared to previous snapshot."""
    current_keys = {make_key(t): t for t in current}
    previous_keys = {make_key(t): t for t in previous}

    added = [current_keys[k] for k in current_keys if k not in previous_keys]
    removed = [previous_keys[k] for k in previous_keys if k not in current_keys]

    return added, removed


def run_once(config: dict, location_ids: list[int], filter_locations: list[str]):
    """Single scan: show all available times."""
    api = TrafikverketAPI(
        ssn=config["swedish_ssn"],
        examination_type=config["exam_type"],
        licence_type=config.get("licence_type", "B"),
    )

    console.print(Panel(f"[bold]Scanning for {config['exam_type']} times...[/bold]"))
    all_times = scan_all(api, location_ids)

    # Filter
    all_times = filter_by_date(all_times, config["date_from"], config["date_to"])
    all_times = filter_by_location_name(all_times, filter_locations)

    # Sort by date then time
    all_times.sort(key=lambda x: (x["date"], x["time"]))

    if all_times:
        console.print(build_table(all_times, f"Lediga {config['exam_type']} tider"))
    else:
        console.print("[yellow]Inga lediga tider hittades inom ditt datumintervall.[/yellow]")

    # Detect changes from last run
    previous = load_snapshot()
    if previous:
        added, removed = detect_changes(all_times, previous)
        if added:
            console.print()
            console.print(
                build_table(added, "[green]NYA tider (avbokade/frigjorda)[/green]")
            )
        if removed:
            console.print()
            console.print(
                build_table(removed, "[red]Borttagna tider (nyligen bokade)[/red]")
            )
        if not added and not removed:
            console.print("[dim]Inga ändringar sedan senaste kontrollen.[/dim]")

    save_snapshot(all_times)
    console.print(f"\n[dim]Snapshot sparad. Kör igen för att se ändringar.[/dim]")


def run_watch(config: dict, location_ids: list[int], filter_locations: list[str]):
    """Continuous monitoring mode."""
    api = TrafikverketAPI(
        ssn=config["swedish_ssn"],
        examination_type=config["exam_type"],
        licence_type=config.get("licence_type", "B"),
    )
    interval = config.get("check_interval_seconds", 300)

    console.print(
        Panel(
            f"[bold]Watching for {config['exam_type']} times "
            f"(every {interval}s)[/bold]\n"
            f"Date range: {config['date_from']} → {config['date_to']}\n"
            f"Press Ctrl+C to stop."
        )
    )

    previous = load_snapshot()
    run_number = 0

    try:
        while True:
            run_number += 1
            now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            console.print(f"\n[bold cyan]── Scan #{run_number} at {now} ──[/bold cyan]")

            all_times = scan_all(api, location_ids)
            all_times = filter_by_date(all_times, config["date_from"], config["date_to"])
            all_times = filter_by_location_name(all_times, filter_locations)
            all_times.sort(key=lambda x: (x["date"], x["time"]))

            # Show changes
            if previous:
                added, removed = detect_changes(all_times, previous)
                if added:
                    console.print(
                        build_table(
                            added,
                            f"[green bold]🆕 {len(added)} NYA tider (avbokade/frigjorda)[/green bold]",
                        )
                    )
                    # Bell sound for notification
                    print("\a", end="")
                if removed:
                    console.print(
                        build_table(
                            removed,
                            f"[red]❌ {len(removed)} tider borttagna[/red]",
                        )
                    )
                if not added and not removed:
                    console.print(f"  [dim]Inga ändringar. {len(all_times)} tider tillgängliga.[/dim]")
            else:
                console.print(f"  [green]Första scan: {len(all_times)} tider hittade.[/green]")
                if all_times:
                    console.print(build_table(all_times))

            previous = all_times
            save_snapshot(all_times)

            console.print(f"  [dim]Nästa scan om {interval} sekunder...[/dim]")
            time.sleep(interval)

    except KeyboardInterrupt:
        console.print("\n[yellow]Avslutad.[/yellow]")
        save_snapshot(previous)


def main():
    parser = argparse.ArgumentParser(
        description="Trafikverket körkortsprov availability checker"
    )
    parser.add_argument(
        "--watch", "-w",
        action="store_true",
        help="Continuous monitoring mode",
    )
    parser.add_argument(
        "--locations", "-l",
        nargs="*",
        default=[],
        help="Filter by location names (e.g., Sollentuna Järfälla)",
    )
    parser.add_argument(
        "--exam",
        choices=["Körprov", "Kunskapsprov"],
        help="Override exam type from config",
    )
    args = parser.parse_args()

    config = load_config()

    if config["swedish_ssn"] == "YYYYMMDD-XXXX":
        console.print(
            "[red bold]Configure your SSN in config.json first![/red bold]\n"
            f"Edit: {CONFIG_PATH}"
        )
        sys.exit(1)

    if args.exam:
        config["exam_type"] = args.exam

    all_location_ids = load_location_ids()
    licence_type = config.get("licence_type", "B")
    licence_locs = all_location_ids.get(licence_type, all_location_ids)
    # Support both old flat format and new nested format
    if isinstance(licence_locs, dict):
        location_ids = licence_locs.get(config["exam_type"], [])
    else:
        location_ids = licence_locs

    filter_locations = args.locations or config.get("locations", [])

    if args.watch:
        run_watch(config, location_ids, filter_locations)
    else:
        run_once(config, location_ids, filter_locations)


if __name__ == "__main__":
    main()
