const std = @import("std");
const Allocator = std.mem.Allocator;
const AudioFileStream = @import("AudioFileStream.zig");
const AudioBuffer = @import("AudioBuffer.zig");

pub const AudioSource = union(enum) {
    stream: AudioFileStream,
    buffer: AudioBuffer,

    pub fn deinit(self: *@This()) void {
        switch (self.*) {
            .stream => |*stream| {
                stream.close();
            },
            inline else => {},
        }
    }

    pub fn durationSeconds(self: @This()) f32 {
        return switch (self) {
            .stream => |stream| stream.durationSeconds(),
            .buffer => |buffer| buffer.duration_seconds,
        };
    }

    pub fn sampleRate(self: @This()) usize {
        return switch (self) {
            inline else => |s| s.sample_rate,
        };
    }

    pub fn nChannels(self: @This()) usize {
        return switch (self) {
            inline else => |s| s.n_channels,
        };
    }
};
