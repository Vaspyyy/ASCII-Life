# Locked Decisions

This file is a quick reference for choices already made by the project owner.

## Identity

- Name: **ASCII-Life**
- Short name/theme: **A Life**
- Native Linux game
- Zig
- custom stack
- tiny executable challenge
- visual quality is equally important to small size

## Renderer

- colored ASCII/glyph cells are the primary visual language
- not a terminal game
- not an ASCII post-process gimmick
- first-person and third-person
- ASCII structure should participate in combat readability
- advanced magic can manipulate/corrupt glyph behavior in lore and mechanics

## Player and premise

- classic isekai world
- player appears near a tiny rural village
- physical starting age: 15
- magically understands local language
- open-ended life simulator
- classic adventurer path exists but is optional

## Progression

Mix of:

- skill-by-use
- knowledge and learned techniques
- lifestyle/body adaptation
- soul progression

Strongest emphasis:

- knowledge/technique
- soul progression

No required global XP level.

## NPCs

NPCs should eventually support:

- jobs
- homes
- memories
- life events
- family trees
- ambition
- relationships
- aging
- marriage
- children
- death
- persistent history

NPC lives continue without the player.

## Conversation

- hybrid structured intents + typed natural language
- no shipped LLM required
- typed language maps into the same intent system
- responses depend on actual NPC knowledge and relationships

## Information and opportunities

- no traditional internal quest system
- world has needs/problems/jobs/promises/rumors/opportunities/threats/ambitions/contracts
- NPCs do not automatically ask a total stranger for help
- public help can be advertised
- player can ask about work
- player can offer help proactively
- trust changes access to private problems
- other NPCs can solve problems first
- automatic journal records noteworthy learned information
- no conventional floating quest punctuation

## Time

- generations matter
- player ages normally
- long deliberate time skips unlock after establishing a stable home
- skipped time is actually simulated
- world continues during travel, death, and absence

## Death

- death occurs normally
- body reconstructs over time
- reanimation age is always 15
- death can stall or derail plans
- immortality is initially secret
- consequences of discovery are emergent
- player may become hunted, protected, worshipped, studied, feared, or ignored depending on history

## Soul Imprints

Forms can be acquired through:

- killing
- being killed by
- bonding
- prolonged study
- sufficiently fresh corpses

Context affects imprint quality.

Forms have real capabilities such as flight, scent, size, or aquatic movement.

## Magic

- hybrid system
- named established spells
- deeper compositional spell rules
- advanced understanding enables modification/invention

## Combat

- real-time action
- directional melee
- dodge
- block/parry
- ranged combat
- magic
- forms
- glyph field is a signature combat communication system

## Peoples

- humans plus classic fantasy peoples
- beastfolk are important and may be cute
- elves/dwarves/etc. are allowed
- culture is not species-locked
- cultures are procedural and historically shaped

## World

- finite planet
- one dominant supercontinent
- secondary continents
- islands and archipelagos
- meaningful seas
- ocean travel can use simulation-aware acceleration
- later traversal can include flying forms, advanced ships, portals, teleportation, airships, etc.
- world generation should be hierarchical, causal, validated, and deterministic

## Settlement growth

- procedural growth is desired
- villages can become towns/cities
- decline is possible
- growth should follow population, economy, trade, safety, infrastructure, and geography
- no arbitrary "settlement level up" button

## File-size philosophy

- no fixed final target
- always seek smaller representations without sacrificing the game
- track both dynamic ELF and self-contained distribution
- generated systems are preferred over large authored asset sets

## Core maxim

> **Store causes. Generate consequences.**
