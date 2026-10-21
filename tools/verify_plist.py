#!/usr/bin/env python3
"""Validate NullsBotFill.plist before shipping it.

Checks the types the dylib expects, the five-slot limits, and (when
--characters is given) that every brawler id is a real row in the client's
characters.csv. Exits non-zero on any failure.
"""
import argparse
import csv
import plistlib
import sys

STRING_ARRAYS = [
    "BotNames", "ExcludedModes", "PlayerClasses", "SetupClasses",
    "SetupSelectors", "TickClasses", "TickSelectors", "PickClasses",
    "PickSelectors", "BanSelectors", "JoinClasses", "JoinSelectors",
]
NUMBER_ARRAYS = ["BotBrawlerIds", "RankedBrawlerIds"]


def fail(errors, message):
    errors.append(message)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("plist")
    ap.add_argument("--characters", help="path to res/csv_logic/characters.csv")
    args = ap.parse_args()

    with open(args.plist, "rb") as fh:
        cfg = plistlib.load(fh)

    errors = []
    for key in NUMBER_ARRAYS:
        value = cfg.get(key)
        if not isinstance(value, list) or not value:
            fail(errors, f"{key}: expected a non-empty array of integers")
            continue
        if any(isinstance(v, bool) or not isinstance(v, int) for v in value):
            fail(errors, f"{key}: every element must be an integer")
            continue
        if any(v < 0 for v in value):
            fail(errors, f"{key}: negative ids are invalid")
        if len(set(value)) != len(value):
            fail(errors, f"{key}: duplicate ids")
        if 16000000 in value:
            fail(errors, f"{key}: 16000000 is not a characters.csv row id")

    for key in STRING_ARRAYS:
        value = cfg.get(key)
        if not isinstance(value, list):
            fail(errors, f"{key}: expected an array of strings")
        elif any(not isinstance(v, str) for v in value):
            fail(errors, f"{key}: every element must be a string")

    names = cfg.get("BotNames")
    if isinstance(names, list) and len(names) < 5:
        fail(errors, "BotNames: five slots are required")

    base = cfg.get("BotBaseId")
    if isinstance(base, bool) or not isinstance(base, int) or base <= 0:
        fail(errors, "BotBaseId: expected a positive integer")

    interval = cfg.get("WalkInterval")
    if not isinstance(interval, (int, float)) or isinstance(interval, bool):
        fail(errors, "WalkInterval: expected a number")
    elif not 0 < float(interval) <= 3600:
        fail(errors, "WalkInterval: must be in (0, 3600]")

    if args.characters:
        with open(args.characters, encoding="utf-8-sig", newline="") as fh:
            rows = list(csv.reader(fh))[2:]
        for key in NUMBER_ARRAYS:
            for value in cfg.get(key) or []:
                if isinstance(value, int) and not 0 <= value < len(rows):
                    fail(errors, f"{key}: {value} outside 0..{len(rows) - 1}")
                elif isinstance(value, int):
                    print(f"{key}: {value} -> {rows[value][0]}")
        names = cfg.get("BotNames") or []
        for i, bot_name in enumerate(names):
            if isinstance(bot_name, str) and not bot_name:
                fail(errors, f"BotNames[{i}]: empty name")

    if errors:
        for message in errors:
            print("ERROR:", message, file=sys.stderr)
        return 1
    print("plist OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
