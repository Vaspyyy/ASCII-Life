# Size Discipline

Binary size is part of ASCII-Life's identity.

It is not the only metric.

The game must also be beautiful, maintainable, deterministic, and fun.

## Two official records

### Dynamic ELF

Measure the stripped release executable produced for the normal Linux build.

Record:

- exact bytes
- Zig version
- build flags
- linked shared libraries
- commit SHA

### Self-contained distribution

Measure the smallest practical redistributable form that includes everything the project itself must ship.

The record may exclude:

- Linux kernel
- Wayland compositor
- GPU driver and Vulkan ICD
- hardware/firmware
- other unavoidable host infrastructure

Document any remaining host library assumptions honestly.

If a truly static/self-contained variant is blocked by the Linux graphics stack, document the boundary instead of pretending otherwise.

## What counts

Count any project-shipped:

- binary
- dynamic library
- data file
- font
- shader blob
- texture
- model
- audio
- localization pack
- script/runtime
- generated cache required before first launch

A feature does not become free merely because it was moved out of the ELF.

## Size ledger

For milestone releases, maintain a table like:

| Commit | Milestone | Dynamic ELF | Self-contained | Notes |
| --- | --- | ---: | ---: | --- |
| ... | M0 | ... | ... | baseline |

Add this table once measurements exist.

## Optimization priority

Prefer savings in this order:

1. remove unnecessary feature/data
2. represent the feature procedurally
3. share mechanisms between systems
4. compact data representation
5. build/link configuration
6. strip symbols/debug data from release
7. remove dependency overhead
8. targeted low-level byte optimization

Do not start with unreadable code golf.

## Asset policy

Default assumption: do not ship conventional assets.

Prefer generated:

- terrain
- vegetation
- materials
- architecture
- animation
- particles
- sound
- music
- UI decoration
- creature variation

Exceptions require evidence that the shipped representation is worth its byte cost.

A tiny embedded bitmap glyph set is expected and not considered a violation of the project's spirit.

## Shader policy

Shaders count.

Prefer compact shader source or generated SPIR-V strategies based on measured total build size and startup cost.

Do not assume precompiled shader blobs are always smaller.

Measure.

## Sound

Long-term direction is procedural synthesis or extremely compact encoded representations.

Do not block early visual milestones on audio architecture.

## Compression

Compression is valid, but report both:

- distributable compressed size
- installed/runtime required size where meaningful

Never use a compressed archive number to hide a bloated required payload.

## Save files

Save size is not part of the executable record, but it matters.

The save should remain compact by storing persistent consequences and deltas rather than a full generated planet.

Track unusually large save growth as a bug or design concern.

## Performance tradeoffs

Never save 2 KB at the cost of making the game unusably slow unless the tiny build is explicitly a separate demonstration profile.

It is acceptable to have multiple release profiles later, for example:

- normal
- size-focused
- ultra-tiny demo

Do not create them before there is something meaningful to measure.

## Milestone 0 baseline — 2026-09-27

Measured on the working tree based on commit `9fabf00b8782e88c14de26033f8d26ef2185e030`; implementation changes were not committed at measurement time. The build/source/shader digest is `b611b68332f90bb0baff87b7b3419924ec3cee46c03c94d9c5c0bdfffabe911c` (SHA-256 over sorted relative filenames plus NUL, file bytes, NUL for `build.zig`, `src/*`, and `shaders/*`).

Environment: Zig 0.16.0, x86-64 CachyOS, KDE Wayland, NVIDIA RTX 3070, NVIDIA 615.71.09, Vulkan loader/validation 1.4.357. No other graphics stack is claimed tested.

| Record | Exact bytes | Notes |
| --- | ---: | --- |
| Stripped dynamic ELF | 61,176 | `zig build -Doptimize=ReleaseSmall` |
| Single ELF compressed with `xz -9` | 23,236 | Requires host libraries; not self-contained |
| Local runtime bundle payload | 3,553,421 | ELF, loader, resolved shared-library closure, license notices, launcher, README |
| Local runtime bundle `.tar.xz` | 1,222,496 | Compressed distribution experiment, not installed size |
| Embedded glyph bitsets | 1,024 | 128 entries × 8 bytes |
| Compiled vertex + fragment shaders | 4,004 | 876 + 3,128 bytes; included in ELF above |

ELF SHA-256: `644fde61e119d508209928411aeaccb40649e691a965d4c525f6f0d5ea7e8b4b`.

The ordinary ELF's direct dependencies are `libwayland-client.so.0`, `libvulkan.so.1`, `libc.so.6`, and `ld-linux-x86-64.so.2`; Wayland additionally resolves `libffi.so.8`. No external font, texture, model, shader file, or network service is required. A run from `/tmp` verified independence from repository-relative assets.

The bundle is generated with `scripts/bundle.py`. Its bundled loader was checked with `--list` to confirm that the dependency closure resolves inside the bundle, then the bundle completed a native 120-frame run from `/tmp`. It still relies on the host kernel, active Wayland compositor, GPU ICD/driver and their infrastructure. The optional launcher also uses the host shell and `dirname`; invoking the included loader directly avoids that launcher dependency. This is a tested same-host runtime bundle, **not** a fully static ELF or a claim of cross-distribution compatibility. The installed development packages do not provide static Wayland-client/Vulkan-loader archives. No static-graphics-stack size is fabricated.

### Runtime baseline

`scripts/measure.py` built the stripped release and ran 600 presented frames at 1280 × 720 with a 160 × 90 logical field. RSS sampling began two seconds after the first-present signal. NVIDIA process memory was sampled once to limit interference. Other desktop applications remained running, so these are baseline observations rather than isolated laboratory results.

| Measurement | Observed |
| --- | ---: |
| Main entry to first successful present call | 147.771 ms |
| Main-thread CPU per draw attempt | 0.6151 ms |
| Frame work wall time, excluding explicit pacing sleep | 0.6258 ms |
| GPU command interval | 0.0384 ms average, 599 samples |
| 600-frame elapsed time including startup | 10,165.98 ms |
| Steady process RSS | 81,740–81,800 KiB |
| NVIDIA per-process graphics memory | 19 MiB |

CPU timing uses `CLOCK_THREAD_CPUTIME_ID`; it includes cell generation, event handling, and Vulkan calls but excludes driver worker threads. GPU timestamps bracket recorded work, not compositor latency or scanout. The last submitted frame's timestamp is not included because results are collected on the following frame. Startup is measured inside the program, not from `exec` or physical display scanout. RSS and NVIDIA memory include native library/driver/context costs; they are not estimates of the cell representation alone. Ordinary runs allocate a 230,400-byte cell payload and 1,024-byte glyph payload before Vulkan allocation alignment. Capture memory is allocated only on request.

### Measured size experiment

The first complete capture-capable release used `std.debug.print` and the default error-returning main path: **188,032 bytes**. Symbol inspection of an unstripped build exposed general I/O and diagnostic machinery, including unused networking/process support. Replacing normal diagnostics with bounded `std.fmt.bufPrint` plus the already-linked C runtime's synchronous `fwrite`, and handling top-level errors explicitly, produced **61,016 bytes** with the same features. Debug builds still retain error traces. The final capture-resize safety fix added 160 bytes, yielding **61,176 bytes**. No source minification, removed renderer feature, or externalized asset accounts for this reduction.

### Validation evidence and limits

- Debug and ReleaseSmall deterministic tests pass: cell layout/glyph orientation, explicit-tick repeatability, and a fixed tick-zero scene fingerprint.
- Final debug 120-frame run with `VK_LAYER_KHRONOS_validation` exited cleanly with no validation messages.
- Native keyboard and pointer events were observed; Escape cleanly exited.
- F11 changed the acknowledged surface from 1280 × 720 to 2560 × 1440 and back; both swapchain recreations and subsequent rendering were validation-clean.
- A real Vulkan image readback was inspected at 1280 × 720. Glyphs, foreground/background colors, orientation, labels, and scene composition render correctly. KDE desktop screenshot capture was unavailable through the automation backend; the capture is a framebuffer readback, not a compositor screenshot.
- Zero extent and xdg suspended state are handled in code; manual compositor minimization was not exercised. Other GPUs, mixed-DPI outputs, and compositor families remain untested.
- Visual captures and raw logs are local outputs under ignored `artifacts/`; regenerate them with the documented commands rather than shipping them as game assets.
