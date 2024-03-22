const std = @import("std");
const log = std.log.scoped(.recording_coordinator);
const AudioBuffer = @import("./audio_utils/AudioBuffer.zig");
const AudioPipeline = @import("./AudioPipeline.zig");
const types = @import("./types.zig");
const SampleIndex = types.SampleIndex;

const Self = @This();

/// Encapsulates a recorder registration and its callbacks
pub const Registration = struct {
    pub const StartRecordingFn = fn (ctx: *anyopaque, sample_number: SampleIndex) void;
    pub const StopRecordingFn = fn (ctx: *anyopaque, sample_number: SampleIndex, keep: bool) void;

    name: []const u8,
    ctx: *anyopaque,
    start_fn: *const StartRecordingFn,
    stop_fn: *const StopRecordingFn,
};

const RecorderMap = std.AutoHashMap(*anyopaque, Registration);

allocator: std.mem.Allocator,
recorders: RecorderMap,
pipeline: *AudioPipeline,

pub fn init(allocator: std.mem.Allocator, pipeline: *AudioPipeline) !*Self {
    const self = try allocator.create(Self);

    self.* = .{
        .allocator = allocator,
        .recorders = RecorderMap.init(allocator),
        .pipeline = pipeline,
    };

    return self;
}

pub fn deinit(self: *Self) void {
    self.recorders.deinit();
    self.allocator.destroy(self);
}

pub fn register(
    self: *Self,
    name: []const u8,
    ctx: *anyopaque,
    start_fn: *const Registration.StartRecordingFn,
    stop_fn: *const Registration.StopRecordingFn,
) !void {
    const registration = Registration{
        .name = name,
        .ctx = ctx,
        .start_fn = start_fn,
        .stop_fn = stop_fn,
    };

    log.info("Registering recorder '{s}'", .{name});

    if (self.recorders.contains(ctx)) {
        std.debug.panic("Recorder '{s}' already registered", .{name});
    }

    self.recorders.putNoClobber(ctx, registration) catch |err| {
        std.debug.panic("Recorder '{s}' already registered after check?! error: {any}", .{ name, err });
    };
}

pub fn unregister(
    self: *Self,
    name: []const u8,
    ctx: *anyopaque,
) void {
    const removed = self.recorders.remove(ctx);

    if (!removed) {
        std.debug.panic("Recorder '{s}' tried to unregister, but it wasn't registered.", .{name});
    }
}

pub fn start(
    self: *const Self,
    sample_number: SampleIndex,
) void {
    log.info("Starting recording from sample {d}", .{sample_number});

    var it = self.recorders.iterator();
    while (it.next()) |item| {
        const recorder = item.value_ptr.*;
        recorder.start_fn(recorder.ctx, sample_number);
    }
}

pub fn stop(
    self: *const Self,
    sample_number: SampleIndex,
    keep: bool,
) void {
    log.info("Ending recording at sample {d}, keep: {s}", .{ sample_number, if (keep) "yes" else "no" });

    var it = self.recorders.iterator();
    while (it.next()) |item| {
        const recorder = item.value_ptr.*;
        recorder.stop_fn(recorder.ctx, sample_number, keep);
    }
}

pub fn onRecording(
    self: *Self,
    ctx: *anyopaque,
    recording: AudioBuffer,
) void {
    const recorder = self.recorders.get(ctx);
    if (recorder) |r| {
        self.pipeline.onRecording(r.name, recording);
    } else {
        std.debug.panic("Received recording from unregistered recorder at {any}", .{ctx});
    }
}
