const std = @import("std");

pub const Command = struct {
    command: []const u8,
    args: [][]const u8,

    pub fn new(command_str: []const u8, alloc: std.mem.Allocator) !*Command {
        const command_ptr = try alloc.create(Command);

        var iter = std.mem.splitAny(u8, command_str, " ");
        const command = (iter.next() orelse return error.ExpectedCommand);

        var args_list = try std.ArrayList([]const u8).initCapacity(alloc, 6);
        while (iter.next()) |arg| try args_list.append(alloc, arg);

        command_ptr.command = command;
        command_ptr.args = try args_list.toOwnedSlice(alloc);

        return command_ptr;
    }

    pub fn destroy(self: *Command, alloc: std.mem.Allocator) void {
        alloc.free(self.args);
        alloc.destroy(self);
    }

    pub fn args_str(self: *Command, alloc: std.mem.Allocator) ![]const u8 {
        return try std.mem.join(alloc, ", ", self.args);
    }
};
