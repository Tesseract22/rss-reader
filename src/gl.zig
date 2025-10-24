// const std = @import("std");

const c = @cImport({
    @cDefine("RGFW_OPENGL", {});
    @cDefine("RGFW_ADVANCED_SMOOTH_RESIZE", {});
    @cInclude("thirdparty/RGFW/RGFW.h");
});

const g = @cImport({
    @cInclude("thirdparty/glad.h");
    @cInclude("GL/gl.h");
});

const base_vs_src = @embedFile("resources/vertex.glsl");
const base_fs_src = @embedFile("resources/fragment.glsl");

const Vec3 = [3]f32;
const Vec2 = [2]f32;
const Vec3u = [3]g.GLuint;

const ShaderError = error { ShaderCompileError };
const ProgramError = error {
    LinkError,
} || ShaderError;

pub const GLObj = g.GLuint;

pub fn Context(comptime T: type) type {
    return struct {
        window: *c.RGFW_window,

        render_fn: *const fn (ctx: Self) void,
        user_data: *T,

        base_shader_pgm: GLObj,
        base_vert_shader: GLObj,
        base_frag_shader: GLObj,
        
        // base_VBO: GLObj,
        // base_VAO: GLObj,
        // base_EAO: GLObj,
       
        const Self = @This();
        pub fn init(self: *Self, user_data: *T, render_fn: *const fn (ctx: Self) void,
            title: [:0]const u8, w: i32, h: i32) !void {

            const win = c.RGFW_createWindow(title, 0, 0, w, h, 
                c.RGFW_windowCenter
                // | c.RGFW_windowNoResize
                | c.RGFW_windowOpenGL) orelse unreachable;
            c.RGFW_window_makeCurrentWindow_OpenGL(win);
            _ = c.RGFW_setWindowRefreshCallback(on_refresh);
            _ = c.RGFW_setWindowResizedCallback(on_resize);

            if (g.gladLoadGL(c.RGFW_getProcAddress_OpenGL) == 0) {
                log("ERROR: failed to load GLAD", .{});
                unreachable;
            }

            g.glEnable(g.GL_BLEND); 
            g.glBlendFunc(g.GL_SRC_ALPHA, g.GL_ONE_MINUS_SRC_ALPHA);
            g.glBlendEquation(g.GL_FUNC_ADD);

            const gl_version = g.glGetString(g.GL_VERSION);
            log("OpenGL version: {s}", .{ gl_version });
            on_resize(win, w, h);

            const base_vs = try load_shader(base_vs_src, g.GL_VERTEX_SHADER);
            const base_fs = try load_shader(base_fs_src, g.GL_FRAGMENT_SHADER);
            const base_pgm = try create_program(base_vs, base_fs);
            c.RGFW_window_setUserPtr(win, self);
            self.window = win;
            self.render_fn = render_fn; self.user_data = user_data;
            self.base_shader_pgm = base_pgm;
            self.base_vert_shader = base_vs;
            self.base_frag_shader = base_fs;
        }

        pub fn window_should_close(self: Self) bool {
            var event: c.RGFW_event = undefined;
            while (c.RGFW_window_checkEvent(self.window, &event) != 0) {}
            return c.RGFW_window_shouldClose(self.window) != 0;
        }

        pub fn close_window(self: Self) void {
            return c.RGFW_window_close(self.window);
        }

        fn on_resize(_: ?*c.RGFW_window, w: i32, h: i32) callconv(.c) void {
            //.std.log.debug("resized", .{});
            // WINDOW_WIDTH = w;
            // WINDOW_HEIGHT = h;
            if (w > h)
                g.glViewport(0, @divFloor(h-w, 2), w, w)
            else
                g.glViewport(@divFloor(w-h, 2), 0, h, h);
        }

        fn on_refresh(win: ?*c.RGFW_window) callconv(.c) void {
            // std.log.debug("refresh", .{});
            const ctx: *Self = @ptrCast(@alignCast(c.RGFW_window_getUserPtr(win)));
            ctx.render();
        }

        pub fn render(self: Self) void {
            self.render_fn(self);
            c.RGFW_window_swapBuffers_OpenGL(self.window);
        }

        const BaseVertexData = extern struct {
            pos: Vec3,
            rgb: Vec3,
            tex: Vec2,
        };


        pub fn draw_rect(self: Self, topleft: Vec2, w: f32, h: f32) void {
            g.glClearColor(18.0/255.0, 18.0/255.0, 18.0/255.0, 1);
            g.glClear(g.GL_COLOR_BUFFER_BIT);

            const vertexes = [_]BaseVertexData {
                .{ .pos = .{topleft[0]+w, topleft[1]-h, 0}, .rgb = .{1, 0, 0}, .tex = .{1, 1} },
                .{ .pos = .{topleft[0]+w, topleft[1],   0}, .rgb = .{1, 0, 0}, .tex = .{1, 0} },
                .{ .pos = .{topleft[0],   topleft[1]-h, 0}, .rgb = .{1, 0, 0}, .tex = .{0, 0} },
                .{ .pos = .{topleft[0],   topleft[1],   0}, .rgb = .{1, 0, 0}, .tex = .{0, 1} },
            };
    

            const indices = [_]Vec3u {
                .{ 0, 1, 3},
                .{ 0, 2, 3},
            };

            g.glUseProgram(self.base_shader_pgm);

            var VBO: GLObj = undefined;
            g.glGenBuffers(1, &VBO);
            g.glBindBuffer(g.GL_ARRAY_BUFFER, VBO);
            g.glBufferData(g.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertexes)), &vertexes, g.GL_STATIC_DRAW);

            var VAO: GLObj = undefined;
            g.glGenVertexArrays(1, &VAO);
            g.glBindVertexArray(VAO);

            bind_vertex_attr(BaseVertexData) catch unreachable;

            var EBO: GLObj = undefined;
            g.glGenBuffers(1, &EBO);
            g.glBindBuffer(g.GL_ELEMENT_ARRAY_BUFFER, EBO);
            g.glBufferData(g.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(indices)), &indices, g.GL_STATIC_DRAW);


            g.glDrawElements(g.GL_TRIANGLES, 6, g.GL_UNSIGNED_INT, @ptrFromInt(0));

        }

        pub fn draw_line() void {

        }


    };
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    const std = @import("std");
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

fn load_shader(src: [:0]const u8, kind: c_uint) ShaderError!g.GLuint {
    const shader = g.glCreateShader(kind);
    g.glShaderSource(shader, 1, &src.ptr, null);
    g.glCompileShader(shader);
    var success: c_int = undefined;
    g.glGetShaderiv(shader, g.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var log_buf: [256]u8 = undefined;
        g.glGetShaderInfoLog(shader, log_buf.len, null, &log_buf);
        log("ERROR: Failed to compile {s} shader: {s}",
            .{ if (kind == g.GL_VERTEX_SHADER) "vertex" else "fragment", log_buf});
        return ShaderError.ShaderCompileError;
    }
    return shader;
}

fn create_program_from_src(vs_src: [:0]const u8, fs_src: [:0]const u8) ProgramError!g.GLuint {
    const vs = try load_shader(vs_src, g.GL_VERTEX_SHADER);
    const fs = try load_shader(fs_src, g.GL_FRAGMENT_SHADER);
    return create_program(vs, fs);
}

fn create_program(vs: GLObj, fs: GLObj) ProgramError!g.GLuint {
    const pgm = g.glCreateProgram();
    g.glAttachShader(pgm, vs);
    g.glAttachShader(pgm, fs);

    g.glLinkProgram(pgm);
    var success: c_int = undefined;
    g.glGetProgramiv(pgm, g.GL_LINK_STATUS, &success);
    if (success == 0) {
        var log_buf: [256]u8 = undefined;
        g.glGetShaderInfoLog(pgm, log_buf.len, null, &log_buf);
        log("ERROR: Failed to compile shader: {s}", .{log_buf});
        return ProgramError.LinkError;
    }
    return pgm;
}

fn use_program(pgm: g.GLuint) void {
    g.glUseProgram(pgm);
}



pub fn bind_vertex_attr(comptime T: type) !void {
    const struct_info = @typeInfo(T).@"struct";
    inline for (struct_info.fields, 0..) |f, i| {
        const field_info = @typeInfo(f.type).array;
        if (field_info.child != f32) @compileError("Unsupported type " ++ @typeName(f.type));
        g.glVertexAttribPointer(i, 
            field_info.len, g.GL_FLOAT,
            g.GL_FALSE,
            @sizeOf(T),
            @ptrFromInt(@offsetOf(T, f.name)));
        g.glEnableVertexAttribArray(i);
    }
}
