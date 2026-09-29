#!/usr/bin/env python3
"""Milestone 2 deterministic geography and native capture checks.

The headless report suite runs without a display. Full mode also requires the
installed private KWin virtual display and Vulkan driver; captures run at 1440p
without opening windows on the user desktop.
"""

from __future__ import annotations

import argparse
import math
import os
import pathlib
import re
import subprocess
import sys

import background


ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "artifacts" / "m2-checks"
DEFAULT_SEED = "659966"
MAX_U64 = "18446744073709551615"
SEEDS = ("0", "1", "42", DEFAULT_SEED, "72019", MAX_U64)
CAPTURE_SIZE = (2560, 1440)


def run_report(binary: pathlib.Path, seed: str, name: str) -> str:
    result = subprocess.run(
        [str(binary), "--world-report", "--seed", seed],
        cwd="/tmp",
        capture_output=True,
        text=True,
        timeout=180,
    )
    report = result.stdout + result.stderr
    (OUTPUT / f"world-{name}.log").write_text(report)
    if result.returncode != 0:
        raise RuntimeError(f"world report for seed {seed} failed:\n{report}")
    return report


def field(pattern: str, report: str, label: str) -> str:
    match = re.search(pattern, report, re.MULTILINE)
    if not match:
        raise AssertionError(f"missing {label} in world report:\n{report}")
    return match.group(1)


def validate_report(report: str, requested_seed: str) -> None:
    seed = field(r"^seed=(\d+)", report, "seed")
    if seed != str(int(requested_seed, 0)):
        raise AssertionError(f"requested seed {requested_seed}, report returned {seed}")

    macro = field(r"^seed=\d+ generation_seed=(\d+) repaired=(?:true|false) macro_fingerprint=([0-9a-fA-F]+)$", report, "macro header")
    del macro  # The expression also verifies that regeneration metadata is present.

    world_peak = float(field(r"^region_m=.*peak_world_y=([-+0-9.eE]+)", report, "world peak"))
    above_sea = float(field(r"^region_m=.*peak_above_sea_m=([-+0-9.eE]+)", report, "peak above sea"))
    if not math.isfinite(world_peak) or not math.isfinite(above_sea) or above_sea <= 0:
        raise AssertionError(f"invalid peak heights: world={world_peak} above sea={above_sea}")

    river_nodes = int(field(r"^river_nodes=(\d+)", report, "river nodes"))
    lake_nodes = int(field(r"^river_nodes=\d+ lake_nodes=(\d+)", report, "lake nodes"))
    rain_min = int(field(r"^river_nodes=\d+ lake_nodes=\d+ rainfall_mm=(\d+)\.\.", report, "minimum rainfall"))
    rain_max = int(field(r"^river_nodes=\d+ lake_nodes=\d+ rainfall_mm=\d+\.\.(\d+)", report, "maximum rainfall"))
    if river_nodes <= 0 or lake_nodes < 0:
        raise AssertionError(f"invalid hydrology counts: rivers={river_nodes} lakes={lake_nodes}")
    if rain_min <= 0 or rain_max <= rain_min:
        raise AssertionError(f"rainfall does not vary positively: {rain_min}..{rain_max} mm")

    suitability = int(field(r"^start=.* suitability=(\d+)", report, "settlement suitability"))
    if suitability <= 0:
        raise AssertionError("no positive settlement candidate suitability")

    biomes = {name: int(value) for name, value in re.findall(r"^biome_([a-z0-9_]+)=(\d+)$", report, re.MULTILINE)}
    land_biomes = {name: count for name, count in biomes.items() if name not in {"water", "shore"} and count > 0}
    if len(land_biomes) < 2:
        raise AssertionError(f"fewer than two land biomes: {land_biomes}")

    evictions = int(field(r"^stream_hits=\d+ misses=\d+ evictions=(\d+)", report, "stream evictions"))
    if evictions <= 0:
        raise AssertionError("streaming scan did not exercise cache eviction")


def normalize_report(report: str) -> str:
    """Ignore cache counters while requiring all generated geography to match."""
    normalized = re.sub(r"^stream_hits=\d+ misses=\d+ evictions=\d+\s*$", "stream_stats=<ignored>", report, flags=re.MULTILINE)
    return normalized.strip()


def capture(binary: pathlib.Path, name: str, *arguments: str) -> bytes:
    path = OUTPUT / f"{name}.ppm"
    command = [
        str(binary),
        "--size",
        f"{CAPTURE_SIZE[0]}x{CAPTURE_SIZE[1]}",
        "--hide-hud",
        "--capture",
        str(path),
        *arguments,
    ]
    env = os.environ.copy()
    layers = [layer for layer in env.get("VK_INSTANCE_LAYERS", "").split(":") if layer]
    if "VK_LAYER_KHRONOS_validation" not in layers:
        layers.append("VK_LAYER_KHRONOS_validation")
    env["VK_INSTANCE_LAYERS"] = ":".join(layers)

    result = background.run(command, cwd="/tmp", env=env, text=True, timeout=180)
    log_text = result.stdout + result.stderr
    (OUTPUT / f"{name}.log").write_text(log_text)
    if result.returncode != 0:
        raise RuntimeError(f"native capture {name} failed:\n{log_text}")
    if "VUID-" in log_text or "Validation Error" in log_text:
        raise AssertionError(f"Vulkan validation error during {name}:\n{log_text}")
    if not path.is_file():
        raise AssertionError(f"capture {name} did not create {path}")

    data = path.read_bytes()
    header = re.match(rb"P6\n(\d+) (\d+)\n255\n", data)
    if not header:
        raise AssertionError(f"{name} is not a binary PPM image")
    width, height = int(header.group(1)), int(header.group(2))
    pixels = data[header.end() :]
    if (width, height) != CAPTURE_SIZE or len(pixels) != width * height * 3:
        raise AssertionError(f"{name} has dimensions/data {width}x{height}/{len(pixels)} bytes")
    if len(set(pixels)) < 32:
        raise AssertionError(f"{name} has too little color variation")
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--headless-only", action="store_true", help="skip Wayland/Vulkan 1440p captures")
    args = parser.parse_args()

    OUTPUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["zig", "build", "-Doptimize=ReleaseSmall"], cwd=ROOT, check=True)
    binary = ROOT / "zig-out" / "bin" / "ascii-life"
    if not binary.is_file():
        raise FileNotFoundError(binary)

    default_report = ""
    for seed in SEEDS:
        name = "default" if seed == DEFAULT_SEED else f"seed-{seed}"
        report = run_report(binary, seed, name)
        validate_report(report, seed)
        if seed == DEFAULT_SEED:
            default_report = report
        print(f"PASS world seed {seed}")

    repeated_default = run_report(binary, DEFAULT_SEED, "default-repeat")
    validate_report(repeated_default, DEFAULT_SEED)
    if normalize_report(default_report) != normalize_report(repeated_default):
        raise AssertionError("repeated default world report changed outside streaming cache counters")
    print("PASS repeated default geography (cache counters ignored)")

    if args.headless_only:
        print(f"PASS Milestone 2 headless suite; reports: {OUTPUT}")
        return 0

    atlas = capture(binary, "atlas", "--atlas")
    default = capture(binary, "default-capture")
    repeated = capture(binary, "default-repeat-capture")
    other_seed = capture(binary, "alternate-seed", "--seed", "72019")
    night = capture(binary, "night", "--time", "0.02")
    third_person = capture(binary, "third-person", "--third-person")
    if default != repeated:
        raise AssertionError("identical default 1440p captures differ")
    for name, variant in (("atlas", atlas), ("alternate seed", other_seed), ("night", night), ("third person", third_person)):
        if variant == default:
            raise AssertionError(f"{name} capture is unchanged from the default landscape")
    print(f"PASS 2560x1440 Vulkan captures (atlas, repeated default, alternate seed, night, third person); artifacts: {OUTPUT}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, FileNotFoundError, RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
