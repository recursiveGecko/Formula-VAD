const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const FFT = @import("../FFT.zig");
const window_fn = @import("../audio_utils/window_fn.zig");
const AudioPipeline = @import("../AudioPipeline.zig");
const SplitSlice = @import("../structures/SplitSlice.zig");
const Segment = @import("./Segment.zig");
const SegmentWriter = @import("./SegmentWriter.zig");
const BufferedStep = @import("./BufferedStep.zig");
const VADMetadata = @import("./VADMetadata.zig");

const Self = @This();

pub const Config = struct {
    n_channels: usize,
    fft_size: usize,
    hop_size: usize,
    sample_rate: usize,
};

pub const Result = struct {
    // Global sample index of the first sample in the FFT window
    allocator: Allocator,
    index: usize,
    fft_size: usize,
    channel_bins: [][]f32 = undefined,
    vad_metadata: VADMetadata.Result,

    pub fn init(allocator: Allocator, n_channels: usize, fft_size: usize, n_bins: usize) !Result {
        var channel_bins = try allocator.alloc([]f32, n_channels);
        var bins_initialized: usize = 0;
        errdefer {
            for (0..bins_initialized) |i| allocator.free(channel_bins[i]);
            allocator.free(channel_bins);
        }
        for (0..n_channels) |channel_idx| {
            channel_bins[channel_idx] = try allocator.alloc(f32, n_bins);
            bins_initialized += 1;
        }

        return Result{
            .allocator = allocator,
            .index = 0,
            .fft_size = fft_size,
            .channel_bins = channel_bins,
            .vad_metadata = .{},
        };
    }

    pub fn deinit(self: *Result) void {
        for (0..self.channel_bins.len) |i| {
            self.allocator.free(self.channel_bins[i]);
        }
        self.allocator.free(self.channel_bins);
    }
};

pub const WriteResult = struct {
    fft_result: ?Result,
    n_remaining_input: usize,
};

allocator: Allocator,
config: Config,
fft_instance: *FFT,
window: []const f32,
buffer: SegmentWriter,
temp_result: Result,
vad_metadata: VADMetadata = .{},
norm_factor: f32,
complex_buffer: []FFT.Complex,

pub fn init(allocator: Allocator, config: Config) !Self {
    var fft_instance = try FFT.init(
        allocator,
        config.fft_size,
        config.sample_rate,
        false,
    );
    errdefer fft_instance.deinit();

    var buffer = try SegmentWriter.init(allocator, config.n_channels, config.fft_size);
    errdefer buffer.deinit();
    // Pipeline sample number that corresponds to the start of the FFT buffer
    buffer.segment.index = 0;

    var temp_result = try Result.init(
        allocator,
        config.n_channels,
        config.fft_size,
        fft_instance.binCount(),
    );

    var window = try allocator.alloc(f32, config.fft_size);
    errdefer allocator.free(window);
    window_fn.hannWindowPeriodic(window);

    const norm_factor = window_fn.windowNormFactor(window) / @intToFloat(f32, config.fft_size);

    var complex_buffer = try allocator.alloc(FFT.Complex, fft_instance.binCount());
    errdefer allocator.free(complex_buffer);

    const hop_size = if (config.hop_size > 0) config.hop_size else config.fft_size;

    var self = Self{
        .allocator = allocator,
        .config = config,
        .buffer = buffer,
        .temp_result = temp_result,
        .fft_instance = fft_instance,
        .window = window,
        .complex_buffer = complex_buffer,
        .norm_factor = norm_factor,
    };
    self.config.hop_size = hop_size;

    return self;
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.window);
    self.allocator.free(self.complex_buffer);
    self.fft_instance.deinit();
    self.buffer.deinit();
    self.temp_result.deinit();
}

pub fn write(
    self: *Self,
    input: *const BufferedStep.Result,
    input_offset: usize,
) !WriteResult {
    const n_written = try self.buffer.write(input.segment, input_offset, null);
    const n_remaining_input = input.segment.length - input_offset - n_written;

    self.vad_metadata.push(
        input.metadata,
        n_written,
    );

    if (!self.buffer.isFull()) {
        return WriteResult{
            .fft_result = null,
            .n_remaining_input = n_remaining_input,
        };
    }

    defer self.buffer.reset(input.segment.index + input_offset + n_written);
    try self.fft(self.buffer.segment, &self.temp_result);

    self.temp_result.index = self.buffer.segment.index;
    self.temp_result.vad_metadata = self.vad_metadata.toResult();

    self.vad_metadata = .{};
    return WriteResult{
        .fft_result = self.temp_result,
        .n_remaining_input = n_remaining_input,
    };
}

pub fn fft(
    self: *Self,
    segment: Segment,
    result: *Result,
) !void {
    const channels = segment.channel_pcm_buf;

    for (0..channels.len) |channel_idx| {
        const samples = channels[channel_idx];
        const result_bins = result.channel_bins[channel_idx];

        try self.fft_instance.fft(samples, self.window, self.complex_buffer);

        for (0..result_bins.len) |i| {
            result_bins[i] = self.complex_buffer[i].abs() * self.norm_factor;
        }
    }

    result.index = segment.index;
}

pub fn averageVolumeInBand(
    self: Self,
    result: *const Result,
    min_freq: f32,
    max_freq: f32,
    channel_results: []f32,
) !void {
    assert(result.channel_bins.len == channel_results.len);

    const min_bin = try self.fft_instance.freqToBin(min_freq);
    const max_bin = try self.fft_instance.freqToBin(max_freq);

    for (0..channel_results.len) |chan_idx| {
        channel_results[chan_idx] = 0.0;

        for (min_bin..max_bin + 1) |i| {
            channel_results[chan_idx] += result.channel_bins[chan_idx][i];
        }
    }
}
