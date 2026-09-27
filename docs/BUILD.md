# Building the native foundation

Milestone 0 is a glyph-rendering test, not an explorable world. It contains no game engine, terminal interface, simulation, or external visual assets.

## Development environment

The initial target is x86-64 CachyOS/Arch Linux with a Wayland session, Zig **0.16.0**, and a Vulkan GPU/driver. Other distributions and drivers are not yet tested.

Arch development packages:

```sh
sudo pacman -S --needed zig wayland wayland-protocols vulkan-headers vulkan-icd-loader shaderc pkgconf vulkan-validation-layers vulkan-tools
```

Your GPU driver must also supply its Vulkan ICD. `wayland-scanner` generates the stable xdg-shell bindings at build time. `glslc` compiles two shaders to embedded SPIR-V. Neither tool is needed at runtime. There are no package downloads in the Zig build.

```sh
zig build                              # debug
zig build test                         # deterministic scene/glyph checks
zig build run                          # run debug
zig build -Doptimize=ReleaseSmall       # stripped release
./zig-out/bin/ascii-life --metrics
./scripts/size.sh                       # rebuild + exact size/library report
./scripts/measure.py                    # bounded release timing/RSS/VRAM probe
./scripts/bundle.py                     # measured same-host runtime bundle
```

The default xdg-shell XML location is `/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml`. Override with `-Dxdg-shell=/path/to/xdg-shell.xml` where necessary.

## Controls and diagnostics

- **Space:** pause/resume the water's glyph animation.
- **F11:** toggle fullscreen (also exercises compositor resize and swapchain recreation).
- **Escape:** close cleanly.
- Keyboard press/release and pointer events are counted in `--metrics` output.
- `--capture PATH` saves the first actual Vulkan frame as an RGB PPM and exits; the image copy is allocated only on request. This provides visual QA without a desktop screenshot portal.
- `--static` fixes the scene at tick zero for repeatable visual inspection.
- `--frames N` exits cleanly after N loop frames; combine with `--metrics` for a bounded measurement.

```sh
VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation zig build run -- --metrics --frames 300
```

The logical field is 160 × 90 cells, independently rasterized at the window's pixel resolution. Each cell has its own glyph and two 24-bit colors. The initial resolution is a development constant in `src/scene.zig`; it is not tied to a world coordinate system. Window resizing scales the field. The original embedded 5 × 7 marks occupy an 8 × 8 bitmap cell. No font or texture is loaded.

## Boundaries

- `src/platform.zig`: Wayland registry, xdg-shell lifecycle, and input.
- `src/renderer.zig`: Vulkan device, buffers, swapchain, and presentation.
- `src/scene.zig`: pure deterministic cell composition and compact glyph bitsets.
- `src/main.zig`: application loop and timing.
- `shaders/`: fullscreen cell rasterization; no image-to-ASCII post-process.

The ordinary build uses the host's Wayland client library, Vulkan loader, and C runtime. Distribution sizes and the self-contained boundary are recorded in `docs/SIZE.md`.

The runtime bundler writes a fresh `artifacts/ascii-life-runtime` directory and refuses to overwrite an existing bundle. Move an older output aside before rebuilding. This packages the local library closure for measurement; see `docs/SIZE.md` for host assumptions.
