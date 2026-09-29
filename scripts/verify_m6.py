#!/usr/bin/env python3
"""Verify earned ordinary life, exact persistence, and private 1440p captures.

Graphics run through verify_m2.capture on a private virtual Wayland display;
the suite never opens a window on the user's desktop.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

sys.dont_write_bytecode = True
import verify_m2 as graphics

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "artifacts" / "m6-checks"
DEFAULT_SEED = "659966"
SEEDS = (DEFAULT_SEED, "1", "2", "3", "42")
THREE_YEARS = 3 * 360


def run(binary: pathlib.Path, name: str, *options: str, success: bool = True) -> str:
    result = subprocess.run(
        [str(binary), "--life-report", "--people-report", "--ecology-report", *options], cwd="/tmp",
        text=True, capture_output=True, timeout=180,
    )
    report = result.stdout + result.stderr
    (OUTPUT / f"{name}.log").write_text(report)
    if success and result.returncode != 0:
        raise RuntimeError(f"{name} failed:\n{report}")
    if not success and result.returncode == 0:
        raise AssertionError(f"{name} unexpectedly succeeded:\n{report}")
    if success:
        for key in ("life_validation_ok=1", "social_validation_ok=1", "ecology_validation_ok=1", "validation_ok=1"):
            if key not in report:
                raise AssertionError(f"{name} missing {key}:\n{report}")
    return report


def field(report: str, key: str) -> str:
    match = re.search(r"\b" + re.escape(key) + r"=([^\s]+)", report)
    if not match:
        raise AssertionError(f"missing {key}:\n{report}")
    return match.group(1)


def number(report: str, key: str) -> int:
    return int(field(report, key))


def trusted_employer(report: str) -> int:
    employer = number(report, "employer")
    match = re.search(r"^person=" + str(employer) + r"\b.*\btrust=(-?\d+)\b", report, re.MULTILINE)
    if not match:
        raise AssertionError(f"missing social history for employer {employer}:\n{report}")
    return int(match.group(1))


def validate_years(report: str) -> None:
    if number(report, "age_years") != 18:
        raise AssertionError("three lived years did not age the physical player from 15 to 18")
    if field(report, "home_household") in {"null", "none", "255", "-1"}:
        raise AssertionError("ordinary working life lost its home")
    for key in ("coins", "food_milli", "paid_hours", "skill", "player_wages_paid", "player_rent_payments"):
        if number(report, key) <= 0:
            raise AssertionError(f"ordinary life did not produce {key}")
    if number(report, "paid_hours") < 3000:
        raise AssertionError("three years did not contain substantial paid field work")
    if number(report, "food_shortage_milli") != 0 or number(report, "hunger") != 0:
        raise AssertionError("earned routine did not provide its real food needs")
    if trusted_employer(report) < 50:
        raise AssertionError("repeated useful work did not develop a strong relationship")


def capture_suite(binary: pathlib.Path) -> None:
    graphics.OUTPUT = OUTPUT
    settled = graphics.capture(binary, "settled-life", "--seed", DEFAULT_SEED, "--settle", "--life-panel")
    repeat = graphics.capture(binary, "settled-life-repeat", "--seed", DEFAULT_SEED, "--settle", "--life-panel")
    if settled != repeat:
        raise AssertionError("identical settled life panels differ")
    winter = graphics.capture(binary, "winter-life", "--seed", DEFAULT_SEED, "--settle", "--live-days", "270", "--life-panel")
    if winter == settled:
        raise AssertionError("winter life panel did not reflect the lived calendar and resources")
    graphics.capture(binary, "three-year-life", "--load", str(OUTPUT / "whole.alife"), "--life-panel")
    graphics.capture(binary, "three-year-journal", "--load", str(OUTPUT / "whole.alife"), "--journal")
    graphics.capture(binary, "rented-home", "--load", str(OUTPUT / "whole.alife"), "--home-view")
    print(f"PASS private 2560x1440 life, winter, learned journal and rented-home captures; {OUTPUT}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--headless-only", action="store_true", help="skip private Wayland/Vulkan captures")
    parser.add_argument("--skip-build", action="store_true", help="verify the existing release binary")
    args = parser.parse_args()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    if not args.skip_build:
        subprocess.run(["zig", "build", "-Doptimize=ReleaseSmall"], cwd=ROOT, check=True)
    binary = ROOT / "zig-out/bin/ascii-life"
    if not binary.is_file():
        raise FileNotFoundError(binary)

    fresh = run(binary, "fresh", "--seed", DEFAULT_SEED)
    if number(fresh, "age_years") != 15 or number(fresh, "paid_hours") != 0 or number(fresh, "journal_entries") != 0:
        raise AssertionError("fresh arrival manufactured prior life or learned facts")
    run(binary, "fresh-refused-skip", "--seed", DEFAULT_SEED, "--live-days", "7", success=False)
    print("PASS fresh arrival and safe-home boundary", flush=True)

    for seed in SEEDS:
        report = run(binary, f"years-{seed}", "--seed", seed, "--settle", "--live-days", str(THREE_YEARS))
        validate_years(report)
        print(f"PASS seed {seed}: three years of wages, provisions, home, aging and friendship", flush=True)

    whole = OUTPUT / "whole.alife"
    middle = OUTPUT / "middle.alife"
    resumed = OUTPUT / "resumed.alife"
    roundtrip = OUTPUT / "roundtrip.alife"
    full = run(binary, "continuation-whole", "--seed", DEFAULT_SEED, "--settle", "--live-days", str(THREE_YEARS), "--save", str(whole))
    run(binary, "continuation-middle", "--seed", DEFAULT_SEED, "--settle", "--live-days", "360", "--save", str(middle))
    continuation = run(binary, "continuation-resumed", "--load", str(middle), "--live-days", "720", "--save", str(resumed))
    for key in ("simulation_fingerprint", "social_fingerprint", "ecology_fingerprint", "life_fingerprint"):
        if field(full, key) != field(continuation, key):
            raise AssertionError(f"saved continuation changed {key}")
    if whole.read_bytes() != resumed.read_bytes():
        raise AssertionError("saved continuation changed full game state beyond the component fingerprints")
    run(binary, "roundtrip", "--load", str(resumed), "--save", str(roundtrip))
    if resumed.read_bytes() != roundtrip.read_bytes():
        raise AssertionError("loading and resaving changed saved causes")
    print("PASS exact full-game save/load and three-year continuation", flush=True)

    if args.headless_only:
        print(f"PASS M6 headless suite; reports: {OUTPUT}")
        return 0

    capture_suite(binary)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, FileNotFoundError, RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
