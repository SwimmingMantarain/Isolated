const std = @import("std");
const Command = @import("./command.zig").Command;

const imgui = @cImport({
    @cInclude("dcimgui.h");
    @cInclude("backends/dcimgui_impl_glfw.h");
    @cInclude("backends/dcimgui_impl_opengl3.h");
});

pub const Loglevel = enum(u8) {
    Debug,
    Info,
    Warn,
    Err,
    Crit,

    pub fn color(self: Loglevel) imgui.ImVec4 {
        return switch (self) {
            .Info => imgui.ImVec4{ .x = 0.275, .y = 0.749, .z = 0.322, .w = 1.0 },
            .Debug => imgui.ImVec4{ .x = 0.275, .y = 0.749, .z = 0.322, .w = 1.0 },
            .Warn => imgui.ImVec4{ .x = 0.988, .y = 0.957, .z = 0.373, .w = 1.0 },
            .Err => imgui.ImVec4{ .x = 0.820, .y = 0.294, .z = 0.294, .w = 1.0 },
            .Crit => imgui.ImVec4{ .x = 0.957, .y = 0.0, .z = 0.0, .w = 1.0 },
        };
    }
};

pub const Mesg = struct {
    level: Loglevel,
    mesg: []const u8,
};

pub const Console = struct {
    alloc: std.mem.Allocator,
    messages: std.ArrayList(Mesg),
    max_messages: u32 = 128,
    auto_scroll: bool = true,
    visible: bool = false,
    was_visible: bool = false,

    pub fn init(alloc: std.mem.Allocator) !Console {
        return Console{
            .alloc = alloc,
            .messages = try .initCapacity(alloc, 128),
        };
    }

    pub fn deinit(self: *Console) void {
        for (self.messages.items) |mesg| {
            self.alloc.free(mesg.mesg);
        }

        self.messages.deinit(self.alloc);
    }

    pub fn log(self: *Console, comptime fmt: []const u8, args: anytype, level: Loglevel) void {
        const string = std.fmt.allocPrint(self.alloc, fmt, args) catch {
            std.log.err("Failed to allocate memory for message", .{});
            return;
        };

        const mesg = Mesg{ .level = level, .mesg = string };

        if (self.messages.items.len >= self.max_messages) {
            const old = self.messages.orderedRemove(0);
            self.alloc.free(old.mesg);
        }

        self.messages.append(self.alloc, mesg) catch {
            std.log.err("Failed to log message: {s}", .{string});
        };
    }

    pub fn command(self: *Console, command_str: []const u8) void {
        const com = Command.new(command_str, self.alloc) catch |err| {
            self.log("Failed to create command: {s}", .{@errorName(err)}, .Crit);
            return;
        };
        defer com.destroy(self.alloc);

        const args = com.args_str(self.alloc) catch |err| {
            self.log("Failed to parse command args: {s}", .{@errorName(err)}, .Crit);
            return;
        };
        defer self.alloc.free(args);

        self.log("Command: {s} Args: {s}", .{ com.command, args }, .Debug);
    }

    pub fn render(self: *Console) void {
        if (!self.visible) {
            self.was_visible = false;
            return;
        }

        const just_opened = !self.was_visible;
        self.was_visible = true;

        imgui.ImGui_SetNextWindowBgAlpha(0.3);
        imgui.ImGui_PushStyleVar(imgui.ImGuiStyleVar_WindowRounding, 0.0);
        imgui.ImGui_PushStyleVar(imgui.ImGuiStyleVar_WindowBorderSize, 0.0);
        imgui.ImGui_PushStyleVarImVec2(imgui.ImGuiStyleVar_ItemSpacing, imgui.ImVec2{ .x = 0.0, .y = 0.0 });
        imgui.ImGui_SetNextWindowFocus();

        if (imgui.ImGui_Begin("Dev Console", null, imgui.ImGuiWindowFlags_NoMove |
            imgui.ImGuiWindowFlags_NoResize |
            imgui.ImGuiWindowFlags_NoCollapse |
            imgui.ImGuiWindowFlags_NoTitleBar |
            imgui.ImGuiWindowFlags_NoScrollbar))
        {
            const imio = imgui.ImGui_GetIO();
            imgui.ImGui_SetWindowPos(imgui.ImVec2{ .x = 0, .y = imio.*.DisplaySize.y - imgui.ImGui_GetWindowHeight() }, 0);
            imgui.ImGui_SetWindowSize(imgui.ImVec2{ .x = 400, .y = 600 }, 0);

            const input_height = imgui.ImGui_GetFrameHeight() * 2;

            if (imgui.ImGui_BeginChild("Messages", imgui.ImVec2{ .x = 0, .y = -input_height }, 0, imgui.ImGuiWindowFlags_NoScrollbar)) {
                for (self.messages.items) |mesg| {
                    const color = mesg.level.color();
                    imgui.ImGui_PushStyleColorImVec4(imgui.ImGuiCol_Text, color);
                    imgui.ImGui_TextWrapped(mesg.mesg.ptr);
                    imgui.ImGui_PopStyleColor();
                }

                if (self.auto_scroll) {
                    imgui.ImGui_SetScrollHereY(1.0);
                    self.auto_scroll = false;
                }

                const scroll_y = imgui.ImGui_GetScrollY();
                const scroll_max_y = imgui.ImGui_GetScrollMaxY();
                if (scroll_max_y - scroll_y < 1.0) {
                    self.auto_scroll = true;
                }
            }
            imgui.ImGui_EndChild();

            if (imgui.ImGui_BeginChild("Input", imgui.ImVec2{ .x = 0, .y = input_height }, 0, imgui.ImGuiWindowFlags_NoScrollWithMouse)) {
                var input: [256]u8 = undefined;
                @memset(&input, 0);

                if (just_opened) {
                    imgui.ImGui_SetKeyboardFocusHere();
                }

                imgui.ImGui_PushStyleColorImVec4(imgui.ImGuiCol_FrameBg, imgui.ImVec4{ .x = 0, .y = 0, .z = 0, .w = 0 });
                if (imgui.ImGui_InputText(" ", &input, @sizeOf(u8) * 256, imgui.ImGuiInputTextFlags_EnterReturnsTrue)) {
                    imgui.ImGui_SetKeyboardFocusHereEx(-1);
                    self.command(&input);
                }
                imgui.ImGui_PopStyleColor();
            }
            imgui.ImGui_EndChild();
        }

        imgui.ImGui_PopStyleVar();
        imgui.ImGui_PopStyleVar();
        imgui.ImGui_PopStyleVar();
        imgui.ImGui_End();
    }
};
