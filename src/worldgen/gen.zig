const std = @import("std");
const noize = @import("noize");
const glfw = @import("glfw");

const Chunk = @import("../world/chunk.zig").Chunk;

pub const Biome = enum(u8) {
    Forest,
    Desert,
    Mountains,

    fn max_height(self: Biome) f64 {
        return switch (self) {
            .Forest => 60.0, // at some point there will be a sea
            .Desert => 45.0,
            .Mountains => 85.0,
        };
    }

    pub fn height(self: Biome, percent: f64) f64 {
        return self.max_height() * percent;
    }
};

pub fn genChunk(chunk: *Chunk, gen: *noize.Worley, alloc: std.mem.Allocator) void {
    const world_x_offset = chunk.pos.x * 32;
    const world_y_offset = chunk.pos.y * 32;
    const world_z_offset = chunk.pos.z * 32;

    // Biomes
    //const chunk_blends = gen.noise(Biome, @floatFromInt(world_x_offset), @floatFromInt(world_z_offset), alloc) catch |err| {
    //    std.log.err("Failed to run OpenCl biome gen: {s}", .{@errorName(err)});
    //    return;
    //};
    //defer alloc.free(chunk_blends);

    // Blocks
    for (0..32) |x| {
        for (0..32) |z| {
            //const blends = chunk_blends[((z * 32 + x) * 9)..((z * 32 + x) * 9 + 9)];
            const blends = gen.noise(Biome, @floatFromInt(world_x_offset + @as(i32, @intCast(x))), @floatFromInt(world_z_offset + @as(i32, @intCast(z))), alloc) catch {
                std.log.err("Failed to beans", .{});
                return;
            };

            defer alloc.free(blends);

            var height: f64 = 0;

            for (blends) |blend| {
                const biome: Biome = blend.biome;

                height += biome.height(blend.percent);
            }

            if (height <= 1 or std.math.isNan(height)) height = 1;

            const int_height: i32 = @intFromFloat(height);

            for (0..32) |y| {
                const world_y: i32 = world_y_offset + @as(i32, @intCast(y));

                if (world_y < int_height) {
                    chunk.blocks[y + (32 * x) + (32 * 32 * z)] = .Dirt;
                } else if (world_y == int_height) {
                    chunk.blocks[y + (32 * x) + (32 * 32 * z)] = .Grass;
                }
            }
        }
    }
}
