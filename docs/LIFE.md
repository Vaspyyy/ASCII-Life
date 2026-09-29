# A life: Milestone 6

The ordinary-life slice adds paid agricultural work, meals, a rented room,
earned friendships, a calendar, seasons, basic aging and a compact save. It
uses the existing village clock and economy. It has no quest object, global
experience level, external assets or new game runtime dependency.

## Establishing a life

Approach a farmer and press **F**. `work` asks about their profession;
`hire me` requests employment. Go to that farmer's field entrance and hold
**G** while the farmer is present during working hours. Each complete hour
earns two coins and up to a quarter daily ration from actual village stock.
The daily paid limit is six hours. Working produces additional provisions,
improves field practice and earns the farmer's trust through useful shared
work. Offering help alone does not earn wages or trust.

Ask the keeper of the village stores to `buy food`: three coins buy two daily
rations when enough provisions exist. A farmer does not serve as an unlimited
food shop. The player consumes one ration per day; shortages cause hunger.
Labor increases fatigue, and ordinary rest recovers it. These needs currently
limit productive work; injury and death are Milestone 7.

After four paid hours for a household, or sufficient earned trust, ask one of
its working adults to `rent a room`. The first week costs seven coins, then
rent costs one coin each day. Seven unpaid days lose the room. A room is a
life anchor at an existing generated household; interiors and furnishing are
not implemented.

**K** opens a life panel showing the player's own arrangements, food, money,
needs and known directions. Reading the panel, conversation or journal pauses
the clock. Names are disclosed through actual introductions and agreements.

## Passing time

At the rented door, with manageable hunger and fatigue, **B** sleeps eight
hours, **V** lives seven days and **N** lives ninety days. Close the life panel
first. Long advancement is unavailable before acquiring a stable home. Loss
of the anchor or severely unmet needs interrupts a domestic routine.

The longer routine follows the player's existing agricultural employment,
shopping, meals, rent and rest through the shared clock. It abstracts the
player's daily commute rather than rendering every journey. The employer
still follows their physical schedule; hourly ecology and social events still
happen, provisions are produced and consumed, and useful work earns trust.
This is a coarse simulation of an established ordinary life, not a date-only
skip or a source of free money and food.

Years contain **360 days**, with four **90-day seasons**. Agricultural output
changes with the season. Cultivated glyphs and deciduous trees show the same
calendar's seasonal changes without changing generated geography or tree
identities. The player starts at physical age fifteen and ages each year.
Residents age too; a child reaching adulthood can join an existing household
trade. New families, romance, births, migration and death are later systems.
The original M5 flock can still decline to zero; seasonal farming sustains the
village independently of that flock.

## Persistence

Normal play resumes and saves a local slot at
`$XDG_DATA_HOME/ascii-life/life.sav`, or
`$HOME/.local/share/ascii-life/life.sav` when XDG_DATA_HOME is unset.
**F5** saves and **F9** reloads. `--new` begins a new life. Display preferences (`--size`, `--third-person`, `--hide-hud`) retain this
ordinary-play slot. Developer reports, captures, benchmarks and scenario flags
do not load or overwrite it.
Explicit `--save PATH` and `--load PATH` support reproducible QA and separate
slots.

Version one has a bounded 128 KiB envelope, explicit little-endian scalar
encoding, world seed, generator and schema versions, identity/layout checks
and a checksum. Decoding validates independent temporary state before
publishing it. File replacement writes and syncs a temporary file before
renaming it. Corrupt or incompatible saves fail clearly; compatibility with
future generator or schema changes is not promised in this pre-alpha.

Terrain, buildings, static resident identities and route polylines are
regenerated. Saves retain economy and resident evolution, route causes,
relationships, memories, learned information, livestock changes, player life
and viewpoint. Dialogue input and open panels are disposable; the journal is
persistent. Save size is recorded separately from executable/distribution
size.

## Validation

```sh
zig build test
zig build test -Doptimize=ReleaseSmall
python3 scripts/verify_m6.py --headless-only
python3 scripts/verify_m6.py
./zig-out/bin/ascii-life --settle --live-days 1080 --life-report
./zig-out/bin/ascii-life --settle --save /tmp/a-life.sav --life-report
./zig-out/bin/ascii-life --load /tmp/a-life.sav --live-days 90 --life-report
```

Simulation, accounting and serialization checks need no display. Native GPU
captures use `scripts/background.py` and an isolated KWin virtual Wayland
display at 2560 × 1440. They open no desktop windows and have no visible
fallback. KWin and dbus-run-session are development test infrastructure,
excluded from the game and its runtime bundle. Headless presentation timing
does not measure physical scanout or desktop compositor latency.

The developer `--settle` scenario goes through employment, actual paid field
work and rental eligibility. It is a QA shortcut for arranging those actions,
not a gameplay reward or journal revelation. Full keyboard interaction is a
separate validation boundary from deterministic simulation and GPU readbacks.
