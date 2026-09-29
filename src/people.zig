const std = @import("std");
const village_sim = @import("village_sim.zig");

pub const max_people: usize = village_sim.max_residents;
pub const max_family_links: usize = 4;
pub const max_memories: usize = 6;
pub const max_knowledge: usize = 4;
pub const player_id: u8 = std.math.maxInt(u8);

pub const Topic = enum(u8) { food_reserves, harvest, work, livestock };
pub const Belief = enum(u8) {
    well_stocked,
    thin_stock,
    critical,
    harvest_started,
    harvest_modest,
    work_steady,
    work_sparse,
    livestock_taken,
    livestock_threatened,
    livestock_protected,
    livestock_lost_all,
};
pub const Provenance = enum(u8) { witnessed, told, inferred, notice };
pub const Privacy = enum(u8) { public, personal, private, secret };

pub const PlayerAction = enum(u8) {
    greeting,
    helpful_work,
    kept_promise,
    useful_information,
    betrayal,
    insult,
};

pub const FamilyKind = enum(u8) { partner, parent, child, sibling };
pub const GoalKind = enum(u8) { tend_fields, maintain_supplies, craft_better_tools, carry_water, learn_village_trades };
pub const MemoryKind = enum(u8) { met_player, player_helped, player_betrayed, player_insulted, learned_news, saw_harvest, saw_work, saw_livestock };

pub const Traits = struct {
    caution: u8 = 50,
    sociability: u8 = 50,
    ambition: u8 = 50,
    patience: u8 = 50,
};

pub const FamilyLink = struct {
    other_id: u8,
    kind: FamilyKind,
};

pub const NpcRelationship = struct {
    affinity: i8 = 0,
    interactions: u16 = 0,
    last_event_id: u32 = 0,
    last_interaction_seconds: u64 = 0,
};

pub const Memory = struct {
    kind: MemoryKind,
    subject_id: u8 = player_id,
    source_id: u8 = player_id,
    event_id: u32 = 0,
    at_seconds: u64 = 0,
    confidence: u8 = 100,
    salience: u8 = 20,
    valence: i8 = 0,
};

pub const Knowledge = struct {
    topic: Topic,
    belief: Belief,
    provenance: Provenance,
    confidence: u8,
    source_id: u8,
    witness_id: u8,
    event_id: u32,
    observed_at: u64, // Original observation time, preserved through retellings.
    evidence_days: u16 = 0,
    evidence_count: u16 = 0,
    evidence_losses: u16 = 0,
    subject_id: u8 = player_id,
    hop_count: u8 = 0,
    privacy: Privacy = .public,
};

pub const Goal = struct {
    kind: GoalKind = .learn_village_trades,
    progress_hours: u16 = 0,
    target_hours: u16 = 24,
    completed: bool = false,
};

pub const PlayerRelationship = struct {
    met: bool = false,
    trust: i8 = 0,
    encounters: u16 = 0,
    meaningful_actions: u16 = 0,
    first_met_at: u64 = 0,
    last_met_at: u64 = 0,
    last_action_day: u64 = std.math.maxInt(u64),
};

pub const Person = struct {
    id: u8 = 0,
    name: [24]u8 = [_]u8{0} ** 24,
    name_len: u8 = 0,
    age_years: u8 = 0,
    household: u8 = 0,
    job: village_sim.Job = .child,
    activity: village_sim.Activity = .resting,
    traits: Traits = .{},
    family: [max_family_links]FamilyLink = undefined,
    family_count: u8 = 0,
    relationships: [max_people]NpcRelationship = [_]NpcRelationship{.{}} ** max_people,
    memories: [max_memories]Memory = undefined,
    memory_count: u8 = 0,
    knowledge: [max_knowledge]Knowledge = undefined,
    knowledge_count: u8 = 0,
    goal: Goal = .{},
    player: PlayerRelationship = .{},

    pub fn nameSlice(self: *const Person) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Compact social state for the current resident population. The opening
/// reserve assessment is grounded in the simulator's actual food stock. News
/// spreads only when people share a place, and every retelling keeps its
/// original witness and immediate source.
pub const Social = struct {
    persons: [max_people]Person = undefined,
    count: u8 = 0,
    seed: u64 = 0,
    last_update_seconds: u64 = 0,
    last_food_produced_milli: u64 = 0,
    last_work_seconds: u64 = 0,
    last_harvest_day: u64 = std.math.maxInt(u64),
    work_remainder_seconds: [max_people]u16 = [_]u16{0} ** max_people,
    last_activity: [max_people]village_sim.Activity = undefined,

    pub fn init(sim: *const village_sim.Sim, seed: u64) Social {
        var self = Social{
            .count = @intCast(@min(sim.resident_count, max_people)),
            .seed = seed,
            .last_update_seconds = sim.elapsed_seconds,
            .last_food_produced_milli = sim.economy.food_produced_milli,
            .last_work_seconds = sim.economy.work_seconds,
        };

        for (0..self.count) |index| {
            const resident = sim.residents[index];
            var person_value = Person{
                .id = @intCast(index),
                .age_years = resident.age_years,
                .household = resident.household,
                .job = resident.job,
                .activity = resident.activity,
                .traits = makeTraits(seed, resident.id),
                .relationships = [_]NpcRelationship{.{}} ** max_people,
            };
            const name = resident.nameSlice();
            const name_len = @min(name.len, person_value.name.len);
            @memcpy(person_value.name[0..name_len], name[0..name_len]);
            person_value.name_len = @intCast(name_len);
            person_value.goal = goalFor(resident.job, person_value.traits.ambition);
            self.persons[index] = person_value;
            self.last_activity[index] = resident.activity;
        }

        self.buildFamilyLinks(sim);
        self.seedOpeningReserve(sim);
        return self;
    }

    /// Call once after each hourly simulation step. The caller splits larger
    /// advances at absolute hour boundaries so work tracking and conversations
    /// see the same event sequence regardless of frame timing.
    pub fn tick(self: *Social, sim: *const village_sim.Sim) void {
        if (sim.elapsed_seconds <= self.last_update_seconds) return;
        const elapsed = sim.elapsed_seconds - self.last_update_seconds;
        self.advanceGoals(sim, elapsed);

        if (sim.economy.work_seconds > self.last_work_seconds) self.observeWork(sim);
        if (sim.economy.food_produced_milli > self.last_food_produced_milli) self.observeHarvest(sim);

        self.spreadNearby(sim);
        self.last_work_seconds = sim.economy.work_seconds;
        self.last_food_produced_milli = sim.economy.food_produced_milli;
        self.last_update_seconds = sim.elapsed_seconds;
        for (0..self.count) |index| {
            self.persons[index].activity = sim.residents[index].activity;
            self.last_activity[index] = sim.residents[index].activity;
        }
    }

    pub fn person(self: *const Social, id: u8) ?*const Person {
        if (id >= self.count) return null;
        return &self.persons[id];
    }

    pub fn knowledgeAbout(self: *const Social, id: u8, topic: Topic) ?Knowledge {
        const person_value = self.person(id) orelse return null;
        for (person_value.knowledge[0..person_value.knowledge_count]) |knowledge| {
            if (knowledge.topic == topic) return knowledge;
        }
        return null;
    }

    /// A local ecology witness or public notice records sourced evidence.
    /// No entry is added merely because the player asked about a problem.
    pub fn observeLivestock(self: *Social, id: u8, knowledge: Knowledge) void {
        if (knowledge.topic != .livestock or id >= self.count) return;
        self.addKnowledge(id, knowledge);
        self.remember(id, .{
            .kind = .saw_livestock,
            .subject_id = knowledge.subject_id,
            .source_id = knowledge.source_id,
            .event_id = knowledge.event_id,
            .at_seconds = knowledge.observed_at,
            .confidence = knowledge.confidence,
            .salience = 72,
            .valence = if (knowledge.belief == .livestock_protected) 1 else -1,
        });
    }

    pub fn trust(self: *const Social, id: u8) i8 {
        if (id >= self.count) return 0;
        return self.persons[id].player.trust;
    }

    /// Meeting again can become familiar history, but greetings never improve
    /// trust. Meaningful help is recorded separately through recordPlayerAction.
    pub fn meet(self: *Social, id: u8, now: u64) void {
        if (id >= self.count) return;
        var relation = &self.persons[id].player;
        if (relation.met and now -| relation.last_met_at < 3600) return;
        if (!relation.met) {
            relation.met = true;
            relation.first_met_at = now;
            self.remember(id, .{
                .kind = .met_player,
                .at_seconds = now,
                .salience = 12,
                .valence = 0,
            });
        }
        relation.encounters +|= 1;
        relation.last_met_at = now;
    }

    /// One consequential player action per resident per simulated day prevents
    /// repeated dialogue choices from manufacturing trust.
    pub fn recordPlayerAction(self: *Social, id: u8, action: PlayerAction, now: u64) void {
        if (id >= self.count or action == .greeting) return;
        self.meet(id, now);
        const day = now / village_sim.seconds_per_day;
        var relation = &self.persons[id].player;
        if (relation.last_action_day == day) return;
        relation.last_action_day = day;
        relation.meaningful_actions +|= 1;
        const delta: i16 = switch (action) {
            .greeting => 0,
            .helpful_work => 8,
            .kept_promise => 10,
            .useful_information => 5,
            .betrayal => -25,
            .insult => -8,
        };
        relation.trust = clampTrust(@as(i16, relation.trust) + delta);
        const kind: MemoryKind = switch (action) {
            .greeting => .met_player,
            .helpful_work, .kept_promise, .useful_information => .player_helped,
            .betrayal => .player_betrayed,
            .insult => .player_insulted,
        };
        self.remember(id, .{
            .kind = kind,
            .event_id = dayEventId(0x400000, now / village_sim.seconds_per_day),
            .at_seconds = now,
            .salience = if (action == .betrayal) 90 else if (action == .kept_promise or action == .helpful_work) 65 else 42,
            .valence = if (delta < 0) -1 else 1,
        });
    }

    pub fn canDisclose(self: *const Social, id: u8, privacy: Privacy) bool {
        const person_value = self.person(id) orelse return false;
        const relation = person_value.player;
        return switch (privacy) {
            .public => true,
            .personal => relation.trust >= 15 + @as(i8, @intCast(person_value.traits.caution / 25)) and relation.meaningful_actions >= 1,
            .private => relation.trust >= 35 + @as(i8, @intCast(person_value.traits.caution / 10)) and relation.meaningful_actions >= 2,
            .secret => relation.trust >= 65 + @as(i8, @intCast(person_value.traits.caution / 5)) and relation.meaningful_actions >= 3,
        };
    }

    pub fn fingerprint(self: *const Social) u64 {
        var h = mix64(self.seed ^ self.last_update_seconds);
        h = mix(h, self.count);
        h = mix(h, self.last_food_produced_milli);
        h = mix(h, self.last_work_seconds);
        h = mix(h, self.last_harvest_day);
        for (self.persons[0..self.count]) |person_value| {
            h = mix(h, person_value.id);
            h = mix(h, person_value.age_years);
            h = mix(h, person_value.household);
            h = mix(h, @intFromEnum(person_value.job));
            h = mix(h, @intFromEnum(person_value.activity));
            h = mix(h, person_value.traits.caution);
            h = mix(h, person_value.traits.sociability);
            h = mix(h, person_value.traits.ambition);
            h = mix(h, person_value.traits.patience);
            h = mix(h, @intFromEnum(person_value.goal.kind));
            h = mix(h, person_value.goal.progress_hours);
            h = mix(h, person_value.goal.target_hours);
            h = mix(h, person_value.goal.completed);
            h = mix(h, @as(u8, @bitCast(person_value.player.trust)));
            h = mix(h, person_value.player.met);
            h = mix(h, person_value.player.encounters);
            h = mix(h, person_value.player.meaningful_actions);
            h = mix(h, person_value.player.first_met_at);
            h = mix(h, person_value.player.last_met_at);
            h = mix(h, person_value.player.last_action_day);
            for (person_value.family[0..person_value.family_count]) |link| {
                h = mix(h, link.other_id);
                h = mix(h, @intFromEnum(link.kind));
            }
            for (person_value.relationships[0..self.count]) |relationship| {
                h = mix(h, @as(u8, @bitCast(relationship.affinity)));
                h = mix(h, relationship.interactions);
                h = mix(h, relationship.last_event_id);
                h = mix(h, relationship.last_interaction_seconds);
            }
            for (person_value.knowledge[0..person_value.knowledge_count]) |knowledge| {
                h = mix(h, @intFromEnum(knowledge.topic));
                h = mix(h, @intFromEnum(knowledge.belief));
                h = mix(h, @intFromEnum(knowledge.provenance));
                h = mix(h, knowledge.confidence);
                h = mix(h, knowledge.source_id);
                h = mix(h, knowledge.witness_id);
                h = mix(h, knowledge.event_id);
                h = mix(h, knowledge.observed_at);
                h = mix(h, knowledge.evidence_days);
                h = mix(h, knowledge.evidence_count);
                h = mix(h, knowledge.evidence_losses);
                h = mix(h, knowledge.subject_id);
                h = mix(h, knowledge.hop_count);
                h = mix(h, @intFromEnum(knowledge.privacy));
            }
            for (person_value.memories[0..person_value.memory_count]) |memory| {
                h = mix(h, @intFromEnum(memory.kind));
                h = mix(h, memory.subject_id);
                h = mix(h, memory.source_id);
                h = mix(h, memory.event_id);
                h = mix(h, memory.at_seconds);
                h = mix(h, memory.salience);
                h = mix(h, @as(u8, @bitCast(memory.valence)));
            }
        }
        for (self.work_remainder_seconds[0..self.count], self.last_activity[0..self.count]) |remainder, activity| {
            h = mix(h, remainder);
            h = mix(h, @intFromEnum(activity));
        }
        return h;
    }

    pub fn validate(self: *const Social, sim: *const village_sim.Sim) error{InvalidState}!void {
        if (self.count != sim.resident_count or self.count > max_people) return error.InvalidState;
        if (self.last_update_seconds > sim.elapsed_seconds) return error.InvalidState;
        for (self.persons[0..self.count], 0..) |person_value, index| {
            if (person_value.id != index or person_value.household != sim.residents[index].household) return error.InvalidState;
            if (person_value.family_count > max_family_links or person_value.memory_count > max_memories or person_value.knowledge_count > max_knowledge) return error.InvalidState;
            if (person_value.goal.completed != (person_value.goal.progress_hours >= person_value.goal.target_hours)) return error.InvalidState;
            for (person_value.family[0..person_value.family_count]) |link| {
                if (link.other_id >= self.count or link.other_id == person_value.id) return error.InvalidState;
                if (!hasReciprocalFamilyLink(self, person_value.id, link)) return error.InvalidState;
            }
            for (person_value.knowledge[0..person_value.knowledge_count], 0..) |knowledge, knowledge_index| {
                if (knowledge.source_id >= self.count or knowledge.witness_id >= self.count or knowledge.confidence > 100) return error.InvalidState;
                for (person_value.knowledge[knowledge_index + 1 .. person_value.knowledge_count]) |other| {
                    if (knowledge.topic == other.topic) return error.InvalidState;
                }
            }
            for (person_value.relationships[0..self.count], 0..) |relationship, other_id| {
                if (relationship.affinity != self.persons[other_id].relationships[index].affinity) return error.InvalidState;
            }
        }
    }

    fn buildFamilyLinks(self: *Social, sim: *const village_sim.Sim) void {
        for (0..self.count) |a| {
            for (a + 1..self.count) |b| {
                const first = sim.residents[a];
                const second = sim.residents[b];
                if (first.household != second.household) continue;
                const a_adult = first.age_years >= 18;
                const b_adult = second.age_years >= 18;
                // A link names the other person's role: an adult's link to a
                // child is `.child`, while the child's link is `.parent`.
                const kind_a: FamilyKind = if (a_adult and b_adult) .partner else if (a_adult) .child else if (b_adult) .parent else .sibling;
                const kind_b: FamilyKind = switch (kind_a) {
                    .parent => .child,
                    .child => .parent,
                    .partner => .partner,
                    .sibling => .sibling,
                };
                self.addFamilyLink(a, @intCast(b), kind_a);
                self.addFamilyLink(b, @intCast(a), kind_b);
                const bond: i8 = switch (kind_a) {
                    .partner => 30,
                    .parent, .child => 26,
                    .sibling => 18,
                };
                self.persons[a].relationships[b].affinity = bond;
                self.persons[b].relationships[a].affinity = bond;
            }
        }
    }

    fn addFamilyLink(self: *Social, id: usize, other_id: u8, kind: FamilyKind) void {
        const person_value = &self.persons[id];
        if (person_value.family_count >= max_family_links) return;
        person_value.family[person_value.family_count] = .{ .other_id = other_id, .kind = kind };
        person_value.family_count += 1;
    }

    fn seedOpeningReserve(self: *Social, sim: *const village_sim.Sim) void {
        if (self.count == 0) return;
        const source_id = findReserveWitness(sim, self.count);
        const daily_demand = @max(@as(u64, 1), @as(u64, self.count) * 1000);
        const evidence_days: u16 = @intCast(@min(sim.economy.food_stock_milli / daily_demand, std.math.maxInt(u16)));
        const source_belief = reserveBelief(evidence_days);
        const opening_event: u32 = 1;
        self.addKnowledge(source_id, .{
            .topic = .food_reserves,
            .belief = source_belief,
            .provenance = .witnessed,
            .confidence = 96,
            .source_id = source_id,
            .witness_id = source_id,
            .event_id = opening_event,
            .observed_at = sim.elapsed_seconds,
            .evidence_days = evidence_days,
            .privacy = .public,
        });
        self.remember(source_id, .{
            .kind = .learned_news,
            .source_id = source_id,
            .event_id = opening_event,
            .at_seconds = sim.elapsed_seconds,
            .confidence = 96,
            .salience = 42,
            .valence = if (source_belief == .critical or source_belief == .thin_stock) -1 else 1,
        });

        // The farmer reads the same seven-day reserve differently because part
        // of those stores must remain available as seed. Preserve the measured
        // amount so listeners can distinguish evidence from interpretation.
        if (source_belief == .well_stocked) {
            if (findDifferentFarmer(sim, self.count, source_id)) |farmer_id| {
                const seed_reserve_horizon = 7 + self.persons[farmer_id].traits.caution / 25;
                if (evidence_days > seed_reserve_horizon) return;
                self.addKnowledge(farmer_id, .{
                    .topic = .food_reserves,
                    .belief = .thin_stock,
                    .provenance = .inferred,
                    .confidence = 64,
                    .source_id = farmer_id,
                    .witness_id = source_id,
                    .event_id = opening_event,
                    .observed_at = sim.elapsed_seconds,
                    .evidence_days = evidence_days,
                    .privacy = .public,
                });
            }
        }
    }

    fn advanceGoals(self: *Social, sim: *const village_sim.Sim, elapsed: u64) void {
        for (0..self.count) |index| {
            const activity = self.last_activity[index];
            const goal = &self.persons[index].goal;
            const advancing = switch (goal.kind) {
                .learn_village_trades => activity == .visiting,
                else => activity == .working and sim.residents[index].employed,
            };
            if (!advancing or goal.completed) continue;
            const target_seconds = @as(u64, goal.target_hours) * 3600;
            const complete_seconds = @as(u64, goal.progress_hours) * 3600 + self.work_remainder_seconds[index];
            const remaining = target_seconds -| complete_seconds;
            const added = @min(elapsed, remaining);
            const accumulated = @as(u64, self.work_remainder_seconds[index]) + added;
            const hours = accumulated / 3600;
            goal.progress_hours = @intCast(@min(goal.target_hours, @as(u64, goal.progress_hours) + hours));
            self.work_remainder_seconds[index] = @intCast(accumulated % 3600);
            goal.completed = goal.progress_hours >= goal.target_hours;
            if (goal.completed) self.work_remainder_seconds[index] = 0;
        }
    }

    fn observeWork(self: *Social, sim: *const village_sim.Sim) void {
        const day = sim.day();
        const event_id = dayEventId(0x200000, day);
        if (self.hasEvent(.work, event_id)) return;
        var source_id: ?u8 = null;
        var reserve_keeper: ?u8 = null;
        var worker_count: u8 = 0;
        for (sim.residents[0..self.count], 0..) |resident, index| {
            if (!resident.employed or resident.activity != .working) continue;
            if (source_id == null) source_id = @intCast(index);
            if (resident.job == .keeper) reserve_keeper = @intCast(index);
            worker_count +|= 1;
        }
        const source = source_id orelse return;
        self.addKnowledge(source, .{
            .topic = .work,
            .belief = if (worker_count >= 2) .work_steady else .work_sparse,
            .provenance = .witnessed,
            .confidence = 92,
            .source_id = source,
            .witness_id = source,
            .event_id = event_id,
            .observed_at = sim.elapsed_seconds,
        });
        self.remember(source, .{
            .kind = .saw_work,
            .source_id = source,
            .event_id = event_id,
            .at_seconds = sim.elapsed_seconds,
            .confidence = 92,
            .salience = 30,
            .valence = if (worker_count >= 2) 1 else 0,
        });
        if (reserve_keeper) |keeper_id| self.observeReserves(sim, keeper_id);
    }

    fn observeReserves(self: *Social, sim: *const village_sim.Sim, source_id: u8) void {
        const event_id = dayEventId(0x300000, sim.day());
        if (self.hasEvent(.food_reserves, event_id)) return;
        const daily_demand = @max(@as(u64, 1), @as(u64, self.count) * 1000);
        const evidence_days: u16 = @intCast(@min(sim.economy.food_stock_milli / daily_demand, std.math.maxInt(u16)));
        const belief = reserveBelief(evidence_days);
        self.addKnowledge(source_id, .{
            .topic = .food_reserves,
            .belief = belief,
            .provenance = .witnessed,
            .confidence = 96,
            .source_id = source_id,
            .witness_id = source_id,
            .event_id = event_id,
            .observed_at = sim.elapsed_seconds,
            .evidence_days = evidence_days,
            .privacy = .public,
        });
        self.remember(source_id, .{
            .kind = .learned_news,
            .source_id = source_id,
            .event_id = event_id,
            .at_seconds = sim.elapsed_seconds,
            .confidence = 96,
            .salience = 42,
            .valence = if (belief == .critical or belief == .thin_stock) -1 else 1,
        });
    }

    fn observeHarvest(self: *Social, sim: *const village_sim.Sim) void {
        const day = sim.day();
        if (day == self.last_harvest_day) return;
        const event_id = dayEventId(0x100000, day);
        var source_id: ?u8 = null;
        for (sim.residents[0..self.count], 0..) |resident, index| {
            if (resident.job == .farmer and resident.employed) {
                source_id = @intCast(index);
                if (resident.activity == .working) break;
            }
        }
        const source = source_id orelse return;
        self.last_harvest_day = day;
        const daily_per_person = @max(@as(u64, 1), @as(u64, self.count) * 1000);
        const production = sim.economy.food_produced_milli -| self.last_food_produced_milli;
        const belief: Belief = if (production >= daily_per_person / 4) .harvest_started else .harvest_modest;
        self.addKnowledge(source, .{
            .topic = .harvest,
            .belief = belief,
            .provenance = .witnessed,
            .confidence = 94,
            .source_id = source,
            .witness_id = source,
            .event_id = event_id,
            .observed_at = sim.elapsed_seconds,
        });
        self.remember(source, .{
            .kind = .saw_harvest,
            .source_id = source,
            .event_id = event_id,
            .at_seconds = sim.elapsed_seconds,
            .confidence = 94,
            .salience = 48,
            .valence = if (belief == .harvest_started) 1 else 0,
        });
    }

    fn spreadNearby(self: *Social, sim: *const village_sim.Sim) void {
        for (0..self.count) |from| {
            if (!canTalk(sim.residents[from].activity)) continue;
            const from_knowledge_count = self.persons[from].knowledge_count;
            for (from + 1..self.count) |to| {
                if (!canTalk(sim.residents[to].activity)) continue;
                const sociability = @max(self.persons[from].traits.sociability, self.persons[to].traits.sociability);
                const radius = 2.0 + @as(f32, @floatFromInt(sociability)) / 50.0;
                if (!near(sim.residents[from].position, sim.residents[to].position, radius)) continue;
                for (0..from_knowledge_count) |knowledge_index| {
                    const knowledge = self.persons[from].knowledge[knowledge_index];
                    self.relayKnowledge(@intCast(from), @intCast(to), knowledge, sim.elapsed_seconds);
                }
                const to_knowledge_count = self.persons[to].knowledge_count;
                for (0..to_knowledge_count) |knowledge_index| {
                    const knowledge = self.persons[to].knowledge[knowledge_index];
                    self.relayKnowledge(@intCast(to), @intCast(from), knowledge, sim.elapsed_seconds);
                }
            }
        }
    }

    fn relayKnowledge(self: *Social, from: u8, to: u8, source_knowledge: Knowledge, now: u64) void {
        if (from == to) return;
        if (self.knowledgeAbout(to, source_knowledge.topic)) |existing| {
            // Event ids are ordered within each topic. A rumor that arrives
            // late cannot push the listener back to an older observation.
            if (existing.event_id >= source_knowledge.event_id) return;
        }
        var belief = source_knowledge.belief;
        const seed_reserve_horizon = 7 + self.persons[to].traits.caution / 25;
        if (source_knowledge.topic == .food_reserves and source_knowledge.evidence_days <= seed_reserve_horizon and self.persons[to].job == .farmer and belief == .well_stocked) {
            belief = .thin_stock;
        }
        const retention = 65 + @as(u16, self.persons[to].traits.patience) / 4;
        const confidence: u8 = @intCast(@max(35, @as(u16, source_knowledge.confidence) * retention / 100));
        self.addKnowledge(to, .{
            .topic = source_knowledge.topic,
            .belief = belief,
            .provenance = .told,
            .confidence = confidence,
            .source_id = from,
            .witness_id = source_knowledge.witness_id,
            .event_id = source_knowledge.event_id,
            .observed_at = source_knowledge.observed_at,
            .evidence_days = source_knowledge.evidence_days,
            .evidence_count = source_knowledge.evidence_count,
            .evidence_losses = source_knowledge.evidence_losses,
            .subject_id = source_knowledge.subject_id,
            .hop_count = @intCast(@min(255, @as(u16, source_knowledge.hop_count) + 1)),
            .privacy = source_knowledge.privacy,
        });
        self.remember(to, .{
            .kind = .learned_news,
            .subject_id = from,
            .source_id = from,
            .event_id = source_knowledge.event_id,
            .at_seconds = now,
            .confidence = confidence,
            .salience = if (source_knowledge.topic == .food_reserves) 36 else 28,
            .valence = if (belief == .critical or belief == .thin_stock or belief == .work_sparse or belief == .harvest_modest or belief == .livestock_taken or belief == .livestock_lost_all) -1 else 0,
        });
        self.recordNpcExchange(from, to, source_knowledge.event_id, now);
    }

    fn recordNpcExchange(self: *Social, from: u8, to: u8, event_id: u32, now: u64) void {
        if (self.persons[from].relationships[to].last_event_id == event_id) return;
        for ([_]u8{ from, to }, 0..) |id, slot| {
            const other = if (slot == 0) to else from;
            var tie = &self.persons[id].relationships[other];
            tie.affinity = @intCast(@min(100, @as(i16, tie.affinity) + 1));
            tie.interactions +|= 1;
            tie.last_event_id = event_id;
            tie.last_interaction_seconds = now;
        }
    }

    fn addKnowledge(self: *Social, id: u8, knowledge: Knowledge) void {
        if (id >= self.count) return;
        var person_value = &self.persons[id];
        for (person_value.knowledge[0..person_value.knowledge_count], 0..) |existing, index| {
            if (existing.topic != knowledge.topic) continue;
            if (existing.event_id == knowledge.event_id) return;
            if (knowledge.event_id > existing.event_id) person_value.knowledge[index] = knowledge;
            return;
        }
        if (person_value.knowledge_count < max_knowledge) {
            person_value.knowledge[person_value.knowledge_count] = knowledge;
            person_value.knowledge_count += 1;
        } else {
            var oldest: usize = 0;
            for (1..max_knowledge) |index| {
                if (person_value.knowledge[index].observed_at < person_value.knowledge[oldest].observed_at) oldest = index;
            }
            person_value.knowledge[oldest] = knowledge;
        }
    }

    fn remember(self: *Social, id: u8, memory: Memory) void {
        if (id >= self.count) return;
        var person_value = &self.persons[id];
        for (person_value.memories[0..person_value.memory_count], 0..) |existing, index| {
            if (existing.kind == memory.kind and existing.event_id == memory.event_id and existing.subject_id == memory.subject_id) {
                person_value.memories[index].at_seconds = memory.at_seconds;
                person_value.memories[index].salience = @max(existing.salience, memory.salience);
                person_value.memories[index].confidence = @max(existing.confidence, memory.confidence);
                return;
            }
        }
        if (person_value.memory_count < max_memories) {
            person_value.memories[person_value.memory_count] = memory;
            person_value.memory_count += 1;
            return;
        }
        var least = memoryScore(person_value.memories[0], memory.at_seconds);
        var replace: usize = 0;
        for (1..max_memories) |index| {
            const score = memoryScore(person_value.memories[index], memory.at_seconds);
            if (score < least) {
                least = score;
                replace = index;
            }
        }
        if (memoryScore(memory, memory.at_seconds) > least) person_value.memories[replace] = memory;
    }

    fn hasEvent(self: *const Social, topic: Topic, event_id: u32) bool {
        for (self.persons[0..self.count]) |person_value| {
            if (hasKnowledge(person_value, topic, event_id)) return true;
        }
        return false;
    }
};

fn makeTraits(seed: u64, id: u8) Traits {
    const base = seed ^ (@as(u64, id) *% 0x9e3779b97f4a7c15);
    return .{
        .caution = @intCast(mix64(base ^ 0x243f6a8885a308d3) % 101),
        .sociability = @intCast(mix64(base ^ 0x13198a2e03707344) % 101),
        .ambition = @intCast(mix64(base ^ 0xa4093822299f31d0) % 101),
        .patience = @intCast(mix64(base ^ 0x082efa98ec4e6c89) % 101),
    };
}

fn goalFor(job: village_sim.Job, ambition: u8) Goal {
    var goal = switch (job) {
        .farmer => Goal{ .kind = .tend_fields, .target_hours = 36 },
        .keeper => Goal{ .kind = .maintain_supplies, .target_hours = 30 },
        .craftsperson => Goal{ .kind = .craft_better_tools, .target_hours = 36 },
        .water_carrier => Goal{ .kind = .carry_water, .target_hours = 24 },
        .child => Goal{ .kind = .learn_village_trades, .target_hours = 12 },
    };
    goal.target_hours += ambition / 20;
    return goal;
}

fn findReserveWitness(sim: *const village_sim.Sim, count: u8) u8 {
    for (sim.residents[0..count], 0..) |resident, index| if (resident.job == .keeper and resident.employed) {
        return @intCast(index);
    };
    for (sim.residents[0..count], 0..) |resident, index| if (resident.job == .farmer and resident.employed) {
        return @intCast(index);
    };
    return 0;
}

fn findDifferentFarmer(sim: *const village_sim.Sim, count: u8, source_id: u8) ?u8 {
    for (sim.residents[0..count], 0..) |resident, index| {
        if (index != source_id and resident.job == .farmer and resident.employed) return @intCast(index);
    }
    return null;
}

fn reserveBelief(days: u16) Belief {
    if (days >= 7) return .well_stocked;
    if (days >= 2) return .thin_stock;
    return .critical;
}

fn dayEventId(namespace: u32, day: u64) u32 {
    return namespace + @as(u32, @truncate(day));
}

fn canTalk(activity: village_sim.Activity) bool {
    return activity != .sleeping and activity != .walking;
}

fn near(a: village_sim.Position, b: village_sim.Position, radius: f32) bool {
    const dx = a.x - b.x;
    const dz = a.z - b.z;
    return dx * dx + dz * dz <= radius * radius;
}

fn clampTrust(value: i16) i8 {
    return @intCast(@max(-100, @min(100, value)));
}

fn hasKnowledge(person_value: Person, topic: Topic, event_id: u32) bool {
    for (person_value.knowledge[0..person_value.knowledge_count]) |knowledge| {
        if (knowledge.topic == topic and knowledge.event_id == event_id) return true;
    }
    return false;
}

fn hasReciprocalFamilyLink(self: *const Social, id: u8, link: FamilyLink) bool {
    const reciprocal: FamilyKind = switch (link.kind) {
        .parent => .child,
        .child => .parent,
        .partner => .partner,
        .sibling => .sibling,
    };
    const other = self.persons[link.other_id];
    for (other.family[0..other.family_count]) |candidate| {
        if (candidate.other_id == id and candidate.kind == reciprocal) return true;
    }
    return false;
}

fn memoryScore(memory: Memory, now: u64) u16 {
    const age_days = @min((now -| memory.at_seconds) / village_sim.seconds_per_day, 365);
    const decay: u16 = @intCast(@min(age_days, 60));
    return @as(u16, memory.salience) + @as(u16, memory.confidence) / 10 -| decay;
}

fn mix(h: u64, value: anytype) u64 {
    const numeric: u64 = if (@TypeOf(value) == bool) @intFromBool(value) else @intCast(value);
    return mix64(h ^ (numeric +% 0x9e3779b97f4a7c15));
}

fn mix64(input: u64) u64 {
    var value = input;
    value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
    value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
    return value ^ (value >> 31);
}

fn testSim() village_sim.Sim {
    var sim = village_sim.Sim{
        .resident_count = 4,
        .household_count = 1,
        .world_seed = 41,
        .economy = .{ .food_stock_milli = 28_000 },
    };
    sim.households[0] = .{ .home_building = 0, .first_resident = 0, .resident_count = 4 };
    sim.residents[0] = .{ .id = 0, .name = .{ 'A', 'd', 'a' } ++ [_]u8{0} ** 21, .name_len = 3, .age_years = 36, .appearance_seed = 1, .household = 0, .home_building = 0, .public_building = 1, .workplace = 2, .job = .farmer, .employed = true, .activity = .working, .position = .{ .x = 0, .y = 0, .z = 0 } };
    sim.residents[1] = .{ .id = 1, .name = .{ 'B', 'e', 'n' } ++ [_]u8{0} ** 21, .name_len = 3, .age_years = 34, .appearance_seed = 2, .household = 0, .home_building = 0, .public_building = 1, .workplace = 3, .job = .keeper, .employed = true, .activity = .working, .position = .{ .x = 1, .y = 0, .z = 0 } };
    sim.residents[2] = .{ .id = 2, .name = .{ 'C', 'a', 'l' } ++ [_]u8{0} ** 21, .name_len = 3, .age_years = 9, .appearance_seed = 3, .household = 0, .home_building = 0, .public_building = 1, .position = .{ .x = 2, .y = 0, .z = 0 } };
    sim.residents[3] = .{ .id = 3, .name = .{ 'D', 'e', 'v' } ++ [_]u8{0} ** 21, .name_len = 3, .age_years = 6, .appearance_seed = 4, .household = 0, .home_building = 0, .public_building = 1, .position = .{ .x = 3, .y = 0, .z = 0 } };
    return sim;
}

test "opening reserve supports different evidence-linked beliefs" {
    const sim = testSim();
    const social = Social.init(&sim, 41);
    const keeper_view = social.knowledgeAbout(1, .food_reserves).?;
    const farmer_view = social.knowledgeAbout(0, .food_reserves).?;
    try std.testing.expectEqual(@as(u16, 7), keeper_view.evidence_days);
    try std.testing.expectEqual(keeper_view.event_id, farmer_view.event_id);
    try std.testing.expectEqual(Belief.well_stocked, keeper_view.belief);
    try std.testing.expectEqual(Belief.thin_stock, farmer_view.belief);
    try std.testing.expectEqual(Provenance.witnessed, keeper_view.provenance);
    try std.testing.expectEqual(Provenance.inferred, farmer_view.provenance);
    try std.testing.expectEqual(@as(u8, 1), farmer_view.witness_id);
}

test "family links are reciprocal and goals follow real activity" {
    var sim = testSim();
    var social = Social.init(&sim, 41);
    try social.validate(&sim);
    try std.testing.expectEqual(@as(u8, 3), social.persons[0].family_count);
    try std.testing.expectEqual(FamilyKind.partner, social.persons[0].family[0].kind);
    try std.testing.expectEqual(FamilyKind.child, social.persons[0].family[1].kind);
    sim.elapsed_seconds = 3600;
    sim.economy.work_seconds = 3600;
    sim.economy.farmer_work_seconds = 3600;
    sim.economy.food_produced_milli = 300;
    social.tick(&sim);
    try std.testing.expectEqual(@as(u16, 1), social.persons[0].goal.progress_hours);
    try std.testing.expect(social.knowledgeAbout(0, .harvest) != null);
    try std.testing.expect(social.knowledgeAbout(0, .work) != null);
    try social.validate(&sim);
}

test "encounters are not trust and private talk needs meaningful history" {
    var sim = testSim();
    var social = Social.init(&sim, 41);
    const stranger_fingerprint = social.fingerprint();
    social.meet(0, 10);
    social.meet(0, 20);
    try std.testing.expect(social.fingerprint() != stranger_fingerprint);
    try std.testing.expectEqual(@as(i8, 0), social.trust(0));
    try std.testing.expect(!social.canDisclose(0, .private));
    social.recordPlayerAction(0, .helpful_work, 100);
    social.recordPlayerAction(0, .helpful_work, 200);
    try std.testing.expectEqual(@as(i8, 8), social.trust(0));
    try std.testing.expect(!social.canDisclose(0, .personal));
    social.recordPlayerAction(0, .kept_promise, village_sim.seconds_per_day + 100);
    social.recordPlayerAction(0, .helpful_work, village_sim.seconds_per_day * 2 + 100);
    try std.testing.expect(social.canDisclose(0, .personal));
    try std.testing.expect(!social.canDisclose(0, .private));
}

test "news travels with teller and original witness provenance" {
    var sim = testSim();
    var social = Social.init(&sim, 41);
    sim.elapsed_seconds = 3600;
    social.tick(&sim);
    const told = social.knowledgeAbout(2, .food_reserves) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(Provenance.told, told.provenance);
    try std.testing.expect(told.source_id < social.count);
    try std.testing.expectEqual(@as(u8, 1), told.witness_id);
    try std.testing.expectEqual(@as(u32, 1), told.event_id);
    try std.testing.expect(social.persons[0].relationships[2].interactions > 0);
}

test "late rumor cannot replace a newer keeper reserve count" {
    var sim = testSim();
    var social = Social.init(&sim, 41);
    sim.residents[0].activity = .sleeping;
    sim.residents[0].position.x = -100;
    sim.residents[1].position.x = 0;
    sim.residents[2].position.x = 1;
    sim.residents[3].activity = .sleeping;
    sim.residents[3].position.x = 100;
    sim.elapsed_seconds = 3600;
    sim.economy.food_stock_milli = 24_000;
    sim.economy.work_seconds = 3600;
    sim.economy.keeper_work_seconds = 3600;
    social.tick(&sim);
    const fresh = social.knowledgeAbout(2, .food_reserves).?;
    try std.testing.expect(fresh.event_id > 1);
    try std.testing.expectEqual(@as(u16, 6), fresh.evidence_days);

    sim.elapsed_seconds = 7200;
    sim.residents[0].activity = .resting;
    sim.residents[0].position.x = 0;
    sim.residents[1].activity = .sleeping;
    sim.residents[1].position.x = 100;
    sim.residents[3].activity = .resting;
    sim.residents[3].position.x = 2;
    social.tick(&sim);
    const still_fresh = social.knowledgeAbout(2, .food_reserves).?;
    try std.testing.expectEqual(fresh.event_id, still_fresh.event_id);
    try std.testing.expectEqual(fresh.evidence_days, still_fresh.evidence_days);
    // Hearing old evidence today must not make its original observation fresh.
    try std.testing.expectEqual(fresh.observed_at, social.knowledgeAbout(3, .food_reserves).?.observed_at);
}

test "important memories stay within a fixed bound" {
    var sim = testSim();
    var social = Social.init(&sim, 41);
    for (0..12) |day| {
        const now = @as(u64, @intCast(day)) * village_sim.seconds_per_day + 1;
        social.recordPlayerAction(0, .betrayal, now);
    }
    try std.testing.expectEqual(@as(u8, max_memories), social.persons[0].memory_count);
    var retained_betrayal = false;
    for (social.persons[0].memories[0..social.persons[0].memory_count]) |memory| {
        if (memory.kind == .player_betrayed and memory.salience >= 90) retained_betrayal = true;
    }
    try std.testing.expect(retained_betrayal);
}

test "livestock information preserves household evidence through retelling" {
    var sim = testSim();
    var social = Social.init(&sim, 41);
    social.observeLivestock(0, .{
        .topic = .livestock,
        .belief = .livestock_taken,
        .provenance = .witnessed,
        .confidence = 96,
        .source_id = 0,
        .witness_id = 0,
        .subject_id = 0,
        .event_id = 0x500001,
        .observed_at = 1800,
        .evidence_count = 5,
        .evidence_losses = 1,
    });
    sim.elapsed_seconds = 3600;
    social.tick(&sim);
    const heard = social.knowledgeAbout(2, .livestock).?;
    try std.testing.expectEqual(Provenance.told, heard.provenance);
    try std.testing.expectEqual(@as(u8, 0), heard.witness_id);
    try std.testing.expectEqual(@as(u8, 0), heard.subject_id);
    try std.testing.expectEqual(@as(u16, 5), heard.evidence_count);
    try std.testing.expectEqual(@as(u16, 1), heard.evidence_losses);
    try std.testing.expectEqual(@as(u64, 1800), heard.observed_at);
    try std.testing.expect(heard.hop_count > 0);
    try social.validate(&sim);
}
