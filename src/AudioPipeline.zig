const std = @import("std");
const log = std.log.scoped(.pipeline);
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Segment = @import("./AudioPipeline/Segment.zig");
const MRBRecorder = @import("./AudioPipeline/MRBRecorder.zig");
const AudioMRB = @import("./types.zig").AudioMRB;
const VADPipeline = @import("./AudioPipeline/VADPipeline.zig");
const AudioBuffer = @import("./audio_utils/AudioBuffer.zig");
const RecordingCoordinator = @import("RecordingCoordinator.zig");

const Self = @This();

pub const Callbacks = struct {
    ctx: *anyopaque,
    on_recording: ?*const fn (
        ctx: *anyopaque,
        recorder_name: []const u8,
        recording: AudioBuffer,
    ) void,
};

pub const Config = struct {
    sample_rate: usize,
    n_channels: usize,
    buffer_length: ?usize = null,
    vad_config: VADPipeline.Config = .{},
    skip_processing: bool = false,
};

allocator: Allocator,
config: Config,
vad: *VADPipeline,
callbacks: ?Callbacks = null,
recording_coordinator: *RecordingCoordinator,
write_index: u64 = 0,

pub fn init(
    allocator: Allocator,
    config: Config,
    callbacks: ?Callbacks,
) !*Self {
    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = Self{
        .config = config,
        .allocator = allocator,
        .recording_coordinator = undefined,
        .vad = undefined,
        .callbacks = callbacks,
    };

    self.recording_coordinator = try RecordingCoordinator.init(allocator, self);
    errdefer self.recording_coordinator.deinit();

    self.vad = try VADPipeline.init(self, config.vad_config);
    errdefer self.vad.deinit();

    return self;
}

pub fn deinit(self: *Self) void {
    self.vad.deinit();
    // self.ring_buffer.deinit();
    self.recording_coordinator.deinit();
    self.allocator.destroy(self);
}

pub fn totalWriteCount(self: *const Self) u64 {
    return self.ring_buffer.total_write_count;
}

pub fn pushSamples(self: *Self, channel_pcm: []const []const f32) !u64 {
    const segment = Segment.wrapChannelPcmBuf(self.write_index, channel_pcm);
    self.write_index += segment.length();

    try self.vad.write(&segment);
    return segment.index;
}

pub fn startRecording(self: *Self, from_sample: usize) void {
    self.recording_coordinator.start(from_sample);
}

pub fn endRecording(self: *Self, to_sample: usize, keep: bool) void {
    self.recording_coordinator.stop(to_sample, keep);
}

pub fn onRecording(
    self: *Self,
    recorder_name: []const u8,
    audio_buffer: AudioBuffer,
) void {
    defer audio_buffer.deinit();
    const cb_config = self.callbacks orelse return;

    if (cb_config.on_recording) |cb| {
        cb(cb_config.ctx, recorder_name, audio_buffer);
    }
}

fn maybeRunPipeline(self: *Self) !void {
    if (self.config.skip_processing) return;
    try self.vad.run();
}

//
// Tests
//

test "simple leak test" {
    var pipeline = try init(
        std.testing.allocator,
        .{
            .n_channels = 2,
            .sample_rate = 48000,
            .vad_config = .{
                .alt_vad_machine_configs = &.{
                    .{},
                    .{},
                },
            },
        },
        null,
    );
    defer pipeline.deinit();
}
