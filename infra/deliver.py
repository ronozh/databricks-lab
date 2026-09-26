#!/usr/bin/env python3
"""
The delivery process: push generated file drops into the landing Volume.

    python3 infra/deliver.py employee                 # one feed, every date
    python3 infra/deliver.py employee 2025-01-31      # one feed, one date
    python3 infra/deliver.py --all                    # every feed

This stands in for an upstream system of record. It knows nothing about bronze,
dbt, or what happens next -- the interface is *files in a volume*, and keeping
that boundary is the point.

APPEND-ONLY, ALWAYS. `databricks fs cp --recursive` skips objects that already
exist unless --overwrite is passed, and this script never passes it. Two reasons,
both learned the hard way in local-lab:

  1. The landing contract says files are appended, never mutated. A correction
     arrives as a NEW file beside the old one.

  2. Bronze's watermark is (_file_name, _file_last_modified). Re-uploading
     byte-identical content still bumps the modification time, so an overwriting
     re-run would look like a fresh delivery and load every row twice. Skipping
     is what makes re-running this a genuine no-op.

There is deliberately no --replace. Reprocessing is a separate, explicit act.
"""
import argparse, os, pathlib, subprocess, sys

SRC_ROOT = pathlib.Path(__file__).resolve().parents[2] / "data-generator" / "data" / "generated" / "hr"
VOLUME = os.environ.get("DBX_LANDING_VOLUME", "/Volumes/hr/landing/drop")
FEEDS = ["employee", "employee_changes", "department"]


def deliver(feed, business_date, profile, dry_run):
    src = SRC_ROOT / feed / business_date if business_date else SRC_ROOT / feed
    if not src.is_dir():
        sys.exit(f"no such path: {src}\n"
                 f"Export the hr domain from the generator first.")
    dest = f"{VOLUME}/{feed}" + (f"/{business_date}" if business_date else "")

    if dry_run:
        n = sum(1 for _ in src.rglob("*") if _.suffix in (".csv", ".ctrl"))
        print(f"  {feed:<18} would consider {n} files -> {dest}")
        return 0, 0

    p = subprocess.run(
        ["databricks", "fs", "cp", "--recursive", str(src), f"dbfs:{dest}",
         "--profile", profile],
        capture_output=True, text=True)
    if p.returncode:
        sys.exit(f"delivery failed for {feed}: {p.stderr.strip()[:400]}")

    lines = [l for l in p.stdout.splitlines() if "->" in l]
    skipped = sum(1 for l in lines if "already exists" in l)
    copied = len(lines) - skipped
    print(f"  {feed:<18} delivered {copied}, skipped {skipped} (already present)")
    return copied, skipped


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("feed", nargs="?", choices=FEEDS)
    ap.add_argument("business_date", nargs="?")
    ap.add_argument("--all", action="store_true", help="deliver every feed")
    ap.add_argument("--profile", default="free")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if not a.feed and not a.all:
        ap.error("name a feed, or pass --all")
    if a.all and a.business_date:
        ap.error("--all takes every date; drop the business_date")

    print(f"Delivering to {VOLUME}")
    c = s = 0
    for f in (FEEDS if a.all else [a.feed]):
        dc, ds = deliver(f, a.business_date, a.profile, a.dry_run)
        c += dc
        s += ds
    print(f"  {'total':<18} {c} delivered, {s} skipped")


if __name__ == "__main__":
    main()
