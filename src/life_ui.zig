const std = @import("std");
const scene = @import("scene.zig");
const life_mod = @import("life.zig");
const sim_mod = @import("village_sim.zig");
const village_mod = @import("village.zig");
const dialogue_mod = @import("dialogue.zig");

const background = scene.rgb(8, 12, 19);
const text_color = scene.rgb(221, 228, 231);
const heading_color = scene.rgb(244, 226, 190);
const hint_color = scene.rgb(149, 183, 187);
const warning_color = scene.rgb(255, 205, 147);

/// Player-owned state can be displayed without revealing NPC knowledge.
pub fn paintStatus(cells: []scene.Cell, life: *const life_mod.Life, sim: *const sim_mod.Sim) void {
    var buffer: [144]u8 = undefined;
    const day = sim.elapsed_seconds / sim_mod.seconds_per_day;
    const calendar = std.fmt.bufPrint(&buffer, "AGE {d} / YEAR {d} / {s} DAY {d}", .{ life.age_years, day / life_mod.days_per_year + 1, @tagName(life_mod.season(sim.elapsed_seconds)), day % life_mod.days_per_season + 1 }) catch return;
    line(cells, 4, 5, calendar, hint_color);
    const status = std.fmt.bufPrint(&buffer, "{d} COINS / FOOD {d}.{d} DAYS / HUNGER {d}% / FATIGUE {d}% / K LIFE", .{ life.coins, life.food_milli / 1000, life.food_milli % 1000 / 100, life.hunger / 10, life.fatigue / 10 }) catch return;
    line(cells, 4, 6, status, if (life.hunger >= 750 or life.fatigue >= 850) warning_color else text_color);
}

/// Reading pauses the shared clock in the caller. Employment and housing are
/// the player's arrangements; unrelated household names are never looked up.
pub fn paintHomePanel(cells: []scene.Cell, life: *const life_mod.Life, sim: *const sim_mod.Sim, village: *const village_mod.Village, dialogue: *const dialogue_mod.Dialogue, x: f32, z: f32) void {
    const width: usize = @min(100, scene.cols);
    const height: usize = @min(20, scene.rows);
    const left = (scene.cols - width) / 2;
    const top = (scene.rows - height) / 2;
    if (width < 8 or height < 8) return;
    for (top..top + height) |row| for (left..left + width) |col| put(cells, col, row, ' ', text_color);
    for (left..left + width) |col| {
        put(cells, col, top, '-', hint_color);
        put(cells, col, top + height - 1, '-', hint_color);
    }
    for (top..top + height) |row| {
        put(cells, left, row, '|', hint_color);
        put(cells, left + width - 1, row, '|', hint_color);
    }
    panelLine(cells, left, top, width, 0, "A LIFE / your days in the village", heading_color);
    var buffer: [144]u8 = undefined;
    const day = sim.elapsed_seconds / sim_mod.seconds_per_day;
    panelLine(cells, left, top, width, 2, std.fmt.bufPrint(&buffer, "Year {d}, {s} day {d} / physical age {d}", .{ day / life_mod.days_per_year + 1, @tagName(life_mod.season(sim.elapsed_seconds)), day % life_mod.days_per_season + 1, life.age_years }) catch "Calendar", text_color);
    panelLine(cells, left, top, width, 3, std.fmt.bufPrint(&buffer, "Coins {d} / food {d}.{d} daily rations / hunger {d}% / fatigue {d}%", .{ life.coins, life.food_milli / 1000, life.food_milli % 1000 / 100, life.hunger / 10, life.fatigue / 10 }) catch "Needs", text_color);

    if (life.employer_id) |id| {
        const name = dialogue.knownName(id) orelse "your farmer";
        panelLine(cells, left, top, width, 5, std.fmt.bufPrint(&buffer, "Work with {s} / paid hours {d} / field practice {d}", .{ name, life.paid_hours, life.skill }) catch "Field work", heading_color);
        if (id < sim.resident_count and sim.residents[id].workplace < village.building_count) {
            const field = village.buildings[sim.residents[id].workplace];
            panelLine(cells, left, top, width, 6, std.fmt.bufPrint(&buffer, "Your field lies {s} of the well. Hold G at its entrance during working hours.", .{direction(village, field.x, field.z)}) catch "Hold G at your field's entrance during working hours.", text_color);
        }
        panelLine(cells, left, top, width, 7, "Each paid hour: 2 coins + a quarter ration if stocked; at most six hours/day.", hint_color);
    } else {
        panelLine(cells, left, top, width, 5, "No paid work yet. Approach a farmer, press F, and say 'hire me'.", text_color);
        panelLine(cells, left, top, width, 6, "Work is physical: hold G at that farmer's field entrance during working hours.", hint_color);
    }
    panelLine(cells, left, top, width, 8, "Keeper of the village stores: 'buy food' buys two daily rations for 3 coins.", hint_color);

    if (life.home_household) |household| {
        if (household < sim.household_count) {
            const door = village.doorPoint(sim.households[household].home_building);
            panelLine(cells, left, top, width, 10, std.fmt.bufPrint(&buffer, "Your rented room is {s} of the well. Upkeep: 1 coin each day.", .{direction(village, door.x, door.z)}) catch "Your rented room costs 1 coin each day.", heading_color);
        }
        if (life.canSkip(sim, village, x, z)) {
            panelLine(cells, left, top, width, 12, "Near your door: B sleep 8 hours / V live 7 days / N live 90 days.", heading_color);
            panelLine(cells, left, top, width, 13, "Close this panel first. Longer stays follow your work and rest routine.", text_color);
        } else if (life.atHome(village, x, z)) {
            panelLine(cells, left, top, width, 12, "Eat and recover before spending longer periods in your village routine.", warning_color);
        } else {
            panelLine(cells, left, top, width, 12, "Return to your rented door to sleep or spend time in your village routine.", text_color);
        }
        panelLine(cells, left, top, width, 14, "Routine work earns wages, eats real provisions, pays upkeep, and ages everyone.", hint_color);
    } else {
        panelLine(cells, left, top, width, 10, "No stable home yet. Ask a working adult 'rent a room'.", text_color);
        panelLine(cells, left, top, width, 11, "A room costs 7 coins for the first week, then 1 coin a day.", hint_color);
        panelLine(cells, left, top, width, 12, "Work four paid hours for that household, or earn trust through real help.", hint_color);
    }
    panelLine(cells, left, top, width, 16, "Relationships change through useful shared work. Your journal keeps learned facts.", hint_color);
    panelLine(cells, left, top, width, height - 2, "K / Esc close / time paused", heading_color);
}

fn panelLine(cells: []scene.Cell, left: usize, top: usize, width: usize, row: usize, text: []const u8, color: u32) void {
    for (text[0..@min(text.len, width - 4)], 0..) |ch, i| put(cells, left + 2 + i, top + row, ch, color);
}

fn line(cells: []scene.Cell, x: usize, y: usize, text: []const u8, color: u32) void {
    for (text, 0..) |ch, i| put(cells, x + i, y, ch, color);
}

fn put(cells: []scene.Cell, x: usize, y: usize, ch: u8, color: u32) void {
    if (x >= scene.cols or y >= scene.rows) return;
    const index = y * scene.cols + x;
    if (index >= cells.len) return;
    cells[index].glyph = ch;
    cells[index].foreground = color;
    cells[index].background = background;
}

fn direction(village: *const village_mod.Village, x: f32, z: f32) []const u8 {
    var well = village.center;
    for (village.buildingsSlice()) |building| if (building.kind == .well) {
        well = .{ .x = building.x, .z = building.z };
        break;
    };
    const dx = x - well.x;
    const dz = z - well.z;
    if (@abs(dx) > @abs(dz) * 2) return if (dx >= 0) "east" else "west";
    if (@abs(dz) > @abs(dx) * 2) return if (dz >= 0) "south" else "north";
    if (dz >= 0) return if (dx >= 0) "southeast" else "southwest";
    return if (dx >= 0) "northeast" else "northwest";
}
