# Codex Kickoff

## Your first job

Build **Milestone 0: Tiny native foundation**.

Do not begin world simulation, NPC systems, combat, magic, or procedural planet generation yet.

The purpose of Milestone 0 is to establish the smallest clean native foundation that future work can trust.

Read:

1. `AGENTS.md`
2. `docs/DECISIONS.md`
3. `docs/ARCHITECTURE.md`
4. `docs/MILESTONES.md`
5. `docs/SIZE.md`

## Required outcome

Create a Zig project that opens a native Wayland window and displays a Vulkan-rendered grid of colored ASCII glyphs.

The grid must clearly demonstrate that each logical cell can independently choose at least:

- glyph
- foreground RGB
- background RGB

The initial visual should be attractive enough to judge the rendering concept. Do not stop at plain white characters on black.

A simple deterministic demo could contain:

- sky-like color gradient
- pseudo-horizon
- glyph-density ramp
- diagonal and horizontal glyph structures
- color variation
- a small animated element if it does not complicate the foundation

## Constraints

- native Linux
- Zig
- Wayland-first
- Vulkan-first
- no game engine
- no browser/webview
- no SDL/GLFW unless you first provide measured evidence that the dependency is worth violating the default architecture
- no external font file
- no external texture
- no external model
- no network dependency at runtime
- no unexplained generated megabytes

Use a tiny embedded bitmap glyph representation.

Keep platform-specific code isolated from renderer-independent code.

## Input

Implement enough input to prove the event loop:

- key press/release
- mouse movement or pointer events
- clean close request

Exact game bindings are not important yet.

## Developer ergonomics

Provide obvious commands for:

- debug build
- release build
- run
- tests
- size measurement

Document required Linux development packages precisely.

Do not claim support for distributions or graphics stacks you have not tested.

## Measurement

At completion, report:

- Zig version
- stripped dynamic ELF size in exact bytes
- linked shared libraries
- best practical self-contained/distribution size and what host components it still relies on
- idle RAM
- VRAM if measurable reliably
- approximate frame CPU/GPU cost if measurable without distorting the tiny foundation

Add measured results to the repository, preferably in a concise section of `docs/SIZE.md` or a dedicated generated/manual benchmark note.

## Correctness

Use Vulkan validation layers during development when available.

Handle:

- initial surface creation
- swapchain recreation on resize/out-of-date
- zero-size/minimized state safely
- clean teardown
- Wayland configure semantics correctly
- frame pacing without a busy-loop that pointlessly maxes a CPU core

## Size discipline

First make the implementation clean and correct.

Then produce a release-size pass.

Inspect what contributes to the binary before optimizing.

Do not make the code unreadable to win the first size number.

Record meaningful experiments if two approaches are compared.

## Completion criteria

Milestone 0 is complete when:

1. the program launches natively under Wayland
2. Vulkan presents successfully
3. the window displays a deterministic colored glyph-cell scene
4. resizing works
5. basic keyboard/pointer input works
6. shutdown is clean
7. no external visual asset is required
8. release binary is stripped
9. size/performance baseline is documented
10. the repository has clear build/run instructions
11. no later-game system has been prematurely implemented

## After Milestone 0

Stop and report results.

Do not automatically continue to Milestone 1.

Milestone 1 is where the project earns its visual identity: a procedural fantasy landscape that looks implausibly good for its byte count.
