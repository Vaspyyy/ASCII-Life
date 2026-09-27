#!/usr/bin/env python3
"""Headless living-village checks and native 1440p Vulkan captures."""
from __future__ import annotations
import argparse
import pathlib
import re
import subprocess
import sys
sys.dont_write_bytecode = True
import verify_m2 as graphics

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'artifacts' / 'm3-checks'


def report(binary, seed, days=0, time='0.36'):
    result = subprocess.run([str(binary), '--seed', str(seed), '--time', time,
                             '--simulate-days', str(days)], cwd='/tmp', text=True,
                            capture_output=True, timeout=180)
    text = result.stdout + result.stderr
    (OUTPUT / f'village-{seed}-{days}-{time}.log').write_text(text)
    assert result.returncode == 0, text
    def number(key):
        match = re.search(r'\b' + key + r'=(\d+)', text)
        assert match, (key, text)
        return int(match.group(1))
    assert number('homes') >= 6, text
    assert number('farms') >= 2, text
    assert number('residents') >= 12, text
    assert number('households') >= 6, text
    assert number('paths') > 0, text
    assert number('unassigned_adults') == 0, text
    assert number('validation_ok') == 1, text
    if days:
        assert number('food_produced') > 0 and number('food_consumed') > 0, text
        assert number('food_shortage') == 0 and number('water_shortage') == 0, text
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--headless-only', action='store_true')
    args = parser.parse_args()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(['zig', 'build', '-Doptimize=ReleaseSmall'], cwd=ROOT, check=True)
    binary = ROOT / 'zig-out/bin/ascii-life'
    for seed in (0, 1, 42, 659966, 72019, 18446744073709551615):
        initial = report(binary, seed)
        weeks = report(binary, seed, 28)
        assert initial != weeks
        if seed == 659966:
            assert weeks == report(binary, seed, 28), 'unattended simulation changed on repeat'
        print(f'PASS seed {seed}: assigned village, 28 unattended days', flush=True)
    if args.headless_only:
        return
    graphics.OUTPUT = OUTPUT
    day = graphics.capture(binary, 'arrival')
    assert day == graphics.capture(binary, 'arrival-repeat')
    for name, options in (
        ('overview', ['--village-overview']),
        ('evening', ['--village-overview', '--time', '0.72']),
        ('commute', ['--village-overview', '--time', '0.22']),
        ('night', ['--time', '0.02']),
        ('third-person', ['--third-person']),
        ('other-seed', ['--seed', '72019']),
    ):
        assert day != graphics.capture(binary, name, *options), name
    print(f'PASS native 1440p repeated arrival, overview, evening, night, third person, seed; {OUTPUT}')

if __name__ == '__main__':
    main()
