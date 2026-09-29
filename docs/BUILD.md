# Building and exploring ASCII-Life

Milestone 6 adds an ordinary village life with paid farm work, provisions, a rented home, seasons, aging and persistent saves. It uses the native glyph renderer without an engine or external visual assets. Combat and deeper generational events remain later work.

## Development environment

The initial target is x86-64 CachyOS/Arch Linux with a Wayland session, Zig **0.16.0**, and a Vulkan GPU/driver. Other distributions and drivers are not yet tested.

Arch development packages:

```sh
sudo pacman -S --needed zig wayland wayland-protocols libxkbcommon vulkan-headers vulkan-icd-loader shaderc pkgconf vulkan-validation-layers vulkan-tools
```

Your GPU driver must also supply its Vulkan ICD. `wayland-scanner` generates the stable xdg-shell bindings at build time. `glslc` compiles two shaders to embedded SPIR-V. Neither tool is needed at runtime. There are no package downloads in the Zig build.

```sh
zig build                              # debug
zig build test                         # terrain, camera, and glyph checks
zig build run -Doptimize=ReleaseSmall   # explore the optimized build
zig build -Doptimize=ReleaseSmall       # stripped release
./zig-out/bin/ascii-life --metrics
./scripts/size.sh                       # rebuild + exact size/library report
./scripts/measure.py                    # 1440p release timing/RSS/VRAM probe
./scripts/bundle.py                     # measured same-host runtime bundle
```

The default xdg-shell XML location is `/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml`. Override with `-Dxdg-shell=/path/to/xdg-shell.xml` where necessary.

## Controls and diagnostics

- **WASD:** move over the terrain; **Shift:** move faster.
- **Arrow keys** or **right-button drag:** look around.
- **Q/E:** lower/raise the development camera above the terrain. This is a landscape inspection control, not a flight skill or game mechanic.
- **C:** switch first/third person, retaining the same player position and world.
- **R:** return to the starting viewpoint.
- **T:** advance the simulation by three hours for development inspection; **Space:** pause/resume simulation and animation.
- **H:** hide/show the compact control labels.
- **F11:** toggle fullscreen (also exercises compositor resize and swapchain recreation).
- **F:** speak with a nearby visible villager. Type a phrase and press **Enter**; **Backspace** edits it. **Escape** leaves the conversation.
- **G:** hold at your employer's field entrance for paid labor while the farmer is present; elsewhere beside the livestock pen, repair or guard the animals.
- **F near the well:** read a posted household notice when no resident is targeted.
- **J:** open the learned-information journal; **N/P** page through it; **J/Escape** closes it. Conversation and journal reading pause world time.
- **K:** open/close your life panel; reading pauses time.
- **B/V/N:** at your rented door, sleep eight hours / live seven days / live ninety days. Longer routines require manageable needs and stop if the safe anchor or needs fail.
- **F5/F9:** save/reload the ordinary local slot. Normal play resumes the slot and saves on exit; `--new` starts fresh.
- **Escape:** close the game when no conversation, journal or life panel is open.
- Keyboard press/release and pointer events are counted in `--metrics` output.
- `--capture PATH` saves the first actual Vulkan frame as an RGB PPM and exits; the image copy is allocated only on request. This provides visual QA without a desktop screenshot portal.
- `--static` freezes the simulation and visual clock for repeatable inspection; camera movement remains available.
- `--frames N` exits cleanly after N presentations; combine with `--metrics` for a bounded measurement.
- `--seed N` selects a reproducible region (decimal or `0x` hexadecimal, default `0xa11fe`).
- `--time F` selects a day fraction in `[0,1)`; `.25` is sunrise, `.5` noon, `.75` sunset. Default `.36`.
- `--third-person` and `--hide-hud` select the initial camera and label visibility.
- `--size WIDTHxHEIGHT` selects initial window pixels; default 2560×1440.
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

The ordinary build uses the host's Wayland client library, xkbcommon keyboard-layout library, Vulkan loader, and C runtime. Distribution sizes and the self-contained boundary are recorded in `docs/SIZE.md`.

The runtime bundler writes a fresh `artifacts/ascii-life-runtime` directory and refuses to overwrite an existing bundle. Move an older output aside before rebuilding. This packages the local library closure for measurement; see `docs/SIZE.md` for host assumptions.

## Regional generation and native visual regression checks

`python3 scripts/verify_m2.py` builds an optimized executable, checks six regional seeds headlessly, and performs 1440p native Vulkan captures under validation. It compares repeat runs pixel-for-pixel and exercises the development atlas, alternate seeds, night lighting and third-person views. The earlier `verify_m1.py` remains as historical foundation regression tooling. Native test captures use a private KWin virtual display; they never open desktop windows. `zig build test` remains display-independent.

```sh
mkdir -p artifacts
./zig-out/bin/ascii-life --hide-hud --capture artifacts/landscape.ppm
./zig-out/bin/ascii-life --third-person --time 0.72 --capture artifacts/evening.ppm
./zig-out/bin/ascii-life --hide-hud --view 60,-600,0,-0.12,120 --capture artifacts/vista.ppm
./zig-out/bin/ascii-life --metrics --tour
```

Completion reports use 2560 × 1440 measurements; `scripts/measure.py` sets that window size by default. This changes output resolution, not the current 240 × 135 logical glyph field. The full required reporting checklist is in `AGENTS.md`.


Milestone 2 inspection:

```sh
./zig-out/bin/ascii-life --world-report
./zig-out/bin/ascii-life --atlas --capture artifacts/geography.ppm
python3 scripts/verify_m2.py --headless-only
python3 scripts/verify_m2.py
```

The development atlas exposes generation data for QA. It is not the player's journal or a revealed gameplay map. See [WORLDGEN.md](WORLDGEN.md) for the algorithms, streaming boundary and current limits.

## Village inspection

See [VILLAGE.md](VILLAGE.md) for the simulation boundary. `--village-report` reports the generated layout and residents without a display. `--simulate-days 28` tests unattended advancement. `--village-overview` selects an elevated QA viewpoint. `python3 scripts/verify_m3.py` checks village reports and native 1440p captures.

## People and conversation inspection

See [PEOPLE.md](PEOPLE.md) for the supported grammar and social rules. `--people-report` prints developer-only social state headlessly; it does not reveal anything in the player's journal. `--talk-to N` opens a developer conversation with a resident index, and repeated `--say TEXT` arguments submit up to 16 lines. A native run also moves the viewpoint near that resident and requires them to be accessible at the chosen time. `--journal` opens the learned entries.

```sh
./zig-out/bin/ascii-life --people-report --simulate-days 28
./zig-out/bin/ascii-life --talk-to 0 --say name --say news
./zig-out/bin/ascii-life --talk-to 0 --say news --journal --capture artifacts/journal.ppm
python3 scripts/verify_m4.py --headless-only
python3 scripts/verify_m4.py
```

## Livestock and simulation needs

See [PROBLEMS.md](PROBLEMS.md) for Milestone 5 gameplay and limits. Ask `ask about livestock`, `ask about wolves` or `help`. An informed resident can direct you to the pen. The household acts and predators can attack without player involvement; actual work and protection affect food, memories and trust. `--ecology-report` validates this state headlessly. `--pen-view` and `--elapsed-days N` support native inspection, while `--work-seconds N` exercises physical pen work for QA. Run `python3 scripts/verify_m5.py` for six-seed and native 1440p checks.

## Background graphics QA

`scripts/measure.py` and all native regression scripts now run through
`scripts/background.py`. The runner uses installed `kwin_wayland --virtual`
and `dbus-run-session`, with private runtime/config directories and a private
D-Bus session. It opens no desktop window, uses no physical output and has no
visible fallback. Failed clients propagate their exit status; cancellation
cleans up the private display and client. These are test tools, not game runtime
dependencies. A working hardware Vulkan driver is still required.

```sh
python3 scripts/background.py -- ./zig-out/bin/ascii-life --metrics --frames 120
python3 scripts/measure.py --static
python3 scripts/measure.py --tour
```

Report these as private-display/headless measurements. They exercise native
Vulkan presentation and GPU readbacks, but do not measure the user's desktop
compositor latency, physical scanout, live keyboard interactions or fullscreen
behavior. Run the game normally only when you intend to play.

## Ordinary life and saves

See [LIFE.md](LIFE.md) for employment, food, rental eligibility, home-gated
routines, save location and scope. `python3 scripts/verify_m6.py` checks
multiple years and save continuation, followed by private 1440p GPU captures;
`--headless-only` skips graphics entirely. Developer scenarios and benchmarks
do not touch the ordinary-play save slot.
