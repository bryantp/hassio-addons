"""Prune old Home Assistant backups, keeping only the N newest."""
import argparse
import os
import sys

import pytz
import requests
from dateutil.parser import parse

BASE_URL = "http://supervisor/"
HEADERS = {"Authorization": "Bearer " + os.environ.get("SUPERVISOR_TOKEN", "")}


def main(number_to_keep: int) -> None:
    resp = requests.get(BASE_URL + "backups", headers=HEADERS, timeout=30)
    resp.raise_for_status()
    backups = resp.json()["data"]["backups"]

    for b in backups:
        d = parse(b["date"])
        if d.tzinfo is None or d.tzinfo.utcoffset(d) is None:
            print(f"Naive datetime for backup {b['slug']}, treating as UTC")
            b["date"] = d.replace(tzinfo=pytz.utc).isoformat()

    backups.sort(key=lambda item: parse(item["date"]), reverse=True)
    stale = backups[number_to_keep:]

    for b in stale:
        url = BASE_URL + "backups/" + b["slug"]
        res = requests.delete(url, headers=HEADERS, timeout=30)
        if res.ok:
            print(f"[Info] Deleted backup {b['slug']}")
        else:
            print(
                f"[Error] Failed to delete backup {b['slug']}: "
                f"{res.status_code} {res.text}",
                file=sys.stderr,
            )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Remove old Home Assistant backups.")
    parser.add_argument("number", type=int, help="Number of backups to keep")
    args = parser.parse_args()
    main(args.number)
