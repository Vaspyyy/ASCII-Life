# ASCII-Life

**A Life** is a native Linux open-world isekai life simulation rendered as beautiful colored ASCII.

The challenge is not merely to make an ASCII game. The challenge is to discover how much world, simulation, beauty, and player freedom can fit inside a *tiny* native executable.

> **Store causes. Generate consequences.**

Instead of shipping huge asset packs, ASCII-Life aims to generate its world from compact rules, algorithms, deterministic seeds, and simulation state.

## The fantasy

You arrive in another world at age 15 near a small rural village.

You can follow the obvious anime-adventure path:

- join an adventurers' guild
- learn swordsmanship and magic
- explore dungeons
- hunt monsters
- travel between kingdoms
- become absurdly powerful

Or you can ignore it.

You can settle in a village, farm, fish, learn a trade, make friends, fall in love, marry, have children, help the settlement prosper, and watch generations pass. A tiny village might eventually become a major city because of what its people, including you, actually did.

The world does not wait for the protagonist.

## Core pillars

### 1. A gorgeous ASCII world

ASCII characters are the actual visual language, not a post-processing joke.

Each cell can carry glyph, foreground color, background color, depth, and other compact rendering data. Terrain, foliage, water, weather, magic, lighting, and combat should exploit the glyph field deliberately.

At normal viewing distance the goal is a beautiful fantasy landscape.

Zoom in and discover that it is text.

### 2. A living generational simulation

Persistent NPCs can have:

- homes and jobs
- families and family trees
- friendships, rivalries, and romance
- memories and opinions
- ambitions and fears
- possessions and wealth
- schedules and life events
- births, aging, marriage, migration, and death

Simulation detail scales with relevance and distance. Nearby lives can run moment by moment. Distant populations can resolve in coarser steps.

### 3. No traditional quest system

Internally, the world has needs, problems, jobs, rumors, promises, threats, ambitions, and contracts.

An NPC does not generate `Quest #41: Kill 5 Wolves`.

A farmer might lose sheep to wolves, ask a trusted hunter, post a public notice, seek help from the reeve, attempt to solve the problem personally, or do nothing because they cannot afford help. The player can discover the situation naturally and choose whether to become involved.

The journal records noteworthy information the character has actually learned. There are no floating quest markers.

### 4. The world keeps moving

Time matters.

If the player ignores a problem, someone else may solve it. If the player leaves home for years, children grow up, people die, businesses change, wars progress, and settlements evolve.

Once the player has a stable home, longer periods of quiet life can be simulated deliberately.

### 5. Immortality with consequences

The protagonist ages normally, but death is not permanent.

After death, the body takes time to reconstruct and eventually reforms at age 15.

Death therefore costs *time*, not a reload screen.

The monster may be gone. The caravan may have left. Crops may fail. A battle may happen without you. Someone may discover your corpse or witness your return.

Your immortality begins as a secret. Over decades or centuries, that secret can become a rumor, religion, political crisis, scientific obsession, manhunt, or source of fierce protection.

### 6. Soul Imprints

The protagonist can acquire biological forms from meaningful encounters with creatures, including killing, being killed by, prolonged study, bonding, or contact with a sufficiently fresh corpse.

An imprint is not a cosmetic skin. Forms have functional anatomy and traversal abilities.

Examples:

- hawk: flight and exceptional vision
- wolf: tracking, scent, wilderness speed
- cat: stealth and access through tiny spaces
- aquatic creature: underwater traversal
- magical creatures: rare late-game capabilities

The quality of an imprint depends on how deeply the creature is understood.

### 7. A finite but enormous procedural planet

The world is a finite generated planet with:

- one dominant supercontinent
- secondary continents
- island chains and archipelagos
- meaningful seas
- mountains shaped by tectonic rules
- rivers and watersheds
- climate and rain shadows
- resources that influence settlement
- centuries of coarse history before the player arrives

Early travel uses walking, mounts, wagons, and ships. Ocean travel can use simulation-aware time acceleration. Later progression can unlock flight, magical gates, teleportation, and other advanced traversal.

## Progression

There is no required global XP level.

Progression mixes:

- **practice:** skills improve through meaningful use
- **knowledge:** teachers, books, observation, and experimentation unlock understanding
- **technique:** specific moves and methods are learned rather than appearing at arbitrary levels
- **lifestyle:** the body adapts to how the player lives
- **soul:** persistent traits and form knowledge survive death

Guild rank, reputation, wealth, social standing, magical knowledge, and combat capability are separate things.

## Magic

Magic is hybrid.

The world teaches recognizable named spells, but they are built from a compositional system underneath. As the player understands magic more deeply, established spells can be modified and original spells can be constructed from principles such as element, shape, behavior, magnitude, and modifiers.

ASCII distortion is allowed to become part of the lore and mechanics of advanced magic.

## Combat

Combat is real-time action with first-person and third-person play.

Expected foundations include:

- directional attacks
- blocking and parrying
- dodging
- stamina
- bows
- magic

The signature layer is the renderer itself. Glyph orientation, density, motion, and corruption can telegraph attacks and represent impacts. Skilled players should gradually learn to *read the ASCII field* in combat.

## Peoples and cultures

The world includes humans and familiar fantasy peoples, including beastfolk, elves, dwarves, and others.

Species do not define a single monoculture. Cultures, religions, economies, customs, politics, and settlements are generated independently, so two groups of the same people can be radically different.

Beastfolk should be allowed to be extremely cute.

## Tiny executable challenge

ASCII-Life keeps two size records:

1. **Dynamic ELF record:** stripped release executable using ordinary supported Linux system interfaces.
2. **Self-contained record:** the smallest practical redistributable build, excluding only the Linux kernel, compositor/display environment, and GPU driver infrastructure that cannot reasonably be part of the game.

No fixed final byte target is sacred. The goal is to keep making the game better while ruthlessly asking whether each feature can be generated from rules rather than stored as bulk data.

Prefer procedural or compact representations for:

- terrain
- vegetation
- architecture
- animation
- sound and music
- materials
- weather
- world history
- settlements
- NPC variation
- magic
- quests and social content

## Technology direction

- **Language:** Zig
- **Platform:** native Linux
- **Display:** Wayland-first
- **Graphics:** Vulkan-first
- **Architecture:** custom renderer and simulation stack
- **Primary philosophy:** deterministic generation, simulation LOD, compact data, measurable binary size

Milestone 4 adds people with relationships, beliefs and memories to the starting village. Talk to residents and record what they actually tell you in your journal.

See:

- [AGENTS.md](AGENTS.md)
- [docs/VISION.md](docs/VISION.md)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/SYSTEMS.md](docs/SYSTEMS.md)
- [docs/MILESTONES.md](docs/MILESTONES.md)
- [docs/SIZE.md](docs/SIZE.md)
- [docs/DECISIONS.md](docs/DECISIONS.md)
- [docs/CODEX_KICKOFF.md](docs/CODEX_KICKOFF.md)

## Status

**Pre-alpha / Milestone 4 people.**

Native build, controls, and validation instructions: [docs/BUILD.md](docs/BUILD.md).
Size and performance records: [docs/SIZE.md](docs/SIZE.md).

Arrive on a path outside a generated rural village. Homes, cultivated plots and workplaces follow the terrain; residents have households, jobs and daily routines. Explore in first or third person while production and consumption continue. Geography and architecture are generated at runtime; no external visual assets are shipped.

Generation and inspection tools: [docs/WORLDGEN.md](docs/WORLDGEN.md).

Village behavior and inspection: [docs/VILLAGE.md](docs/VILLAGE.md). Conversation and social state: [docs/PEOPLE.md](docs/PEOPLE.md). Combat, generational events and save files remain future work.
