const std = @import("std");
const scene = @import("scene.zig");
const terrain_mod = @import("terrain.zig");
const camera_mod = @import("camera.zig");

const Terrain = terrain_mod.Terrain;
const View = camera_mod.View;

const cols_f: f32 = @floatFromInt(scene.cols);
const rows_f: f32 = @floatFromInt(scene.rows);
const pi: f32 = std.math.pi;
const tau: f32 = 2.0 * pi;
const vertical_focal: f32 = rows_f * 0.82;
const horizontal_focal: f32 = vertical_focal;
const max_view_depth: f32 = 4000.0;
const tree_grid: f32 = 24.0;
const tree_view_depth: f32 = 1500.0;

const Material = enum { water, shore, grass, rock, snow };

const Sky = struct {
    horizon_y: f32,
    horizon_color: u32,
    zenith_color: u32,
    fog_color: u32,
    view_yaw: f32,
    view_pitch: f32,
    daylight: f32,
    sun_strength: f32,
    sunlight_warmth: f32,
    light_x: f32,
    light_y: f32,
    light_z: f32,
    sun_x: f32,
    sun_y: f32,
    sun_visible: bool,
    moon_x: f32,
    moon_y: f32,
    moon_visible: bool,
    night: bool,
};

/// Fill a deterministic glyph landscape. Animation is entirely explicit: the
/// same terrain, view, time, and animation values produce the same cells.
/// This is a compact heightfield renderer: terrain silhouettes are found by
/// front-to-back column marching, then real generated tree forms are projected
/// and depth-tested over the land.
pub fn fill(
    cells: []scene.Cell,
    terrain: *const Terrain,
    view: View,
    time_of_day: f32,
    animation_seconds: f32,
    show_hud: bool,
) void {
    std.debug.assert(cells.len == scene.cols * scene.rows);

    const time = if (std.math.isFinite(time_of_day)) @mod(time_of_day, 1.0) else 0.36;
    const animation = if (std.math.isFinite(animation_seconds)) animation_seconds else 0;
    const sky = makeSky(time, view);
    paintSky(cells, sky, animation);

    // One compact depth plane lets trees and the third-person avatar disappear
    // behind the same terrain that produced the base image.
    var depth_buffer: [scene.cols * scene.rows]f32 = undefined;
    @memset(&depth_buffer, std.math.inf(f32));
    paintTerrain(cells, &depth_buffer, terrain, view, sky, animation);
    paintTrees(cells, &depth_buffer, terrain, view, sky, animation);
    if (view.third_person) paintExplorer(cells, &depth_buffer, terrain, view, sky);
    if (show_hud) paintHud(cells, time);
}

fn makeSky(time: f32, view: View) Sky {
    const sun_wave = @sin((time - 0.25) * tau);
    const sun_strength = @max(0, sun_wave);
    const daylight = smooth(-0.10, 0.36, sun_wave);
    const warmth = 1.0 - smooth(0.12, 0.78, sun_strength);
    const horizon_y = rows_f * 0.50 + @tan(view.pitch) * vertical_focal;

    const night_zenith = scene.rgb(7, 16, 39);
    const day_zenith = scene.rgb(50, 111, 179);
    const night_horizon = scene.rgb(31, 45, 69);
    const day_horizon = mixColor(scene.rgb(255, 177, 131), scene.rgb(213, 190, 173), 1.0 - warmth);
    const zenith = mixColor(night_zenith, day_zenith, daylight);
    const horizon = mixColor(night_horizon, day_horizon, daylight);

    const sun_azimuth = (0.50 - time) * pi;
    const sun_elevation_sine = sun_wave * 0.50;
    const sun_elevation = std.math.asin(@max(-0.50, @min(0.50, sun_elevation_sine)));
    const sun_delta = wrapAngle(sun_azimuth - view.yaw);
    const half_fov = std.math.atan(cols_f * 0.5 / horizontal_focal);
    const sun_x = projectAzimuth(sun_azimuth, view.yaw);
    const sun_y = rows_f * 0.5 - @tan(sun_elevation - view.pitch) * vertical_focal;
    const sun_visible = @abs(sun_delta) <= half_fov + 0.20 and sun_elevation > -0.08;

    // The moon follows the opposing celestial arc. Its location and the
    // background star field are fixed in world-angle space as the camera turns.
    const moon_azimuth = wrapAngle(sun_azimuth + pi);
    const moon_elevation = -sun_elevation;
    const moon_delta = wrapAngle(moon_azimuth - view.yaw);
    const moon_x = projectAzimuth(moon_azimuth, view.yaw);
    const moon_y = rows_f * 0.5 - @tan(moon_elevation - view.pitch) * vertical_focal;
    const night = sun_wave < -0.12;
    const moon_visible = night and @abs(moon_delta) <= half_fov + 0.20 and moon_elevation > -0.08;

    const light_azimuth = if (night) moon_azimuth else sun_azimuth;
    const light_elevation = if (night) moon_elevation else sun_elevation;
    const light_horizontal = @cos(light_elevation);
    const azimuth_x = @sin(light_azimuth);
    const azimuth_z = @cos(light_azimuth);

    const twilight_zenith = mixColor(scene.rgb(40, 64, 105), scene.rgb(50, 111, 179), daylight);
    const fog_color = mixColor(horizon, twilight_zenith, 0.40);
    return .{
        .horizon_y = horizon_y,
        .horizon_color = horizon,
        .zenith_color = zenith,
        .fog_color = fog_color,
        .view_yaw = view.yaw,
        .view_pitch = view.pitch,
        .daylight = daylight,
        .sun_strength = sun_strength,
        .sunlight_warmth = warmth,
        .light_x = azimuth_x * light_horizontal,
        .light_y = @sin(light_elevation),
        .light_z = azimuth_z * light_horizontal,
        .sun_x = sun_x,
        .sun_y = sun_y,
        .sun_visible = sun_visible,
        .moon_x = moon_x,
        .moon_y = moon_y,
        .moon_visible = moon_visible,
        .night = night,
    };
}

fn paintSky(cells: []scene.Cell, sky: Sky, animation: f32) void {
    const horizon_span = @max(1.0, sky.horizon_y);
    const cloud_phase: i32 = @intFromFloat(@floor(animation * 0.018 * 36.0));
    var columns: [scene.cols]SkyColumn = undefined;
    for (0..scene.cols) |x| {
        const screen_offset = (@as(f32, @floatFromInt(x)) + 0.5 - cols_f * 0.5) / horizontal_focal;
        const azimuth = wrapAngle(sky.view_yaw + std.math.atan(screen_offset));
        const world_x = @sin(azimuth);
        const world_z = @cos(azimuth);
        columns[x] = .{
            .azimuth = azimuth,
            .hash_x = @intFromFloat(@floor(world_x * 180.0)),
            .hash_z = @intFromFloat(@floor(world_z * 180.0)),
        };
    }

    for (0..scene.rows) |y| {
        const screen_y: f32 = @floatFromInt(y);
        const world_altitude = sky.view_pitch + std.math.atan((rows_f * 0.5 - (screen_y + 0.5)) / vertical_focal);
        const altitude_key: i32 = @intFromFloat(@floor(world_altitude * 180.0));
        const height_ratio = smooth(0.0, horizon_span, sky.horizon_y - screen_y);
        const muting = if (screen_y > sky.horizon_y) 0.0 else height_ratio;
        const sky_color = mixColor(sky.horizon_color, sky.zenith_color, muting);
        const haze = mixColor(sky_color, sky.horizon_color, 0.16 * (1.0 - muting));

        for (0..scene.cols) |x| {
            const index = y * scene.cols + x;
            const direction = columns[x];
            const h = hash2(direction.hash_x, direction.hash_z + altitude_key * 421);
            var bg = haze;
            var fg = mixColor(bg, scene.rgb(214, 224, 226), 0.30);
            var glyph: u32 = ' ';

            if (sky.night and world_altitude > 0.02 and h % 197 == 0) {
                glyph = if (h % 3 == 0) '*' else '.';
                fg = scene.rgb(202, 221, 230);
            }

            if (!sky.night) {
                // Cloud bands and their texture are keyed by world azimuth and
                // elevation, so turning the camera reveals new sky instead of
                // carrying the clouds along with the screen.
                const cloud_azimuth = direction.azimuth - animation * 0.018;
                const cloud_x = @sin(cloud_azimuth);
                const cloud_z = @cos(cloud_azimuth);
                const line_a = 0.16 + @sin(cloud_azimuth * 2.6 + 0.4) * 0.042;
                const line_b = 0.31 + @sin(cloud_azimuth * 1.8 + 1.7) * 0.052;
                const band_a = cloudBand(@abs(world_altitude - line_a));
                const band_b = cloudBand(@abs(world_altitude - line_b));
                const cloud_strength = @max(band_a, band_b * 0.72);
                const cloud_key_x: i32 = @intFromFloat(@floor(cloud_x * 36.0));
                const cloud_key_z: i32 = @intFromFloat(@floor(cloud_z * 36.0));
                const cloud_alt_key: i32 = @intFromFloat(@floor(world_altitude * 36.0));
                const cloud_hash = hash2(cloud_key_x, cloud_key_z + cloud_alt_key * 83 + cloud_phase);
                const threshold: u32 = @intFromFloat(@min(225.0, cloud_strength * 212.0));
                if (cloud_hash % 256 < threshold) {
                    const cloud_tint = if (sky.sunlight_warmth > 0.25)
                        scene.rgb(244, 205, 179)
                    else
                        scene.rgb(199, 218, 230);
                    bg = mixColor(bg, cloud_tint, cloud_strength * 0.24);
                    if (cloud_strength > 0.36 and cloud_hash % 5 == 0) {
                        glyph = if (cloud_hash % 2 == 0) '_' else '~';
                        fg = mixColor(cloud_tint, scene.rgb(255, 237, 217), 0.27);
                    }
                }
            }

            if (sky.sun_visible) {
                const dx = @as(f32, @floatFromInt(x)) - sky.sun_x;
                const dy = screen_y - sky.sun_y;
                const radius_sq = dx * dx + dy * dy;
                const glow_radius: f32 = 15.5;
                if (radius_sq < glow_radius * glow_radius) {
                    const distance = @sqrt(radius_sq);
                    const glow = (1.0 - distance / glow_radius) * 0.25;
                    bg = mixColor(bg, scene.rgb(255, 194, 135), glow);
                    if (distance < 3.7) {
                        glyph = if (radius_sq < 5.0) 'O' else '*';
                        fg = scene.rgb(255, 240, 198);
                        bg = mixColor(bg, scene.rgb(255, 194, 128), 0.58);
                    }
                }
            }

            if (sky.moon_visible) {
                const dx = @as(f32, @floatFromInt(x)) - sky.moon_x;
                const dy = screen_y - sky.moon_y;
                if (dx * dx + dy * dy < 13.0) {
                    glyph = if (dx > 0.4) ')' else 'C';
                    fg = scene.rgb(218, 220, 193);
                    bg = mixColor(bg, scene.rgb(143, 168, 188), 0.28);
                }
            }

            cells[index] = .{ .glyph = glyph, .foreground = fg, .background = bg };
        }
    }
}

const SkyColumn = struct {
    azimuth: f32,
    hash_x: i32,
    hash_z: i32,
};

fn cloudBand(distance: f32) f32 {
    return @max(0, 1.0 - distance / 0.058);
}

fn paintTerrain(
    cells: []scene.Cell,
    depth_buffer: []f32,
    terrain: *const Terrain,
    view: View,
    sky: Sky,
    animation: f32,
) void {
    const sin_yaw = @sin(view.yaw);
    const cos_yaw = @cos(view.yaw);
    const right_x = cos_yaw;
    const right_z = -sin_yaw;
    const forward_x = sin_yaw;
    const forward_z = cos_yaw;
    const top_start = @as(i32, @intFromFloat(@floor(sky.horizon_y)));

    for (0..scene.cols) |column| {
        const screen_offset = (@as(f32, @floatFromInt(column)) + 0.5 - cols_f * 0.5) / horizontal_focal;
        const ray_x = forward_x + right_x * screen_offset;
        const ray_z = forward_z + right_z * screen_offset;
        var depth: f32 = 2.0;
        var top = @as(i32, @intCast(scene.rows)) - 1;

        while (depth <= max_view_depth and top >= 0) {
            const world_x = view.x + ray_x * depth;
            const world_z = view.z + ray_z * depth;
            const water = terrain.water(world_x, world_z);
            const raw_height = terrain.renderHeight(world_x, world_z, depth, water);
            const is_water = water.wet and raw_height < water.water_y;
            const surface_height = if (is_water) water.water_y else raw_height;
            const projected = sky.horizon_y - (surface_height - view.y) * vertical_focal / depth;
            const projected_row = @as(i32, @intFromFloat(@floor(projected)));

            if (projected_row < top) {
                const normal = if (is_water)
                    waterNormal(world_x, world_z, animation)
                else
                    terrain.renderNormal(world_x, world_z, depth);
                const surface = makeSurface(raw_height, normal, world_x, world_z, depth, view, sky, animation, water, terrain.geography(world_x, world_z, water));
                const first = @max(0, projected_row);
                const last = @min(@as(i32, @intCast(scene.rows)) - 1, top);
                if (first <= last) {
                    var row = first;
                    while (row <= last) : (row += 1) {
                        const y: usize = @intCast(row);
                        const index = y * scene.cols + column;
                        const detail = hash2(
                            @as(i32, @intFromFloat(@floor(world_x * 0.43))) + @as(i32, @intCast(y * 3)),
                            @as(i32, @intFromFloat(@floor(world_z * 0.43))) - @as(i32, @intCast(y * 5)),
                        );
                        const edge = row == projected_row;
                        const cell = surfaceCell(surface, detail, edge, column, y, depth, sky, animation);
                        cells[index] = cell;
                        depth_buffer[index] = depth;
                    }
                }
                top = projected_row - 1;
            }

            depth += @max(1.25, depth * 0.021);
        }

        // Preserve a single horizon edge mark for unusually level terrain.
        if (top_start >= 0 and top_start < @as(i32, @intCast(scene.rows))) {
            const index = @as(usize, @intCast(top_start)) * scene.cols + column;
            if (depth_buffer[index] == std.math.inf(f32)) {
                depth_buffer[index] = max_view_depth;
            }
        }
    }
}

const Surface = struct {
    color: u32,
    highlight: u32,
    material: Material,
    normal: [3]f32,
    water_shimmer: f32,
    flow_glyph: u32,
    steep: bool,
};

fn makeSurface(raw_height: f32, normal: [3]f32, x: f32, z: f32, depth: f32, view: View, sky: Sky, animation: f32, water: terrain_mod.Water, geo: terrain_mod.climate_mod.Sample) Surface {
    const sea = if (water.wet) water.water_y else terrain_mod.sea_level;
    const material: Material = if (water.wet and raw_height < sea)
        .water
    else if ((raw_height < terrain_mod.sea_level + 8) or (!water.wet and water.river_distance < water.river_width * 0.5 + 5))
        .shore
    else if (geo.biome == .snowfield)
        .snow
    else if (normal[1] < 0.77 or geo.biome == .alpine)
        .rock
    else
        .grass;

    const steep = normal[1] < 0.72;
    const region_hash = hash2(@intFromFloat(@floor(x / 560.0)), @intFromFloat(@floor(z / 560.0)));
    var base: u32 = undefined;
    var water_shimmer: f32 = 0;
    switch (material) {
        .water => {
            const depth_below = @max(0, sea - raw_height);
            const deep = smooth(3.0, 90.0, depth_below);
            base = mixColor(scene.rgb(75, 151, 157), scene.rgb(17, 57, 83), deep);

            // A small Fresnel-like sky reflection makes lakes inherit the
            // surrounding dawn, dusk, or night color without a reflection map.
            const view_elevation = std.math.atan(@max(0.0, view.y - sea) / @max(depth, 0.01));
            const reflected_sky = mixColor(sky.horizon_color, sky.zenith_color, smooth(0.015, 0.74, view_elevation));
            const grazing = 1.0 - @sin(@min(pi * 0.5, view_elevation));
            base = mixColor(base, reflected_sky, 0.15 + grazing * 0.43);

            // The glint falls along rays aimed toward the sun in world space;
            // two slow wave phases break it into restrained moving flecks.
            const ray_x = x - view.x;
            const ray_z = z - view.z;
            const ray_length = @sqrt(ray_x * ray_x + ray_z * ray_z);
            const light_length = @sqrt(sky.light_x * sky.light_x + sky.light_z * sky.light_z);
            if (!sky.night and ray_length > 0.01 and light_length > 0.01) {
                const alignment = (ray_x * sky.light_x + ray_z * sky.light_z) / (ray_length * light_length);
                const reflected_sun = smooth(0.965, 0.999, alignment);
                const wave_a = 0.5 + 0.5 * @sin(x * 0.041 + z * 0.013 + animation * 1.05);
                const wave_b = 0.5 + 0.5 * @cos(z * 0.029 - x * 0.011 - animation * 0.72);
                water_shimmer = reflected_sun * sky.daylight * sky.sun_strength * (0.035 + 0.19 * wave_a * wave_b);
            }
        },
        .shore => {
            const dry = @as(f32, @floatFromInt(region_hash % 41)) / 100.0;
            base = mixColor(scene.rgb(174, 155, 111), scene.rgb(92, 121, 79), smooth(sea + 1.0, sea + 17.0, raw_height) * (0.78 + dry));
        },
        .grass => {
            const altitude = smooth(sea + 28.0, sea + 245.0, raw_height);
            const palette = region_hash % 4;
            const low = switch (palette) {
                0 => scene.rgb(56, 105, 67),
                1 => scene.rgb(62, 111, 71),
                2 => scene.rgb(75, 105, 66),
                else => scene.rgb(54, 97, 74),
            };
            const high = switch (palette) {
                0 => scene.rgb(105, 132, 90),
                1 => scene.rgb(113, 136, 97),
                2 => scene.rgb(132, 132, 91),
                else => scene.rgb(94, 128, 102),
            };
            base = mixColor(mixColor(low, high, altitude), biomeColor(geo.biome), 0.68);
        },
        .rock => {
            const upland = smooth(sea + 170.0, sea + 420.0, raw_height);
            base = mixColor(scene.rgb(101, 99, 93), scene.rgb(133, 130, 123), upland);
        },
        .snow => {
            const altitude = smooth(sea + 470.0, sea + 700.0, raw_height);
            base = mixColor(scene.rgb(149, 166, 161), scene.rgb(218, 226, 215), altitude);
        },
    }

    const diffuse = @max(0, normal[0] * sky.light_x + normal[1] * sky.light_y + normal[2] * sky.light_z);
    const daylight = @max(0.0, sky.sun_strength);
    const illumination = if (sky.night)
        0.16 + diffuse * 0.075
    else
        0.30 + daylight * (0.16 + diffuse * 0.62);
    const warm = sky.sunlight_warmth * daylight;
    base = gainColor(base, illumination * (1.0 + warm * 0.14), illumination * (1.0 + warm * 0.01), illumination * (1.0 - warm * 0.20));

    // Distance strips away contrast toward the horizon and gives each landform
    // the cool or warm color of the surrounding air.
    const fog = smooth(360.0, max_view_depth, depth) * 0.84;
    const atmospheric = mixColor(sky.fog_color, scene.rgb(107, 145, 167), 0.25);
    base = mixColor(base, atmospheric, fog);
    const highlight = mixColor(base, scene.rgb(231, 219, 187), if (material == .snow) 0.28 else 0.22);
    const flow_side = water.flow_x * @cos(view.yaw) - water.flow_z * @sin(view.yaw);
    const flow_forward = water.flow_x * @sin(view.yaw) + water.flow_z * @cos(view.yaw);
    const flow_glyph: u32 = if (water.kind != .river) '~' else if (@abs(flow_side) > @abs(flow_forward) * 1.5) '-' else if (@abs(flow_forward) > @abs(flow_side) * 1.5) '|' else if (flow_side * flow_forward > 0) '/' else '\\';
    return .{ .color = base, .highlight = highlight, .material = material, .normal = normal, .water_shimmer = water_shimmer, .flow_glyph = flow_glyph, .steep = steep };
}

fn surfaceCell(surface: Surface, detail: u32, edge: bool, x: usize, y: usize, depth: f32, sky: Sky, animation: f32) scene.Cell {
    const detail_density = @max(0.10, 0.84 - depth / 3600.0);
    const threshold: u32 = @intFromFloat(detail_density * 78.0);
    const textured = detail % 100 < threshold;
    var glyph: u32 = ' ';
    var fg = surface.highlight;

    if (edge) {
        glyph = edgeGlyph(surface);
        fg = mixColor(surface.highlight, sky.horizon_color, smooth(600.0, max_view_depth, depth) * 0.22);
    } else switch (surface.material) {
        .water => {
            const phase: i32 = @intFromFloat(@floor(animation * 3.0));
            const shimmer_density: u32 = @intFromFloat(surface.water_shimmer * 100.0);
            if (surface.water_shimmer > 0.045 and detail % 100 < shimmer_density) {
                glyph = if (detail % 3 == 0) '=' else '~';
                fg = mixColor(surface.highlight, scene.rgb(255, 229, 177), surface.water_shimmer * 1.8);
            } else if (textured and (detail +% @as(u32, @intCast(x + y)) +% @as(u32, @bitCast(phase))) % 3 != 0) {
                glyph = if (detail % 5 == 0) '=' else surface.flow_glyph;
                fg = mixColor(surface.highlight, scene.rgb(170, 211, 205), 0.30);
            }
        },
        .shore => {
            if (textured and detail % 3 == 0) glyph = if (detail % 2 == 0) '.' else ',';
        },
        .grass => {
            if (textured) glyph = switch (detail % 7) {
                0, 1 => ',',
                2, 3 => '.',
                4 => '\'',
                5 => '`',
                else => ' ',
            };
            if (surface.normal[1] > 0.94 and detail % 71 == 0) glyph = '^';
        },
        .rock => {
            if (textured or surface.steep and detail % 3 == 0) glyph = edgeGlyph(surface);
            if (surface.steep and detail % 11 == 0) glyph = if (detail % 2 == 0) ':' else '.';
        },
        .snow => {
            if (textured) glyph = if (detail % 9 == 0) '*' else '.';
        },
    }

    return .{ .glyph = glyph, .foreground = fg, .background = surface.color };
}

fn edgeGlyph(surface: Surface) u32 {
    if (surface.material == .water) return '~';
    if (surface.normal[1] > 0.93) return if (surface.material == .snow) '^' else '.';
    const ax = @abs(surface.normal[0]);
    const az = @abs(surface.normal[2]);
    if (ax > az * 1.12) return if (surface.normal[0] > 0) '/' else '\\';
    if (surface.normal[2] > 0) return if (surface.material == .rock or surface.material == .snow) '^' else '_';
    return if (surface.material == .rock or surface.material == .snow) 'v' else '-';
}

fn waterNormal(x: f32, z: f32, animation: f32) [3]f32 {
    const slope_x = @cos(x * 0.035 + animation * 0.8) * 0.045;
    const slope_z = @sin(z * 0.027 - animation * 0.63) * 0.045;
    const magnitude = @sqrt(1.0 + slope_x * slope_x + slope_z * slope_z);
    return .{ -slope_x / magnitude, 1.0 / magnitude, -slope_z / magnitude };
}

fn paintTrees(cells: []scene.Cell, depth_buffer: []f32, terrain: *const Terrain, view: View, sky: Sky, animation: f32) void {
    const search_radius = tree_view_depth * 1.55;
    const min_x: i32 = @intFromFloat(@floor((view.x - search_radius) / tree_grid));
    const max_x: i32 = @intFromFloat(@ceil((view.x + search_radius) / tree_grid));
    const min_z: i32 = @intFromFloat(@floor((view.z - search_radius) / tree_grid));
    const max_z: i32 = @intFromFloat(@ceil((view.z + search_radius) / tree_grid));
    const sin_yaw = @sin(view.yaw);
    const cos_yaw = @cos(view.yaw);

    var gz = min_z;
    while (gz <= max_z) : (gz += 1) {
        var gx = min_x;
        while (gx <= max_x) : (gx += 1) {
            // Reject cells outside the visible forward cone before asking the
            // tree generator to do its terrain and forest-density checks.
            const center_x = (@as(f32, @floatFromInt(gx)) + 0.5) * tree_grid;
            const center_z = (@as(f32, @floatFromInt(gz)) + 0.5) * tree_grid;
            const rel_x = center_x - view.x;
            const rel_z = center_z - view.z;
            const forward = rel_x * sin_yaw + rel_z * cos_yaw;
            if (forward < -24.0 or forward > tree_view_depth + 24.0) continue;
            const lateral = rel_x * cos_yaw - rel_z * sin_yaw;
            if (@abs(lateral) > @max(0.0, forward) * 1.16 + 28.0) continue;
            if (terrain.tree(gx, gz)) |tree| {
                drawTree(cells, depth_buffer, view, sky, tree, animation);
            }
        }
    }
}

fn drawTree(cells: []scene.Cell, depth_buffer: []f32, view: View, sky: Sky, tree: terrain_mod.Tree, animation: f32) void {
    const rel_x = tree.x - view.x;
    const rel_z = tree.z - view.z;
    const sin_yaw = @sin(view.yaw);
    const cos_yaw = @cos(view.yaw);
    const forward = rel_x * sin_yaw + rel_z * cos_yaw;
    if (forward < 2.0 or forward > tree_view_depth) return;
    const lateral = rel_x * cos_yaw - rel_z * sin_yaw;
    if (@abs(lateral) > forward * 1.24 + tree.radius * 2.0) return;

    const center_x = cols_f * 0.5 + lateral * horizontal_focal / forward;
    const ground_y = tree.ground;
    const top_y = sky.horizon_y - (ground_y + tree.height - view.y) * vertical_focal / forward;
    const base_y = sky.horizon_y - (ground_y - view.y) * vertical_focal / forward;
    if (base_y < -2 or top_y > rows_f + 2 or top_y >= base_y) return;

    const top_row = @max(0, @as(i32, @intFromFloat(@floor(top_y))));
    const bottom_row = @min(@as(i32, @intCast(scene.rows)) - 1, @as(i32, @intFromFloat(@ceil(base_y))));
    const projected_radius = tree.radius * horizontal_focal / forward;
    const projected_height = tree.height * vertical_focal / forward;
    // A sub-cell crown on a sub-cell trunk reads as a detached speck. Let the
    // terrain's distant color and glyph texture represent those forests.
    if (projected_radius < 0.85 and projected_height < 2.4) return;
    const center_col = @as(i32, @intFromFloat(@floor(center_x)));
    const projected_span = @max(0.001, base_y - top_y);
    const canopy_end: f32 = if (tree.kind == 0) 0.80 else 0.74;
    const tree_tint = tree.tint & 0x00ff_ffff;
    const leaves = shadeTreeColor(mixColor(if (tree.kind == 0) scene.rgb(25, 59, 47) else scene.rgb(35, 75, 52), tree_tint, 0.37), sky, if (sky.night) 0.38 else 0.78);
    const leaf_light = shadeTreeColor(mixColor(leaves, if (tree.kind == 0) scene.rgb(133, 170, 113) else scene.rgb(153, 177, 112), 0.34), sky, if (sky.night) 0.54 else 0.98);
    const fog = smooth(420.0, max_view_depth, forward) * 0.85;
    const leaf_bg = mixColor(leaves, sky.fog_color, fog);
    const leaf_fg = mixColor(leaf_light, sky.horizon_color, fog * 0.50);
    const trunk_bg = mixColor(shadeTreeColor(scene.rgb(73, 55, 43), sky, if (sky.night) 0.38 else 0.74), sky.fog_color, fog);
    const trunk_fg = mixColor(shadeTreeColor(scene.rgb(143, 103, 68), sky, if (sky.night) 0.52 else 0.95), sky.horizon_color, fog * 0.45);
    const time_tick: i32 = @intFromFloat(@floor(animation * 2.0));

    var sy = top_row;
    while (sy <= bottom_row) : (sy += 1) {
        const vertical = (@as(f32, @floatFromInt(sy)) + 0.5 - top_y) / projected_span;
        if (vertical < 0 or vertical > 1) continue;
        const canopy = vertical < canopy_end;
        var half_width: f32 = 0;
        if (canopy) {
            if (tree.kind == 0) {
                half_width = projected_radius * (0.10 + 0.86 * vertical / canopy_end);
            } else {
                const distance_from_center = (vertical - 0.37) / 0.45;
                half_width = projected_radius * @sqrt(@max(0.0, 1.0 - distance_from_center * distance_from_center));
            }
        } else {
            half_width = @max(0.25, projected_radius * 0.15);
        }
        const row_radius: i32 = @intFromFloat(@min(cols_f, @ceil(half_width)));
        var sx = center_col - row_radius;
        while (sx <= center_col + row_radius) : (sx += 1) {
            if (sx < 0 or sx >= @as(i32, @intCast(scene.cols))) continue;
            const horizontal = @as(f32, @floatFromInt(sx - center_col));
            if (@abs(horizontal) > half_width + 0.18) continue;
            const index = @as(usize, @intCast(sy)) * scene.cols + @as(usize, @intCast(sx));
            if (forward > depth_buffer[index] + 0.8) continue;

            var glyph: u32 = ' ';
            var foreground = leaf_fg;
            var background = leaf_bg;
            if (canopy) {
                const detail = hash2(@intCast(sx), @intCast(sy)) +% @as(u32, @bitCast(time_tick));
                if (tree.kind == 0) {
                    glyph = if (detail % 5 == 0) '^' else if (detail % 3 == 0) '/' else '\\';
                } else {
                    glyph = switch (detail % 6) {
                        0, 1 => '*',
                        2 => 'o',
                        3 => '%',
                        4 => '.',
                        else => '&',
                    };
                }
                if (forward > 850 and detail % 2 == 0) glyph = if (tree.kind == 0) '^' else '*';
            } else {
                glyph = if (horizontal < 0) '/' else '\\';
                foreground = trunk_fg;
                background = trunk_bg;
            }
            cells[index] = .{ .glyph = glyph, .foreground = foreground, .background = background };
            depth_buffer[index] = forward;
        }
    }
}

fn paintExplorer(cells: []scene.Cell, depth_buffer: []f32, terrain: *const Terrain, view: View, sky: Sky) void {
    const rel_x = view.player_x - view.x;
    const rel_z = view.player_z - view.z;
    const sin_yaw = @sin(view.yaw);
    const cos_yaw = @cos(view.yaw);
    const forward = rel_x * sin_yaw + rel_z * cos_yaw;
    if (forward < 1.2) return;
    const lateral = rel_x * cos_yaw - rel_z * sin_yaw;
    if (@abs(lateral) > forward * 1.16) return;

    const ground = @max(view.player_y, terrain.standingHeight(view.player_x, view.player_z));
    const figure_height: f32 = 1.76;
    const center_x = cols_f * 0.5 + lateral * horizontal_focal / forward;
    const top_y = sky.horizon_y - (ground + figure_height - view.y) * vertical_focal / forward;
    const feet_y = sky.horizon_y - (ground - view.y) * vertical_focal / forward;
    if (feet_y < 0 or top_y > rows_f or top_y >= feet_y) return;

    const top = @max(0, @as(i32, @intFromFloat(@floor(top_y))));
    const bottom = @min(@as(i32, @intCast(scene.rows)) - 1, @as(i32, @intFromFloat(@ceil(feet_y))));
    const projected_span = @max(0.001, feet_y - top_y);
    const center_col = @as(i32, @intFromFloat(@floor(center_x)));
    const fog = smooth(200.0, max_view_depth, forward) * 0.65;
    const skin = mixColor(scene.rgb(215, 173, 137), sky.horizon_color, fog);
    const hair = mixColor(scene.rgb(43, 37, 43), sky.fog_color, fog);
    const cloak = mixColor(scene.rgb(59, 91, 80), sky.horizon_color, fog * 0.56);
    const leather = mixColor(scene.rgb(111, 76, 52), sky.horizon_color, fog * 0.50);
    const boots = mixColor(scene.rgb(49, 44, 42), sky.fog_color, fog);

    var sy = top;
    while (sy <= bottom) : (sy += 1) {
        const v = (@as(f32, @floatFromInt(sy)) + 0.5 - top_y) / projected_span;
        const half_width: i32 = if (v < 0.16) 1 else if (v < 0.69) 2 else 1;
        var sx = center_col - half_width;
        while (sx <= center_col + half_width) : (sx += 1) {
            if (sx < 0 or sx >= @as(i32, @intCast(scene.cols))) continue;
            const dx = sx - center_col;
            const index = @as(usize, @intCast(sy)) * scene.cols + @as(usize, @intCast(sx));
            if (forward > depth_buffer[index] + 0.9) continue;

            var glyph: u32 = ' ';
            var foreground = cloak;
            var background = scene.rgb(21, 34, 33);
            if (v < 0.16) {
                glyph = if (v < 0.06) '@' else 'O';
                foreground = if (v < 0.10) hair else skin;
                background = hair;
            } else if (v < 0.32) {
                if (@abs(dx) == 2) {
                    glyph = if (dx < 0) '/' else '\\';
                    foreground = leather;
                    background = leather;
                } else {
                    glyph = if (dx == 0 and v < 0.24) '|' else '#';
                    foreground = if (v < 0.24) leather else cloak;
                    background = if (v < 0.24) leather else cloak;
                }
            } else if (v < 0.67) {
                if (@abs(dx) == 2 and v < 0.50) {
                    glyph = if (dx < 0) '/' else '\\';
                    foreground = leather;
                    background = leather;
                } else {
                    glyph = if (dx == 0) '&' else '#';
                    foreground = if (v > 0.54) leather else cloak;
                    background = if (v > 0.54) leather else cloak;
                }
            } else {
                if (dx == 0 or v > 0.80) {
                    glyph = if (dx < 0) '/' else '\\';
                    foreground = boots;
                    background = boots;
                } else {
                    glyph = if (dx < 0) '/' else '\\';
                    foreground = leather;
                    background = leather;
                }
            }
            cells[index] = .{ .glyph = glyph, .foreground = foreground, .background = background };
            depth_buffer[index] = forward;
        }
    }
}

fn paintHud(cells: []scene.Cell, time: f32) void {
    const top_width: usize = @min(scene.cols - 4, 43);
    panel(cells, 2, 2, top_width, 5, scene.rgb(10, 21, 27), 0.78);
    scene.label(cells, 4, 3, "A LIFE", scene.rgb(244, 226, 190));
    scene.label(cells, 4, 5, "RIVERS AND RANGES / MILESTONE 02", scene.rgb(177, 202, 205));

    const bottom_y = scene.rows - 4;
    const bottom_height: usize = 3;
    panel(cells, 2, bottom_y, scene.cols - 4, bottom_height, scene.rgb(9, 18, 24), 0.82);
    scene.label(cells, 4, bottom_y, "WASD MOVE  ARROWS LOOK  C CAMERA  Q E HEIGHT  SHIFT FAST", scene.rgb(207, 222, 216));
    scene.label(cells, 4, bottom_y + 1, "SPACE TIME  F11 FULLSCREEN  ESC CLOSE", scene.rgb(155, 179, 181));

    const clock_x = scene.cols - 23;
    panel(cells, clock_x - 2, 2, 21, 3, scene.rgb(10, 21, 27), 0.78);
    const phase = if (@sin((time - 0.25) * tau) < -0.10) "NIGHT AIR" else if (time < 0.50) "MORNING" else "EVENING";
    scene.label(cells, clock_x, 3, phase, scene.rgb(231, 205, 166));
}

fn panel(cells: []scene.Cell, x: usize, y: usize, width: usize, height: usize, color: u32, opacity: f32) void {
    const y_end = @min(scene.rows, y + height);
    const x_end = @min(scene.cols, x + width);
    for (y..y_end) |row| for (x..x_end) |column| {
        const cell = &cells[row * scene.cols + column];
        cell.background = mixColor(cell.background, color, opacity);
        cell.glyph = ' ';
        cell.foreground = scene.rgb(222, 229, 218);
    };
}

fn hash2(x: i32, z: i32) u32 {
    var h = @as(u32, @bitCast(x)) *% 0x9e37_79b9 ^ @as(u32, @bitCast(z)) *% 0x85eb_ca6b ^ 0x51f1_5e;
    h = (h ^ (h >> 16)) *% 0x7feb_352d;
    h = (h ^ (h >> 15)) *% 0x846c_a68b;
    return h ^ (h >> 16);
}

fn wrapAngle(angle: f32) f32 {
    var wrapped = @rem(angle, tau);
    if (wrapped > pi) wrapped -= tau;
    if (wrapped < -pi) wrapped += tau;
    return wrapped;
}

fn projectAzimuth(world_azimuth: f32, view_yaw: f32) f32 {
    return cols_f * 0.5 + @tan(wrapAngle(world_azimuth - view_yaw)) * horizontal_focal;
}

fn smooth(edge0: f32, edge1: f32, value: f32) f32 {
    const t = @max(0.0, @min(1.0, (value - edge0) / @max(0.0001, edge1 - edge0)));
    return t * t * (3.0 - 2.0 * t);
}

fn mixColor(a: u32, b: u32, amount: f32) u32 {
    const t = @max(0.0, @min(1.0, amount));
    var result: u32 = 0;
    inline for (0..3) |channel| {
        const shift: u5 = @intCast(channel * 8);
        const av: f32 = @floatFromInt((a >> shift) & 255);
        const bv: f32 = @floatFromInt((b >> shift) & 255);
        const value: u32 = @intFromFloat(@max(0, @min(255, av + (bv - av) * t)) + 0.5);
        result |= value << shift;
    }
    return result;
}

fn gainColor(color: u32, red: f32, green: f32, blue: f32) u32 {
    const gains = .{ red, green, blue };
    var result: u32 = 0;
    inline for (gains, 0..) |gain, channel| {
        const shift: u5 = @intCast(channel * 8);
        const value: f32 = @floatFromInt((color >> shift) & 255);
        const component: u32 = @intFromFloat(@max(0, @min(255, value * gain)) + 0.5);
        result |= component << shift;
    }
    return result;
}

fn shadeTreeColor(color: u32, sky: Sky, amount: f32) u32 {
    if (sky.night) return gainColor(color, amount * 0.76, amount * 0.90, amount * 1.18);
    const warmth = sky.sunlight_warmth * sky.daylight * 0.13;
    return gainColor(color, amount * (1.0 + warmth), amount, amount * (1.0 - warmth * 0.58));
}

test "world-anchored sun shifts across the view with camera yaw" {
    const level_view = View{
        .x = 0,
        .y = terrain_mod.sea_level + 5.0,
        .z = 0,
        .yaw = 0,
        .pitch = 0,
        .player_x = 0,
        .player_y = terrain_mod.sea_level,
        .player_z = 0,
        .third_person = false,
    };
    const morning = makeSky(0.36, level_view);
    var turned_view = level_view;
    turned_view.yaw = 0.20;
    const turned = makeSky(0.36, turned_view);
    try std.testing.expect(morning.sun_x > turned.sun_x);
    try std.testing.expectApproxEqAbs(morning.light_x, turned.light_x, 0.0001);

    const sun_azimuth = (0.50 - 0.36) * pi;
    turned_view.yaw = sun_azimuth;
    const facing_sun = makeSky(0.36, turned_view);
    try std.testing.expectApproxEqAbs(cols_f * 0.5, facing_sun.sun_x, 0.001);
}

test "landscape fill is repeatable for an explicit view and animation time" {
    var terrain = try Terrain.init(std.testing.allocator, 0xa11fe);
    defer terrain.deinit();
    const camera = camera_mod.Camera.init(&terrain);
    const view = camera.view(&terrain);
    const first = try std.testing.allocator.alloc(scene.Cell, scene.cols * scene.rows);
    defer std.testing.allocator.free(first);
    const second = try std.testing.allocator.alloc(scene.Cell, scene.cols * scene.rows);
    defer std.testing.allocator.free(second);

    fill(first, &terrain, view, 0.36, 12.5, false);
    fill(second, &terrain, view, 0.36, 12.5, false);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(first), std.mem.sliceAsBytes(second));
    for (first) |cell| try std.testing.expect(cell.glyph < scene.glyph_bits.len);
}

fn biomeColor(biome: terrain_mod.climate_mod.Biome) u32 {
    return switch (biome) {
        .water => scene.rgb(49, 112, 146),
        .shore => scene.rgb(158, 146, 109),
        .woodland => scene.rgb(46, 108, 66),
        .grassland => scene.rgb(113, 144, 78),
        .scrub, .steppe => scene.rgb(137, 133, 82),
        .desert => scene.rgb(188, 153, 104),
        .savanna => scene.rgb(168, 153, 83),
        .alpine => scene.rgb(123, 134, 126),
        .tundra => scene.rgb(123, 141, 121),
        .snowfield => scene.rgb(215, 226, 226),
        .wetland => scene.rgb(56, 124, 101),
    };
}

/// Developer atlas exposes generated causes for QA; it is not the player's map
/// or journal, which will only reveal information learned during play.
pub fn fillAtlas(cells: []scene.Cell, terrain: *const Terrain, view: View) void {
    for (cells) |*cell| cell.* = .{ .glyph = ' ', .foreground = scene.rgb(170, 194, 178), .background = scene.rgb(12, 21, 28) };
    const map_side: usize = scene.rows - 10;
    const offset: usize = 4;
    for (0..map_side) |iz| for (0..map_side) |ix| {
        const x = -4096 + (@as(f32, @floatFromInt(ix)) + 0.5) * 8192 / @as(f32, @floatFromInt(map_side));
        const z = 4096 - (@as(f32, @floatFromInt(iz)) + 0.5) * 8192 / @as(f32, @floatFromInt(map_side));
        const water = terrain.water(x, z);
        const geo = terrain.geography(x, z, water);
        const elevation = terrain.macroHeight(x, z);
        const color = if (water.wet) scene.rgb(48, 126, 171) else biomeColor(geo.biome);
        var glyph: u32 = if (water.wet) '~' else if (geo.biome == .woodland) '^' else if (elevation > 500) '/' else '.';
        if (!water.wet and water.river_distance < 24) glyph = '~';
        cells[(iz + 6) * scene.cols + ix + offset] = .{ .glyph = glyph, .foreground = if (glyph == '~') scene.rgb(130, 207, 234) else gainColor(color, 1.35, 1.35, 1.35), .background = gainColor(color, 0.55 + elevation / 1800, 0.55 + elevation / 1800, 0.55 + elevation / 1800) };
    };
    const px: usize = @intFromFloat(std.math.clamp((view.player_x + 4096) / 8192 * @as(f32, @floatFromInt(map_side)), 0, @as(f32, @floatFromInt(map_side - 1))));
    const pz: usize = @intFromFloat(std.math.clamp((4096 - view.player_z) / 8192 * @as(f32, @floatFromInt(map_side)), 0, @as(f32, @floatFromInt(map_side - 1))));
    cells[(pz + 6) * scene.cols + px + offset] = .{ .glyph = '@', .foreground = scene.rgb(255, 236, 175), .background = scene.rgb(59, 42, 36) };
    scene.label(cells, 4, 2, "REGIONAL GEOGRAPHY / DEVELOPMENT ATLAS", scene.rgb(241, 225, 183));
    scene.label(cells, 4, 4, "NORTH UP / 8.192 KM SQUARE", scene.rgb(174, 198, 196));
    const lx = map_side + 10;
    scene.label(cells, lx, 10, "RAINFALL FEEDS DRAINAGE", scene.rgb(160, 202, 223));
    scene.label(cells, lx, 13, "~ RIVERS / LAKES / SEA", scene.rgb(130, 207, 234));
    scene.label(cells, lx, 16, "^ WOODLAND", biomeColor(.woodland));
    scene.label(cells, lx, 19, ". GRASSLAND / SCRUB", biomeColor(.grassland));
    scene.label(cells, lx, 22, "/ ALPINE / SNOW", biomeColor(.snowfield));
    scene.label(cells, lx, 25, "@ CURRENT VIEWPOINT", scene.rgb(255, 236, 175));
    scene.label(cells, lx, 31, "COAST + WIND + ALTITUDE", scene.rgb(211, 204, 178));
    scene.label(cells, lx, 34, "DETERMINE CLIMATE", scene.rgb(211, 204, 178));
    scene.label(cells, lx, 40, "UNTOUCHED DETAIL REBUILDS", scene.rgb(174, 198, 196));
    scene.label(cells, lx, 43, "AFTER TILE EVICTION", scene.rgb(174, 198, 196));
}
