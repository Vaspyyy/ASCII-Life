# Building and exploring ASCII-Life

Milestone 1 is an explorable, seeded regional landscape. It uses a custom native glyph renderer, with no game engine or external visual assets. NPCs, world history, combat, and persistent gameplay are later milestones.

## Development environment

The initial target is x86-64 CachyOS/Arch Linux with a Wayland session, Zig **0.16.0**, and a Vulkan GPU/driver. Other distributions and drivers are not yet tested.

Arch development packages:

```sh
sudo pacman -S --needed zig wayland wayland-protocols vulkan-headers vulkan-icd-loader shaderc pkgconf vulkan-validation-layers vulkan-tools
```

Your GPU driver must also supply its Vulkan ICD. `wayland-scanner` generates the stable xdg-shell bindings at build time. `glslc` compiles two shaders to embedded SPIR-V. Neither tool is needed at runtime. There are no package downloads in the Zig build.

```sh
zig build                              # debug
zig build test                         # terrain, camera, and glyph checks
zig build run -Doptimize=ReleaseSmall   # explore the optimized build
zig build -Doptimize=ReleaseSmall       # stripped release
./zig-out/bin/ascii-life --metrics
./scripts/size.sh                       # rebuild + exact size/library report
./scripts/measure.py                    # bounded release timing/RSS/VRAM probe
./scripts/bundle.py                     # measured same-host runtime bundle
```

The default xdg-shell XML location is `/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml`. Override with `-Dxdg-shell=/path/to/xdg-shell.xml` where necessary.

## Controls and diagnostics

- **WASD:** move over the terrain; **Shift:** move faster.
- **Arrow keys** or **right-button drag:** look around.
- **Q/E:** lower/raise the development camera above the terrain. This is a landscape inspection control, not a flight skill or game mechanic.
- **C:** switch first/third person, retaining the same player position and world.
- **R:** return to the starting viewpoint.
- **T:** advance the sun by one eighth of a day; **Space:** pause/resume sun and water animation.
- **H:** hide/show the compact control labels.
- **F11:** toggle fullscreen (also exercises compositor resize and swapchain recreation).
- **Escape:** close cleanly.
- Keyboard press/release and pointer events are counted in `--metrics` output.
- `--capture PATH` saves the first actual Vulkan frame as an RGB PPM and exits; the image copy is allocated only on request. This provides visual QA without a desktop screenshot portal.
- `--static` freezes the visual clock for repeatable inspection; camera movement remains available.
- `--frames N` exits cleanly after N presentations; combine with `--metrics` for a bounded measurement.
- `--seed N` selects a reproducible region (decimal or `0x` hexadecimal, default `0xa11fe`).
- `--time F` selects a day fraction in `[0,1)`; `.25` is sunrise, `.5` noon, `.75` sunset. Default `.36`.
- `--third-person` and `--hide-hud` select the initial camera and label visibility.
- `--size WIDTHxHEIGHT` selects initial window pixels; default 1920×1080.
- `--view X,Z,YAW,PITCH,HEIGHT` selects a repeatable development viewpoint. Position/height use metres; yaw/pitch use radians. Height is lift above the standing surface. Yaw zero faces +Z, and positive pitch looks up.
- `--tour` runs a fixed-step moving-camera benchmark, switching view halfway through; defaults to 600 frames. It cannot be combined with `--capture`.

```sh
VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation zig build run -- --metrics --frames 300
```

The logical field is 240 × 135 cells, independently rasterized at the window's pixel resolution. Each cell has its own glyph and two 24-bit colors. The initial resolution is a development constant in `src/scene.zig`; it is not tied to a world coordinate system. Window resizing scales the field. The original embedded 5 × 7 marks occupy an 8 × 8 bitmap cell, matching an 8-pixel cell at 1080p. No font or texture is loaded.

## Boundaries

- `src/platform.zig`: Wayland registry, xdg-shell lifecycle, and input.
- `src/renderer.zig`: Vulkan device, buffers, swapchain, and presentation.
- `src/scene.zig`: cell interface and compact glyph bitsets.
- `src/terrain.zig`: seed-stable regional heightfield and tree identities.
- `src/camera.zig`: platform-independent movement and both camera modes.
- `src/landscape.zig`: terrain, trees, water, sky, atmosphere, and glyph selection.
- `src/main.zig`: application loop and timing.
- `shaders/`: fullscreen cell rasterization; no image-to-ASCII post-process.

The ordinary build uses the host's Wayland client library, Vulkan loader, and C runtime. Distribution sizes and the self-contained boundary are recorded in `docs/SIZE.md`.

The runtime bundler writes a fresh `artifacts/ascii-life-runtime` directory and refuses to overwrite an existing bundle. Move an older output aside before rebuilding. This packages the local library closure for measurement; see `docs/SIZE.md` for host assumptions.

## Native visual regression checks

`./scripts/verify_m1.py` builds an optimized executable and performs native Vulkan captures under validation. It compares repeat runs pixel-for-pixel, exercises seed/time/camera variants, repeats a fixed-step movement tour, and checks invalid CLI inputs. It requires an active Wayland session; `zig build test` remains display-independent.

```sh
mkdir -p artifacts
./zig-out/bin/ascii-life --hide-hud --capture artifacts/landscape.ppm
./zig-out/bin/ascii-life --third-person --time 0.72 --capture artifacts/evening.ppm
./zig-out/bin/ascii-life --hide-hud --view 60,-600,0,-0.12,120 --capture artifacts/vista.ppm
./zig-out/bin/ascii-life --metrics --tour
```
