//! Version 1 persistent causes. Generated terrain, names, geometry, household
//! identities and route polylines are rebuilt, never copied into the save.
//! Integers and IEEE floats have explicit little-endian encodings; usize uses
//! u32 (0xffffffff is the missing-building sentinel), independent of the host.
//! Field lists below are the format contract. Changing them changes the schema
//! fingerprint and must accompany a format version/compatibility decision.
const std = @import("std");
const sim_mod = @import("village_sim.zig");
const people = @import("people.zig");
const eco_mod = @import("ecology.zig");
const life_mod = @import("life.zig");
const dialogue_mod = @import("dialogue.zig");
const Sim = sim_mod.Sim;
const Social = people.Social;
const Ecology = eco_mod.Ecology;
const Life = life_mod.Life;
const Dialogue = dialogue_mod.Dialogue;
const Camera = @import("camera.zig").Camera;
const Village = @import("village.zig").Village;

pub const version: u16 = 1;
pub const generator_version: u16 = 1;
pub const header_bytes: usize = 56;
pub const max_file_bytes: usize = 128 * 1024;
const magic = "ALIFESV1";
const max_time: u64 = 1000 * life_mod.days_per_year * sim_mod.seconds_per_day;
const schema_hash = schemaFingerprint();

comptime {
    if (@typeInfo(Life).@"struct".fields.len != life_fields.len) @compileError("Update Life save field contract explicitly");
    if (@typeInfo(sim_mod.Economy).@"struct".fields.len != economy_fields.len) @compileError("Update Economy save field contract explicitly");
}

const economy_fields = .{
    "food_stock_milli",           "goods_stock_milli",           "water_stock_milli",    "food_produced_milli",  "goods_produced_milli",  "water_produced_milli",
    "food_consumed_milli",        "goods_consumed_milli",        "water_consumed_milli", "food_demand_milli",    "goods_demand_milli",    "water_demand_milli",
    "food_shortage_milli",        "goods_shortage_milli",        "water_shortage_milli", "food_discarded_milli", "goods_discarded_milli", "water_discarded_milli",
    "work_seconds",               "farmer_work_seconds",         "craft_work_seconds",   "keeper_work_seconds",  "water_work_seconds",    "livestock_food_produced_milli",
    "livestock_food_lost_milli",  "repair_goods_consumed_milli", "initial_food_milli",   "initial_goods_milli",  "initial_water_milli",   "player_food_provisioned_milli",
    "player_food_produced_milli", "player_wages_paid",           "player_food_payments", "player_rent_payments",
};
const resident_fields = .{ "age_years", "workplace", "job", "position", "activity", "employed", "route_started", "route_arrives", "target_building", "target_activity", "at_target", "work_remainder" };
const social_fields = .{ "last_update_seconds", "last_food_produced_milli", "last_work_seconds", "last_harvest_day" };
const person_fields = .{ "age_years", "job", "activity", "goal", "player" };
const ecology_fields = .{
    "animals",              "losses",              "attacks",          "defenses",          "repaired",              "player_repaired", "notice",           "player_volunteered", "fence",            "predators",   "hunger",              "pressure",
    "last_tick_seconds",    "last_attack_seconds", "observed_attacks", "assessed_pressure", "event_serial",          "informed_mask",   "npc_work_seconds", "npc_responder_id",   "neighbor_repairs", "npc_assists", "player_work_seconds", "player_help_recorded",
    "guarded_from_seconds", "guard_until_seconds", "guard_defenses",   "guard_pending",     "player_repair_pending", "repair_pending",  "posted_knowledge",
};
const life_fields = .{ "coins", "food_milli", "hunger", "fatigue", "age_years", "employer_id", "home_household", "home_building", "work_seconds", "paid_hours", "skill", "routine", "arrived_at", "last_tick_seconds", "last_work_at", "work_day", "day_work_seconds", "work_remainder_seconds", "production_remainder", "need_remainder", "food_consumed_milli", "food_shortage_milli", "aged_years", "rent_paid_until_day", "rent_arrears_days" };
const camera_fields = .{ "player_x", "player_y", "player_z", "yaw", "pitch", "third_person" };

fn fields(comptime T: type) []const []const u8 {
    if (T == sim_mod.Position) return &.{ "x", "y", "z" };
    if (T == @import("village.zig").Point) return &.{ "x", "z" };
    if (T == people.Goal) return &.{ "kind", "progress_hours", "target_hours", "completed" };
    if (T == people.PlayerRelationship) return &.{ "met", "trust", "encounters", "meaningful_actions", "first_met_at", "last_met_at", "last_action_day" };
    if (T == people.NpcRelationship) return &.{ "affinity", "interactions", "last_event_id", "last_interaction_seconds" };
    if (T == people.FamilyLink) return &.{ "other_id", "kind" };
    if (T == people.Memory) return &.{ "kind", "subject_id", "source_id", "event_id", "at_seconds", "confidence", "salience", "valence" };
    if (T == people.Knowledge) return &.{ "topic", "belief", "provenance", "confidence", "source_id", "witness_id", "event_id", "observed_at", "evidence_days", "evidence_count", "evidence_losses", "subject_id", "hop_count", "privacy" };
    @compileError("No stable field contract for " ++ @typeName(T));
}

const Writer = struct {
    bytes: []u8,
    offset: usize = 0,

    fn raw(self: *Writer, bytes: []const u8) !void {
        if (bytes.len > self.bytes.len - self.offset) return error.SaveTooLarge;
        @memcpy(self.bytes[self.offset..][0..bytes.len], bytes);
        self.offset += bytes.len;
    }
    fn value(self: *Writer, v: anytype) anyerror!void {
        const T = @TypeOf(v);
        switch (@typeInfo(T)) {
            .int => |info| {
                if (T == usize) return self.value(if (v == std.math.maxInt(usize)) @as(u32, 0xffffffff) else std.math.cast(u32, v) orelse return error.InvalidState);
                const U = std.meta.Int(.unsigned, info.bits);
                var bytes: [@sizeOf(T)]u8 = undefined;
                std.mem.writeInt(U, &bytes, @bitCast(v), .little);
                try self.raw(&bytes);
            },
            .float => |info| {
                if (!std.math.isFinite(v)) return error.InvalidState;
                try self.value(@as(std.meta.Int(.unsigned, info.bits), @bitCast(v)));
            },
            .bool => try self.value(@as(u8, @intFromBool(v))),
            .@"enum" => try self.value(@intFromEnum(v)),
            .optional => {
                try self.value(v != null);
                if (v) |child| try self.value(child);
            },
            .@"struct" => try self.named(v, comptime fields(T)),
            else => @compileError("Unsupported save type " ++ @typeName(T)),
        }
    }
    fn named(self: *Writer, v: anytype, comptime names: anytype) !void {
        inline for (names) |name| try self.value(@field(v, name));
    }
    fn text(self: *Writer, bytes: []const u8) !void {
        try self.value(std.math.cast(u8, bytes.len) orelse return error.InvalidState);
        try self.raw(bytes);
    }
};
const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn raw(self: *Reader, len: usize) ![]const u8 {
        if (len > self.bytes.len - self.offset) return error.TruncatedSave;
        const result = self.bytes[self.offset..][0..len];
        self.offset += len;
        return result;
    }
    fn value(self: *Reader, comptime T: type) anyerror!T {
        switch (@typeInfo(T)) {
            .int => |info| {
                if (T == usize) {
                    const v = try self.value(u32);
                    return if (v == 0xffffffff) std.math.maxInt(usize) else v;
                }
                const bytes = try self.raw(@sizeOf(T));
                return @bitCast(std.mem.readInt(std.meta.Int(.unsigned, info.bits), bytes[0..@sizeOf(T)], .little));
            },
            .float => |info| {
                const result: T = @bitCast(try self.value(std.meta.Int(.unsigned, info.bits)));
                if (!std.math.isFinite(result)) return error.InvalidState;
                return result;
            },
            .bool => return switch (try self.value(u8)) {
                0 => false,
                1 => true,
                else => error.InvalidState,
            },
            .@"enum" => |info| {
                const tag = try self.value(info.tag_type);
                inline for (info.fields) |field| if (tag == field.value) return @enumFromInt(tag);
                return error.InvalidState;
            },
            .optional => |info| return if (try self.value(bool)) try self.value(info.child) else null,
            .@"struct" => {
                var result: T = undefined;
                try self.named(&result, comptime fields(T));
                return result;
            },
            else => @compileError("Unsupported load type " ++ @typeName(T)),
        }
    }
    fn named(self: *Reader, dest: anytype, comptime names: anytype) !void {
        inline for (names) |name| @field(dest, name) = try self.value(@TypeOf(@field(dest, name)));
    }
    fn count(self: *Reader, maximum: usize) !u8 {
        const result = try self.value(u8);
        if (result > maximum) return error.InvalidState;
        return result;
    }
    fn text(self: *Reader, destination: []u8) !u8 {
        const len = try self.count(destination.len);
        const bytes = try self.raw(len);
        for (bytes) |byte| if (byte < 32 or byte > 126) return error.InvalidState;
        @memset(destination, 0);
        @memcpy(destination[0..len], bytes);
        return len;
    }
};

const Header = struct { seed: u64, layout: u64, identity: u64 };
fn readHeader(data: []const u8) !Header {
    if (data.len < header_bytes) return error.TruncatedSave;
    if (data.len > max_file_bytes) return error.SaveTooLarge;
    var reader = Reader{ .bytes = data };
    if (!std.mem.eql(u8, try reader.raw(magic.len), magic)) return error.InvalidMagic;
    if (try reader.value(u16) != version or try reader.value(u16) != generator_version) return error.UnsupportedVersion;
    const seed = try reader.value(u64);
    const layout = try reader.value(u64);
    const identity = try reader.value(u64);
    if (try reader.value(u64) != schema_hash) return error.UnsupportedSchema;
    const len = try reader.value(u32);
    const checksum = try reader.value(u64);
    if (len != data.len - header_bytes) return error.InvalidLength;
    if (checksum != fileChecksum(data)) return error.BadChecksum;
    return .{ .seed = seed, .layout = layout, .identity = identity };
}

/// Validate the complete envelope before using its seed for regeneration.
pub fn savedSeed(data: []const u8) !u64 {
    return (try readHeader(data)).seed;
}
fn fileChecksum(data: []const u8) u64 {
    return std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, data[0 .. header_bytes - 8]), data[header_bytes..]);
}
fn identityFingerprint(sim: *const Sim) u64 {
    var h = std.hash.Wyhash.hash(sim.world_seed, "initial village identities v1");
    for (sim.residents[0..sim.resident_count]) |resident| {
        h = std.hash.Wyhash.hash(h, resident.nameSlice());
        var bytes: [24]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        writer.value(resident.id) catch unreachable;
        writer.value(resident.appearance_seed) catch unreachable;
        writer.value(resident.household) catch unreachable;
        writer.value(resident.home_building) catch unreachable;
        writer.value(resident.public_building) catch unreachable;
        h = std.hash.Wyhash.hash(h, bytes[0..writer.offset]);
    }
    return h;
}
fn schemaFingerprint() u64 {
    @setEvalBranchQuota(200_000);
    var h: u64 = 1;
    inline for (.{ .{ sim_mod.Economy, economy_fields }, .{ sim_mod.Resident, resident_fields }, .{ Social, social_fields }, .{ people.Person, person_fields }, .{ Ecology, ecology_fields }, .{ Life, life_fields }, .{ Camera, camera_fields } }) |contract| {
        inline for (contract[1]) |name| h = std.hash.Wyhash.hash(h, name ++ ":" ++ @typeName(@FieldType(contract[0], name)));
    }
    inline for (.{ sim_mod.Position, @import("village.zig").Point, people.Goal, people.PlayerRelationship, people.NpcRelationship, people.FamilyLink, people.Memory, people.Knowledge }) |T| {
        inline for (comptime fields(T)) |name| h = std.hash.Wyhash.hash(h, name ++ ":" ++ @typeName(@FieldType(T, name)));
    }
    return h;
}

pub fn encode(allocator: std.mem.Allocator, sim: *const Sim, social: *const Social, ecology: *const Ecology, life: *const Life, dialogue: *const Dialogue, camera: *const Camera) ![]u8 {
    if (sim.resident_count > sim_mod.max_residents or social.count != sim.resident_count or sim.elapsed_seconds > max_time) return error.InvalidState;
    const scratch = try allocator.alloc(u8, max_file_bytes);
    defer allocator.free(scratch);
    var writer = Writer{ .bytes = scratch, .offset = header_bytes };
    try writer.value(sim.elapsed_seconds);
    try writer.value(sim.seasonal_farming);
    try writer.named(sim.economy, economy_fields);
    try writer.value(@as(u8, @intCast(sim.resident_count)));
    for (sim.residents[0..sim.resident_count]) |resident| {
        try writer.named(resident, resident_fields);
        const has_route = resident.route_count >= 2;
        try writer.value(has_route);
        if (has_route) try writer.value(resident.route_points[0]);
    }
    try writer.named(social.*, social_fields);
    for (social.persons[0..social.count], 0..) |person, index| {
        try writer.named(person, person_fields);
        try writer.value(social.work_remainder_seconds[index]);
        try writer.value(social.last_activity[index]);
        if (person.family_count > people.max_family_links or person.memory_count > people.max_memories or person.knowledge_count > people.max_knowledge) return error.InvalidState;
        try writer.value(person.family_count);
        for (person.family[0..person.family_count]) |v| try writer.value(v);
        for (person.relationships[0..social.count]) |v| try writer.value(v);
        try writer.value(person.memory_count);
        for (person.memories[0..person.memory_count]) |v| try writer.value(v);
        try writer.value(person.knowledge_count);
        for (person.knowledge[0..person.knowledge_count]) |v| try writer.value(v);
    }
    try writer.named(ecology.*, ecology_fields);
    // Life is deliberately a fixed, scalar cause record. Its field manifest is
    // schema-checked above; no native layout, pointers or generated arrays leak.
    try writer.named(life.*, life_fields);
    try writeJournal(&writer, dialogue);
    try writer.named(camera.*, camera_fields);
    const total = writer.offset;
    writer.offset = 0;
    try writer.raw(magic);
    try writer.value(version);
    try writer.value(generator_version);
    try writer.value(sim.world_seed);
    try writer.value(sim.generation_layout);
    try writer.value(identityFingerprint(sim));
    try writer.value(schema_hash);
    try writer.value(@as(u32, @intCast(total - header_bytes)));
    try writer.value(fileChecksum(scratch[0..total]));
    return allocator.dupe(u8, scratch[0..total]);
}

fn writeJournal(writer: *Writer, dialogue: *const Dialogue) !void {
    if (dialogue.known_count > people.max_people or dialogue.journal_count > dialogue_mod.max_journal_entries or dialogue.journal_start >= dialogue_mod.max_journal_entries) return error.InvalidState;
    try writer.value(@as(u8, @intCast(dialogue.known_count)));
    for (0..dialogue.known_count) |i| {
        if (dialogue.known_name_lens[i] > dialogue_mod.name_capacity) return error.InvalidState;
        try writer.value(dialogue.known_ids[i]);
        try writer.text(dialogue.known_names[i][0..dialogue.known_name_lens[i]]);
    }
    try writer.value(@as(u8, @intCast(dialogue.journal_count)));
    // Store the learned journal's logical order, not its disposable ring slots.
    for (0..dialogue.journal_count) |i| {
        const entry = dialogue.journal[(dialogue.journal_start + i) % dialogue_mod.max_journal_entries];
        if (entry.text_len > dialogue_mod.journal_text_capacity or entry.source_name_len > dialogue_mod.name_capacity or entry.underlying_source_name_len > dialogue_mod.name_capacity) return error.InvalidState;
        try writer.text(entry.text[0..entry.text_len]);
        try writer.text(entry.source_name[0..entry.source_name_len]);
        try writer.text(entry.underlying_source_name[0..entry.underlying_source_name_len]);
        try writer.named(entry, .{ "source_id", "underlying_source_id", "provenance", "learned_day" });
    }
}

/// Decode into independent temporaries, regenerate disposable consequences and
/// validate every record before committing any of the six live state objects.
pub fn decode(data: []const u8, village: *const Village, sim: *Sim, social: *Social, ecology: *Ecology, life: *Life, dialogue: *Dialogue, camera: *Camera) !void {
    const header = try readHeader(data);
    if (village.terrain_ref.seed != header.seed) return error.WrongWorld;
    var next_sim = Sim.init(village, header.seed);
    if (next_sim.generation_layout != header.layout or identityFingerprint(&next_sim) != header.identity) return error.WrongWorld;
    var next_social = Social.init(&next_sim, header.seed);
    var next_ecology = Ecology.init(village, &next_sim, header.seed);
    var next_life: Life = undefined;
    var next_dialogue = Dialogue{};
    var next_camera: Camera = undefined;
    var reader = Reader{ .bytes = data, .offset = header_bytes };
    next_sim.elapsed_seconds = try reader.value(u64);
    if (next_sim.elapsed_seconds > max_time) return error.InvalidState;
    next_sim.seasonal_farming = try reader.value(bool);
    try reader.named(&next_sim.economy, economy_fields);
    if (try reader.value(u8) != next_sim.resident_count) return error.WrongWorld;
    var origins: [sim_mod.max_residents]?@import("village.zig").Point = undefined;
    for (next_sim.residents[0..next_sim.resident_count], 0..) |*resident, i| {
        try reader.named(resident, resident_fields);
        origins[i] = if (try reader.value(bool)) try reader.value(@import("village.zig").Point) else null;
    }
    try reader.named(&next_social, social_fields);
    for (next_social.persons[0..next_social.count], 0..) |*person, i| {
        try reader.named(person, person_fields);
        next_social.work_remainder_seconds[i] = try reader.value(u16);
        next_social.last_activity[i] = try reader.value(sim_mod.Activity);
        person.family_count = try reader.count(people.max_family_links);
        for (person.family[0..person.family_count]) |*v| v.* = try reader.value(people.FamilyLink);
        for (person.relationships[0..next_social.count]) |*v| v.* = try reader.value(people.NpcRelationship);
        person.memory_count = try reader.count(people.max_memories);
        for (person.memories[0..person.memory_count]) |*v| v.* = try reader.value(people.Memory);
        person.knowledge_count = try reader.count(people.max_knowledge);
        for (person.knowledge[0..person.knowledge_count]) |*v| v.* = try reader.value(people.Knowledge);
    }
    try reader.named(&next_ecology, ecology_fields);
    try reader.named(&next_life, life_fields);
    next_dialogue.known_count = try reader.count(people.max_people);
    for (0..next_dialogue.known_count) |i| {
        next_dialogue.known_ids[i] = try reader.value(usize);
        next_dialogue.known_name_lens[i] = try reader.text(&next_dialogue.known_names[i]);
    }
    next_dialogue.journal_count = try reader.count(dialogue_mod.max_journal_entries);
    for (next_dialogue.journal[0..next_dialogue.journal_count]) |*entry| {
        entry.text_len = try reader.text(&entry.text);
        entry.source_name_len = try reader.text(&entry.source_name);
        entry.underlying_source_name_len = try reader.text(&entry.underlying_source_name);
        try reader.named(entry, .{ "source_id", "underlying_source_id", "provenance", "learned_day" });
    }
    try reader.named(&next_camera, camera_fields);
    if (reader.offset != data.len) return error.TrailingData;
    try validateCauses(&next_sim, &next_social, &next_ecology, &next_life, &next_dialogue, &next_camera, village);
    for (next_sim.residents[0..next_sim.resident_count], 0..) |*resident, i| try next_sim.restoreMovement(village, resident, origins[i]);
    try next_sim.validate(village);
    try next_social.validate(&next_sim);
    try next_ecology.validate(&next_sim);
    sim.* = next_sim;
    social.* = next_social;
    ecology.* = next_ecology;
    life.* = next_life;
    dialogue.* = next_dialogue;
    camera.* = next_camera;
}

fn validPerson(id: usize, count: usize) bool {
    return id < count or id == people.player_id;
}
fn validateKnowledge(value: people.Knowledge, count: usize, now: u64) !void {
    if (value.source_id >= count or value.witness_id >= count or !validPerson(value.subject_id, count) or value.confidence > 100 or value.observed_at > now) return error.InvalidState;
}
fn validateCauses(sim: *const Sim, social: *const Social, ecology: *const Ecology, life: *const Life, dialogue: *const Dialogue, camera: *const Camera, village: *const Village) !void {
    // Conservative bounds prevent arithmetic traps in existing simulation
    // accounting checks, even for a forged file with a recomputed checksum.
    inline for (economy_fields) |name| if (@field(sim.economy, name) > std.math.maxInt(u64) / 64) return error.InvalidState;
    for (sim.residents[0..sim.resident_count]) |resident| {
        if (resident.target_building >= village.building_count or
            (resident.workplace != std.math.maxInt(usize) and resident.workplace >= village.building_count) or
            @abs(resident.position.x) > 4096 or @abs(resident.position.z) > 4096 or @abs(resident.position.y) > 8192 or
            resident.work_remainder >= sim_mod.seconds_per_day or resident.route_started > sim.elapsed_seconds or resident.route_arrives > max_time) return error.InvalidState;
    }
    if (social.last_food_produced_milli > sim.economy.food_produced_milli or social.last_work_seconds > sim.economy.work_seconds or
        social.last_update_seconds / 3600 != sim.elapsed_seconds / 3600 or ecology.last_tick_seconds / 3600 != sim.elapsed_seconds / 3600 or
        life.last_tick_seconds / 3600 != sim.elapsed_seconds / 3600 or
        (social.last_harvest_day != std.math.maxInt(u64) and social.last_harvest_day > sim.day())) return error.InvalidState;
    for (social.persons[0..social.count], 0..) |person, i| {
        if (person.age_years != sim.residents[i].age_years or person.job != sim.residents[i].job or person.player.trust < -100 or person.player.trust > 100 or
            person.player.first_met_at > sim.elapsed_seconds or person.player.last_met_at > sim.elapsed_seconds or social.work_remainder_seconds[i] >= 3600 or
            (person.player.last_action_day != std.math.maxInt(u64) and person.player.last_action_day > sim.day())) return error.InvalidState;
        for (person.memories[0..person.memory_count]) |memory| if (!validPerson(memory.subject_id, social.count) or !validPerson(memory.source_id, social.count) or memory.confidence > 100 or memory.at_seconds > sim.elapsed_seconds) return error.InvalidState;
        for (person.knowledge[0..person.knowledge_count]) |knowledge| try validateKnowledge(knowledge, social.count, sim.elapsed_seconds);
        for (person.relationships[0..social.count]) |relationship| if (relationship.last_interaction_seconds > sim.elapsed_seconds) return error.InvalidState;
    }
    inline for (ecology_fields) |name| {
        if (comptime @TypeOf(@field(ecology, name)) == u32) {
            if (@field(ecology, name) > std.math.maxInt(u32) / 4) return error.InvalidState;
        } else if (comptime @TypeOf(@field(ecology, name)) == u64) {
            if (@field(ecology, name) > std.math.maxInt(u64) / 64) return error.InvalidState;
        }
    }
    if (ecology.losses > 8 or ecology.defenses > std.math.maxInt(u32) / 2 or ecology.attacks > std.math.maxInt(u32) / 2 or ecology.last_attack_seconds > sim.elapsed_seconds or
        !validPerson(ecology.npc_responder_id, social.count) or ecology.informed_mask >> @as(u5, @intCast(social.count)) != 0) return error.InvalidState;
    if (ecology.posted_knowledge) |knowledge| try validateKnowledge(knowledge, social.count, sim.elapsed_seconds);
    for (0..dialogue.known_count) |i| {
        if (dialogue.known_ids[i] >= social.count or dialogue.known_name_lens[i] == 0 or !std.mem.eql(u8, dialogue.known_names[i][0..dialogue.known_name_lens[i]], sim.residents[dialogue.known_ids[i]].nameSlice())) return error.InvalidState;
        for (dialogue.known_ids[0..i]) |previous| if (previous == dialogue.known_ids[i]) return error.InvalidState;
    }
    for (dialogue.journal[0..dialogue.journal_count]) |entry| if (!validPerson(entry.source_id, social.count) or !validPerson(entry.underlying_source_id, social.count) or entry.learned_day > sim.day()) return error.InvalidState;
    if (@abs(camera.player_x) > 4096 or @abs(camera.player_z) > 4096 or camera.player_y < -8192 or camera.player_y > 16384 or @abs(camera.yaw) > std.math.pi or @abs(camera.pitch) > 0.8) return error.InvalidState;
    inline for (life_fields) |name| {
        if (comptime @TypeOf(@field(life, name)) == u64) {
            if (@field(life, name) > std.math.maxInt(u64) / 64) return error.InvalidState;
        }
    }
    try life.validate(sim);
    const generated = Sim.init(village, sim.world_seed);
    inline for (.{ "initial_food_milli", "initial_goods_milli", "initial_water_milli" }) |name| if (@field(sim.economy, name) != @field(generated.economy, name)) return error.InvalidState;
    for (sim.residents[0..sim.resident_count], 0..) |resident, i| {
        if (resident.age_years != @min(255, @as(u32, generated.residents[i].age_years) + life.aged_years)) return error.InvalidState;
    }
}

test "compact causes restore interrupted routes and continue identically" {
    const terrain_mod = @import("terrain.zig");
    const clock = @import("world_clock.zig");
    var terrain = try terrain_mod.Terrain.init(std.testing.allocator, terrain_mod.default_seed);
    defer terrain.deinit();
    const village = try Village.init(&terrain);
    var sim = Sim.init(&village, terrain.seed);
    var social = Social.init(&sim, terrain.seed);
    var ecology = Ecology.init(&village, &sim, terrain.seed);
    var life = Life.init(&sim);
    var dialogue = Dialogue{};
    var camera = Camera.init(&terrain);
    clock.advanceLife(&sim, &social, &village, &ecology, &life, .idle, 0, 0, 5 * 3600 + 41);
    try std.testing.expect(sim.residents[0].route_count >= 2);
    social.recordPlayerAction(0, .helpful_work, sim.elapsed_seconds);
    dialogue.open(0, &social, &sim);
    dialogue.input_len = 4;
    @memcpy(dialogue.input[0..4], "name");
    dialogue.submit(&social, &sim);
    dialogue.close();
    const bytes = try encode(std.testing.allocator, &sim, &social, &ecology, &life, &dialogue, &camera);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len < 24 * 1024);
    try std.testing.expectEqual(terrain.seed, try savedSeed(bytes));
    var restored_sim = Sim.init(&village, terrain.seed);
    var restored_social = Social.init(&restored_sim, terrain.seed);
    var restored_ecology = Ecology.init(&village, &restored_sim, terrain.seed);
    var restored_life = Life.init(&restored_sim);
    var restored_dialogue = Dialogue{};
    var restored_camera = camera;
    try decode(bytes, &village, &restored_sim, &restored_social, &restored_ecology, &restored_life, &restored_dialogue, &restored_camera);
    try std.testing.expectEqual(sim.fingerprint(), restored_sim.fingerprint());
    try std.testing.expectEqual(social.fingerprint(), restored_social.fingerprint());
    try std.testing.expectEqual(ecology.fingerprint(), restored_ecology.fingerprint());
    try std.testing.expectEqual(life.fingerprint(), restored_life.fingerprint());
    try std.testing.expectEqual(dialogue.known_count, restored_dialogue.known_count);
    try std.testing.expectEqual(dialogue.journal_count, restored_dialogue.journal_count);
    const roundtrip = try encode(std.testing.allocator, &restored_sim, &restored_social, &restored_ecology, &restored_life, &restored_dialogue, &restored_camera);
    defer std.testing.allocator.free(roundtrip);
    try std.testing.expectEqualSlices(u8, bytes, roundtrip);
    clock.advanceLife(&sim, &social, &village, &ecology, &life, .idle, 0, 0, 4 * 86400 + 317);
    clock.advanceLife(&restored_sim, &restored_social, &village, &restored_ecology, &restored_life, .idle, 0, 0, 4 * 86400 + 317);
    try std.testing.expectEqual(sim.fingerprint(), restored_sim.fingerprint());
    try std.testing.expectEqual(social.fingerprint(), restored_social.fingerprint());
    try std.testing.expectEqual(ecology.fingerprint(), restored_ecology.fingerprint());
    const before = restored_sim.fingerprint();
    const before_social = restored_social.fingerprint();
    var corrupt = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupt);
    corrupt[corrupt.len - 1] ^= 1;
    try std.testing.expectError(error.BadChecksum, decode(corrupt, &village, &restored_sim, &restored_social, &restored_ecology, &restored_life, &restored_dialogue, &restored_camera));
    try std.testing.expectEqual(before, restored_sim.fingerprint());
    try std.testing.expectEqual(before_social, restored_social.fingerprint());
    try std.testing.expectError(error.TruncatedSave, savedSeed(bytes[0..20]));
    corrupt[8] = 2;
    try std.testing.expectError(error.UnsupportedVersion, savedSeed(corrupt));
}

fn refreshTestChecksum(data: []u8) void {
    std.mem.writeInt(u64, data[header_bytes - 8 ..][0..8], fileChecksum(data), .little);
}

fn assertRejectedUnchanged(data: []const u8, expected: anyerror, village: *const Village, sim: *Sim, social: *Social, ecology: *Ecology, life: *Life, dialogue: *Dialogue, camera: *Camera) !void {
    const before = try encode(std.testing.allocator, sim, social, ecology, life, dialogue, camera);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(expected, decode(data, village, sim, social, ecology, life, dialogue, camera));
    const after = try encode(std.testing.allocator, sim, social, ecology, life, dialogue, camera);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

test "forged payloads reject indices floats truncation and excess without changing live causes" {
    const terrain_mod = @import("terrain.zig");
    var terrain = try terrain_mod.Terrain.init(std.testing.allocator, terrain_mod.default_seed);
    defer terrain.deinit();
    const village = try Village.init(&terrain);
    var sim = Sim.init(&village, terrain.seed);
    var social = Social.init(&sim, terrain.seed);
    var ecology = Ecology.init(&village, &sim, terrain.seed);
    var life = Life.init(&sim);
    var dialogue = Dialogue{};
    var camera = Camera.init(&terrain);
    const original = try encode(std.testing.allocator, &sim, &social, &ecology, &life, &dialogue, &camera);
    defer std.testing.allocator.free(original);
    const forged = try std.testing.allocator.dupe(u8, original);
    defer std.testing.allocator.free(forged);
    // IEEE quiet NaN in the player's X coordinate, with a valid checksum.
    std.mem.writeInt(u32, forged[forged.len - 21 ..][0..4], 0x7fc00000, .little);
    refreshTestChecksum(forged);
    try assertRejectedUnchanged(forged, error.InvalidState, &village, &sim, &social, &ecology, &life, &dialogue, &camera);
    @memcpy(forged, original);
    // First resident's workplace is outside the generated building set.
    const first_resident = header_bytes + 8 + 1 + 8 * economy_fields.len + 1;
    std.mem.writeInt(u32, forged[first_resident + 1 ..][0..4], 99, .little);
    refreshTestChecksum(forged);
    try assertRejectedUnchanged(forged, error.InvalidState, &village, &sim, &social, &ecology, &life, &dialogue, &camera);
    @memcpy(forged, original);
    forged[first_resident + 5] = 255; // Invalid Job tag.
    refreshTestChecksum(forged);
    try assertRejectedUnchanged(forged, error.InvalidState, &village, &sim, &social, &ecology, &life, &dialogue, &camera);
    @memcpy(forged, original);
    std.mem.writeInt(u64, forged[header_bytes + 9 ..][0..8], std.math.maxInt(u64), .little);
    refreshTestChecksum(forged);
    try assertRejectedUnchanged(forged, error.InvalidState, &village, &sim, &social, &ecology, &life, &dialogue, &camera);
    // A checksum-valid truncated payload must fail inside the reader.
    const short = forged[0 .. original.len - 1];
    @memcpy(short, original[0..short.len]);
    std.mem.writeInt(u32, short[44..48], @intCast(short.len - header_bytes), .little);
    refreshTestChecksum(short);
    try assertRejectedUnchanged(short, error.TruncatedSave, &village, &sim, &social, &ecology, &life, &dialogue, &camera);
    const excess = try std.testing.allocator.alloc(u8, original.len + 1);
    defer std.testing.allocator.free(excess);
    @memcpy(excess[0..original.len], original);
    excess[original.len] = 0;
    std.mem.writeInt(u32, excess[44..48], @intCast(excess.len - header_bytes), .little);
    refreshTestChecksum(excess);
    try assertRejectedUnchanged(excess, error.TrailingData, &village, &sim, &social, &ecology, &life, &dialogue, &camera);
    var changed_village = village;
    changed_village.paths[0].width += 0.5;
    try assertRejectedUnchanged(original, error.WrongWorld, &changed_village, &sim, &social, &ecology, &life, &dialogue, &camera);
    @memcpy(forged, original);
    forged[36] ^= 1; // Schema manifest differs, not a field-offset guess.
    refreshTestChecksum(forged);
    try std.testing.expectError(error.UnsupportedSchema, savedSeed(forged));
}

test "three year ordinary life saves matured jobs ownership and resumes household routine" {
    const terrain_mod = @import("terrain.zig");
    const clock = @import("world_clock.zig");
    var terrain = try terrain_mod.Terrain.init(std.testing.allocator, terrain_mod.default_seed);
    defer terrain.deinit();
    const village = try Village.init(&terrain);
    var sim = Sim.init(&village, terrain.seed);
    var social = Social.init(&sim, terrain.seed);
    var ecology = Ecology.init(&village, &sim, terrain.seed);
    var life = Life.init(&sim);
    var dialogue = Dialogue{};
    var camera = Camera.init(&terrain);
    try std.testing.expect(life.hire(ecology.owner_id, &sim, &social));
    clock.advanceLife(&sim, &social, &village, &ecology, &life, .idle, 0, 0, 8 * 3600);
    const field = life.fieldPoint(&sim, &village).?;
    clock.advanceLife(&sim, &social, &village, &ecology, &life, .field, field.x, field.z, 9 * 3600);
    try std.testing.expect(life.paid_hours >= 4);
    try std.testing.expect(life.rentHome(ecology.owner_id, &sim, &social));
    const home = village.doorPoint(life.home_building.?);
    camera.player_x = home.x;
    camera.player_y = village.surfaceY(home.x, home.z);
    camera.player_z = home.z;
    clock.advanceLife(&sim, &social, &village, &ecology, &life, .routine, home.x, home.z, 3 * life_mod.seconds_per_year + 41);
    try std.testing.expectEqual(@as(u16, 18), life.age_years);
    try std.testing.expect(life.home_household != null);
    const bytes = try encode(std.testing.allocator, &sim, &social, &ecology, &life, &dialogue, &camera);
    defer std.testing.allocator.free(bytes);
    var restored_sim = Sim.init(&village, terrain.seed);
    var restored_social = Social.init(&restored_sim, terrain.seed);
    var restored_ecology = Ecology.init(&village, &restored_sim, terrain.seed);
    var restored_life = Life.init(&restored_sim);
    var restored_dialogue = Dialogue{};
    var restored_camera = camera;
    try decode(bytes, &village, &restored_sim, &restored_social, &restored_ecology, &restored_life, &restored_dialogue, &restored_camera);
    try std.testing.expectEqual(sim.fingerprint(), restored_sim.fingerprint());
    try std.testing.expectEqual(social.fingerprint(), restored_social.fingerprint());
    try std.testing.expectEqual(ecology.fingerprint(), restored_ecology.fingerprint());
    try std.testing.expectEqual(life.fingerprint(), restored_life.fingerprint());
    clock.advanceLife(&sim, &social, &village, &ecology, &life, .routine, home.x, home.z, 90 * sim_mod.seconds_per_day + 739);
    clock.advanceLife(&restored_sim, &restored_social, &village, &restored_ecology, &restored_life, .routine, home.x, home.z, 90 * sim_mod.seconds_per_day + 739);
    const continued = try encode(std.testing.allocator, &sim, &social, &ecology, &life, &dialogue, &camera);
    defer std.testing.allocator.free(continued);
    const restored_continued = try encode(std.testing.allocator, &restored_sim, &restored_social, &restored_ecology, &restored_life, &restored_dialogue, &restored_camera);
    defer std.testing.allocator.free(restored_continued);
    try std.testing.expectEqualSlices(u8, continued, restored_continued);
}
