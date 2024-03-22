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
    is_disabled: bool = true,
    is_recording: bool = false,
    ctx: *anyopaque,
    start_fn: *const StartRecordingFn,
    stop_fn: *const StopRecordingFn,

    pub fn disable(self: *Registration) void {
        self.is_disabled = true;
        if (self.is_recording) {
            self.stop_fn(self.ctx, 0, false);
            self.is_recording = false;
        }
    }

    pub fn enable(self: *Registration) void {
        self.is_disabled = false;
    }
};

const RecorderMap = std.AutoHashMap(*anyopaque, Registration);

allocator: std.mem.Allocator,
recorders: RecorderMap,
pipeline: *AudioPipeline,
is_recording: bool = false,

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

pub fn disableAll(self: *Self) void {
    log.info("Disabling all recorders.", .{});
    var it = self.recorders.iterator();
    while (it.next()) |item| {
        const recorder = item.value_ptr;
        recorder.disable();
    }
}

pub fn disableOne(self: *Self, ctx: *anyopaque) !void {
    const maybe_recorder = self.recorders.getPtr(ctx);
    if (maybe_recorder) |recorder| {
        log.info("Disabling recorder: {s}", .{recorder.name});
        recorder.disable();
    } else {
        return error.UnknownRecorder;
    }
}

pub fn enableAll(self: *Self) void {
    log.info("Enabling all recorders.", .{});
    var it = self.recorders.iterator();
    while (it.next()) |item| {
        const recorder = item.value_ptr;
        recorder.enable();
    }
}

pub fn enableOne(self: *Self, ctx: *anyopaque) !void {
    const maybe_recorder = self.recorders.getPtr(ctx);
    if (maybe_recorder) |recorder| {
        log.info("Enabling recorder: {s}", .{recorder.name});
        recorder.enable();
    } else {
        return error.UnknownRecorder;
    }
}

pub fn start(
    self: *Self,
    sample_number: SampleIndex,
) void {
    if (self.is_recording) {
        std.debug.panic(
            "RecordingCoordinator: Attempted to stop recording at sample {d} but recording is already active.",
            .{sample_number},
        );
    }

    log.info("Starting recording from sample {d}", .{sample_number});
    defer self.is_recording = true;

    var it = self.recorders.iterator();
    while (it.next()) |item| {
        const recorder = item.value_ptr;
        std.debug.assert(recorder.is_recording == false);
        if (recorder.is_disabled) continue;

        recorder.start_fn(recorder.ctx, sample_number);
        recorder.is_recording = true;
    }
}

pub fn stop(
    self: *Self,
    sample_number: SampleIndex,
    keep: bool,
) void {
    const keep_str = if (keep) "yes" else "no";

    if (!self.is_recording) {
        std.debug.panic(
            "RecordingCoordinator: Attempted to stop recording at sample {d} (keep= {s}) but recording is not active.",
            .{ sample_number, keep_str },
        );
    }

    defer self.is_recording = false;
    log.info("Ending recording at sample {d}, keep: {s}", .{ sample_number, keep_str });

    var it = self.recorders.iterator();
    while (it.next()) |item| {
        const recorder = item.value_ptr;
        if (!recorder.is_recording) continue;

        recorder.stop_fn(recorder.ctx, sample_number, keep);
        recorder.is_recording = false;
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
