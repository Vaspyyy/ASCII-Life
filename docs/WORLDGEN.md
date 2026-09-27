# Regional geography: Milestone 2

This milestone builds one finite 8.192 km square region. It is not yet a generated planet, a life simulation, or a persistent edited world.

## Causes and consequences

The seed creates a meandering coastal valley bounded by foothill and mountain bands. A 257 × 257 quarter-metre elevation lattice provides the common regional skeleton. Validation requires meaningful land, water and relief; invalid skeletons regenerate through a bounded, deterministic sequence of derived seeds.

Climate uses a seed-derived regional latitude, local northing in actual metres, elevation lapse, distance to water, and prevailing west-to-east moisture transport. Orographic condensation and moisture depletion produce windward rain and lee rain shadows. Annual rainfall supplies the drainage model. Biomes and relative fertility, timber, stone and ore potential follow this geography. These are generation potentials, not inventories of harvestable game objects.

Drainage repairs depressions through a deterministic priority flood. Parent links point toward already-reached downstream cells, giving an acyclic outlet graph even on flats. Accumulation combines upstream rainfall. Sufficiently accumulated flow defines channel segments; depression filling defines lake surfaces. River water surfaces descend toward their parent and join at common endpoints. Fine terrain carves beds and banks around those channels. Vegetation responds to the resulting moisture and excludes wet ground.

A scored riverbank candidate considers water access, fertility, elevation and local slope. This identifies a possible future settlement site; no village, roads, residents or quests are created. The exploration camera starts on a generated riverbank.

## Detail and streaming

The regional causes stay in memory. The 8 m local height lattice is regenerated into a bounded 64-tile cache. Each 512 m tile contains 65 × 65 quarter-metre samples, including shared edges. Global sample coordinates make adjacent tile edges identical. Eviction discards only reconstructible data; returning to a tile reproduces its previous heights. Trees retain coordinate-derived identities independently of cache residency.

The renderer blends toward the macro heightfield from 800–1000 m. This is visual distance detail only: standing heights and tree identities use the fine field. Both views share the same water surfaces. There is no save file for untouched terrain and no background streaming thread in this milestone.

## Inspection

`--atlas` renders a development overview of the region. It is a QA tool, not the player's learned map or journal.

`--world-report` runs without a display, scans the full fine-height lattice for peak elevation, and reports drainage, climate/biome, generation identity, settlement suitability and cache statistics.

`python3 scripts/verify_m2.py --headless-only` checks multiple seeds and repeat generation. The full script additionally compares native 1440p Vulkan captures under validation. `zig build test` checks drainage invariants, climate response, macro repair, and cache eviction/reload.

## Current limits

Drainage is a static generation model; it does not simulate time-varying floods, sediment transport or seasonal discharge. Water shading approximates sky reflection. Regional climate is annual, not weather. Rivers can descend steeply as cascades. The coarse regional skeleton remains resident while local detail streams. The finite boundary is an outlet or clamped world edge, not an adjacent generated continent. Resource potentials and site suitability precede the economic and settlement systems in later milestones.
