#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
zig build -Doptimize=ReleaseSmall
binary=zig-out/bin/ascii-life
printf 'Commit: '; git rev-parse HEAD
printf 'Zig: '; zig version
printf 'Build: zig build -Doptimize=ReleaseSmall (stripped)\n'
printf 'Dynamic ELF bytes: '; stat -c %s "$binary"
printf '\nELF sections:\n'; size "$binary"
printf '\nShared libraries (host-resolved):\n'; ldd "$binary"
printf '\nSingle-file distribution, xz bytes: '; xz -c -9 "$binary" | wc -c
printf '\nThe single-file distribution requires host libraries; it is not self-contained.\n'
