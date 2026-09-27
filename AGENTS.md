# AGENTS.md

This repository is **ASCII-Life**, also called **A Life**.

Read this file before making changes. Then read the relevant documents in `docs/`.

## Prime directive

> **Store causes. Generate consequences.**

ASCII-Life is a native Linux isekai life simulation built around deterministic procedural generation, deep world simulation, and a colored ASCII renderer.

Do not solve a problem by adding a large asset, database, script bundle, or framework when a compact algorithm or generated representation can solve it cleanly.

Binary size is a design constraint, not an excuse for poor architecture or unreadable code.

## Project identity

ASCII-Life is NOT:

- a terminal game
- a roguelike tile game
- a normal 3D game with an ASCII post-process filter
- a web app
- an engine-based game
- a traditional quest-driven RPG
- a static procgen walking simulator

ASCII-Life IS:

- a real native Linux game
- written in Zig
- Wayland-first
- Vulkan-first
- built on a custom renderer and simulation stack
- visually composed from colored glyph cells
- a finite but enormous procedural fantasy world
- a generational life simulation
- an open-ended isekai RPG where adventuring is optional
- an experiment in how much game can fit in a tiny executable

## Locked design decisions

Do not silently reinterpret these.

- The protagonist arrives near a tiny rural village at physical age 15.
- The protagonist magically understands the local spoken language.
- The protagonist ages normally.
- Death is not permanent.
- Reanimation takes meaningful simulated time.
- Reanimation reconstructs the player at physical age 15.
- The player's immortality is initially secret.
- Discovery of immortality must emerge through information, relationships, politics, religion, fear, curiosity, and history. It is not a fixed chapter trigger.
- NPCs are persistent people with homes, work, memories, relationships, families, ambitions, and life events.
- NPCs age, marry, have children, migrate, and die.
- The world continues without player involvement.
- There is no internal traditional quest system.
- The journal records information actually learned by the player.
- No floating exclamation marks, question marks, or conventional quest arrows.
- Progression has no required global XP level.
- Progression combines practice, knowledge, learned techniques, lifestyle adaptation, and soul progression.
- Magic has known named spells backed by a compositional magic system.
- The player can acquire Soul Imprints and transform into functional creature forms.
- Soul Imprints may arise through killing, being killed by, bonding, prolonged study, or sufficiently fresh remains. Circumstance influences imprint quality.
- Combat is real-time action.
- The ASCII field is part of combat telegraphing and eventually part of magical mechanics and lore.
- First-person and third-person views are both supported by the design.
- Large time skips become available only after the player has a stable home or equivalent safe life anchor.
- The world contains humans and familiar fantasy peoples, including beastfolk, but culture is not species-locked.
- The generated planet is finite.
- It has one dominant supercontinent plus secondary continents, islands, archipelagos, and meaningful seas.
- Ocean voyages may advance simulation time quickly rather than forcing hours of empty real-time travel.
- The main fantasy is classic isekai adventuring, but the player can instead live an ordinary life indefinitely.
- Settlements can grow or decline through simulation.
- Cute beastfolk are explicitly within the desired tone.

## Engineering rules

### Keep dependencies rare

Before adding a dependency, answer:

1. What capability does it provide?
2. What would the in-house implementation cost?
3. How much does it add to stripped dynamic ELF size?
4. How much does it add to the self-contained build?
5. Does it constrain determinism or portability?
6. Can it be removed later without rewriting the project?

Do not add SDL, GLFW, a game engine, ECS framework, physics engine, serializer, UI toolkit, scripting runtime, or audio middleware merely for convenience without explicit justification.

### Measure instead of guessing

For every foundation-level decision that affects executable size or frame cost, create a small benchmark or record measurements.

Track at minimum:

- stripped dynamic ELF bytes
- practical self-contained distribution bytes
- startup time
- steady-state RAM
- VRAM
- frame CPU time
- frame GPU time when measurable

Do not claim something is smaller or faster without measuring it.

### Determinism matters

Generation must be reproducible from stable inputs.

Prefer explicit seeds and deterministic sub-seed derivation.

A location should be reconstructible from compact causes such as:

`world_seed + coordinates + historical state + local persistent deltas`

Avoid hidden dependence on wall-clock time, hash-map iteration order, global mutable RNG state, or machine-specific floating-point accidents in systems whose output must persist.

### Simulate at multiple levels of detail

Do not update the entire planet at local fidelity.

Expected pattern:

- immediate vicinity: frame or second scale
- settlement/region: minute or hour scale
- distant regions: day scale
- remote world history: week, month, season, or event scale

A distant baker does not need to pathfind to an oven every morning for their life to remain coherent.

### Persistent state stores deviations, not regenerated bulk

Do not serialize an entire procedurally generated world.

Persist only information that cannot be reconstructed safely from deterministic generation plus simulation rules, such as:

- player-caused changes
- evolved settlement state
- important NPC state
- memories and relationships
- persistent world events
- construction/destruction
- inventory and ownership
- historical divergence from the initial generated state

### Avoid premature byte-golf

Readable, testable code comes first.

Do not hand-minify source, abuse undefined behavior, or merge unrelated systems to save a few bytes during early milestones.

Optimize binary size using evidence, release configuration, symbol stripping, feature removal, representation design, and architectural leverage.

Byte-golf belongs after correctness and measurement.

## Renderer principles

The glyph cell is a first-class render primitive.

A cell may conceptually contain compact information such as:

- glyph index
- foreground color
- background color
- depth
- material/semantic hints where useful

Do not treat ASCII conversion as a simple brightness ramp.

Glyph selection should eventually exploit:

- surface orientation
- edges
- material
- motion
- foliage structure
- water direction
- lighting
- attack direction
- magic distortion

The visual target is:

> beautiful fantasy scene from normal viewing distance, obviously constructed from characters when inspected closely.

The embedded glyph set should be compact and generated or represented as bit data, not shipped as a conventional texture asset unless measurement proves a better option.

## World-generation principles

Generate in causal layers:

1. planetary skeleton
2. landmasses and ocean basins
3. tectonic structure
4. elevation
5. erosion and hydrology
6. climate
7. biomes
8. resources
9. settlement suitability
10. cultures and polities
11. coarse history
12. present-day world
13. streamed regional detail
14. streamed local detail

Generation needs validation and repair passes. Do not accept every random output blindly.

## Simulation principles

NPCs are people, not quest emitters.

An NPC problem should exist independently of player involvement.

Example:

`wolves threaten livestock`

Possible consequences include:

- owner tells family
- owner asks a trusted hunter
- owner posts public work
- owner seeks local authority
- owner cannot afford help
- another NPC solves it
- livestock losses continue
- player notices evidence and volunteers

The simulation owns the problem. UI only exposes information the player actually receives.

## Scope discipline

The vision is intentionally huge. Do not attempt to implement it all at once.

Follow `docs/MILESTONES.md`.

Current work should optimize for the earliest milestone that proves the risky idea.

When a task asks for a milestone, complete that milestone cleanly before expanding scope.

## Change discipline

For non-trivial changes:

1. Read the relevant docs.
2. State the intended behavior in the PR/commit context.
3. Keep unrelated refactors out.
4. Add tests or deterministic checks where practical.
5. Record size deltas when the change can materially affect the binary.
6. Update docs when behavior or architecture changes.
7. Do not overwrite locked design decisions without explicit owner direction.

## Build and platform expectations

Primary development target:

- native Linux
- Wayland session
- Vulkan-capable GPU
- Zig toolchain

Keep platform boundaries isolated. Do not smear Wayland/Vulkan details throughout simulation code.

The game should still have clean internal interfaces so alternative Linux display paths could be explored later if measurement justifies them.

## Definition of success

A technically impressive tiny binary that looks bad is not enough.

A beautiful renderer with no systemic life is not enough.

A giant simulation that needs huge content packs is not enough.

ASCII-Life succeeds when all three reinforce one another:

**beauty + life + tiny representation.**
