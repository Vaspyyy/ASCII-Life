#!/usr/bin/env python3
"""Verify causal livestock, sourced discovery and native 1440p presentation."""
import argparse
import pathlib
import re
import subprocess
import sys
sys.dont_write_bytecode = True
import verify_m2 as graphics

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'artifacts' / 'm5-checks'


def report(binary, name, *options):
    result = subprocess.run([str(binary), '--ecology-report', *options], cwd='/tmp',
                            text=True, capture_output=True, timeout=180)
    text = result.stdout + result.stderr
    (OUTPUT / f'{name}.log').write_text(text)
    assert result.returncode == 0, text
    assert 'ecology_validation_ok=1' in text and 'social_validation_ok=1' in text, text
    return text


def number(text, key):
    match = re.search(r'\b' + key + r'=(\d+)', text)
    assert match, (key, text)
    return int(match.group(1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--headless-only', action='store_true')
    args = parser.parse_args()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(['zig', 'build', '-Doptimize=ReleaseSmall'], cwd=ROOT, check=True)
    binary = ROOT / 'zig-out/bin/ascii-life'
    for seed in (0, 1, 42, 659966, 72019, 18446744073709551615):
        initial = report(binary, f'initial-{seed}', '--seed', str(seed))
        weeks = report(binary, f'weeks-{seed}', '--seed', str(seed), '--simulate-days', '28')
        assert number(initial, 'journal_entries') == 0
        assert number(initial, 'animals') > 0
        assert number(weeks, 'animals') + number(weeks, 'losses') == number(weeks, 'initial_animals')
        assert number(weeks, 'livestock_food_produced') > 0
        if seed == 659966:
            assert weeks == report(binary, 'weeks-repeat', '--seed', str(seed), '--simulate-days', '28')
        print(f'PASS seed {seed}: 28-day ecology, social and stock conservation', flush=True)
    initial = report(binary, 'default', '--time', '.38')
    owner = str(number(initial, 'livestock_owner'))
    help_text = report(binary, 'offer', '--time', '.38', '--talk-to', owner, '--say', 'help')
    assert number(help_text, 'player_work_seconds') == 0
    assert 'trust=0' in help_text
    worked = report(binary, 'work', '--time', '.38', '--work-seconds', '3600')
    assert number(worked, 'repairs') > number(initial, 'repairs')
    assert number(worked, 'repair_goods_consumed') > 0
    assert worked == report(binary, 'work-repeat', '--time', '.38', '--work-seconds', '3600')
    learned = report(binary, 'learned', '--time', '.38', '--talk-to', owner, '--say', 'name', '--say', 'ask about livestock', '--say', 'help')
    assert number(learned, 'journal_entries') >= 2
    notice = report(binary, 'notice', '--time', '.38', '--notice')
    assert number(notice, 'journal_entries') >= 2
    assert 'Public notice' not in notice or 'Signed' in notice
    assert 'conversation_active=false' in notice and 'Signed Bevan' in notice
    print('PASS sourced discovery, signed notice, unrewarded offer and actual consequential repair', flush=True)
    if args.headless_only:
        return
    graphics.OUTPUT = OUTPUT
    pen = graphics.capture(binary, 'pen', '--pen-view', '--time', '.38')
    assert pen == graphics.capture(binary, 'pen-repeat', '--pen-view', '--time', '.38')
    repaired = graphics.capture(binary, 'repaired', '--pen-view', '--time', '.38', '--work-seconds', '3600')
    assert pen != repaired
    graphics.capture(binary, 'pen-third-person', '--pen-view', '--third-person')
    graphics.capture(binary, 'livestock-conversation', '--time', '.38', '--talk-to', owner, '--say', 'ask about livestock', '--say', 'help')
    graphics.capture(binary, 'notice', '--time', '.38', '--notice')
    graphics.capture(binary, 'notice-board', '--time', '.38', '--view', '0,-3085,0,-0.13,0')
    graphics.capture(binary, 'wolves', '--time', '.9', '--pen-view')
    graphics.capture(binary, 'weeks-pen', '--pen-view', '--elapsed-days', '28')
    print(f'PASS native 1440p pen, repair, third person, disclosure and unattended outcomes; {OUTPUT}')


if __name__ == '__main__':
    main()
