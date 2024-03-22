const std = @import("std");
const log = std.log.scoped(.buffered_recorder);
const BufferedStep = @import("BufferedStep.zig");
const MRBRecorder = @import("MRBRecorder.zig");
const audio_utils = @import("../audio_utils.zig");
const AudioBuffer = @import("../audio_utils/AudioBuffer.zig");
const RecordingCoordinator = @import("../RecordingCoordinator.zig");
const types = @import("../types.zig");
const AudioMRB = types.AudioMRB;

const Self = @This();

allocator: std.mem.Allocator,
name: []const u8,
audio_config: BufferedStep.AudioConfig,
step: *BufferedStep,
ring_buffer: AudioMRB,
mrb_recorder: MRBRecorder,
rec_coordinator: ?*RecordingCoordinator,

pub fn init(
    allocator: std.mem.Allocator,
    name: []const u8,
    rec_coordinator: ?*RecordingCoordinator,
    sample_rate: usize,
    n_channels: usize,
    expect_output: bool,
) !*Self {
    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const input_buffer_size = sample_rate / 10;

    const ring_buffer_size = 10 * sample_rate;
    var ring_buffer = try AudioMRB.init(allocator, n_channels, ring_buffer_size);
    errdefer ring_buffer.deinit();

    self.* = .{
        .allocator = allocator,
        .name = name,
        .rec_coordinator = rec_coordinator,
        .audio_config = .{
            .buffer_size = input_buffer_size,
            .in_channels = n_channels,
            .in_sample_rate = sample_rate,
            .out_channels = n_channels,
            .out_sample_rate = sample_rate,
            .expect_output = expect_output,
        },
        .ring_buffer = ring_buffer,
        .mrb_recorder = undefined,
        .step = undefined,
    };

    self.mrb_recorder = try MRBRecorder.init(
        allocator,
        &self.ring_buffer,
        sample_rate,
        onRecording,
        self,
    );
    errdefer self.mrb_recorder.deinit();

    self.step = try BufferedStep.init(
        allocator,
        name,
        self.audio_config,
        BufferedStep.Processor.forContext(self),
    );
    errdefer self.step.deinit();

    if (rec_coordinator) |coordinator| {
        try coordinator.register(
            self.name,
            self,
            &coordinatedStartRecording,
            &coordinatedStopRecording,
        );
    }

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.rec_coordinator) |coordinator| {
        coordinator.unregister(self.name, self);
    }
    self.step.deinit();
    self.mrb_recorder.deinit();
    self.ring_buffer.deinit();
    self.allocator.destroy(self);
}

pub fn process(self: *Self, prev_result: *const BufferedStep.Result) *const BufferedStep.Result {
    const write_head = self.ring_buffer.totalWriteCount();
    const input_len = prev_result.segment.length();

    self.mrb_recorder.beforeMRBWrite(write_head + input_len) catch |err| {
        std.debug.panic("BufferedRecorder '{s}': beforeMRBWrite failed with: {any}", .{ self.step.name, err });
    };

    const n_written = self.ring_buffer.write(prev_result.segment.channel_pcm_buf, 0, input_len);
    std.debug.assert(n_written == input_len);

    return prev_result;
}

pub fn onRecording(self_opaque: *anyopaque, _audio_buffer: AudioBuffer) void {
    const self: *Self = @ptrCast(@alignCast(self_opaque));

    var audio_buffer = _audio_buffer;
    const our_start_sample = audio_buffer.first_sample_number.?;
    const global_start_sample = self.step.convertSampleIndexToRoot(our_start_sample).from;

    audio_buffer.first_sample_number = global_start_sample;

    if (self.rec_coordinator) |coordinator| {
        coordinator.onRecording(self, audio_buffer);
    }
}

fn coordinatedStartRecording(self_opaque: *anyopaque, sample_number: u64) void {
    const self: *Self = @ptrCast(@alignCast(self_opaque));
    const our_sample_number = self.step.convertSampleIndexFromRoot(sample_number).from;

    self.mrb_recorder.startRecording(our_sample_number) catch |err| {
        std.debug.panic(
            "BufferedRecorder '{s}': coordinatedStartRecording encountered error: {any}",
            .{ self.name, err },
        );
    };
}

fn coordinatedStopRecording(self_opaque: *anyopaque, sample_number: u64, keep: bool) void {
    const self: *Self = @ptrCast(@alignCast(self_opaque));
    const our_sample_number = self.step.convertSampleIndexFromRoot(sample_number).to;

    self.mrb_recorder.stopRecording(our_sample_number, keep) catch |err| {
        std.debug.panic(
            "BufferedRecorder '{s}': coordinatedStopRecording encountered error: {any}",
            .{ self.name, err },
        );
    };
}
