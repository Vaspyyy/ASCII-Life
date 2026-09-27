#!/usr/bin/env python3
"""Measure a bounded release run without changing desktop settings."""
import os
import pathlib
import select
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

root = pathlib.Path(__file__).resolve().parent.parent
subprocess.run(["zig", "build", "-Doptimize=ReleaseSmall"], cwd=root, check=True)
binary = root / "zig-out/bin/ascii-life"
process = subprocess.Popen([str(binary), "--size", "2560x1440", *sys.argv[1:], "--metrics", "--frames", "600"], cwd=root,
                           stderr=subprocess.PIPE)
os.set_blocking(process.stderr.fileno(), False)
log_parts = []
first_present = None
vram_sampled = False
samples = []
gpu_samples = []
start = time.monotonic()
while process.poll() is None:
    if select.select([process.stderr], [], [], 0)[0]:
        log_parts.append(os.read(process.stderr.fileno(), 65536))
        if first_present is None and b"startup_to_first_present_ms=" in b"".join(log_parts):
            first_present = time.monotonic()
    if first_present is not None and time.monotonic() - first_present > 2:
        try:
            status = pathlib.Path(f"/proc/{process.pid}/status").read_text()
            samples.append(int(next(line.split()[1] for line in status.splitlines()
                                    if line.startswith("VmRSS:"))))
        except (FileNotFoundError, StopIteration):
            pass
        # Probe the driver only once to limit measurement interference.
        if not vram_sampled:
            vram_sampled = True
            try:
                result = subprocess.run(["nvidia-smi", "-q", "-x"], capture_output=True,
                                        text=True, timeout=2, check=True)
                for info in ET.fromstring(result.stdout).findall(".//process_info"):
                    if info.findtext("pid") == str(process.pid):
                        value = info.findtext("used_memory", "N/A")
                        if value.endswith(" MiB"):
                            gpu_samples.append(int(value.split()[0]))
            except (OSError, ValueError, ET.ParseError, subprocess.SubprocessError):
                pass
    if time.monotonic() - start > 30:
        process.terminate()
        print("Measurement interrupted: window may be suspended; keep it visible.")
        break
    time.sleep(0.5)
_, tail = process.communicate(timeout=5)
log_parts.append(tail)
print(b"".join(log_parts).decode(errors="replace"), end="")
print(f"exit_code={process.returncode} elf_bytes={binary.stat().st_size}")
if samples:
    print(f"steady_rss_kib_min={min(samples)} steady_rss_kib_max={max(samples)}")
else:
    print("steady_rss=unavailable")
if gpu_samples:
    print(f"nvidia_process_memory_mib={sum(gpu_samples)}")
else:
    print("per_process_vram=unavailable (not inferred from total GPU usage)")
raise SystemExit(process.returncode)
