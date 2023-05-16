const std = @import("std");
const Allocator = std.mem.Allocator;
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const Spectrogram = @import("./audio_utils/Spectrogram.zig");

pub const GUIContext = struct {
    window: *zglfw.Window,
    gctx: *zgpu.GraphicsContext,
    w: u32 = 0,
    h: u32 = 0,
    w_f: f32 = 0.0,
    h_f: f32 = 0.0,
};

pub fn setup(allocator: Allocator) !*GUIContext {
    try zglfw.init();

    var window = try zglfw.Window.create(1000, 800, "Example", null);
    var gctx = try zgpu.GraphicsContext.create(allocator, window);
    zgui.init(allocator);
    zgui.plot.init();
    zgui.backend.initWithConfig(
        window,
        gctx.device,
        @enumToInt(zgpu.GraphicsContext.swapchain_format),
        .{ .texture_filter_mode = .linear, .pipeline_multisample_count = 1 },
    );


    var context = try allocator.create(GUIContext);
    context.* = .{
        .window = window,
        .gctx = gctx,
    };

    return context;
}

pub fn beginFrame(ctx: *GUIContext) void {
    const size = ctx.window.getSize();
    ctx.w = @intCast(u32, size[0]);
    ctx.h = @intCast(u32, size[1]);
    ctx.w_f = @intToFloat(f32, ctx.w);
    ctx.h_f = @intToFloat(f32, ctx.h);
    zglfw.pollEvents();
    zgui.backend.newFrame(ctx.w, ctx.h);
}

pub fn endFrame(ctx: *GUIContext) void {
    const gctx = ctx.gctx;
    //const fb_width = gctx.swapchain_descriptor.width;
    //const fb_height = gctx.swapchain_descriptor.height;

    const swapchain_texv = gctx.swapchain.getCurrentTextureView();
    defer swapchain_texv.release();

    const commands = commands: {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        // Gui pass.
        {
            const pass = zgpu.beginRenderPassSimple(encoder, .load, swapchain_texv, null, null, null);
            defer zgpu.endReleasePass(pass);
            zgui.backend.draw(pass);
        }

        break :commands encoder.finish(null);
    };
    defer commands.release();

    gctx.submit(&.{commands});
    _ = gctx.present();
}


pub fn visualizeSpectrogram(allocator: std.mem.Allocator, spectrogram: Spectrogram) !void {
    var ctx = try setup(allocator);

    while (true) {
        beginFrame(ctx);
        // zgui.plot.showDemoWindow(null);
        // zgui.showDemoWindow(null);

        zgui.setNextWindowPos(.{ .x = 0, .y = 0 });
        zgui.setNextWindowSize(.{ .h = ctx.h_f, .w = ctx.w_f });
        if (zgui.begin("Plot", .{})) {
            if (zgui.plot.beginPlot("Spectrogram", .{ .h = -1, .w = -1 })) {
                // zgui.plot.setupAxis(.x1, .{ .label = "Freq (Hz)" });
                // zgui.plot.setupAxis(.y1, .{ .label = "dbFS" });
                // zgui.plot.setupAxisLimits(.x1, .{ .min = 0, .max = 5 });
                // zgui.plot.setupLegend(.{ .south = true, .west = true }, .{});
                zgui.plot.setupFinish();

                zgui.plot.plotHeatmap("", f32, .{
                    // .values = &.{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1 },
                    // .rows = 5,
                    // .cols = 2,
                    // .flags = .{ .col_major = false },

                    .values = spectrogram.values,
                    // .rows = @intCast(i32, spectrogram.height),
                    // .cols = @intCast(i32, spectrogram.width),
                    // There's some kind of a bug with col-major heatmaps
                    // .flags = .{ .col_major = true },

                    .rows = @intCast(i32, spectrogram.width),
                    .cols = @intCast(i32, spectrogram.height),
                    .flags = .{ .col_major = false },

                    .bounds_min = .{ .x = 0, .y = 0 },
                    .bounds_max = .{
                        .x = spectrogram.nyquist_freq,
                        .y = spectrogram.length_sec,
                    },
                    .scale_min = 0,
                    .scale_max = 1,
                    .label_fmt = null,
                });

                // zgui.plot.plotLine("", f32, .{
                //     .xv = x,
                //     .yv = y,
                // });
            }
            zgui.plot.endPlot();
        }
        zgui.end();

        endFrame(ctx);
    }
}