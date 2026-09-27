# Milestones

The vision is enormous. Development must prove one risky layer at a time.

Do not skip ahead because a later system sounds exciting.

## Milestone 0: Tiny native foundation

### Goal

Prove that Zig can open a native Linux window, present a Vulkan-backed colored glyph grid, accept input, and produce useful size/performance measurements without a game engine.

### Deliverables

- Zig build
- Wayland-native window
- Vulkan surface and swapchain
- keyboard input
- mouse input
- stable frame loop
- embedded compact bitmap glyph data
- colored glyph-cell rendering
- resize handling
- clean shutdown
- release build
- size-report command or script
- basic runtime metrics in a developer mode

### Visual result

A window showing a deliberately attractive test scene made from colored glyph cells, not just "Hello world."

Include:

- gradients/colors
- several glyph densities
- oriented glyphs
- enough cells to judge scaling at 1080p and 1440p

### Acceptance

- runs natively on the target Wayland Linux environment
- no web runtime
- no game engine
- no external texture/font asset required for the glyph grid
- deterministic test pattern
- dynamic ELF size recorded
- practical self-contained build size recorded or blocker documented precisely
- RAM and VRAM baseline recorded
- no validation errors in normal Vulkan debug development run

## Milestone 1: The impossible screenshot

### Goal

Produce a procedural landscape that makes someone ask:

> "Wait, that's ASCII?"

No RPG systems yet.

### Features

- deterministic world seed
- camera movement
- first-person/third-person camera switch
- large heightfield
- mountains and valleys
- water
- forests
- sky
- atmospheric fog
- directional sun lighting
- day/night movement sufficient for visual testing
- material-aware glyph selection
- orientation-aware glyph selection
- distance-aware detail

### Acceptance

- same seed reproduces the same vista
- changing visual implementation does not reshuffle world identity
- landscape can be explored continuously
- no conventional texture assets
- stable performance measurement
- size delta from Milestone 0 documented
- at least one view is genuinely screenshot-worthy

## Milestone 2: A place

### Goal

Turn terrain into geography.

### Features

- constrained regional generation
- coherent mountain ranges
- hydrology
- rivers/lakes
- climate
- biomes
- resource potential
- deterministic region streaming
- world-generation validation

### Acceptance

- rivers obey defined invariants
- climate responds to geography
- seeds with invalid macro geography are repaired/regenerated deterministically
- regional transitions remain stable after unload/reload
- save system is not yet required for untouched generated land

## Milestone 3: The village

### Goal

Generate the initial rural settlement as a functioning place.

### Features

- settlement site selection
- roads/paths
- homes
- workplaces
- farms
- public buildings as appropriate
- small resident population
- households
- jobs
- schedules at local fidelity
- basic economy summaries
- starting player spawn nearby

### Acceptance

- residents have actual homes and work
- settlement layout follows terrain and needs
- no NPC exists solely to stand around waiting for the player
- village can run for simulated weeks without player intervention

## Milestone 4: People

### Goal

Make residents persistent social actors.

### Features

- identity
- traits
- family links
- relationships
- salient memory
- goals/ambition
- knowledge and belief
- information propagation
- basic conversation intents
- typed-input parser for a deliberately narrow useful grammar

### Acceptance

- two NPCs can hold different beliefs about the same event
- information has provenance
- relationship history changes responses
- strangers do not reveal implausibly private information
- player can learn about public work/problems by asking or observing

## Milestone 5: Problems, not quests

### Goal

Create gameplay from simulation needs.

### Example vertical slice

- livestock exists
- predator ecology exists
- attacks can happen
- household suffers consequences
- information spreads
- household chooses responses
- public notice may be created
- another NPC can respond
- player can discover and volunteer
- outcome changes memories/economy/trust
- journal records what player actually learned

### Acceptance

There is no hidden traditional quest object required to make the scenario function.

## Milestone 6: A life

### Goal

Prove that ordinary life is fun and persistent.

### Features

Choose a minimal coherent subset:

- work
- home
- farming or fishing
- friendship
- romance
- household formation
- calendar/seasons
- stable-home time advancement
- aging

### Acceptance

A player can spend multiple simulated years in the village without joining an adventurers' guild and still experience meaningful change.

## Milestone 7: Death and the soul

### Goal

Introduce the protagonist's defining supernatural rule.

### Features

- player death
- corpse/death location
- reconstruction timer
- world simulation continues
- reformation at physical age 15
- witnesses and information consequences
- initial Soul Imprint
- at least one functional animal form

### Acceptance

Death can cause a meaningful missed opportunity without requiring save reload.

## Milestone 8: Action

### Goal

Add combat whose visual language belongs to ASCII-Life.

### Features

- melee
- directional attack
- block/parry
- dodge
- stamina
- hostile creature
- glyph telegraphing
- glyph impact disruption
- first/third person compatibility

### Acceptance

A player can learn something about attack direction by reading the glyph field rather than relying only on conventional HUD markers.

## Milestone 9: Magic

### Goal

Prove named spells and compositional rules can coexist.

### Features

- mana/energy model as later designed
- several culturally established spells
- underlying spell composition
- one modifiable spell
- glyph-field magical effect

## Milestone 10: Generations

### Goal

Prove the world can outlive individuals.

### Features

- birth
- childhood
- aging
- marriage/partnership
- children
- death
- inheritance basics
- family trees
- long-term memories/stories
- settlement demographic evolution

### Acceptance

Simulate decades and inspect coherent multi-generation households.

## Milestone 11: Settlement evolution

### Goal

Allow the starting village to physically and socially change.

### Features

- migration
- population pressure
- construction demand
- building placement
- business creation/closure
- infrastructure
- trade effects
- decline as well as growth

### Acceptance

A village can become larger through simulated causes without calling a scripted "upgrade village" event.

## Milestone 12: Planet

### Goal

Connect local life to the finite world.

### Features

- dominant supercontinent
- secondary continents
- archipelagos
- polities
- cultures
- fantasy peoples
- coarse historical burn-in
- ship travel
- simulation-aware travel acceleration

This milestone is intentionally late. Do not build a planet before one village is worth living in.
