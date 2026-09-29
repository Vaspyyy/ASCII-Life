const std = @import("std");
const scene = @import("scene.zig");
const camera_mod = @import("camera.zig");
const village_mod = @import("village.zig");
const sim_mod = @import("village_sim.zig");
const interaction = @import("interaction.zig");

const View = camera_mod.View;
const Village = village_mod.Village;
const Sim = sim_mod.Sim;

const near_plane: f32 = 0.8;
const village_draw_distance: f32 = 1450.0;
const rows_f: f32 = @floatFromInt(scene.rows);
const cols_f: f32 = @floatFromInt(scene.cols);
const focal: f32 = rows_f * 0.82;
const tau: f32 = 2.0 * std.math.pi;

const Vec3 = struct { x: f32, y: f32, z: f32 };
const CameraPoint = struct { side: f32, forward: f32, vertical: f32 };
const ScreenPoint = struct { x: f32, y: f32, forward: f32 };

const Face = enum { plaster, timber, roof, stone, door, window, dark, iron };
const FaceStyle = struct {
    face: Face,
    base: u32,
    accent: u32,
    seed: u64,
};

const Light = struct {
    daylight: f32,
    sun_strength: f32,
    warmth: f32,
    night: bool,
    x: f32,
    y: f32,
    z: f32,
    fog: u32,
};

const FacadeSide = enum { neg_z, pos_z, neg_x, pos_x };

/// Paint the generated settlement into the already-rendered terrain. The
/// depth plane is shared with terrain and trees, so nearby slopes and other
/// buildings correctly hide their far sides.
pub fn paint(
    cells: []scene.Cell,
    depth_buffer: []f32,
    village: *const Village,
    sim: *const Sim,
    view: View,
    time_of_day: f32,
) void {
    if (cells.len != scene.cols * scene.rows or depth_buffer.len != cells.len) return;
    const light = makeLight(time_of_day);

    for (village.buildingsSlice(), 0..) |building, building_index| {
        if (building.kind == .farm) continue;
        const rel_x = building.x - view.x;
        const rel_z = building.z - view.z;
        const sin_yaw = @sin(view.yaw);
        const cos_yaw = @cos(view.yaw);
        const forward = rel_x * sin_yaw + rel_z * cos_yaw;
        const lateral = rel_x * cos_yaw - rel_z * sin_yaw;
        const radius = @sqrt(building.width * building.width + building.depth * building.depth) * 0.5 + building.height;
        if (forward + radius < near_plane or forward - radius > village_draw_distance) continue;
        if (@abs(lateral) > @max(0.0, forward) * 1.45 + radius + 4.0) continue;
        if (building.width <= 0.2 or building.depth <= 0.2 or building.height <= 0.2) continue;

        switch (building.kind) {
            .home, .workshop, .granary => drawBuilding(cells, depth_buffer, village, view, light, building, building_index, time_of_day),
            .well => drawWell(cells, depth_buffer, view, light, building),
            .farm => unreachable,
        }
    }

    const count = @min(sim.resident_count, sim.residents.len);
    for (0..count) |index| {
        const resident = &sim.residents[index];
        if (!interaction.visible(resident, village)) continue;
        const position = sim.residentPosition(index) orelse resident.position;
        const ground = village.surfaceY(position.x, position.z);
        const motion_seconds: f32 = if (resident.activity == .walking) @as(f32, @floatFromInt(sim.elapsed_seconds % 60000)) / 60.0 else 0;
        drawResident(cells, depth_buffer, view, light, position.x, ground, position.z, resident.age_years, resident.appearance_seed, motion_seconds);
    }
}

fn drawBuilding(cells: []scene.Cell, depth_buffer: []f32, village: *const Village, view: View, light: Light, building: village_mod.Building, building_index: usize, time_of_day: f32) void {
    const x0 = building.x - building.width * 0.5;
    const x1 = building.x + building.width * 0.5;
    const z0 = building.z - building.depth * 0.5;
    const z1 = building.z + building.depth * 0.5;
    const base = building.y;
    const stilt = if (building.kind == .granary) @min(0.7, building.height * 0.16) else 0.0;
    const wall_base = base + stilt;
    const eaves = wall_base + building.height * 0.64;
    const ridge = wall_base + building.height;
    const wall = wallStyle(building.kind, building.seed);
    const trim = timberStyle(building.seed ^ 0x6172_6368_6974_7261);
    const roof = roofStyle(building.kind, building.seed ^ 0x726f_6f66_7469_6c65);

    if (stilt > 0.0) {
        const post_w = @min(0.24, @min(building.width, building.depth) * 0.07);
        for ([_]f32{ x0 + post_w, x1 - post_w }) |px| {
            for ([_]f32{ z0 + post_w, z1 - post_w }) |pz| {
                const ground = village.surfaceY(px, pz);
                const post_bottom = ground - 0.06;
                const post_height = wall_base - post_bottom;
                if (post_height > 0.12) drawPrism(cells, depth_buffer, view, light, .{ .x = px - post_w * 0.5, .y = post_bottom, .z = pz - post_w * 0.5 }, post_w, post_height, post_w, trim);
            }
        }
        drawQuad(cells, depth_buffer, view, light, .{
            .{ .x = x0, .y = wall_base, .z = z0 }, .{ .x = x1, .y = wall_base, .z = z0 },
            .{ .x = x1, .y = wall_base, .z = z1 }, .{ .x = x0, .y = wall_base, .z = z1 },
        }, .{ .x = 0, .y = 1, .z = 0 }, trim);
    } else {
        drawFoundationSkirt(cells, depth_buffer, village, view, light, building, x0, x1, z0, z1, base);
    }

    // Four load-bearing walls and the triangular gable ends form a real
    // projected structure rather than a camera-facing house symbol.
    drawQuad(cells, depth_buffer, view, light, .{
        .{ .x = x0, .y = wall_base, .z = z0 }, .{ .x = x1, .y = wall_base, .z = z0 },
        .{ .x = x1, .y = eaves, .z = z0 },     .{ .x = x0, .y = eaves, .z = z0 },
    }, .{ .x = 0, .y = 0, .z = -1 }, wall);
    drawQuad(cells, depth_buffer, view, light, .{
        .{ .x = x1, .y = wall_base, .z = z1 }, .{ .x = x0, .y = wall_base, .z = z1 },
        .{ .x = x0, .y = eaves, .z = z1 },     .{ .x = x1, .y = eaves, .z = z1 },
    }, .{ .x = 0, .y = 0, .z = 1 }, wall);
    drawQuad(cells, depth_buffer, view, light, .{
        .{ .x = x0, .y = wall_base, .z = z1 }, .{ .x = x0, .y = wall_base, .z = z0 },
        .{ .x = x0, .y = eaves, .z = z0 },     .{ .x = x0, .y = eaves, .z = z1 },
    }, .{ .x = -1, .y = 0, .z = 0 }, wall);
    drawQuad(cells, depth_buffer, view, light, .{
        .{ .x = x1, .y = wall_base, .z = z0 }, .{ .x = x1, .y = wall_base, .z = z1 },
        .{ .x = x1, .y = eaves, .z = z1 },     .{ .x = x1, .y = eaves, .z = z0 },
    }, .{ .x = 1, .y = 0, .z = 0 }, wall);

    for ([_]f32{ x0, x1 }) |gx| {
        drawTriangle(cells, depth_buffer, view, light, .{
            .{ .x = gx, .y = eaves, .z = z0 }, .{ .x = gx, .y = ridge, .z = building.z }, .{ .x = gx, .y = eaves, .z = z1 },
        }, .{ .x = if (gx == x0) -1 else 1, .y = 0, .z = 0 }, wall);
    }

    const roof_run = building.depth * 0.5;
    const roof_rise = ridge - eaves;
    const normal_length = @sqrt(roof_run * roof_run + roof_rise * roof_rise);
    const roof_front_normal: Vec3 = .{ .x = 0.0, .y = roof_run / normal_length, .z = -roof_rise / normal_length };
    const roof_back_normal: Vec3 = .{ .x = 0.0, .y = roof_run / normal_length, .z = roof_rise / normal_length };
    drawQuad(cells, depth_buffer, view, light, .{
        .{ .x = x0 - 0.15, .y = eaves, .z = z0 - 0.11 },  .{ .x = x1 + 0.15, .y = eaves, .z = z0 - 0.11 },
        .{ .x = x1 + 0.15, .y = ridge, .z = building.z }, .{ .x = x0 - 0.15, .y = ridge, .z = building.z },
    }, roof_front_normal, roof);
    drawQuad(cells, depth_buffer, view, light, .{
        .{ .x = x1 + 0.15, .y = eaves, .z = z1 + 0.11 },  .{ .x = x0 - 0.15, .y = eaves, .z = z1 + 0.11 },
        .{ .x = x0 - 0.15, .y = ridge, .z = building.z }, .{ .x = x1 + 0.15, .y = ridge, .z = building.z },
    }, roof_back_normal, roof);

    // Dark fascia beneath the roof edge sharpens the roof silhouette.
    drawQuad(cells, depth_buffer, view, light, .{
        .{ .x = x0 - 0.14, .y = eaves - 0.12, .z = z0 - 0.10 }, .{ .x = x1 + 0.14, .y = eaves - 0.12, .z = z0 - 0.10 },
        .{ .x = x1 + 0.14, .y = eaves, .z = z0 - 0.10 },        .{ .x = x0 - 0.14, .y = eaves, .z = z0 - 0.10 },
    }, .{ .x = 0, .y = 0, .z = -1 }, trim);

    drawBuildingOpenings(cells, depth_buffer, village, view, light, building, building_index, wall_base, eaves, x0, x1, z0, z1);

    if (building.kind == .workshop) {
        const chimney_w = @min(0.75, building.width * 0.16);
        const chimney_h = @max(1.0, building.height * 0.34);
        const chimney: Vec3 = .{ .x = building.x + building.width * 0.23 - chimney_w * 0.5, .y = eaves + roof_rise * 0.38, .z = z1 - building.depth * 0.19 };
        drawPrism(cells, depth_buffer, view, light, chimney, chimney_w, chimney_h, chimney_w, .{ .face = .stone, .base = color(107, 71, 59), .accent = color(174, 119, 83), .seed = building.seed ^ 0x6368_696d_6e65_7900 });
        drawSmoke(cells, depth_buffer, view, light, chimney, chimney_w, chimney_h, building.seed, building.x, building.z, time_of_day);
    }
}

fn drawFoundationSkirt(cells: []scene.Cell, depth_buffer: []f32, village: *const Village, view: View, light: Light, building: village_mod.Building, x0: f32, x1: f32, z0: f32, z1: f32, top: f32) void {
    const lower = 0.20;
    const y00 = @min(top - 0.035, village.surfaceY(x0, z0) - lower);
    const y10 = @min(top - 0.035, village.surfaceY(x1, z0) - lower);
    const y11 = @min(top - 0.035, village.surfaceY(x1, z1) - lower);
    const y01 = @min(top - 0.035, village.surfaceY(x0, z1) - lower);
    const stone = FaceStyle{ .face = .stone, .base = color(112, 105, 91), .accent = color(190, 173, 143), .seed = building.seed ^ 0x666f_756e_6461_746e };
    drawQuad(cells, depth_buffer, view, light, .{
        .{ .x = x0, .y = y00, .z = z0 }, .{ .x = x1, .y = y10, .z = z0 }, .{ .x = x1, .y = top, .z = z0 }, .{ .x = x0, .y = top, .z = z0 },
    }, .{ .x = 0, .y = 0, .z = -1 }, stone);
    drawQuad(cells, depth_buffer, view, light, .{
        .{ .x = x1, .y = y10, .z = z0 }, .{ .x = x1, .y = y11, .z = z1 }, .{ .x = x1, .y = top, .z = z1 }, .{ .x = x1, .y = top, .z = z0 },
    }, .{ .x = 1, .y = 0, .z = 0 }, stone);
    drawQuad(cells, depth_buffer, view, light, .{
        .{ .x = x1, .y = y11, .z = z1 }, .{ .x = x0, .y = y01, .z = z1 }, .{ .x = x0, .y = top, .z = z1 }, .{ .x = x1, .y = top, .z = z1 },
    }, .{ .x = 0, .y = 0, .z = 1 }, stone);
    drawQuad(cells, depth_buffer, view, light, .{
        .{ .x = x0, .y = y01, .z = z1 }, .{ .x = x0, .y = y00, .z = z0 }, .{ .x = x0, .y = top, .z = z0 }, .{ .x = x0, .y = top, .z = z1 },
    }, .{ .x = -1, .y = 0, .z = 0 }, stone);
}

fn drawBuildingOpenings(cells: []scene.Cell, depth_buffer: []f32, village: *const Village, view: View, light: Light, building: village_mod.Building, building_index: usize, wall_base: f32, eaves: f32, x0: f32, x1: f32, z0: f32, z1: f32) void {
    const front = villageFront(building, village.doorPoint(building_index));
    const wall_height = eaves - wall_base;
    const desired_door_width: f32 = if (building.kind == .workshop) 2.1 else 1.15;
    const desired_door_height: f32 = if (building.kind == .granary) 1.6 else 2.0;
    const door_width = @min(desired_door_width, building.width * 0.31);
    const door_height = @min(desired_door_height, wall_height * 0.88);
    const door_style = FaceStyle{ .face = .door, .base = color(78, 48, 34), .accent = color(151, 103, 63), .seed = building.seed ^ 0x646f_6f72_7061_6e65 };
    const pane = FaceStyle{ .face = .window, .base = color(45, 81, 102), .accent = color(218, 185, 126), .seed = building.seed ^ 0x7769_6e64_6f77_0001 };
    const frame = timberStyle(building.seed ^ 0x6672_616d_6500_0001);

    for ([_]FacadeSide{ .neg_z, .pos_z, .neg_x, .pos_x }) |side| {
        const front_side = side == front;
        const length = if (side == .neg_z or side == .pos_z) x1 - x0 else z1 - z0;
        const normal_offset: f32 = 0.04;
        const window_width = @min(0.92, length * 0.22);
        const window_height = @min(0.75, wall_height * 0.30);
        const window_y = wall_base + wall_height * 0.57;
        const side_windows = if (front_side) [_]f32{ -length * 0.29, length * 0.29 } else [_]f32{ -length * 0.26, length * 0.26 };
        for (side_windows) |offset| {
            if (length < 3.0 and @abs(offset) > 0.01) continue;
            drawFacadeRect(cells, depth_buffer, view, light, side, building.x, building.z, offset, window_width + 0.13, window_y - 0.07, window_height + 0.14, normal_offset, frame);
            drawFacadeRect(cells, depth_buffer, view, light, side, building.x, building.z, offset, window_width, window_y, window_height, normal_offset + 0.035, pane);
            const bar = FaceStyle{ .face = .timber, .base = color(117, 81, 51), .accent = color(189, 137, 85), .seed = building.seed ^ @as(u64, @intFromFloat(@abs(offset) * 1000.0)) };
            drawFacadeRect(cells, depth_buffer, view, light, side, building.x, building.z, offset, 0.075, window_y, window_height, normal_offset + 0.055, bar);
            drawFacadeRect(cells, depth_buffer, view, light, side, building.x, building.z, offset, window_width, window_y, 0.07, normal_offset + 0.06, bar);
        }

        if (front_side) {
            const door_y = wall_base + door_height * 0.5;
            drawFacadeRect(cells, depth_buffer, view, light, side, building.x, building.z, 0, door_width + 0.18, door_y - 0.03, door_height + 0.10, normal_offset + 0.01, frame);
            drawFacadeRect(cells, depth_buffer, view, light, side, building.x, building.z, 0, door_width, door_y, door_height, normal_offset + 0.06, door_style);
            const latch = FaceStyle{ .face = .iron, .base = color(176, 148, 91), .accent = color(231, 207, 148), .seed = building.seed ^ 0x6c61_7463_6800_0001 };
            drawFacadeRect(cells, depth_buffer, view, light, side, building.x, building.z, door_width * 0.28, 0.11, door_y, 0.13, normal_offset + 0.08, latch);
        }
    }
}

fn villageFront(building: village_mod.Building, door: village_mod.Point) FacadeSide {
    const toward_x = door.x - building.x;
    const toward_z = door.z - building.z;
    if (@abs(toward_z) >= @abs(toward_x)) return if (toward_z >= 0) .pos_z else .neg_z;
    return if (toward_x >= 0) .pos_x else .neg_x;
}

fn drawFacadeRect(cells: []scene.Cell, depth_buffer: []f32, view: View, light: Light, side: FacadeSide, center_x: f32, center_z: f32, along: f32, width: f32, center_y: f32, height: f32, offset: f32, style: FaceStyle) void {
    if (width <= 0 or height <= 0) return;
    const half = width * 0.5;
    var normal: Vec3 = undefined;
    var p: [4]Vec3 = undefined;
    switch (side) {
        .neg_z => {
            const plane = center_z - offset;
            normal = .{ .x = 0, .y = 0, .z = -1 };
            p = .{ .{ .x = center_x + along - half, .y = center_y - height * 0.5, .z = plane }, .{ .x = center_x + along + half, .y = center_y - height * 0.5, .z = plane }, .{ .x = center_x + along + half, .y = center_y + height * 0.5, .z = plane }, .{ .x = center_x + along - half, .y = center_y + height * 0.5, .z = plane } };
        },
        .pos_z => {
            const plane = center_z + offset;
            normal = .{ .x = 0, .y = 0, .z = 1 };
            p = .{ .{ .x = center_x + along + half, .y = center_y - height * 0.5, .z = plane }, .{ .x = center_x + along - half, .y = center_y - height * 0.5, .z = plane }, .{ .x = center_x + along - half, .y = center_y + height * 0.5, .z = plane }, .{ .x = center_x + along + half, .y = center_y + height * 0.5, .z = plane } };
        },
        .neg_x => {
            const plane = center_x - offset;
            normal = .{ .x = -1, .y = 0, .z = 0 };
            p = .{ .{ .x = plane, .y = center_y - height * 0.5, .z = center_z + along + half }, .{ .x = plane, .y = center_y - height * 0.5, .z = center_z + along - half }, .{ .x = plane, .y = center_y + height * 0.5, .z = center_z + along - half }, .{ .x = plane, .y = center_y + height * 0.5, .z = center_z + along + half } };
        },
        .pos_x => {
            const plane = center_x + offset;
            normal = .{ .x = 1, .y = 0, .z = 0 };
            p = .{ .{ .x = plane, .y = center_y - height * 0.5, .z = center_z + along - half }, .{ .x = plane, .y = center_y - height * 0.5, .z = center_z + along + half }, .{ .x = plane, .y = center_y + height * 0.5, .z = center_z + along + half }, .{ .x = plane, .y = center_y + height * 0.5, .z = center_z + along - half } };
        },
    }
    drawQuad(cells, depth_buffer, view, light, p, normal, style);
}

fn drawWell(cells: []scene.Cell, depth_buffer: []f32, view: View, light: Light, building: village_mod.Building) void {
    const radius = @max(0.5, @min(0.92, @min(building.width, building.depth) * 0.40));
    const rim = @max(0.78, building.height * 0.55);
    const base = building.y;
    const stone = FaceStyle{ .face = .stone, .base = color(104, 108, 102), .accent = color(184, 174, 145), .seed = building.seed ^ 0x7374_6f6e_6572_696d };
    const interior = FaceStyle{ .face = .dark, .base = color(21, 37, 43), .accent = color(72, 132, 142), .seed = building.seed ^ 0x7765_6c6c_7761_7465 };
    const count: usize = 8;
    for (0..count) |i| {
        const a0 = tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
        const a1 = tau * @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(count));
        const x0 = building.x + @cos(a0) * radius;
        const z0 = building.z + @sin(a0) * radius;
        const x1 = building.x + @cos(a1) * radius;
        const z1 = building.z + @sin(a1) * radius;
        const nx = @cos((a0 + a1) * 0.5);
        const nz = @sin((a0 + a1) * 0.5);
        drawQuad(cells, depth_buffer, view, light, .{
            .{ .x = x0, .y = base, .z = z0 },       .{ .x = x1, .y = base, .z = z1 },
            .{ .x = x1, .y = base + rim, .z = z1 }, .{ .x = x0, .y = base + rim, .z = z0 },
        }, .{ .x = nx, .y = 0, .z = nz }, stone);
    }
    // The dark aperture and a cool water glint distinguish a working well
    // from a stone stump when viewed from above.
    const mouth = radius * 0.60;
    drawQuad(cells, depth_buffer, view, light, .{
        .{ .x = building.x - mouth, .y = base + rim - 0.05, .z = building.z - mouth }, .{ .x = building.x + mouth, .y = base + rim - 0.05, .z = building.z - mouth },
        .{ .x = building.x + mouth, .y = base + rim - 0.05, .z = building.z + mouth }, .{ .x = building.x - mouth, .y = base + rim - 0.05, .z = building.z + mouth },
    }, .{ .x = 0, .y = 1, .z = 0 }, interior);
    drawGlyphAtWorld(cells, depth_buffer, view, light, building.x, base + rim - 0.27, building.z, '~', color(133, 200, 195), color(20, 46, 50), building.seed, 0.7);

    const post = FaceStyle{ .face = .timber, .base = color(86, 57, 37), .accent = color(176, 123, 69), .seed = building.seed ^ 0x7765_6c6c_706f_7374 };
    const post_w = 0.16;
    const roof_eave = base + rim + 0.72;
    const roof_top = base + rim + 1.48;
    for ([_]f32{ -radius * 0.88, radius * 0.88 }) |px| {
        for ([_]f32{ -radius * 0.88, radius * 0.88 }) |pz| {
            drawPrism(cells, depth_buffer, view, light, .{ .x = building.x + px - post_w * 0.5, .y = base + rim - 0.02, .z = building.z + pz - post_w * 0.5 }, post_w, roof_eave - (base + rim), post_w, post);
        }
    }
    drawPrism(cells, depth_buffer, view, light, .{ .x = building.x - radius * 0.98, .y = base + rim + 0.27, .z = building.z - 0.07 }, radius * 1.96, 0.16, 0.14, post);

    const roof_style = roofStyle(.well, building.seed ^ 0x7765_6c6c_726f_6f66);
    const half = radius * 1.28;
    const pitch_run = half;
    const pitch_rise = roof_top - roof_eave;
    const length = @sqrt(pitch_run * pitch_run + pitch_rise * pitch_rise);
    const front_n = Vec3{ .x = 0, .y = pitch_run / length, .z = -pitch_rise / length };
    const back_n = Vec3{ .x = 0, .y = pitch_run / length, .z = pitch_rise / length };
    drawQuad(cells, depth_buffer, view, light, .{
        .{ .x = building.x - half, .y = roof_eave, .z = building.z - half }, .{ .x = building.x + half, .y = roof_eave, .z = building.z - half },
        .{ .x = building.x + half, .y = roof_top, .z = building.z },         .{ .x = building.x - half, .y = roof_top, .z = building.z },
    }, front_n, roof_style);
    drawQuad(cells, depth_buffer, view, light, .{
        .{ .x = building.x + half, .y = roof_eave, .z = building.z + half }, .{ .x = building.x - half, .y = roof_eave, .z = building.z + half },
        .{ .x = building.x - half, .y = roof_top, .z = building.z },         .{ .x = building.x + half, .y = roof_top, .z = building.z },
    }, back_n, roof_style);
}

fn drawPrism(cells: []scene.Cell, depth_buffer: []f32, view: View, light: Light, origin: Vec3, width: f32, height: f32, depth: f32, style: FaceStyle) void {
    if (width <= 0 or height <= 0 or depth <= 0) return;
    const x0 = origin.x;
    const x1 = origin.x + width;
    const y0 = origin.y;
    const y1 = origin.y + height;
    const z0 = origin.z;
    const z1 = origin.z + depth;
    drawQuad(cells, depth_buffer, view, light, .{ .{ .x = x0, .y = y0, .z = z0 }, .{ .x = x1, .y = y0, .z = z0 }, .{ .x = x1, .y = y1, .z = z0 }, .{ .x = x0, .y = y1, .z = z0 } }, .{ .x = 0, .y = 0, .z = -1 }, style);
    drawQuad(cells, depth_buffer, view, light, .{ .{ .x = x1, .y = y0, .z = z1 }, .{ .x = x0, .y = y0, .z = z1 }, .{ .x = x0, .y = y1, .z = z1 }, .{ .x = x1, .y = y1, .z = z1 } }, .{ .x = 0, .y = 0, .z = 1 }, style);
    drawQuad(cells, depth_buffer, view, light, .{ .{ .x = x0, .y = y0, .z = z1 }, .{ .x = x0, .y = y0, .z = z0 }, .{ .x = x0, .y = y1, .z = z0 }, .{ .x = x0, .y = y1, .z = z1 } }, .{ .x = -1, .y = 0, .z = 0 }, style);
    drawQuad(cells, depth_buffer, view, light, .{ .{ .x = x1, .y = y0, .z = z0 }, .{ .x = x1, .y = y0, .z = z1 }, .{ .x = x1, .y = y1, .z = z1 }, .{ .x = x1, .y = y1, .z = z0 } }, .{ .x = 1, .y = 0, .z = 0 }, style);
    drawQuad(cells, depth_buffer, view, light, .{ .{ .x = x0, .y = y1, .z = z0 }, .{ .x = x1, .y = y1, .z = z0 }, .{ .x = x1, .y = y1, .z = z1 }, .{ .x = x0, .y = y1, .z = z1 } }, .{ .x = 0, .y = 1, .z = 0 }, style);
}

fn drawSmoke(cells: []scene.Cell, depth_buffer: []f32, view: View, light: Light, chimney: Vec3, width: f32, height: f32, seed: u64, world_x: f32, world_z: f32, phase: f32) void {
    const base_y = chimney.y + height;
    for (0..3) |i| {
        const step: f32 = @floatFromInt(i);
        const rise = @mod(phase + step * 0.37 + @as(f32, @floatFromInt(mix32(seed) % 100)) * 0.01, 1.0);
        const drift = (@sin((phase + step) * tau + @as(f32, @floatFromInt(mix32(seed ^ stepSeed(i)) % 100)) * 0.03)) * (0.10 + rise * 0.32);
        const glyph: u32 = if (i % 2 == 0) '~' else '\'';
        const tint = mixColor(color(154, 164, 160), light.fog, rise * 0.55);
        drawGlyphAtWorld(cells, depth_buffer, view, light, world_x + width * 0.2 + drift, base_y + rise * 1.15, world_z, glyph, tint, color(0, 0, 0), seed +% @as(u64, i), 0.7);
    }
}

fn drawGlyphAtWorld(cells: []scene.Cell, depth_buffer: []f32, view: View, light: Light, x: f32, y: f32, z: f32, glyph: u32, fg: u32, bg: u32, seed: u64, size_world: f32) void {
    const point = projectWorld(.{ .x = x, .y = y, .z = z }, view) orelse return;
    if (point.forward < near_plane or point.forward > village_draw_distance) return;
    const center_x = @floor(point.x);
    const center_y = @floor(point.y);
    if (center_x < 0 or center_x >= cols_f or center_y < 0 or center_y >= rows_f) return;
    const index = @as(usize, @intFromFloat(center_y)) * scene.cols + @as(usize, @intFromFloat(center_x));
    if (point.forward > depth_buffer[index] + 0.8) return;
    _ = seed;
    _ = size_world;
    cells[index] = .{ .glyph = glyph, .foreground = fg, .background = bg };
    depth_buffer[index] = point.forward;
    _ = light;
}

fn drawResident(cells: []scene.Cell, depth_buffer: []f32, view: View, light: Light, x: f32, ground: f32, z: f32, age: u8, seed: u64, time: f32) void {
    const rel_x = x - view.x;
    const rel_z = z - view.z;
    const sin_yaw = @sin(view.yaw);
    const cos_yaw = @cos(view.yaw);
    const forward = rel_x * sin_yaw + rel_z * cos_yaw;
    const lateral = rel_x * cos_yaw - rel_z * sin_yaw;
    if (forward < 1.0 or forward > village_draw_distance or @abs(lateral) > forward * 1.35 + 3.0) return;

    const height: f32 = if (age < 7) 1.08 else if (age < 13) 1.34 else 1.72;
    const feet = projectWorld(.{ .x = x, .y = ground, .z = z }, view) orelse return;
    const head = projectWorld(.{ .x = x, .y = ground + height, .z = z }, view) orelse return;
    if (feet.y < -2 or head.y > rows_f or head.y >= feet.y) return;

    const top = @max(0, @as(i32, @intFromFloat(@floor(head.y))));
    const bottom = @min(@as(i32, @intCast(scene.rows)) - 1, @as(i32, @intFromFloat(@ceil(feet.y))));
    const center_col = @as(i32, @intFromFloat(@floor(feet.x)));
    const span = @max(0.001, feet.y - head.y);
    const phase = time * tau * 1.8 + @as(f32, @floatFromInt(mix32(seed) % 1000)) * 0.006283;
    const step = @sin(phase);
    const outfit = residentColor(seed);
    const skin_base = color(218, 175, 139);
    const hair_base = color(50, 38, 39);
    const skin = shadeAndFog(skin_base, .{ .x = -sin_yaw, .y = 0.32, .z = -cos_yaw }, light, forward);
    const hair = shadeAndFog(hair_base, .{ .x = -sin_yaw, .y = 0.18, .z = -cos_yaw }, light, forward);
    const cloth = shadeAndFog(outfit, .{ .x = -sin_yaw, .y = 0.15, .z = -cos_yaw }, light, forward);
    const cloth_detail = shadeAndFog(mixColor(outfit, color(215, 206, 180), 0.18), .{ .x = -sin_yaw, .y = 0.15, .z = -cos_yaw }, light, forward);
    const leather = shadeAndFog(color(102, 68, 48), .{ .x = -sin_yaw, .y = 0.12, .z = -cos_yaw }, light, forward);
    const boot = shadeAndFog(color(50, 45, 42), .{ .x = 0, .y = 0.10, .z = 0 }, light, forward);
    const small = span < 7;

    // Keep anatomy proportional at conversation distance. A fixed two-cell
    // width was sufficient in the village overview, but stretched people into
    // thin columns when the player approached them.
    const half_width: i32 = if (small) 0 else @max(1, @as(i32, @intFromFloat(@ceil(span * 0.19))));
    var sy = top;
    while (sy <= bottom) : (sy += 1) {
        const v = (@as(f32, @floatFromInt(sy)) + 0.5 - head.y) / span;
        var sx = center_col - half_width;
        while (sx <= center_col + half_width) : (sx += 1) {
            if (sx < 0 or sx >= @as(i32, @intCast(scene.cols))) continue;
            const u = (@as(f32, @floatFromInt(sx)) + 0.5 - feet.x) / span;
            const across = @abs(u);
            const index = @as(usize, @intCast(sy)) * scene.cols + @as(usize, @intCast(sx));
            if (forward > depth_buffer[index] + 0.9) continue;

            var glyph: u32 = '#';
            var fg = cloth;
            var bg = cloth;
            if (small) {
                glyph = if (v < 0.30) 'o' else if (v < 0.70) '|' else '/';
                fg = if (v < 0.30) skin else leather;
                bg = cloth;
            } else if (v < 0.19) {
                const head_y = (v - 0.095) / 0.095;
                if (u * u / (0.067 * 0.067) + head_y * head_y > 1) continue;
                const is_hair = v < 0.045 or (across > 0.052 and v < 0.11);
                bg = if (is_hair) hair else skin;
                const eye = v > 0.08 and v < 0.11 and across > 0.025 and across < 0.052;
                fg = if (eye) hair else bg;
                glyph = if (eye) '.' else '#';
            } else if (v < 0.60) {
                const torso_width: f32 = if (v < 0.27) 0.12 else 0.095;
                if (across > torso_width) {
                    const arm_center = 0.145 + step * u * 0.1;
                    if (v < 0.25 or @abs(across - arm_center) > 0.027) continue;
                    bg = if (v > 0.52) skin else cloth;
                    fg = leather;
                    glyph = if (u < 0) '/' else '\\';
                } else {
                    fg = if (v > 0.55) leather else cloth_detail;
                    glyph = if (v > 0.55) '=' else if (across < 0.018) ':' else '#';
                }
            } else {
                const leg_center = 0.052 + step * (v - 0.60) * (if (u < 0) @as(f32, 0.05) else -0.05);
                const leg_width: f32 = if (v > 0.93) 0.049 else 0.034;
                if (v > 1 or @abs(across - leg_center) > leg_width) continue;
                bg = if (v > 0.93) boot else leather;
                fg = boot;
                glyph = if (v > 0.93) '_' else if (u < 0) '/' else '\\';
            }
            cells[index] = .{ .glyph = glyph, .foreground = fg, .background = bg };
            depth_buffer[index] = forward;
        }
    }
}

fn drawQuad(cells: []scene.Cell, depth_buffer: []f32, view: View, light: Light, points: [4]Vec3, normal: Vec3, style: FaceStyle) void {
    drawTriangle(cells, depth_buffer, view, light, .{ points[0], points[1], points[2] }, normal, style);
    drawTriangle(cells, depth_buffer, view, light, .{ points[0], points[2], points[3] }, normal, style);
}

fn drawTriangle(cells: []scene.Cell, depth_buffer: []f32, view: View, light: Light, points: [3]Vec3, normal: Vec3, style: FaceStyle) void {
    const camera_points = .{
        toCamera(points[0], view),
        toCamera(points[1], view),
        toCamera(points[2], view),
    };
    const clipped = clipTriangle(.{ camera_points[0], camera_points[1], camera_points[2] }, near_plane);
    if (clipped.count < 3) return;
    for (1..clipped.count - 1) |i| {
        const camera_triangle = .{ clipped.points[0], clipped.points[i], clipped.points[i + 1] };
        const screen_triangle: [3]ScreenPoint = .{
            projectCamera(camera_triangle[0], view) orelse continue,
            projectCamera(camera_triangle[1], view) orelse continue,
            projectCamera(camera_triangle[2], view) orelse continue,
        };
        rasterTriangle(cells, depth_buffer, screen_triangle, normal, style, light);
    }
}

const Clipped = struct { points: [4]CameraPoint, count: usize };

fn clipTriangle(points: [3]CameraPoint, min_forward: f32) Clipped {
    var out: Clipped = .{ .points = undefined, .count = 0 };
    var previous = points[2];
    var previous_inside = previous.forward >= min_forward;
    for (points) |current| {
        const current_inside = current.forward >= min_forward;
        if (current_inside != previous_inside) {
            const denominator = current.forward - previous.forward;
            if (@abs(denominator) > 0.000001 and out.count < out.points.len) {
                const t = std.math.clamp((min_forward - previous.forward) / denominator, 0.0, 1.0);
                out.points[out.count] = .{
                    .side = previous.side + (current.side - previous.side) * t,
                    .forward = min_forward,
                    .vertical = previous.vertical + (current.vertical - previous.vertical) * t,
                };
                out.count += 1;
            }
        }
        if (current_inside and out.count < out.points.len) {
            out.points[out.count] = current;
            out.count += 1;
        }
        previous = current;
        previous_inside = current_inside;
    }
    return out;
}

fn rasterTriangle(cells: []scene.Cell, depth_buffer: []f32, p: [3]ScreenPoint, normal: Vec3, style: FaceStyle, light: Light) void {
    const area = edge(p[0], p[1], .{ .x = p[2].x, .y = p[2].y });
    if (!std.math.isFinite(area) or @abs(area) < 0.0001) return;
    const min_xf = @min(p[0].x, @min(p[1].x, p[2].x));
    const max_xf = @max(p[0].x, @max(p[1].x, p[2].x));
    const min_yf = @min(p[0].y, @min(p[1].y, p[2].y));
    const max_yf = @max(p[0].y, @max(p[1].y, p[2].y));
    if (max_xf < 0 or max_yf < 0 or min_xf >= cols_f or min_yf >= rows_f) return;
    const min_x: i32 = @intFromFloat(@floor(std.math.clamp(min_xf, 0.0, cols_f - 1.0)));
    const max_x: i32 = @intFromFloat(@ceil(std.math.clamp(max_xf, 0.0, cols_f - 1.0)));
    const min_y: i32 = @intFromFloat(@floor(std.math.clamp(min_yf, 0.0, rows_f - 1.0)));
    const max_y: i32 = @intFromFloat(@ceil(std.math.clamp(max_yf, 0.0, rows_f - 1.0)));
    const lit_base = shade(style.base, normal, light);
    const lit_accent = shade(style.accent, normal, light);

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const sample = .{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 };
            const w0 = edge(p[1], p[2], sample) / area;
            const w1 = edge(p[2], p[0], sample) / area;
            const w2 = edge(p[0], p[1], sample) / area;
            if (w0 < -0.0001 or w1 < -0.0001 or w2 < -0.0001) continue;
            const inverse_depth = w0 / p[0].forward + w1 / p[1].forward + w2 / p[2].forward;
            if (!std.math.isFinite(inverse_depth) or inverse_depth <= 0) continue;
            const depth = 1.0 / inverse_depth;
            const index = @as(usize, @intCast(y)) * scene.cols + @as(usize, @intCast(x));
            if (depth > depth_buffer[index] + 0.15) continue;

            const fog = smooth(300.0, 1600.0, depth) * 0.76;
            const background = mixColor(lit_base, light.fog, fog);
            const foreground = mixColor(lit_accent, light.fog, fog * 0.68);
            const detail = cellHash(style.seed, x, y);
            const glyph = faceGlyph(style.face, detail, x, y, normal);
            cells[index] = .{ .glyph = glyph, .foreground = foreground, .background = background };
            depth_buffer[index] = depth;
        }
    }
}

fn edge(a: anytype, b: anytype, p: anytype) f32 {
    return (p.x - a.x) * (b.y - a.y) - (p.y - a.y) * (b.x - a.x);
}

fn projectWorld(point: Vec3, view: View) ?ScreenPoint {
    return projectCamera(toCamera(point, view), view);
}

fn toCamera(point: Vec3, view: View) CameraPoint {
    const dx = point.x - view.x;
    const dz = point.z - view.z;
    const sin_yaw = @sin(view.yaw);
    const cos_yaw = @cos(view.yaw);
    return .{
        .side = dx * cos_yaw - dz * sin_yaw,
        .forward = dx * sin_yaw + dz * cos_yaw,
        .vertical = point.y - view.y,
    };
}

fn projectCamera(point: CameraPoint, view: View) ?ScreenPoint {
    if (!finite(point.side) or !finite(point.forward) or !finite(point.vertical) or point.forward <= 0.0001 or !finite(view.pitch)) return null;
    const x = cols_f * 0.5 + point.side * focal / point.forward;
    // Match the landscape and tree projection: pitch shifts the horizon, then
    // world height changes the glyph row by focal * height / forward.
    const y = rows_f * 0.5 + @tan(view.pitch) * focal - point.vertical * focal / point.forward;
    if (!finite(x) or !finite(y)) return null;
    return .{ .x = x, .y = y, .forward = point.forward };
}

fn makeLight(time_value: f32) Light {
    const time = if (finite(time_value)) @mod(time_value, 1.0) else 0.36;
    const sun_wave = @sin((time - 0.25) * tau);
    const sun_strength = @max(0.0, sun_wave);
    const daylight = smooth(-0.10, 0.36, sun_wave);
    const warmth = 1.0 - smooth(0.12, 0.78, sun_strength);
    const night = sun_wave < -0.12;
    const sun_azimuth = (0.50 - time) * std.math.pi;
    const sun_elevation = std.math.asin(std.math.clamp(sun_wave * 0.50, -0.50, 0.50));
    const azimuth = if (night) sun_azimuth + std.math.pi else sun_azimuth;
    const elevation = if (night) -sun_elevation else sun_elevation;
    const horizontal = @cos(elevation);
    const night_fog = color(31, 45, 68);
    const morning_fog = color(255, 177, 132);
    const noon_fog = color(182, 207, 218);
    const warm_fog = mixColor(morning_fog, noon_fog, 1.0 - warmth);
    return .{
        .daylight = daylight,
        .sun_strength = sun_strength,
        .warmth = warmth,
        .night = night,
        .x = horizontal * @sin(azimuth),
        .y = @sin(elevation),
        .z = horizontal * @cos(azimuth),
        .fog = mixColor(night_fog, warm_fog, daylight),
    };
}

fn shade(base: u32, normal: Vec3, light: Light) u32 {
    const n = normalize(normal);
    const diffuse = @max(0.0, n.x * light.x + n.y * light.y + n.z * light.z);
    const illumination = if (light.night) 0.20 + diffuse * 0.11 else 0.32 + light.daylight * 0.24 + light.sun_strength * (0.08 + diffuse * 0.36);
    const warm = light.warmth * light.daylight;
    return gainColor(base, illumination * (1.0 + warm * 0.16), illumination * (1.0 + warm * 0.02), illumination * (1.0 - warm * 0.17));
}

fn shadeAndFog(base: u32, normal: Vec3, light: Light, depth: f32) u32 {
    const lit = shade(base, normal, light);
    return mixColor(lit, light.fog, smooth(220.0, 1350.0, depth) * 0.72);
}

fn faceGlyph(face: Face, detail: u32, x: i32, y: i32, normal: Vec3) u32 {
    const stripe = @as(u32, @bitCast(x)) +% @as(u32, @bitCast(y));
    return switch (face) {
        .plaster => if (detail % 11 == 0) ':' else if (stripe % 5 == 0) '|' else ' ',
        .timber => if (stripe % 3 == 0) '|' else if (detail % 5 == 0) '/' else ' ',
        .roof => if (normal.z < -0.18) (if (stripe % 3 == 0) '/' else if (detail % 3 == 0) '%' else '#') else if (normal.z > 0.18) (if (stripe % 3 == 0) '\\' else if (detail % 3 == 0) '%' else '#') else if (detail % 3 == 0) '^' else '#',
        .stone => if (detail % 4 == 0) ':' else if (stripe % 4 == 0) '#' else ' ',
        .door => if (stripe % 4 == 0) '|' else if (detail % 4 == 0) '-' else '#',
        .window => if (stripe % 4 == 0) '+' else if (detail % 7 == 0) '=' else ' ',
        .dark => if (detail % 4 == 0) '~' else ' ',
        .iron => if (detail % 3 == 0) '+' else '#',
    };
}

fn wallStyle(kind: village_mod.Kind, seed: u64) FaceStyle {
    return switch (kind) {
        .home => switch (mix32(seed) % 4) {
            0 => .{ .face = .plaster, .base = color(196, 168, 127), .accent = color(248, 218, 167), .seed = seed },
            1 => .{ .face = .plaster, .base = color(187, 189, 164), .accent = color(241, 229, 194), .seed = seed },
            2 => .{ .face = .timber, .base = color(128, 91, 62), .accent = color(205, 157, 103), .seed = seed },
            else => .{ .face = .plaster, .base = color(195, 148, 105), .accent = color(243, 205, 157), .seed = seed },
        },
        .workshop => .{ .face = .timber, .base = color(137, 91, 57), .accent = color(214, 159, 95), .seed = seed },
        .granary => .{ .face = .timber, .base = color(148, 109, 65), .accent = color(222, 174, 101), .seed = seed },
        .well, .farm => .{ .face = .stone, .base = color(115, 109, 94), .accent = color(200, 181, 142), .seed = seed },
    };
}

fn timberStyle(seed: u64) FaceStyle {
    return .{ .face = .timber, .base = color(91, 59, 39), .accent = color(183, 128, 75), .seed = seed };
}

fn roofStyle(kind: village_mod.Kind, seed: u64) FaceStyle {
    return switch (mix32(seed ^ @intFromEnum(kind)) % 4) {
        0 => .{ .face = .roof, .base = color(128, 60, 44), .accent = color(207, 121, 79), .seed = seed },
        1 => .{ .face = .roof, .base = color(106, 80, 65), .accent = color(191, 151, 119), .seed = seed },
        2 => .{ .face = .roof, .base = color(70, 87, 85), .accent = color(146, 171, 155), .seed = seed },
        else => .{ .face = .roof, .base = color(130, 92, 53), .accent = color(208, 154, 91), .seed = seed },
    };
}

fn residentColor(seed: u64) u32 {
    return switch (mix32(seed ^ 0x7265_7369_6465_6e74) % 6) {
        0 => color(58, 94, 87),
        1 => color(94, 64, 63),
        2 => color(67, 75, 113),
        3 => color(145, 103, 49),
        4 => color(83, 103, 55),
        else => color(112, 77, 49),
    };
}

fn color(r: u32, g: u32, b: u32) u32 {
    return scene.rgb(r, g, b);
}

fn gainColor(base: u32, red: f32, green: f32, blue: f32) u32 {
    var result: u32 = 0;
    inline for (.{ red, green, blue }, 0..) |gain, channel| {
        const shift: u5 = @intCast(channel * 8);
        const value: f32 = @floatFromInt((base >> shift) & 255);
        result |= @as(u32, @intFromFloat(std.math.clamp(value * gain + 0.5, 0.0, 255.0))) << shift;
    }
    return result;
}

fn mixColor(a: u32, b: u32, amount: f32) u32 {
    const t = std.math.clamp(amount, 0.0, 1.0);
    var result: u32 = 0;
    inline for (0..3) |channel| {
        const shift: u5 = @intCast(channel * 8);
        const av: f32 = @floatFromInt((a >> shift) & 255);
        const bv: f32 = @floatFromInt((b >> shift) & 255);
        const value: u32 = @intFromFloat(std.math.clamp(av + (bv - av) * t + 0.5, 0.0, 255.0));
        result |= value << shift;
    }
    return result;
}

fn smooth(edge0: f32, edge1: f32, value: f32) f32 {
    const t = std.math.clamp((value - edge0) / @max(0.0001, edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn normalize(v: Vec3) Vec3 {
    const length = @sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    if (length <= 0.0001 or !finite(length)) return .{ .x = 0, .y = 1, .z = 0 };
    return .{ .x = v.x / length, .y = v.y / length, .z = v.z / length };
}

fn finite(value: f32) bool {
    return std.math.isFinite(value);
}

fn cellHash(seed: u64, x: i32, y: i32) u32 {
    return mix32(seed ^ (@as(u64, @as(u32, @bitCast(x))) *% 0x9e37_79b9) ^ (@as(u64, @as(u32, @bitCast(y))) *% 0x85eb_ca6b));
}

fn mix32(value: u64) u32 {
    var h: u64 = value +% 0x9e37_79b9_7f4a_7c15;
    h = (h ^ (h >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    h = (h ^ (h >> 27)) *% 0x94d0_49bb_1331_11eb;
    h ^= h >> 31;
    return @truncate(h);
}

fn stepSeed(i: usize) u64 {
    return @as(u64, @intCast(i)) *% 0x9e37_79b9_7f4a_7c15;
}

fn timeOfDayPhase(light: Light) f32 {
    return light.daylight;
}

test "village projection uses the landscape glyph focal scale" {
    const view = View{ .x = 0, .y = 10, .z = 0, .yaw = 0, .pitch = 0, .player_x = 0, .player_y = 0, .player_z = 0, .third_person = false };
    const point = projectWorld(.{ .x = 1, .y = 10, .z = 10 }, view).?;
    try std.testing.expectApproxEqAbs(cols_f * 0.5 + focal * 0.1, point.x, 0.001);
    try std.testing.expectApproxEqAbs(rows_f * 0.5, point.y, 0.001);
    var pitched = view;
    pitched.pitch = 0.2;
    const pitched_point = projectWorld(.{ .x = 0, .y = 10, .z = 10 }, pitched).?;
    try std.testing.expectApproxEqAbs(rows_f * 0.5 + @tan(0.2) * focal, pitched_point.y, 0.001);
}

test "near plane clips crossing triangles into finite visible polygons" {
    const clipped = clipTriangle(.{
        .{ .side = -1, .forward = 0.1, .vertical = 0 },
        .{ .side = 1, .forward = 2, .vertical = 1 },
        .{ .side = 0, .forward = 3, .vertical = -1 },
    }, near_plane);
    try std.testing.expectEqual(@as(usize, 4), clipped.count);
    for (clipped.points[0..clipped.count]) |point| {
        try std.testing.expect(point.forward >= near_plane);
        try std.testing.expect(finite(point.side) and finite(point.vertical));
    }
    const all_behind = clipTriangle(.{
        .{ .side = 0, .forward = 0.1, .vertical = 0 }, .{ .side = 1, .forward = 0.2, .vertical = 1 }, .{ .side = 2, .forward = 0.3, .vertical = -1 },
    }, near_plane);
    try std.testing.expectEqual(@as(usize, 0), all_behind.count);
}

test "glyph-space triangle rasterization is deterministic and depth tested" {
    const allocator = std.testing.allocator;
    const n = scene.cols * scene.rows;
    const cells_a = try allocator.alloc(scene.Cell, n);
    defer allocator.free(cells_a);
    const cells_b = try allocator.alloc(scene.Cell, n);
    defer allocator.free(cells_b);
    const depth_a = try allocator.alloc(f32, n);
    defer allocator.free(depth_a);
    const depth_b = try allocator.alloc(f32, n);
    defer allocator.free(depth_b);
    @memset(cells_a, .{ .glyph = ' ', .foreground = 0, .background = 0 });
    @memset(cells_b, .{ .glyph = ' ', .foreground = 0, .background = 0 });
    @memset(depth_a, std.math.inf(f32));
    @memset(depth_b, std.math.inf(f32));

    const triangle: [3]ScreenPoint = .{ .{ .x = 90, .y = 40, .forward = 20 }, .{ .x = 150, .y = 45, .forward = 24 }, .{ .x = 118, .y = 91, .forward = 18 } };
    const style = FaceStyle{ .face = .roof, .base = color(110, 56, 41), .accent = color(195, 128, 87), .seed = 0xfeed_beef };
    const light = makeLight(0.36);
    rasterTriangle(cells_a, depth_a, triangle, .{ .x = 0, .y = 1, .z = -0.3 }, style, light);
    rasterTriangle(cells_b, depth_b, triangle, .{ .x = 0, .y = 1, .z = -0.3 }, style, light);
    try std.testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(cells_a), std.mem.sliceAsBytes(cells_b)));
    try std.testing.expect(std.mem.eql(f32, depth_a, depth_b));

    const before = cells_a[60 * scene.cols + 120];
    depth_a[60 * scene.cols + 120] = 1;
    rasterTriangle(cells_a, depth_a, triangle, .{ .x = 0, .y = 1, .z = -0.3 }, style, light);
    try std.testing.expectEqual(@as(u32, before.glyph), cells_a[60 * scene.cols + 120].glyph);
    try std.testing.expectEqual(@as(f32, 1), depth_a[60 * scene.cols + 120]);
}
