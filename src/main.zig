const std = @import("std");
const math = @import("zlm").as(f32);
const glfw = @import("glfw");
const noize = @import("noize");

const Shader = @import("./renderer/shader.zig").Shader;
const World = @import("./world/world.zig").World;
const Console = @import("./ui/dev/console.zig").Console;
const OpenCLContext = @import("./opencl/opencl.zig").OpenCLContext;

const cglfw = @cImport({
    @cInclude("GLFW/glfw3.h");
});

const gl = @cImport({
    @cInclude("glad/glad.h");
});

const stbi = @cImport({
    @cInclude("stb/stb_image.h");
});

const cl = @import("cl").cl;

const imgui = @cImport({
    @cInclude("dcimgui.h");
    @cInclude("backends/dcimgui_impl_glfw.h");
    @cInclude("backends/dcimgui_impl_opengl3.h");
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // GLFW & OpenGL Init
    const cam = Camera{ .aspect_ratio = 800.0 / 600.0 };
    const console = try Console.init(alloc);
    var config = Config{ .cam = cam, .console = console };
    updateCamDir(&config.cam);

    glfw.init() catch {
        std.log.err("Failed to init GLFW!", .{});
        return;
    };
    glfw.windowHint(glfw.ContextVersionMajor, 3);
    glfw.windowHint(glfw.ContextVersionMinor, 3);
    glfw.windowHint(glfw.OpenGLProfile, glfw.OpenGLCoreProfile);
    // glfw.windowHint(glfw.OpenGLForwardCompat, glfw.GLTrue); for macos

    const w = glfw.createWindow(800, 600, "Isolated Game", null, null) catch {
        std.log.err("Failed to create GLFW window!", .{});
        glfw.terminate();
        return;
    };

    glfw.makeContextCurrent(w);

    const loader = @as(gl.GLADloadproc, @ptrCast(&cglfw.glfwGetProcAddress));
    if (gl.gladLoadGLLoader(loader) == 0) {
        std.log.err("Failed to init GLAD!", .{});
        glfw.destroyWindow(w);
        glfw.terminate();
        return;
    }

    _ = glfw.setWindowUserPointer(w, &config);
    _ = glfw.setFramebufferSizeCallback(w, fb_size_callback);
    _ = glfw.setCursorPosCallback(w, cursor_callback);

    // Imgui init
    _ = imgui.CIMGUI_CHECKVERSION();
    _ = imgui.ImGui_CreateContext(null);
    defer imgui.ImGui_DestroyContext(null);

    const imio = imgui.ImGui_GetIO();
    imio.*.ConfigFlags |= imgui.ImGuiConfigFlags_NavEnableKeyboard;
    imio.*.ConfigFlags |= imgui.ImGuiConfigFlags_DockingEnable;

    imgui.ImGui_StyleColorsDark(null);

    _ = imgui.cImGui_ImplGlfw_InitForOpenGL(@ptrCast(w), true);
    defer imgui.cImGui_ImplGlfw_Shutdown();

    _ = imgui.cImGui_ImplOpenGL3_InitEx("#version 330");
    defer imgui.cImGui_ImplOpenGL3_Shutdown();

    const style = imgui.ImGui_GetStyle();
    style.*.WindowRounding = 6.0;

    // Opengl Shaders
    var shader = Shader.new();

    if (shader == null) {
        std.log.err("Failed to create shader!", .{});
        return;
    }

    shader.?.use();

    gl.glEnable(gl.GL_DEPTH_TEST);

    // Init OpenCL
    var platform: cl.cl_platform_id = undefined;
    _ = cl.clGetPlatformIDs(1, &platform, null);

    var devices: cl.cl_device_id = undefined;
    _ = cl.clGetDeviceIDs(platform, cl.CL_DEVICE_TYPE_GPU, 1, &devices, null);

    var device_name: [256]u8 = undefined;
    @memset(device_name[0..256], 0);
    _ = cl.clGetDeviceInfo(devices, cl.CL_DEVICE_NAME, device_name.len, &device_name, null);
    config.console.log("Using gpu: {s}", .{device_name}, .Info);

    var cl_context = try OpenCLContext.init(alloc, devices);
    defer cl_context.deinit();

    // World Init
    var world = World{
        .alloc = alloc,
        .chunks = undefined,
        .cl_context = &cl_context,
        .gen = undefined,
    };

    world.init() catch {
        std.log.err("Failed to create worker thread!", .{});
        return;
    };

    var last_chunk_x: i32 = @intFromFloat(@floor(config.cam.pos.x / 32));
    var last_chunk_z: i32 = @intFromFloat(@floor(config.cam.pos.z / 32));

    world.load_chunks(&config.cam) catch {
        std.log.err("Failed to load initial chunks!", .{});
        return;
    };

    // Load texture atlas and send to opengl
    var atlas_w: c_int = 0;
    var atlas_h: c_int = 0;
    var atlas_col_channels: c_int = 0;

    // FIXME: use a proper path for the file
    const pixels = stbi.stbi_load("./src/assets/textures/atlas.png", &atlas_w, &atlas_h, &atlas_col_channels, 3);

    var atlas_tex: c_uint = 0;
    gl.glGenTextures(1, @ptrCast(&atlas_tex));
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, atlas_tex);
    gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1);
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGB8, atlas_w, atlas_h, 0, gl.GL_RGB, gl.GL_UNSIGNED_BYTE, pixels);

    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST_MIPMAP_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_REPEAT);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_REPEAT);

    gl.glGenerateMipmap(gl.GL_TEXTURE_2D);
    stbi.stbi_image_free(pixels);

    gl.glUniform1i(gl.glGetUniformLocation(shader.?.id, "uAtlas"), 0);

    while (!glfw.windowShouldClose(w)) {
        processInput(w, &config);

        // Imgui
        imgui.cImGui_ImplOpenGL3_NewFrame();
        imgui.cImGui_ImplGlfw_NewFrame();
        imgui.ImGui_NewFrame();

        // Break & Place blocks
        if (config.break_block) {
            config.break_block = false;
            try world.break_block(&config.cam);
        }

        if (config.place_block) {
            config.place_block = false;
            try world.place_block(&config.cam);
        }

        // clear bg
        gl.glClearColor(0.2, 0.3, 0.3, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

        // draw
        shader.?.use();

        // matrices :)
        const proj = math.Mat4.createPerspective(config.cam.fov_rad, config.cam.aspect_ratio, config.cam.near_clip, config.cam.far_clip);
        const view = math.Mat4.createLookAt(config.cam.pos, config.cam.target, config.cam.up);
        const light = [3]f32{ 0.2, -0.8, 0.3 }; // above left
        //const model = math.Mat4.createAngleAxis(math.Vec3.new(1.0, 0.0, 0.0), @floatCast(glfw.getTime()));

        const proj_flat = flattenMatrix(4, proj.fields);
        const view_flat = flattenMatrix(4, view.fields);
        //const model_flat = flattenMatrix(4, model.fields);

        const projUni = gl.glGetUniformLocation(shader.?.id, "proj");
        const viewUni = gl.glGetUniformLocation(shader.?.id, "view");
        const modelUni = gl.glGetUniformLocation(shader.?.id, "model");
        const lightDirUni = gl.glGetUniformLocation(shader.?.id, "ldir");

        gl.glUniformMatrix4fv(projUni, 1, gl.GL_FALSE, &proj_flat);
        gl.glUniformMatrix4fv(viewUni, 1, gl.GL_FALSE, &view_flat);
        gl.glUniform3fv(lightDirUni, 1, &light);
        //gl.glUniformMatrix4fv(modelUni, 1, gl.GL_FALSE, &model_flat);

        // update chunks
        const current_chunk_x: i32 = @intFromFloat(@floor(config.cam.pos.x / 32));
        const current_chunk_z: i32 = @intFromFloat(@floor(config.cam.pos.z / 32));

        if (current_chunk_x != last_chunk_x or current_chunk_z != last_chunk_z) {
            world.load_chunks(&config.cam) catch break;
            world.unload_chunks(&config.cam) catch break;
            last_chunk_x = current_chunk_x;
            last_chunk_z = current_chunk_z;
        }

        // Upload any chunks that are ready
        var it_upload = world.chunks.valueIterator();
        while (it_upload.next()) |chunk_ptr_ptr| {
            const chunk_ptr = chunk_ptr_ptr.*;
            chunk_ptr.mutex.lock();
            if (chunk_ptr.state == .ToUpload) {
                chunk_ptr.uploadMesh();
            }
            chunk_ptr.mutex.unlock();
        }

        // chunks
        var it = world.chunks.valueIterator();
        while (it.next()) |chunk_ptr_ptr| {
            const chunk_ptr = chunk_ptr_ptr.*;

            const chunk_offset = math.Mat4.createTranslation(math.Vec3.new(
                @as(f32, @floatFromInt(chunk_ptr.pos.x)) * 32.0,
                @as(f32, @floatFromInt(chunk_ptr.pos.y)) * 32.0,
                @as(f32, @floatFromInt(chunk_ptr.pos.z)) * 32.0,
            ));

            const model_flat = flattenMatrix(4, chunk_offset.fields);
            gl.glUniformMatrix4fv(modelUni, 1, gl.GL_FALSE, &model_flat);

            // Draw chunk
            gl.glBindVertexArray(chunk_ptr.fmesh.vao);
            gl.glDrawElements(gl.GL_TRIANGLES, @intCast(chunk_ptr.fmesh.indices.items.len), gl.GL_UNSIGNED_INT, null);
        }
        gl.glBindVertexArray(0);

        // redraw imgui
        draw_gui(&config, imio);
        config.console.render();

        imgui.ImGui_Render();
        imgui.cImGui_ImplOpenGL3_RenderDrawData(imgui.ImGui_GetDrawData());

        // stuff
        glfw.swapBuffers(w);
        glfw.pollEvents();
    }

    config.console.deinit();
    world.deinit();
    glfw.destroyWindow(w);
    glfw.terminate();
}

fn flattenMatrix(comptime N: usize, input: [N][N]f32) [N * N]f32 {
    var out: [N * N]f32 = undefined;
    for (0..N) |i| {
        for (0..N) |j| {
            out[i * N + j] = input[i][j];
        }
    }
    return out;
}

pub const Camera = struct {
    fov_rad: f32 = 0.785,
    aspect_ratio: f32 = 0,
    near_clip: f32 = 0.1,
    far_clip: f32 = 10000000.0,
    pos: math.Vec3 = math.vec3(40.0, 20.0, 40.0),
    target: math.Vec3 = math.vec3(16.0, 0.0, 16.0),
    up: math.Vec3 = math.vec3(0.0, 1.0, 0.0),
    yaw: f32 = -90.0,
    pitch: f32 = 0.0,
    sensitivity: f32 = 0.1,
    first_move: bool = true,
    last_x: f64 = 400.0,
    last_y: f64 = 300.0,
};

const Config = struct {
    fps: u32 = 60,
    vsync: bool = true,
    wireframe: bool = false,
    v_was_pressed: bool = false,
    f_was_pressed: bool = false,
    bt_was_pressed: bool = false,
    window_width: u32 = 800,
    window_height: u32 = 600,
    cam: Camera,
    break_block: bool = false,
    place_block: bool = false,
    last_block_action: f64 = 0.0,
    block_cooldown: f64 = 0.001,
    window_focused: bool = false,
    console: Console,
};

fn processInput(w: ?*glfw.Window, config: *Config) void {
    if (glfw.getKey(w, glfw.KeyEscape) == 1) glfw.setWindowShouldClose(w, true);

    // Toggle console with backtick
    const bt_pressed = glfw.getKey(w, glfw.KeyGraveAccent) == 1;
    if (bt_pressed and !config.bt_was_pressed) {
        config.console.visible = !config.console.visible;
    }
    config.bt_was_pressed = bt_pressed;

    if (config.console.visible) return;

    const v_pressed = glfw.getKey(w, glfw.KeyV) == 1;
    if (v_pressed and !config.v_was_pressed) {
        config.wireframe = !config.wireframe;
        if (config.wireframe) {
            gl.glPolygonMode(gl.GL_FRONT_AND_BACK, gl.GL_LINE);
        } else {
            gl.glPolygonMode(gl.GL_FRONT_AND_BACK, gl.GL_FILL);
        }
    }

    config.v_was_pressed = v_pressed;

    // Toggle focus with F key
    const f_pressed = glfw.getKey(w, glfw.KeyF) == 1;
    if (f_pressed and !config.f_was_pressed) {
        config.window_focused = !config.window_focused;
        if (config.window_focused) {
            glfw.setInputMode(w, glfw.Cursor, glfw.CursorDisabled);
        } else {
            glfw.setInputMode(w, glfw.Cursor, glfw.CursorNormal);
        }
    }
    config.f_was_pressed = f_pressed;

    // Camera input
    const speed: f32 = 1.0;
    const forward = math.Vec3.sub(config.cam.target, config.cam.pos).normalize();
    const right = math.Vec3.cross(forward, config.cam.up).normalize();

    if (config.window_focused) {
        if (glfw.getKey(w, glfw.KeyW) == 1) {
            config.cam.pos = math.Vec3.add(config.cam.pos, math.Vec3.scale(forward, speed));
            config.cam.target = math.Vec3.add(config.cam.target, math.Vec3.scale(forward, speed));
        }
        if (glfw.getKey(w, glfw.KeyS) == 1) {
            config.cam.pos = math.Vec3.sub(config.cam.pos, math.Vec3.scale(forward, speed));
            config.cam.target = math.Vec3.sub(config.cam.target, math.Vec3.scale(forward, speed));
        }
        if (glfw.getKey(w, glfw.KeyA) == 1) {
            config.cam.pos = math.Vec3.sub(config.cam.pos, math.Vec3.scale(right, speed));
            config.cam.target = math.Vec3.sub(config.cam.target, math.Vec3.scale(right, speed));
        }
        if (glfw.getKey(w, glfw.KeyD) == 1) {
            config.cam.pos = math.Vec3.add(config.cam.pos, math.Vec3.scale(right, speed));
            config.cam.target = math.Vec3.add(config.cam.target, math.Vec3.scale(right, speed));
        }
        if (glfw.getKey(w, glfw.KeyE) == 1) {
            config.cam.pos.y += speed;
            config.cam.target.y += speed;
        }
        if (glfw.getKey(w, glfw.KeyQ) == 1) {
            config.cam.pos.y -= speed;
            config.cam.target.y -= speed;
        }

        const current_time = glfw.getTime();
        if (current_time - config.last_block_action >= config.block_cooldown) {
            config.last_block_action = current_time;
            if (glfw.getMouseButton(w, glfw.MouseButtonLeft) == 1) {
                config.break_block = true;
            }

            if (glfw.getMouseButton(w, glfw.MouseButtonRight) == 1) {
                config.place_block = true;
            }
        }
    }
}

fn fb_size_callback(w: *c_long, width: c_int, height: c_int) callconv(.c) void {
    const config = @as(*Config, @ptrCast(@alignCast(glfw.getWindowUserPointer(w).?)));
    config.window_width = @intCast(width);
    config.window_height = @intCast(height);
    const new_ratio: f32 = @as(f32, @floatFromInt(config.window_width)) / @as(f32, @floatFromInt(config.window_height));
    config.cam.aspect_ratio = new_ratio;
    gl.glViewport(0, 0, width, height);
}

fn cursor_callback(w: *c_long, x: f64, y: f64) callconv(.c) void {
    const config = @as(*Config, @ptrCast(@alignCast(glfw.getWindowUserPointer(w).?)));

    if (!config.window_focused or config.console.visible) return;

    if (config.cam.first_move) {
        config.cam.last_x = x;
        config.cam.last_y = y;
        config.cam.first_move = false;
        return;
    }

    const x_offset: f32 = @floatCast(x - config.cam.last_x);
    const y_offset: f32 = @floatCast(y - config.cam.last_y);

    config.cam.last_x = x;
    config.cam.last_y = y;

    config.cam.yaw += x_offset * config.cam.sensitivity;
    config.cam.pitch -= y_offset * config.cam.sensitivity;

    if (config.cam.pitch > 89.0) config.cam.pitch = 89.0;
    if (config.cam.pitch < -89.0) config.cam.pitch = -89.0;

    updateCamDir(&config.cam);
}

fn updateCamDir(cam: *Camera) void {
    const yaw_rad = cam.yaw * (std.math.pi / 180.0);
    const pitch_rad = cam.pitch * (std.math.pi / 180.0);

    const dir = math.vec3(
        @cos(pitch_rad) * @cos(yaw_rad),
        @sin(pitch_rad),
        @cos(pitch_rad) * @sin(yaw_rad),
    );

    cam.target = math.Vec3.add(cam.pos, dir.normalize());
}

fn draw_gui(config: *Config, io: [*c]imgui.ImGuiIO_t) void {
    if (imgui.ImGui_Begin("Isolated", null, 0)) {
        imgui.ImGui_Text("FPS (%.0f) POS (%.0f, %0.f, %0.f)", io.*.Framerate, config.cam.pos.x, config.cam.pos.y, config.cam.pos.z);
        if (imgui.ImGui_BeginTabBar("bar", 0)) {
            if (imgui.ImGui_BeginTabItem("General", null, 0)) {
                imgui.ImGui_EndTabItem();
            }

            if (imgui.ImGui_BeginTabItem("Render", null, 0)) {
                _ = imgui.ImGui_SliderInt("FPS", @ptrCast(&config.fps), 30, 120);
                if (imgui.ImGui_Checkbox("V-Sync", @ptrCast(&config.vsync))) {
                    if (config.vsync) {
                        glfw.swapInterval(1);
                    } else {
                        glfw.swapInterval(0);
                    }
                }
                imgui.ImGui_EndTabItem();
            }
            imgui.ImGui_EndTabBar();
        }
    }
    imgui.ImGui_End();
}
