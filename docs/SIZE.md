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
