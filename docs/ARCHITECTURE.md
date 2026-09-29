# Architecture

This document defines the intended technical shape. It is a direction, not permission to overbuild future systems during early milestones.

## Stack

- language: Zig
- operating system: Linux
- display path: Wayland-first
- graphics: Vulkan-first
- renderer: custom
- game engine: none
- simulation: custom deterministic systems

Keep platform, renderer, simulation, generation, persistence, and game logic separable enough that each can be tested independently.

## High-level modules

A likely conceptual split:

```text
platform/
  wayland
  input
  timing

render/
  vulkan
  glyph_atlas
  cell_buffer
  camera
  terrain
  atmosphere

world/
  seed
  planet
  tectonics
  hydrology
  climate
  biome
  resources
  region_generation

sim/
  clock
  event_queue
  npc
  family
  settlement
  economy
  ecology
  politics
  information

game/
  player
  progression
  soul_imprints
  combat
  magic
  conversation
  journal

persist/
  save_format
  deltas
  history
```

This is conceptual. Do not create empty folders or abstractions merely to match the diagram.

## Platform boundary

Keep native window/input code isolated.

The rest of the project should not care whether input arrived through Wayland or another future Linux backend.

The renderer should receive a native surface/window handle through a small boundary.

Avoid dragging large platform libraries into the project before measuring whether they are worth their byte cost.

## Renderer model

The final visible image is a grid of colored glyph cells.

A conceptual cell:

```text
glyph
foreground RGB
background RGB
depth
optional compact semantic/material data
```

Do not freeze the exact in-memory layout until measured.

The renderer may use one or more lower-resolution geometry/material buffers internally, but the final visual decision should be made in glyph space.

### Glyph selection

Eventually consider:

- luminance
- local contrast
- edge direction
- surface normal
- material class
- motion
- distance
- atmospheric depth
- combat telegraph direction
- magical corruption/distortion

A brightness ramp alone is acceptable only as an early milestone.

### Font representation

Prefer an embedded compact bitmap/bitset glyph representation.

A small fixed glyph set can be extraordinarily cheap.

Do not ship a large font file merely for convenience without measuring alternatives.

### Resolution

The logical cell grid is independent of output pixel resolution.

A 1440p window can display a much lower logical glyph grid whose cells are rasterized sharply at presentation.

Expose logical cell resolution as a development tuning parameter.

### Camera

The design requires both first-person and third-person.

Do not duplicate world rendering. Camera mode should be a view-layer concern.

## Procedural planet

Do not generate land by thresholding one noise field.

Generation is hierarchical and constrained.

### Stage 1: planetary skeleton

Generate:

- dominant landmass target
- secondary landmasses
- ocean basins
- island/archipelago regions
- broad latitude/climate structure

### Stage 2: tectonic structure

Use compact plate-like or ridge/rift rules to create coherent:

- mountain chains
- volcanic arcs
- plateaus
- rifts
- old stable terrain

A full geophysical simulator is not required. The goal is believable causality at low code/data cost.

### Stage 3: elevation and erosion

Build terrain from the structural skeleton.

Use erosion or erosion-like passes where cost-effective.

### Stage 4: hydrology

Determine drainage and watersheds.

Rules:

- rivers flow downhill
- streams merge
- basins can form lakes
- overflowing lakes can create outlets
- major rivers should reach plausible sinks

### Stage 5: climate

Derive climate from:

- latitude
- elevation
- ocean proximity
- prevailing moisture direction
- rain shadow
- seasonality

### Stage 6: biomes and ecology

Biomes emerge from climate and terrain rather than random stamping.

### Stage 7: resources

Place resource potential according to geology, hydrology, ecology, and climate.

### Stage 8: settlement suitability

Evaluate locations based on plausible needs such as:

- fresh water
- food potential
- transport
- defense
- resources
- river crossings
- harbors
- trade junctions

### Stage 9: coarse cultures and polities

Seed populations and let geography/history shape them.

### Stage 10: historical burn-in

Simulate centuries at a coarse level before game start.

The goal is to create causes for:

- old roads
- ruins
- borders
- cities
- abandoned settlements
- cultural spread
- wars
- trade routes
- fortresses
- migration

### Stage 11: validation and repair

Generation must inspect its own output.

Examples:

- dominant continent missing
- pathological fragmentation
- unusable climate monotony
- impossible drainage
- huge pointless ocean gaps
- no viable starting region
- trapped major populations

Repair small failures deterministically.

Regenerate a high-level stage deterministically when repair is inappropriate.

## Deterministic seed hierarchy

Never consume one giant global RNG stream for everything.

Derive sub-seeds from stable identities.

Conceptually:

```text
world seed
  -> planet seed
  -> region seed(x,y)
  -> settlement seed(id)
  -> person seed(id)
  -> local object seed(position/type)
```

Changing tree generation should not reshuffle every NPC in the world.

Use stable hashing or another explicit sub-seed derivation scheme.

## Streaming

The planet is represented at several spatial scales.

### Global

Cheap persistent summaries:

- landmasses
- climate
- major terrain
- major rivers
- regions
- polities
- major settlements
- coarse demographics

### Regional

Generated or loaded when relevant:

- roads
- tributaries
- forests
- villages
- local resource structure
- ruins

### Local

High-detail transient or persistent state:

- trees
- rocks
- buildings
- interiors
- nearby NPC behavior
- combat

Regenerate deterministic detail when possible.

Persist only meaningful divergence.

## Simulation LOD

Simulation resolution changes with relevance.

Possible cadence:

```text
visible/nearby      frame, second, or event driven
same settlement     minutes or hours
same region         hours or days
distant polity      days or weeks
remote world        weeks, months, seasons, events
```

The model must preserve important causality when crossing fidelity boundaries.

Do not merely randomize a distant person's future every time they come back into range.

## NPC representation

A persistent NPC may contain compact state for:

- identity seed
- birth date
- people/species
- culture
- traits
- home
- profession
- household
- family links
- social links
- goals
- wealth/inventory summary
- health/life status
- salient memories
- beliefs/knowledge
- current coarse activity

Not all information needs equal fidelity.

### Memory

Do not store every conversation verbatim.

Prefer salient structured memories with:

- subject
- event type
- participants
- time
- emotional weight
- confidence
- source
- decay/persistence class

Memories affect behavior and information sharing.

### Information propagation

Facts and rumors move through people and institutions.

An NPC can distinguish:

- witnessed
- told by trusted source
- rumor
- official notice
- inference
- uncertain belief

This system supports the immortality secret, politics, crime, gossip, quest-like opportunities, and reputation.

## Problems instead of quests

Represent world situations causally.

Example:

```text
wolf pack
  -> attacks livestock
  -> household loses food/wealth
  -> fear rises
  -> household seeks solutions
  -> information spreads
  -> hunter may respond
  -> player may learn and volunteer
```

Do not create an objective object merely because the player heard about it.

The journal subscribes to information the player learns and records useful summaries.

## Settlement growth

Settlement physical form should follow simulated demand.

Inputs can include:

- population
- households
- professions
- food surplus
- wealth
- trade
- traffic
- security
- transport
- institutions
- resource extraction

When new capacity is required, a compact layout generator can choose plausible expansion.

Use the terrain, roads, water, property, and existing buildings as constraints.

The save file should preserve significant built changes, not a redundant copy of untouched generated terrain.

## Time

The simulation owns one world clock.

Ordinary gameplay has a meaningful day/night cycle.

Longer time advancement is available only after the player has a stable home or equivalent safe anchor.

During a skip:

- advance coarse world simulation
- resolve queued events
- age people
- update households
- update settlements/economy
- update player domestic state
- stop or warn for events that require direct player intervention according to later design

Do not fake a time skip by merely incrementing a date.

## Reanimation

Death creates a world event.

The player enters a non-active reconstruction period.

The world continues.

The reconstruction duration can later depend on damage, soul progression, form, magic, or other factors.

On completion, the player reforms at physical age 15.

Personal identity, memories, knowledge, soul state, and appropriate progression persist.

Physical consequences require later design and balancing.

## Soul Imprints

Treat a form as a biological capability set plus learned familiarity.

Avoid storing unique meshes or textures.

Forms should be generated from compact procedural morphology and glyph vocabulary where possible.

Imprint quality can influence:

- control
- stamina
- sensory fidelity
- transformation speed
- access to specialized abilities

## Conversation parser

Conversation has two front ends:

1. explicit intent controls
2. typed natural language

Both produce a compact intent representation.

The parser should identify enough structure to support gameplay without pretending to be a general language model.

Possible fields:

- speech act
- topic
- target entity
- requested action
- offered action
- time reference
- location reference
- truth/lie intent where explicitly chosen
- tone modifier if later useful

NPC response selection then consults knowledge, memory, relationship, personality, culture, goals, and context.

## Persistence

Save data should be versioned from the first persistent milestone.

Principle:

```text
generated base world
+ historical simulation state
+ persistent deltas
= current world
```

Avoid dumping raw memory structs as a save format.

Use explicit stable serialization.

Keep compatibility concerns proportional to project maturity, but never make deterministic worlds impossible to load because an internal struct moved.

## Testing

Prioritize tests for systems where invisible determinism bugs can poison long saves.

Examples:

- seed derivation
- world generation invariants
- hydrology invariants
- date/calendar arithmetic
- genealogy consistency
- information propagation
- save/load round trips
- coarse/fine simulation transitions
- settlement accounting

Visual renderer tests can use deterministic scene hashes or captured development references where practical.

## Performance target philosophy

Do not pick fantasy numbers before a renderer exists.

Instead establish baselines, profile, and track regressions.

The renderer should be extremely cheap relative to conventional high-resolution 3D because logical world shading can operate at glyph-cell scale.

Use that saved budget on atmosphere, world scale, and simulation rather than wasting it.

## Milestone 0 implementation boundary

The first foundation uses four small Zig modules rather than creating the entire conceptual tree above. Wayland and Vulkan are confined to `platform.zig` and `renderer.zig`. `scene.zig` generates a fixed test composition from integer coordinates and an explicit animation tick; it has no native-platform imports. This is a renderer test image, not the future terrain generator.

A cell uses 16 bytes in the initial CPU/GPU interface: glyph index, packed foreground RGB, packed background RGB, and reserved padding matching the shader storage-buffer layout. The glyph table is 128 entries of two 32-bit words (1,024 bytes); only the original demonstration characters have nonzero patterns. Resolution, table size, shader sizes, and resulting ELF cost are measured before attempting tighter packing.

The platform calls ordinary system libraries directly. `libwayland-client` supplies protocol transport and proxy management, and the Vulkan loader connects to the host GPU driver. Reimplementing either would add substantial protocol/driver-discovery and synchronization obligations without evidence of a useful size saving. These choices are isolated behind the two native modules and do not affect deterministic cell generation. The initial size ledger records their runtime/distribution boundary rather than treating dynamic linking as a self-contained build.

## Milestone 1 regional landscape

The terrain's identity is independent of the renderer. `terrain.zig` derives a bounded 8.192 km × 8.192 km region from a 64-bit seed: a meandering valley/lake corridor, separate foothill and mountain bands, and smaller surface variation. It reconstructs a 1025 × 1025 quarter-metre height cache at startup (2,101,250 bytes), then bilinearly samples it. Strict floating-point generation plus explicit quantization is regression-checked against a complete sample fingerprint. Rendering palette, glyph choices, camera, and time of day never enter terrain identity. This is a regional visual prototype; planetary generation and hydrological simulation remain later milestones.

Trees have stable signed 24-metre grid identities with separate tagged sub-seeds for placement, size, kind, density, and tint. They depend on elevation and slope, not camera distance or iteration order. Renderer distance limits affect visibility only.

`camera.zig` owns platform-independent movement and produces the same view interface for first and third person. A pitch-driven third-person boom keeps the explorer framed using the glyph projection, enforces terrain/water clearance, and samples the intervening segment for obstruction. Extreme clefts can force a close view that crops the placeholder figure. The player silhouette is a compact visual placeholder; development elevation controls and movement over water are inspection tools, not implemented flight or swimming systems.

`landscape.zig` projects the heightfield directly into glyph columns with adaptive distance steps and per-cell depth. Trees and the third-person silhouette use the same depth field. Surface material, orientation, distance, and directional illumination determine glyph/color choices; the Vulkan pass only rasterizes those already-selected cells. No conventional high-resolution image is converted into ASCII. Sky, cloud patterns, water effects, and atmospheric haze are generated from rules. The visual clock can be paused or stepped without changing world identity; it is not yet the life simulation's clock.


## Milestone 2 geography and detail cache

The M1 full fine-height cache is superseded by a 257 × 257 regional skeleton, derived climate/drainage fields, and a bounded 64-tile local-detail cache. `hydrology.zig` owns drainage graph construction, accumulation and water sampling; `climate.zig` owns annual climate, biome classification and resource potentials; `streaming.zig` owns disposable 512 m height tiles. `terrain.zig` integrates those causes, carves channel banks, chooses an initial riverbank and scores a future settlement candidate. It retains one precomputed ridge frame per 8 m row to avoid repeating row-wide generation during tile fills.

Only distant rendering blends to the regional lattice. Tree positions and physical standing heights use stable fine generation. The developer atlas and headless world report inspect the generated world without introducing a revealed player journal. See [WORLDGEN.md](WORLDGEN.md) for the invariants, validation commands and limits.

## Milestone 3 village

Physical settlement generation, resident simulation and architecture rendering are separate modules: `village.zig`, `village_sim.zig`, and `village_render.zig`. Landscape rendering supplies paths, cultivated ground and clearing. Projected structure surfaces share its depth buffer. The world clock drives resident schedules and economy; draw frequency does not determine production. Headless advancement exercises the same simulation as native play. See [VILLAGE.md](VILLAGE.md) for current behavior and scope.

## Milestone 4 people

`people.zig` attaches compact social state to stable resident identities. `world_clock.zig` schedules social updates at absolute simulation-hour boundaries, including across development clock jumps. `dialogue.zig` owns the narrow intent parser, bounded transcript, learned-information journal and glyph panels. `interaction.zig` gates conversation by physical range, orientation and visibility.

Wayland keyboard layout translation uses libxkbcommon inside `platform.zig`; the game consumes an ordered queue of printable ASCII/edit/submit/cancel events. Simulation and dialogue have no native library imports. Modal reading pauses the shared clock and suppresses movement hotkeys. No save format is introduced in this milestone; social state is session-resident. See [PEOPLE.md](PEOPLE.md) for behavior, limits and the measured dependency rationale.
