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

## Milestone 3 village — 2026-09-28

Measured the M3 working tree based on `ec74e5b34bad9d0146e362dc39e99a961138a3a1`, Zig 0.16.0 ReleaseSmall, KDE Wayland / RTX 3070. Build/source/shader digest using the M0 procedure: `40d4034c4c1faf9be02def4159088719bc1b08836c9bb175a2e273815193492d`. ELF SHA-256: `d940955e2d9b86be5a7aef0ad50ea4a5202eaf7a5f0fdc7ecf5b605cd7d41dad`.

| Distribution | Exact bytes | Change from M2 |
| --- | ---: | ---: |
| Stripped dynamic ELF | 202,328 | +51,824 |
| ELF compressed with `xz -9` | 97,604 | +23,988 |
| Runtime bundle payload | 3,694,573 | +51,824 |
| Runtime bundle `.tar.xz` | 1,296,580 | +24,204 |

No dependencies or external visual assets were added. The bundle retains the documented kernel/compositor/GPU-driver boundary and same-host compatibility limit. Its executable hash matches the measured binary, and it completed a 120-frame native run from `/tmp` at 1440p.

### 1440p runtime

Both runs presented 600 frames at **2560 × 1440**, default seed **659966 (`0xa11fe`)**, with 599 GPU samples and no validation layer. Stationary uses `--static`; the tour advances simulation and moves from the village approach, switching to third person halfway through. Unlike the old visual-only tour clock, 600 tour frames now advance 600 simulated seconds.

| Metric | Stationary | Moving tour |
| --- | ---: | ---: |
| Terrain generation | 34.837 ms | 37.501 ms |
| Village generation and initial simulation | 24.710 ms | 24.805 ms |
| Main entry → first successful present | 207.789 ms | 221.370 ms |
| Main-thread CPU/frame | 9.8985 ms | 9.4034 ms |
| Frame work wall time | 10.0449 ms | 9.5208 ms |
| GPU command interval | 0.1080 ms | 0.1068 ms |
| CPU-equivalent FPS (`1000 / CPU ms`) | 101.03 | 106.34 |
| Steady RSS | 85,932–85,992 KiB | 85,880–85,944 KiB |
| NVIDIA process graphics memory | 55 MiB | 55 MiB |
| Tile cache misses / evictions, including generation | 76 / 12 | 92 / 28 |

The logical render grid remains **240 × 135 (32,400 cells)**. The region remains **8,192 × 8,192 m (67.108864 km²)**. A fresh complete height scan again found peak world Y **1,040.75 m**, or **960.75 m above the Y=80 m sea datum**.

The application still caps work at 60 Hz. CPU-equivalent FPS is arithmetic main-thread capacity, not measured uncapped presentation throughput. Startup excludes physical scanout. These are new village views, not controlled identical-scene comparisons with M2. Generation measures the geography separately from the village plan and initial clock advancement; steady frame cost includes glyph construction, architecture, residents and simulation when running.

### Validation and scope

- Final Debug and ReleaseSmall unit suites passed. Coverage includes village site/entry/path invariants, building collision, projection/clipping/depth behavior, resident assignment, stock conservation, and exact 28-day state equivalence between large and irregular time advances.
- Redirecting farm labour to craft work produces food shortages. The ordinary village covers food and water demand for 28 unattended days across seeds 0, 1, 42, 659966, 72019 and maximum u64.
- `scripts/verify_m3.py` passed headless reports and native 1440p Vulkan validation captures: repeated arrival, overview, morning commute, evening, night, third person and alternate seed. Repeat arrival captures are byte-identical.
- Native W/C/T/F11/Escape input was observed; movement, camera mode, simulation clock stepping, fullscreen geometry and clean exit worked without Vulkan validation messages. Fullscreen changed surface placement on this already-1440p window, not pixel extent; it is not an additional resize-extent test.
- Inspected GPU readbacks include arrival, village overview, night and a close street with commuting residents. Logs/captures are ignored local artifacts under `artifacts/m3-*`.

The default village has **21 residents, six households, six homes, two fields, a workshop, granary and well**, connected by 31 path segments. This milestone uses a common street arrangement fitted to viable terrain. It has abstract provisioning and session-resident state, but no building interiors, conversation, generational events or save files. Distant paths can alias at the current glyph resolution. See [VILLAGE.md](VILLAGE.md) for the precise simulation and generation limits.

## Milestone 4 people — 2026-09-29

Measured the M4 working tree based on `1fab90eb63f1c7fa23a26213aab7f7e1b6460072`, Zig 0.16.0 ReleaseSmall, KDE Wayland / NVIDIA RTX 3070, driver 615.71.09. The live power profile was **power-saver** before and after measurement; desktop settings were not changed. These are not performance-mode comparison runs. Build/source/shader digest using the M0 procedure: `10a84e020ab9398c4f72c05e0e571d8b398d936810d85d22c90eb3bad4bc3d2e`. ELF SHA-256: `983f434fd0ff2474a08d1830d642a57ab8ad26287bcfbf197bbfdcad81e7edb6`.

| Distribution | Exact bytes | Change from M3 |
| --- | ---: | ---: |
| Stripped dynamic ELF | 252,792 | +50,464 |
| ELF compressed with `xz -9` | 117,448 | +19,844 |
| Runtime bundle payload | 4,198,345 | +503,772 |
| Runtime bundle `.tar.xz` | 1,479,064 | +182,484 |

The added library is libxkbcommon for compositor-provided keyboard layouts and modifiers. The input-only ELF experiment added 1,984 bytes; the library itself is 440,488 bytes (167,044 bytes under `xz -9`). Its library and license are included in the complete distribution totals above. libffi was already in the runtime closure. The font remains a generated 1,024-byte bit table, now covering all printable ASCII; no visual assets or dialogue service were added. The rationale and replacement boundary are in [PEOPLE.md](PEOPLE.md).

The final bundle's ELF hash matches the measured executable. Its loader resolves all ordinary shared-library dependencies inside the bundle, including xkbcommon. It completed 120 native frames at 2560 × 1440 from `/tmp`, displaying a conversation. The kernel, Wayland compositor, GPU driver/ICD and their infrastructure remain host requirements. This is the same-host distribution experiment described above, not a fully static or cross-distribution build.

### 1440p runtime

Each run presented 600 frames at **2560 × 1440**, seed **659966 (`0xa11fe`)**, with 599 GPU timestamp samples and no validation layer. Stationary uses `--static`; the moving tour advances 600 simulated seconds and switches camera halfway through. Conversation uses `--talk-to 0 --say name --say news`, showing the nearby resident and typed dialogue panel with the world clock paused for reading.

| Metric | Stationary | Moving tour | Conversation |
| --- | ---: | ---: | ---: |
| Terrain generation | 35.245 ms | 43.072 ms | 38.474 ms |
| Village and social initialization | 28.321 ms | 27.163 ms | 25.447 ms |
| Main entry → first successful present | 265.261 ms | 229.842 ms | 242.556 ms |
| Main-thread CPU/frame | 9.8719 ms | 9.3841 ms | 9.6520 ms |
| Frame work wall time | 9.9746 ms | 9.4874 ms | 9.7716 ms |
| GPU command interval | 0.1001 ms | 0.0969 ms | 0.0974 ms |
| CPU-equivalent FPS (`1000 / CPU ms`) | 101.30 | 106.56 | 103.61 |
| Steady RSS | 86,336–86,400 KiB | 86,340–86,404 KiB | 86,424–86,488 KiB |
| NVIDIA process graphics memory | 55 MiB | 55 MiB | 55 MiB |

The logical render field is **240 × 135 (32,400 cells)**. The generated region is **8,192 × 8,192 m (67.108864 km²)**. A fresh complete fine-lattice height scan found **1,040.75 m world Y**, or **960.75 m above the Y=80 m sea datum**.

CPU-equivalent FPS is calculated main-thread capacity, not measured uncapped presentation throughput. The game retains its 60 Hz work cap and FIFO presentation. CPU timings exclude driver worker threads; GPU intervals and startup exclude compositor latency and physical scanout. Other desktop applications remained running. Raw measurements are `artifacts/m4-1440-{static,tour,conversation}.log`, with packaging logs in `artifacts/m4-{size,bundle,bundle-runtime}.log`.

### Validation and scope

- **38/38 tests pass in Debug and ReleaseSmall.** Checks cover reciprocal families, different evidence-linked beliefs, original witness/teller and observation times, stale-rumor rejection, trust/privacy, bounded salient memory, actual goal progress and uneven world-clock partition equivalence. Dialogue checks cover name introduction, refusal without journal leaks, insult history, explicit grammar, input bounds, visible caret and journal paging.
- `scripts/verify_m4.py` passes six seeds over 28 unattended days, repeat reports, malformed arguments, relationship-dependent replies and learned-only journal assertions. Native 1440p Vulkan validation captures cover repeated conversation, journal, privacy refusal and third person. Repeat images are byte-identical and validation-clean.
- The M3 six-seed unattended suite and native arrival, overview, commute, evening, night, third-person and alternate-seed captures still pass. Close conversation views now use proportional head/body/limb silhouettes; the far representation stays compact. Conversation and control panels have a six-cell bottom inset so desktop window placement does not clip the input line on the tested monitor.
- Native key-event probes verified Backspace correction, Shift, spaces, Enter and the active German QWERTZ layout (`q`, physical Y, physical Z produced `qzy`). A 48-second conversation retained simulation time **31,104 seconds** and the starting viewpoint despite typing movement-key letters. Escape left conversation without closing the game; J/N/P/J and F reopened the journal/conversation correctly, then Escape closed the game from normal play. Live input was verified through the game's diagnostics; visual inspection used Vulkan readbacks because the desktop screenshot backend was unavailable.

Social and journal state persist within the running session. Save files, generational events, actual player employment/contracts and further problem simulation remain later work. Saying `help` reveals public work; it does not manufacture completed help or trust. See [PEOPLE.md](PEOPLE.md) for the current rules and limits.

## Milestone 5 problems, not quests — 2026-09-29

Measured the M5 working tree based on `daa122d08a61eaa4f3f186867323f93a98d2c791`, Zig 0.16.0 ReleaseSmall, KDE Wayland / NVIDIA RTX 3070, driver 615.71.09. The power profile was **power-saver** before and after the runs. Source/build/shader digest under the M0 procedure: `1c3423a60cf090549eafd486af27a47bbf1abf248703db25bd2c26aa48e4765a`. Final ELF SHA-256: `889c7795eec399092e9fd17d0a4587f2e9a21653cd760cc63e107fb12c9e6b0a`.

| Distribution | Exact bytes | Change from M4 |
| --- | ---: | ---: |
| Stripped dynamic ELF | 275,496 | +22,704 |
| ELF compressed with `xz -9` | 127,216 | +9,768 |
| Runtime bundle payload | 4,216,953 | +18,608 |
| Runtime bundle `.tar.xz` | 1,490,384 | +11,320 |

No dependencies or external visual assets were added. The library closure is unchanged; the current host libc is 4,096 bytes smaller than the libc in the saved M4 bundle, accounting for the difference between ELF and payload deltas. The final bundle executable hash matches the measured ELF. Its loader resolves every ordinary dependency within the bundle, and it completed 120 native frames at 1440p from `/tmp`, looking at the pen. Kernel, compositor and GPU driver/ICD infrastructure remain host requirements; this is still the same-host packaging experiment.

### 1440p runtime

Each final run presented 600 frames at **2560 × 1440**, seed **659966 (`0xa11fe`)**, with 599 GPU timestamp samples and no validation layer. Stationary uses `--static` at the default village approach and time `.36`. Moving uses `--tour`, advancing 600 simulated seconds and switching camera halfway through. Pen uses `--static --pen-view --time .38`, showing eight sheep, damaged fencing and the nearby farmers after the first threat inspection. Packaging and compression finished before these final measurements.

| Metric | Stationary | Moving tour | Pen close view |
| --- | ---: | ---: | ---: |
| Terrain generation | 36.674 ms | 34.877 ms | 36.656 ms |
| Village/social/ecology initialization | 25.452 ms | 24.960 ms | 25.396 ms |
| Main entry → first successful present | 219.984 ms | 223.258 ms | 227.286 ms |
| Main-thread CPU/frame | 10.0935 ms | 9.3896 ms | 10.7581 ms |
| Frame work wall time | 10.2390 ms | 9.4772 ms | 10.8104 ms |
| GPU command interval | 0.1039 ms | 0.1063 ms | 0.0969 ms |
| CPU-equivalent FPS (`1000 / CPU ms`) | 99.07 | 106.50 | 92.95 |
| Steady RSS | 86,592–86,656 KiB | 86,580–86,644 KiB | 86,612–86,676 KiB |
| NVIDIA process graphics memory | 55 MiB | 55 MiB | 55 MiB |

The logical render field remains **240 × 135 (32,400 cells)**; the generated region is **8,192 × 8,192 m (67.108864 km²)**. A fresh complete height scan found peak **1,040.75 m world Y**, or **960.75 m above the Y=80 m sea datum**.

CPU-equivalent FPS is arithmetic main-thread capacity, **not measured uncapped presentation FPS**. The application retains its 60 Hz work cap and FIFO presentation. CPU excludes driver worker threads; GPU command intervals and startup exclude compositor latency and physical scanout. Other desktop applications remained running. Raw logs are `artifacts/m5-1440-{static,tour,pen}.log`, `artifacts/m5-{world,size,bundle,bundle-runtime}.log`.

### Validation and scope

- **52/52 tests pass in Debug and ReleaseSmall.** New coverage includes predator removal and materials counterfactuals, physical guard defense and expiry, local inspection, known/unknown livestock disclosure, signed notice provenance, informed neighbor intervention, absent-owner outcome withholding, and real-clock work partition equivalence across hourly/completion boundaries. The final UI label adjustment was release-built and covered by the native captures.
- M3 and M4 six-seed 28-day headless suites pass. M5 also validates six seeds, animal/attack/food/goods conservation, repeat reports, real repair costs and no reward for merely offering help.
- `scripts/verify_m5.py` passes native 1440p Vulkan validation captures for repeated pen, repair, third person, livestock conversation, signed notice/journal, physical notice board, night wolves and 28-day pen state. Repeat pen pixels are byte-identical. Pen, fence damage/repair, notice panel and predator readbacks were visually inspected. The new F/G native key paths were inspected in code; they were not exercised by a live native keyboard probe this milestone. Work correctness is verified through the same simulation path using the developer harness and clock tests.

This is a bounded village-scale need-driven slice, not full animal ecology or combat. NPC repair effort is a coarse hourly allocation at the field checkpoint; player labor instead runs against exact clock/completion boundaries. Outcome knowledge and earned trust wait for the owner's inspection. Session state still has no save format, breeding or long-term animal replenishment. The initial flock can decline to zero while the wider village keeps running. See [PROBLEMS.md](PROBLEMS.md) for controls and simulation limits.
