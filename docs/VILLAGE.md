# The starting village

Milestone 3 turns a suitable patch of regional terrain into an inhabited rural settlement. The generated plan, households and jobs are derived from the world seed. No architecture models, textures, scripts or population database are shipped.

## Boundaries

`village.zig` owns the physical plan: buildings, cultivated plots, connecting paths, clearing and arrival. `village_sim.zig` owns people, households, schedules and economy. `village_render.zig` projects generated architecture and residents directly into glyph cells, sharing the landscape depth buffer. Simulation does not depend on Wayland or Vulkan.

The plan borrows its terrain for surface heights; terrain must stay alive at a stable address. Local height-tile eviction changes neither buildings nor resident identities. A village remains in memory while its landscape detail streams.

## Time and observation

The simulation clock advances sixty seconds per real second: a full day takes 24 real minutes. Residents travel between assigned homes, work and public space. Production and consumption continue without player input. Rendering reads the resulting state; it does not cause work to happen.

The initial `--time` selects the starting day phase by advancing the same simulation from midnight. Space pauses time; `--static` freezes it for measurements. The existing T control advances three simulated hours as a development inspection tool. It does not implement player rest or bypass the design requirement for a safe home before gameplay time skips.

The player arrives outside the village on its approach. Buildings block ground-level movement and the third-person camera retracts against them. Development elevation controls can still inspect the scene from above.

## Inspection

```sh
./zig-out/bin/ascii-life --village-report
./zig-out/bin/ascii-life --simulate-days 28
./zig-out/bin/ascii-life --village-overview --capture artifacts/village.ppm
python3 scripts/verify_m3.py
```

Reports are developer data, not facts automatically revealed to the player or journal. Headless simulation runs without a display. Native visual checks use 2560 × 1440 Vulkan readbacks.

## Scope

The milestone establishes a small functioning settlement. Building interiors, conversation, social memory, relationship changes, player employment, combat and a save-file format are later work. State persists during the running session; restarting reconstructs the initial village. The economy is a compact production/consumption model, not a complete agricultural or market simulation. NPC age and household records provide starting identities; generational life events are not yet implemented.

## Generation and current limits

The initial population needs six homes, two cultivated plots, a workshop, granary and shared well. A compact rural layout rule produces these footprints and 31 connected path segments. This version uses a common street arrangement across seeds; site, ground elevation, building appearance and resident identities vary. It does not yet grow organically or choose new buildings from changing demand.

Site search first checks bounded grids near the M2 settlement candidate and starting bank. If neither fits, it ranks candidates on a 256 m regional grid, then a 128 m grid as a final fallback. Fine checks reject wet pads, overlapping buildings, disconnected entries and roads steeper than 22 percent. Homes use 9 × 8 m footprints and may span at most 3.6 m of terrain relief; their masonry foundations meet the ground. Cultivated plots are 34 × 28 m with at most 4.8 m relief. River proximity, fertility, height and slope inform scoring. Failure remains an explicit generation error rather than permission to place invalid structures.

The arrival connects to a road end 60 m beyond the village edge. Every building has a shared entry point used by both the rendered door and resident routes. Routes follow the connected path graph and validate their segments against water and occupied footprints. Failed routes wait and retry rather than taking a shortcut through a wall.

## Daily life and economy

Each home contains two working adults and one or two children, giving 18–24 residents. Seed-derived names and appearance remain stable. Adults receive farm, craft, storage or water-carrying work; children stay with their household and visit the shared public place. Residents commute, take a midday break, gather in the evening and return home. Sleeping residents are treated as indoors and hidden; interiors are not rendered.

Travel advances at 0.02 metres per simulated second, equivalent to 1.2 metres per real second at the normal clock rate. Integer event boundaries split departures, arrivals and consumption. Fractional production carries between calls, so work does not depend on how elapsed time is partitioned. Only workers who have arrived and are actually working contribute production.

Stocks are settlement-wide abstract food, water and goods units, stored in thousandths. Food and water each consume one daily ration per resident; goods demand is periodic per household. Initial stocks cover seven days of food and water. Storage is bounded, with overflow accounted for as discarded stock. Validation checks production/stock/consumption conservation and served demand plus shortages. Continuous farm output represents aggregate provisioning, not an implemented crop calendar. Water production represents well access rather than a simulated aquifer.

The unattended test advances 28 days both at once and in irregular chunks, requiring matching state fingerprints and no food/water shortages. A separate intervention redirects farm workers to craft jobs and requires food shortages, demonstrating that supply depends on labour. Native capture checks verify repeatability, morning commute, evening, night, third-person and an alternate seed at 1440p.
