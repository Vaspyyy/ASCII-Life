#version 450

layout(set = 0, binding = 0, std430) readonly buffer CellBuffer {
    uvec4 cells[];
};

layout(set = 0, binding = 1, std430) readonly buffer GlyphBuffer {
    uvec2 glyphs[128];
};

layout(push_constant) uniform Grid {
    uint width;
    uint height;
    uint cols;
    uint rows;
    uint output_srgb;
} grid;

layout(location = 0) out vec4 out_color;

vec3 unpack_rgb(uint color) {
    return vec3(
        float(color & 255u),
        float((color >> 8u) & 255u),
        float((color >> 16u) & 255u)
    ) / 255.0;
}

vec3 srgb_to_linear(vec3 color) {
    bvec3 low = lessThanEqual(color, vec3(0.04045));
    vec3 linear_low = color / 12.92;
    vec3 linear_high = pow((color + 0.055) / 1.055, vec3(2.4));
    return mix(linear_high, linear_low, low);
}

void main() {
    uvec2 pixel = uvec2(gl_FragCoord.xy);
    uvec2 cell_pos = min(
        (pixel * uvec2(grid.cols, grid.rows)) / uvec2(grid.width, grid.height),
        uvec2(grid.cols - 1u, grid.rows - 1u)
    );
    uvec4 cell = cells[cell_pos.y * grid.cols + cell_pos.x];

    uvec2 in_cell = (pixel * uvec2(grid.cols, grid.rows)) % uvec2(grid.width, grid.height);
    uint glyph_x = (in_cell.x * 8u) / grid.width;
    uint glyph_y = (in_cell.y * 8u) / grid.height;
    uint bit_index = glyph_y * 8u + glyph_x;
    uvec2 bits = glyphs[min(cell.x, 127u)];
    uint word = bit_index < 32u ? bits.x : bits.y;
    bool ink = ((word >> (bit_index & 31u)) & 1u) != 0u;
    vec3 color = unpack_rgb(ink ? cell.y : cell.z);
    if (grid.output_srgb != 0u) color = srgb_to_linear(color);
    out_color = vec4(color, 1.0);
}
