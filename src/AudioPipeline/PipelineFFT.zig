const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const FFT = @import("../FFT.zig");
const window_fn = @import("../audio_utils/window_fn.zig");
const AudioPipeline = @import("../AudioPipeline.zig");
const SplitSlice = @import("../structures/SplitSlice.zig");
const Segment = @import("./Segment.zig");

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

    pub fn init(allocator: Allocator, n_channels: usize, fft_size: usize, n_bins: usize) !Result {
        var channel_bins = try allocator.alloc([]f32, n_channels);
        var bins_initialized: usize = 0;
        errdefer {
            for (0..bins_initialized) |i| {
                allocator.free(channel_bins[i]);
            }
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
        };
    }

    pub fn deinit(self: *Result) void {
        for (0..self.channel_bins.len) |i| {
            self.allocator.free(self.channel_bins[i]);
        }
        self.allocator.free(self.channel_bins);
    }
};

allocator: Allocator,
config: Config,
fft_instance: FFT,
window: []const f32,

pub fn init(allocator: Allocator, config: Config) !Self {
    var fft_instance_ = try FFT.init(allocator, config.fft_size, config.sample_rate);
    errdefer fft_instance_.deinit();

    var window = try allocator.alloc(f32, config.fft_size);
    errdefer allocator.free(window);
    window_fn.hannWindowPeriodic(window);

    const hop_size = if (config.hop_size > 0) config.hop_size else config.fft_size;

    var self = Self{
        .allocator = allocator,
        .config = config,
        .fft_instance = fft_instance_,
        .window = window,
    };
    self.config.hop_size = hop_size;

    return self;
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.window);
    self.fft_instance.deinit();
}

pub fn fft(self: *Self, segment: Segment) !Result {
    const channels = segment.channel_pcm_buf;

    var result = try Result.init(
        self.allocator,
        channels.len,
        self.config.fft_size,
        self.fft_instance.binCount(),
    );
    errdefer result.deinit();


    for (0..channels.len) |channel_idx| {
        const samples = channels[channel_idx];
        try self.fft_instance.fft(samples, self.window, result.channel_bins[channel_idx]);
    }
    
    result.index = segment.index;

    return result;
}

pub fn averageVolumeInBand(self: Self, result: Result, min_freq: f32, max_freq: f32, channel_results: []f32) !void {
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
