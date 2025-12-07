const std = @import("std");

const imgui = @cImport({
    @cInclude("dcimgui.h");
    @cInclude("backends/dcimgui_impl_glfw.h");
    @cInclude("backends/dcimgui_impl_opengl3.h");
});

pub const Loglevel = enum { Debug, Info, Warn, Err, Crit };

pub const Mesg = struct {
    level: Loglevel,
    mesg: []const u8,
};

pub const Console = struct {
    alloc: std.mem.Allocator,
    messages: std.ArrayList(Mesg),
    visible: bool,

    pub fn init(alloc: std.mem.Allocator) !Console {
        return Console{
            .alloc = alloc,
            .messages = try .initCapacity(alloc, 64),
            .visible = false,
        };
    }

    pub fn deinit(self: *Console) void {
        self.messages.deinit(self.alloc);
    }

    pub fn log(self: *Console, string: []const u8, level: Loglevel) void {
        const mesg = Mesg{ .level = level, .mesg = string };

        self.messages.append(self.alloc, mesg) catch {
            std.log.err("Failed to log message: {s}", .{string});
        };
    }

    pub fn render(self: *Console) void {
        if (!self.visible) return;
    }
};
