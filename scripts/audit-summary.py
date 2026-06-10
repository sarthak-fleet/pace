#!/usr/bin/env python3
"""Summarizes Pace's local API audit log into a per-subsystem latency table.

Reads ~/Library/Application Support/Pace/api-audit.jsonl (plus its rotated
.1 generation) and prints count, error rate, and p50/p95/max latency per
(subsystem, target). Use it to find which local call is eating the turn
budget before tuning anything.

Usage:
  python3 scripts/audit-summary.py                # all recorded history
  python3 scripts/audit-summary.py --last 60      # only the last 60 minutes
"""

import argparse
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

LOG_PATH = os.path.expanduser("~/Library/Application Support/Pace/api-audit.jsonl")


def percentile(sorted_values, fraction):
    if not sorted_values:
        return 0
    index = min(len(sorted_values) - 1, int(len(sorted_values) * fraction))
    return sorted_values[index]


def load_entries(cutoff):
    entries = []
    for path in (LOG_PATH + ".1", LOG_PATH):
        if not os.path.exists(path):
            continue
        with open(path) as f:
            for line in f:
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if cutoff is not None:
                    try:
                        at = datetime.fromisoformat(entry["at"].replace("Z", "+00:00"))
                    except (KeyError, ValueError):
                        continue
                    if at < cutoff:
                        continue
                entries.append(entry)
    return entries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--last", type=int, metavar="MINUTES", help="only entries from the last N minutes")
    args = parser.parse_args()

    cutoff = None
    if args.last:
        cutoff = datetime.now(timezone.utc) - timedelta(minutes=args.last)

    entries = load_entries(cutoff)
    if not entries:
        print(f"no audit entries found at {LOG_PATH}")
        sys.exit(0)

    groups = defaultdict(list)
    for entry in entries:
        key = (entry.get("subsystem", "?"), entry.get("target", "?"))
        groups[key].append(entry)

    print(f"{len(entries)} call(s) audited\n")
    header = f"{'subsystem':<12} {'target':<42} {'calls':>5} {'err%':>5} {'p50ms':>7} {'p95ms':>7} {'maxms':>7}"
    print(header)
    print("-" * len(header))
    for (subsystem, target), group in sorted(groups.items()):
        durations = sorted(e.get("durationMilliseconds", 0) for e in group)
        errors = sum(1 for e in group if e.get("outcome") != "ok")
        print(
            f"{subsystem:<12} {target[:42]:<42} {len(group):>5} "
            f"{100 * errors / len(group):>4.0f}% "
            f"{percentile(durations, 0.50):>7} {percentile(durations, 0.95):>7} {durations[-1]:>7}"
        )

    failures = [e for e in entries if e.get("outcome") != "ok"]
    if failures:
        print(f"\nlast {min(5, len(failures))} failure(s):")
        for entry in failures[-5:]:
            print(f"  {entry.get('at')} {entry.get('subsystem')}/{entry.get('target')}: "
                  f"{entry.get('outcome')} {entry.get('detail') or ''}")


if __name__ == "__main__":
    main()
