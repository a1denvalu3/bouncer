#!/usr/bin/env python3
"""Select Git review units without using GitHub PR metadata or APIs."""

from datetime import datetime, timedelta, timezone
import re
import subprocess
import sys


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def resolve_commit(ref):
    return git("rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}")


def select_commits(ref, mode, start="", end=""):
    tip = resolve_commit(ref)
    if mode == "single":
        if not start or re.fullmatch(r"#?\d+", start):
            raise ValueError("PR numbers require a GitHub token; specify a commit SHA or Git ref")
        return [resolve_commit(start)]

    rows = [line.split("\t") for line in git(
        "log", "--first-parent", "--reverse", "--format=%H%x09%ct", tip, "--"
    ).splitlines()]
    commits = [oid for oid, _ in rows]
    lower, upper = 0, len(rows)
    dates = {}
    for name, value in (("start", start), ("end", end)):
        if not value:
            continue
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
            dates[name] = datetime.strptime(value, "%Y-%m-%d").replace(tzinfo=timezone.utc)
        elif re.fullmatch(r"#?\d+", value):
            raise ValueError("PR-number bounds require a GitHub token; use dates or commit SHAs")
        else:
            if not re.fullmatch(r"[0-9a-fA-F]{7,64}", value):
                raise ValueError(f"Invalid {name} bound '{value}'; use YYYY-MM-DD or a commit SHA")
            oid = resolve_commit(value)
            if oid not in commits:
                raise ValueError(f"{name} commit is not on the first-parent history of {ref}")
            if name == "start":
                lower = commits.index(oid)
            else:
                upper = commits.index(oid) + 1
    if lower >= upper:
        raise ValueError("Start commit must not follow the end commit")
    if "start" in dates and "end" in dates and dates["start"] > dates["end"]:
        raise ValueError("Start date must not follow the end date")

    # Filter timestamps after walking the complete history: --since can prune
    # commits when a repository contains out-of-order committer timestamps.
    return [oid for oid, timestamp in rows[lower:upper]
            if ("start" not in dates or int(timestamp) >= dates["start"].timestamp())
            and ("end" not in dates or
                 int(timestamp) < (dates["end"] + timedelta(days=1)).timestamp())]


def main():
    try:
        ref, mode, *bounds = sys.argv[1:]
        if len(bounds) > 2:
            raise ValueError("Expected a ref, mode, and at most two bounds")
        if mode not in ("backfill", "continuous", "single"):
            raise ValueError(f"Unknown Git scan mode: {mode}")
        for oid in select_commits(ref, mode, *(bounds + [""] * (2 - len(bounds)))):
            print(oid)
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"ERROR: Cannot select Git history: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
