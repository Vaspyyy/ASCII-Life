#!/usr/bin/env python3
"""Check bounded social state, learned disclosures and native 1440p panels."""
import argparse
import pathlib
import re
import subprocess
import sys

sys.dont_write_bytecode = True
import verify_m2 as graphics

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "artifacts" / "m4-checks"


def report(binary, name, *options):
    result = subprocess.run([str(binary), "--people-report", *options], cwd="/tmp",
                            text=True, capture_output=True, timeout=180)
    text = result.stdout + result.stderr
    (OUTPUT / f"{name}.log").write_text(text)
    assert result.returncode == 0, text
    assert "social_validation_ok=1" in text, text
    return text


def number(text, key):
    match = re.search(r"\b" + key + r"=(\d+)", text)
    assert match, (key, text)
    return int(match.group(1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--headless-only", action="store_true")
    args = parser.parse_args()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["zig", "build", "-Doptimize=ReleaseSmall"], cwd=ROOT, check=True)
    binary = ROOT / "zig-out/bin/ascii-life"
    for seed in (0, 1, 42, 659966, 72019, 18446744073709551615):
        initial = report(binary, f"initial-{seed}", "--seed", str(seed))
        assert number(initial, "journal_entries") == 0
        weeks = report(binary, f"weeks-{seed}", "--seed", str(seed), "--simulate-days", "28")
        assert initial != weeks
        if seed == 659966:
            assert weeks == report(binary, "weeks-repeat", "--seed", str(seed), "--simulate-days", "28")
        print(f"PASS seed {seed}: social invariants and 28 unattended days", flush=True)
    unknown = report(binary, "unknown", "--talk-to", "0", "--say", "a purple moon owes me cheese")
    assert number(unknown, "journal_entries") == 0, unknown
    private = report(binary, "private", "--talk-to", "0", "--say", "family")
    assert number(private, "journal_entries") == 0, private
    options = ["--talk-to", "0", "--say", "name", "--say", "work", "--say", "news"]
    learned = report(binary, "learned", *options)
    assert number(learned, "journal_entries") >= 2, learned
    assert "journal_source=0" in learned, learned
    assert learned == report(binary, "learned-repeat", *options)
    goodbye = report(binary, "goodbye", "--talk-to", "0", "--say", "goodbye")
    assert "conversation_active=false" in goodbye
    neutral = report(binary, "neutral", "--talk-to", "0", "--say", "hello")
    insulted = report(binary, "insulted", "--talk-to", "0", "--say", "you are rude", "--say", "hello")
    assert "trust=-8" in insulted
    assert re.findall(r"^reply=(.*)$", neutral, re.MULTILINE)[-1] != re.findall(r"^reply=(.*)$", insulted, re.MULTILINE)[-1]
    for invalid in (("--say", "hello"), ("--talk-to", "999"),
                    ("--talk-to", "0", "--say", "x" * 97),
                    ("--talk-to", "0", "--say", "grüß dich")):
        result = subprocess.run([str(binary), "--people-report", *invalid], cwd="/tmp",
                                text=True, capture_output=True, timeout=30)
        assert result.returncode != 0, invalid
    print("PASS explicit grammar, private boundaries, learned-only journal and repeat replies", flush=True)
    if args.headless_only:
        return
    graphics.OUTPUT = OUTPUT
    conversation = graphics.capture(binary, "conversation", *options)
    assert conversation == graphics.capture(binary, "conversation-repeat", *options)
    journal = graphics.capture(binary, "journal", *options, "--journal")
    assert conversation != journal
    private_frame = graphics.capture(binary, "private", "--talk-to", "0", "--say", "family")
    assert conversation != private_frame
    graphics.capture(binary, "third-person-conversation", *options, "--third-person")
    print(f"PASS native 1440p conversation, journal, privacy and third person; {OUTPUT}")


if __name__ == "__main__":
    main()
