# Problems, not quests

Milestone 5 adds one causal livestock and predator scenario to the starting village. The sheep belong to a farming household; their pen, vulnerable fence and nearby predators are generated from stable seed inputs. The same world clock drives animal provisioning, hunger, raids, household responses and information. No accepted/completed quest record is needed for these events to happen.

## Playing the slice

Ask residents `news`, `ask about livestock`, `ask about sheep`, or `ask about wolves`. Each answer comes from that person's current knowledge and retains the original evidence, witness, immediate source and observation time. A resident who has not heard about the animals cannot disclose hidden state.

The household can post a signed notice at the well when protection is needed. Approach the well and press **F** when the notice prompt appears. Reading records the posted statement and directions in the journal; it does not silently reveal subsequent changes to the flock. A nearby resident takes precedence for F conversation.

Say `help` to an informed resident who can arrange protection. Offering help earns no trust and does not solve the problem. Close the conversation and walk to the pen beside the field, following the spoken direction from the well. Hold **G** at ground level within nine metres of the pen to mend its fence and keep watch. World time continues while working; conversation and journal reading still pause it. A repair takes thirty simulated minutes of physical work (about thirty real seconds at the normal clock rate) and consumes real village goods. Holding G also keeps watch while nearby; a completed repair does not provide a permanent player guard. Protection and repairs affect actual subsequent losses and household livelihood, and consequential help can change the owner's trust and memories after the owner inspects the outcome. Nearby informed relatives or trusted coworkers can also contribute repair labor.

The pen, sheep and predator presence are generated geometry in glyph cells, sharing terrain/building depth. Fence gaps reflect damage. There are no objective arrows, floating punctuation or external creature models.

## Simulation and limits

`ecology.zig` owns compact livestock, predator and protection state. `world_clock.zig` advances the settlement to absolute hourly boundaries, updates ecology, then lets social observation and gossip proceed. Advancing unattended days visits the same checkpoints as small frame advances. NPC repair effort is a coarse hourly allocation based on being at the field checkpoint, not continuous per-resident labor tracking. Player work instead splits the real simulation at hourly and repair-completion boundaries. `village_sim.zig` records livestock provisioning/losses and repair inputs explicitly in its conservation ledger.

This is a bounded village-scale proof of needs creating gameplay. Predator behavior is a coarse hunger and pressure model; G performs husbandry and protective work. Real-time creature combat, breeding, seasonal pasture, save files and a general employment or contract system remain future milestones. State persists for this running session.

## Developer checks

```sh
zig build test
zig build test -Doptimize=ReleaseSmall
python3 scripts/verify_m5.py --headless-only
python3 scripts/verify_m5.py
./zig-out/bin/ascii-life --ecology-report --simulate-days 28
./zig-out/bin/ascii-life --pen-view
./zig-out/bin/ascii-life --pen-view --work-seconds 3600
./zig-out/bin/ascii-life --pen-view --elapsed-days 28
```

`--ecology-report` exposes privileged state and accounting headlessly. `--pen-view`, `--notice`, `--work-seconds` and `--elapsed-days` are inspection shortcuts, not gameplay travel, learned knowledge or unlocked time advancement. `--work-seconds` performs real work at the pen through the same state transitions and clock, with automatic developer volunteering. `--simulate-days` remains headless; `--elapsed-days` permits a native capture or continued play after advancement. Native visual checks run at 2560 × 1440 under Vulkan validation. Completion measurements are in [SIZE.md](SIZE.md).
