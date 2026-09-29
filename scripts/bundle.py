#!/usr/bin/env python3
"""Build a measured local runtime bundle; GPU/compositor infrastructure stays host-owned."""
import pathlib
import re
import shutil
import subprocess
import tarfile

root = pathlib.Path(__file__).resolve().parent.parent
subprocess.run(["zig", "build", "-Doptimize=ReleaseSmall"], cwd=root, check=True)
binary = root / "zig-out/bin/ascii-life"
bundle = root / "artifacts/ascii-life-runtime"
if bundle.exists():
    raise SystemExit(f"Output already exists: {bundle}. Move it aside before rebuilding.")
(bundle / "lib").mkdir(parents=True)
shutil.copy2(binary, bundle / "ascii-life")
listing = subprocess.check_output(["ldd", str(binary)], text=True)
for path in sorted(set(re.findall(r"(/[^\s]+)", listing))):
    source = pathlib.Path(path)
    shutil.copy2(source.resolve(), bundle / "lib" / source.name)
licenses = bundle / "licenses"
licenses.mkdir()
for package in ("glibc", "wayland", "libffi", "libxkbcommon", "vulkan-icd-loader"):
    source = pathlib.Path("/usr/share/licenses") / package
    if source.exists():
        shutil.copytree(source, licenses / package, symlinks=False)
(bundle / "run").write_text('''#!/bin/sh
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$base/lib/ld-linux-x86-64.so.2" --library-path "$base/lib" "$base/ascii-life" "$@"
''')
(bundle / "run").chmod(0o755)
(bundle / "README.txt").write_text('''ASCII-Life Milestone 5 local runtime bundle.
Run ./run inside an active Wayland session.
Includes the executable and its current ldd library closure, with available
system package license notices. Generated for the tested x86-64 CachyOS host.
Excludes kernel, compositor, GPU driver/ICD and their infrastructure.
The optional launcher uses the host shell, dirname and pwd. The bundled
ld-linux loader can also be invoked directly with --library-path ./lib.
This is a same-host packaging measurement, not a cross-distribution guarantee.
''')
archive = bundle.with_suffix(".tar.xz")
with tarfile.open(archive, "w:xz", preset=9) as output:
    output.add(bundle, arcname=bundle.name)
size = sum(p.stat().st_size for p in bundle.rglob("*") if p.is_file())
print(f"bundle_payload_bytes={size}")
print(f"bundle_archive_bytes={archive.stat().st_size}")
print(f"bundle={bundle}")
