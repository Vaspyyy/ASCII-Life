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

## Milestone 1 landscape — 2026-09-27

Measured on the M1 working tree based on `51c94143c32f771380b382f615770a485e1b19c2`, using the same Zig 0.16.0 / KDE Wayland / RTX 3070 host as M0. Build/source/shader digest, using the M0 procedure: `8f963f841f0588a771f97c7513cbd8bc7816164345ab68282a046d84a54f7859`. ELF SHA-256: `01b3f6285c36e9088c892f13596428500538dd66a9e0e3872ee63f46500e11cc`.

| Record | Exact bytes | Change from M0 |
| --- | ---: | ---: |
| Stripped dynamic ELF | 120,840 | +59,664 |
| Single ELF compressed with `xz -9` | 59,388 | +36,152 |
| Local runtime bundle payload | 3,613,085 | +59,664 |
| Local runtime bundle `.tar.xz` | 1,258,436 | +35,940 |
| Transient height cache | 2,101,250 | New; generated at startup, not shipped |
| Logical cell payload | 518,400 | +288,000 |
| Per-cell terrain depth plane | 129,600 | New CPU working memory |
| Embedded glyph bitsets | 1,024 | Unchanged |

No dependencies or external assets were added. The practical bundle retains the M0 host boundary: it includes the locally resolved library closure, but requires the kernel, Wayland compositor and GPU driver/ICD infrastructure. It is not a fully static executable or a cross-distribution compatibility claim. The new bundle completed a 120-frame native run from `/tmp`.

### Runtime measurements

Both commands presented 600 frames at **1920 × 1080**, with a **240 × 135** logical field, default seed `0xa11fe`, and no validation layer. These are larger pixel and cell counts than the M0 baseline, so this is a milestone cost record rather than a controlled renderer speed comparison. Measurement definitions and host-noise limitations remain as described under M0.

| Measurement | `scripts/measure.py --static` | `scripts/measure.py --tour` |
| --- | ---: | ---: |
| Heightfield generation | 58.357 ms | 58.978 ms |
| Main entry to first successful present | 199.807 ms | 202.695 ms |
| Main-thread CPU per draw attempt | 3.7630 ms | 3.7583 ms |
| Frame work wall time | 3.8340 ms | 3.8060 ms |
| GPU command interval, 599 samples | 0.0781 ms | 0.0756 ms |
| 600-frame elapsed time including startup | 10,217.38 ms | 10,220.34 ms |
| Steady RSS | 84,868–84,928 KiB | 84,908–84,968 KiB |
| NVIDIA per-process graphics memory | 37 MiB | 37 MiB |

The fixed-step tour advances movement and visual time once per successful presentation and switches to third person at its midpoint. Its final reported pose was `216.85,-87.24,0.900,0.100,0.00`, third person, day fraction `0.4017`. The CPU cost includes procedural glyph selection and tree projection; the GPU rasterizes the resulting cells. Both runs used the existing 60 Hz work cap.

### Validation and visual evidence

- Debug and ReleaseSmall tests pass for the complete terrain fingerprint, seed distinction, bounds/normals, stable tree identities, camera motion, third-person framing, glyph layout, sun direction under camera yaw, and repeated landscape output.
- `scripts/verify_m1.py` passes: identical inputs produce byte-identical native GPU captures; alternate seeds, day/night and camera views differ; two fixed-step tours end in the same state; invalid arguments are rejected. Captures run from `/tmp` under `VK_LAYER_KHRONOS_validation`, with no Vulkan validation errors.
- Native key input verified movement, turning, camera switching and stepping time. F11 resized 1920 × 1080 → 2560 × 1440 → 1920 × 1080, and Escape exited cleanly. These input/resize checks were performed before the final shading and camera-framing adjustments; those adjustments were subsequently covered by unit tests, native tours and captures.
- Inspected native readbacks include the default shoreline, night lighting, an elevated lake vista, and third-person upward framing. Reproduce the elevated view with `--hide-hud --view 60,-600,0,-0.12,120 --capture artifacts/vista.ppm`. Images/logs remain local ignored artifacts, not shipped content.

This remains a landscape prototype. Water reflection approximates sky color and sunlight; it does not reflect nearby geometry. Trees and the explorer use generated projected silhouettes. There is no physical tree collision, swimming, animation rig or life simulation. Third-person terrain clearance can force close framing in extreme clefts. The finite heightfield clamps at its boundary; planetary geography, hydrology and streaming are later work. Visual quality beyond the inspected views and other GPUs/compositors is not claimed validated.


## 1440p completion baseline — 2026-09-27

From this point, completion metrics use **2560 × 1440** output by default. Remeasured the unchanged M1 executable from commit `8e4fb8f6bee1204f7a21477b9ae90021801b1568` on the same RTX 3070 / KDE Wayland host, ReleaseSmall, seed `0xa11fe`. Native window inspection confirmed 2560 × 1440. Each run presented 600 frames, with 599 GPU timestamp samples, without validation layers. The current logical grid remains **240 × 135 (32,400 cells)**.

| Metric | Stationary (`--static`) | Moving (`--tour`) |
| --- | ---: | ---: |
| Terrain generation | 61.667 ms | 57.778 ms |
| Main entry to first successful present | 221.966 ms | 206.353 ms |
| CPU per frame/draw attempt | 3.7112 ms | 3.7044 ms |
| GPU command interval | 0.1059 ms | 0.1047 ms |
| Uncapped CPU-equivalent FPS (`1000 / CPU ms`) | 269.45 | 269.95 |
| Steady RSS | 84,864–84,928 KiB | 84,912–84,972 KiB |
| NVIDIA process graphics memory | 55 MiB | 55 MiB |

CPU-equivalent FPS is an arithmetic estimate of main-thread capacity, not measured uncapped presentation throughput. The application retains its 60 Hz work cap and FIFO presentation. Startup measures main entry to the successful present call, not physical display scanout. RSS includes native libraries and driver/context allocations; driver-reported process graphics memory is the available VRAM measurement.

Reverified packaging sizes: **120,840 bytes** stripped dynamic ELF; **59,388 bytes** `xz -9` ELF; **1,258,436 bytes** runtime `.tar.xz` (3,613,085-byte unpacked payload). The bundle's ELF checksum still matches the measured game. Resolution does not alter those files; no runtime/source changes were needed for this measurement.

The finite region is **8,192 × 8,192 m (67.108864 km²)**. A full scan of its 1,050,625 cached height samples found peak world Y **1,040.75 m**, or **960.75 m above the water/sea datum at Y=80 m**, for seed `0xa11fe`. Bilinear interpolation cannot exceed the maximum cached corner height. This is the complete region maximum, not a sampled visible ridge or the generator's theoretical height limit.

Raw run logs are `artifacts/m1-1440-static.log` and `artifacts/m1-1440-tour.log`. Historical 1080p measurements above remain unchanged.

## Milestone 2 geography — 2026-09-27

Measured the M2 working tree based on `b6e3d7499a9700a9366e95117c9f59d83c1771b4`, Zig 0.16.0 ReleaseSmall, on the same KDE Wayland / RTX 3070 host. Build/source/shader digest using the M0 procedure: `78999373dac77260c9416344907e21f31fb5aa118fc1231467792a5b297a32e3`. ELF SHA-256: `a6c650bb747651c8e54eb6e65492e1f47fe505aa7d3c03a34662b551a401e927`.

| Distribution | Exact bytes | Change from M1 |
| --- | ---: | ---: |
| Stripped dynamic ELF | 150,504 | +29,664 |
| ELF compressed with `xz -9` | 73,616 | +14,228 |
| Runtime bundle payload | 3,642,749 | +29,664 |
| Runtime bundle `.tar.xz` | 1,272,376 | +13,940 |

No dependencies or external assets were added. The runtime bundle retains the host requirements documented above; it is not fully static. It passed a native 120-frame run from `/tmp` at 2560 × 1440.

Both measured runs presented 600 frames at **2560 × 1440**, seed `0xa11fe`, with 599 GPU samples and no validation layer. The logical field is **240 × 135 (32,400 cells)**. The region remains **8,192 × 8,192 m (67.108864 km²)**. A complete fine-lattice scan found peak world Y **1,040.75 m**, or **960.75 m above sea level**. The hydrology lattice is 257 × 257 at 32 m spacing; streamed terrain uses 8 m samples in 512 m tiles.

| Metric | Stationary | Moving tour |
| --- | ---: | ---: |
| Terrain/geography generation | 35.310 ms | 34.792 ms |
| Main entry → first successful present | 278.154 ms | 199.246 ms |
| Main-thread CPU/frame | 8.7328 ms | 7.7773 ms |
| Frame work wall time | 8.7796 ms | 7.8559 ms |
| GPU command interval | 0.1046 ms | 0.1041 ms |
| CPU-equivalent FPS (`1000 / CPU ms`) | 114.51 | 128.58 |
| Steady RSS | 85,548–85,612 KiB | 85,608–85,760 KiB |
| NVIDIA process graphics memory | 55 MiB | 55 MiB |
| Tile cache misses / evictions | 22 / 0 | 41 / 0 |

The existing 60 Hz work cap remains. CPU-equivalent FPS is arithmetic main-thread capacity, not measured uncapped presentation throughput. Startup and GPU timings exclude physical scanout. The changed geography and starting view prevent a controlled speed comparison against M1; this records the full new workload. Generation builds macro geography and initial local tiles; later tile costs are included in frame measurements.

The bounded fine-height cache uses 540,800 sample bytes across 64 slots. A 264,196-byte nearby-channel mask reduced a standalone ReleaseFast million-query hydrology benchmark from 545.490 to 331.551 ms with an identical checksum, a 39.2% reduction. Shared row frames also avoid repeated row-wide terrain calculations during tile creation. These are generated transient representations, not shipped assets.

Validation: Debug and ReleaseSmall suites passed, including drainage adjacency, downstream ordering/levels, water conservation, basin filling, climate response, seam agreement, and regeneration after eviction. The eviction test checks a real generated tree's identity. `scripts/verify_m2.py` passed six seeds, repeat reports, and 1440p Vulkan captures for atlas, repeated default, alternate seed, night and third person. Repeated default pixels are byte-identical; captures were validation-layer clean. Day, night, atlas and third-person readbacks were inspected. Logs and images remain under ignored `artifacts/`.

This is regional geography, not planetary generation or life simulation. Channels still reveal the coarse drainage lattice in some views; water and erosion are procedural approximations rather than fluid simulation. The settlement candidate is a suitability result, not an inhabited village. See `WORLDGEN.md` for generation rules and limits.
