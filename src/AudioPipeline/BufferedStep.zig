const std = @import("std");
const builtin = @import("builtin");
const Segment = @import("./Segment.zig");
const VADMetadata = @import("./VADMetadata.zig");
const SegmentWriter = @import("./SegmentWriter.zig");

pub const Result = struct {
    segment: *const Segment,
    metadata: VADMetadata.Result,
};

pub const AudioConfig = struct {
    expect_output: bool = true,
    buffer_size: usize,
    in_channels: usize,
    out_channels: usize,
    in_sample_rate: usize,
    out_sample_rate: usize,
};

/// Encapsulates a generic processor (pointer to `process` function + context pointer) attached to a BufferedStep.
pub const Processor = struct {
    ctx: *anyopaque,
    fun: *const processFnType(*anyopaque),

    /// Creates a generic Processor for given callback context.
    ///
    /// Context must be a pointer to a container with suitable `process` function, accepting the `context` and
    /// `BufferedStep.Result` as an argument and returning `BufferedStep.Result`.
    ///
    /// `process` function must accurately track `Segment.index` in its output.
    pub fn forContext(ctx: anytype) Processor {
        comptime var err: []const u8 = "Context must be a pointer to a container with suitable `process` function.";

        // Check that the context is a pointer
        const ctx_info = @typeInfo(@TypeOf(ctx));
        if (ctx_info != .Pointer) @compileError(err);

        // Extract the type it's pointing to
        const ChildType = ctx_info.Pointer.child;

        // Define what the the `process` function is supposed to look like
        const ExpectedProcessFn = processFnType(*ChildType);
        err = "Context must be a pointer to a container with suitable `process` function.\nExpected: " ++
            @typeName(ExpectedProcessFn);

        // Verify that the type is a container with a `process` function
        if (!@hasDecl(ChildType, "process")) @compileError(err);
        const ActualProcessFn = @TypeOf(ChildType.process);

        err = "Context must be a pointer to a container with suitable `process` function.\nExpected: " ++
            @typeName(ExpectedProcessFn) ++ "\nProvided: " ++ @typeName(ActualProcessFn);

        // Verify that the type of the process function is a match
        if (ExpectedProcessFn != ActualProcessFn) {
            @compileError(err);
        }

        const ctx_opaque: *anyopaque = @ptrCast(ctx);
        const fun_opaque: *const processFnType(*anyopaque) = @ptrCast(&ChildType.process);

        return Processor{
            .ctx = ctx_opaque,
            .fun = fun_opaque,
        };
    }

    pub inline fn call(
        self: *const Processor,
        result: *const Result,
    ) *const Result {
        return self.fun(self.ctx, result);
    }

    fn processFnType(CtxType: type) type {
        const ctx_info = @typeInfo(CtxType);

        if (ctx_info != .Pointer) {
            @compileError("CtxType must be a pointer, but it's " ++ @typeName(ctx_info));
        }

        return fn (ctx: CtxType, prev_result: *const Result) *const Result;
    }
};

const Self = @This();

name: []const u8,
allocator: std.mem.Allocator,
buffer_writer: SegmentWriter,
buffer_metadata: VADMetadata = .{},
last_out_index: if (builtin.mode == .Debug) ?u64 else ?void = null,
audio_config: AudioConfig,
processor: Processor,
prev: ?*Self = null,
next: ?*Self = null,

pub fn init(
    allocator: std.mem.Allocator,
    name: []const u8,
    audio_config: AudioConfig,
    processor: Processor,
) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const buffer_writer = try SegmentWriter.init(
        allocator,
        audio_config.in_channels,
        audio_config.buffer_size,
    );
    errdefer buffer_writer.deinit();

    self.* = .{
        .name = name,
        .allocator = allocator,
        .buffer_writer = buffer_writer,
        .audio_config = audio_config,
        .processor = processor,
    };

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.next) |n| n.prev = null;
    if (self.prev) |p| p.next = null;

    self.buffer_writer.deinit();
    self.allocator.destroy(self);
}

/// Write data to the current `BufferedStep`, calling the processor when the buffer is filled,
/// and forwarding the result to the next following step (if connected)
///
/// *Caller owns the memory associated with `prev_result` passed to this function!*
///
/// It's imperative the the caller tracks the sample index contained in `Segment.index` correctly.
/// `prev_result.segment.index` should increase by previous `prev_result.segment.length` between calls
pub fn write(self: *Self, prev_result: *const Result) !void {
    if (self.next == null and self.audio_config.expect_output) {
        std.debug.panic("BufferedStep '{s}' doesn't have an expected output connected", .{self.name});
    }

    if (prev_result.segment.length() == 0) return;

    var total_written: usize = 0;
    while (true) {
        // TODO: We could bypass the buffer when input exactly matches the required size and our buffer is otherwise empty
        const n_written = try self.buffer_writer.write(prev_result.segment, total_written);
        total_written += n_written;

        self.buffer_metadata.push(prev_result.metadata, n_written);

        if (self.buffer_writer.isFull()) {
            // Result of this buffering step
            const buffer_metadata = self.buffer_metadata.toResult();
            const processor_input = Result{
                .metadata = buffer_metadata,
                .segment = &self.buffer_writer.segment_view,
            };

            // Process the input buffer
            const processor_result = self.processor.call(&processor_input);

            // Extra sanity checks in debug mode to ensure buffered steps are handling data correctly
            if (builtin.mode == .Debug) {
                const last_out = self.last_out_index;
                const this_out = processor_result.segment.index;

                // Correct handling of Segment indices
                if (last_out != null and last_out.? == this_out) {
                    std.debug.panic(
                        "BufferedStep processor '{s}' didn't increment the segment index of its output. Last seen index: {d}",
                        .{ self.name, self.last_out_index.? },
                    );
                }

                // Correct handling of metadata
                const empty_metadata = VADMetadata.Result{};
                const had_metadata = !std.meta.eql(buffer_metadata, empty_metadata);
                const has_metadata = !std.meta.eql(processor_result.metadata, empty_metadata);
                if (had_metadata and !has_metadata) {
                    std.debug.panic(
                        "BufferedStep processor '{s}' dropped all metadata at index {d}.",
                        .{ self.name, processor_input.segment.index },
                    );
                }

                // Correct number of channels
                if (processor_result.segment.nChannels() != self.audio_config.out_channels) {
                    std.debug.panic(
                        "BufferedStep processor '{s}' returned an invalid number of channels. Expected: {d}, Received: {d}.",
                        .{ self.name, self.audio_config.out_channels, processor_result.segment.nChannels() },
                    );
                }

                self.last_out_index = processor_result.segment.index;
            }

            // Pass processed output to the next step
            if (self.next) |next| {
                try next.write(processor_result);
            }

            // Reset our buffer, it's imperative that previous steps set the correct segment index
            const next_sample_index = prev_result.segment.index + total_written;
            self.buffer_writer.reset(next_sample_index);
            self.buffer_metadata = .{};
        }

        if (total_written == prev_result.segment.length()) {
            break;
        } else if (total_written > prev_result.segment.length()) {
            @setCold(true);
            std.debug.panic(
                "BufferedStep '{s}' wrote more samples ({d}) than the input ({d})",
                .{ self.name, total_written, prev_result.segment.length() },
            );
        } else {
            // left empty, we haven't written our full input to the buffer yet
        }
    }
}

/// Returns the sample rate multiplier of this node relative to the first node (the root)
pub fn rootSampleRateMultiplier(self: *const Self) f64 {
    var mul: f64 = 1;
    var maybe_step: ?*const Self = self;

    while (maybe_step) |step| {
        const this_in: f64 = @floatFromInt(step.audio_config.in_sample_rate);
        const this_out: f64 = @floatFromInt(step.audio_config.out_sample_rate);
        const this_mul = this_out / this_in;
        mul *= this_mul;
        maybe_step = step.prev;
    }

    return mul;
}

const IndexRange = struct {
    /// **Inclusive**
    from: usize,
    /// **Exclusive**
    to: usize,
};
/// Converts sample index number at the current step to root sample index (before resampling transformations)
pub fn convertSampleIndexToRoot(self: *const Self, index: usize) IndexRange {
    const sr_mul = self.rootSampleRateMultiplier();
    const index_f: f64 = @floatFromInt(index);

    return IndexRange{
        .from = @intFromFloat(index_f / sr_mul),
        .to = @intFromFloat((index_f + 1) / sr_mul),
    };
}

pub fn connectTo(self: *Self, other: *Self) !void {
    const our_config = self.audio_config;
    const their_config = other.audio_config;

    if (!self.audio_config.expect_output) {
        return error.UnexpectedOutput;
    }

    if (self.next != null) {
        return error.OutputAlreadyConnected;
    }

    if (other.prev != null) {
        return error.InputAlreadyConnected;
    }

    if (our_config.out_channels != their_config.in_channels) {
        return error.ChannelCountMismatch;
    }

    if (our_config.out_sample_rate != their_config.in_sample_rate) {
        return error.SampleRateMismatch;
    }

    self.next = other;
    other.prev = self;
}

// downmixes stereo to mono, resamples (twice) and doubles every sample
test "BufferedStep chain" {
    const allocator = std.testing.allocator;

    //
    // Downmixer, downmixes with simple average of 2 channels
    //
    const Downmixer = struct {
        allocator: std.mem.Allocator,
        out_segment: Segment,
        out_result: Result,
        test_samples: std.ArrayList(f32),
        test_indices: std.ArrayList(usize),

        pub fn init(alloc: std.mem.Allocator) !*@This() {
            var self = try alloc.create(@This());

            self.* = .{
                .allocator = alloc,
                // Number of channels and length (buffer size) must match BufferedStep definition below
                .out_segment = try Segment.initWithCapacity(alloc, 1, 2),
                .out_result = .{
                    .metadata = .{},
                    .segment = &self.out_segment,
                },
                .test_samples = std.ArrayList(f32).init(allocator),
                .test_indices = std.ArrayList(usize).init(allocator),
            };

            return self;
        }

        pub fn deinit(self: *@This()) void {
            self.out_segment.deinit();
            self.test_samples.deinit();
            self.test_indices.deinit();
            self.allocator.destroy(self);
        }

        pub fn process(self: *@This(), prev_result: *const Result) *const Result {
            const in_channels = prev_result.segment.channel_pcm_buf;
            const out_channel = self.out_segment.writablePCM()[0];

            const test_samples_slice = self.test_samples.addManyAsSlice(out_channel.len) catch @panic("nooo");

            for (0..prev_result.segment.length()) |i_sample| {
                var sum: f32 = 0;
                for (0..in_channels.len) |i_chan| {
                    sum += in_channels[i_chan][i_sample];
                }
                const n_channels_f: f32 = @floatFromInt(in_channels.len);
                const out_val: f32 = sum / n_channels_f;

                out_channel[i_sample] = out_val;
                // capture output for testing
                test_samples_slice[i_sample] = out_channel[i_sample];
            }

            self.out_result.metadata = prev_result.metadata;
            self.out_segment.index = prev_result.segment.index;

            // capture output for testing
            const out_index = self.test_indices.addOne() catch @panic("nooo");
            out_index.* = self.out_segment.index;

            return &self.out_result;
        }
    };

    //
    // Resampler, keeps every `n`-th sample (configurable)
    //
    const Resampler = struct {
        name: []const u8,
        allocator: std.mem.Allocator,
        out_segment: Segment,
        out_result: Result,
        downsample_rate: usize,
        test_samples: std.ArrayList(f32),
        test_indices: std.ArrayList(usize),

        pub fn init(
            alloc: std.mem.Allocator,
            name: []const u8,
            /// only used for verifying that the downsampling rate makes sense
            in_buffer_size: usize,
            downsample_rate: usize,
        ) !*@This() {
            const out_buffer_size = try std.math.divExact(usize, in_buffer_size, downsample_rate);

            var self = try alloc.create(@This());

            self.* = .{
                .allocator = alloc,
                .name = name,
                // Number of channels and length (buffer size) must match BufferedStep definition below
                // This is a resampler that skips every other sample, so `out_length` must be half of `in_length`
                .out_segment = try Segment.initWithCapacity(alloc, 1, out_buffer_size),
                .out_result = .{
                    .metadata = .{},
                    .segment = &self.out_segment,
                },
                .test_samples = std.ArrayList(f32).init(allocator),
                .test_indices = std.ArrayList(usize).init(allocator),
                .downsample_rate = downsample_rate,
            };

            return self;
        }

        pub fn deinit(self: *@This()) void {
            self.out_segment.deinit();
            self.test_samples.deinit();
            self.test_indices.deinit();
            self.allocator.destroy(self);
        }

        pub fn process(
            self: *@This(),
            prev_result: *const Result,
        ) *const Result {
            const in_slice = prev_result.segment.channel_pcm_buf[0];
            const out_slice = self.out_segment.writablePCM()[0];

            const test_samples_slice = self.test_samples.addManyAsSlice(out_slice.len) catch @panic("nooo");

            for (0..out_slice.len) |i| {
                out_slice[i] = in_slice[i * self.downsample_rate];
                // capture output for testing
                test_samples_slice[i] = out_slice[i];
            }
            self.out_result.metadata = prev_result.metadata;
            self.out_segment.index = std.math.divExact(usize, @intCast(prev_result.segment.index), self.downsample_rate) catch {
                @panic("impossible (checked in init)");
            };

            // capture output for testing
            const out_index = self.test_indices.addOne() catch @panic("nooo");
            out_index.* = self.out_segment.index;

            return &self.out_result;
        }
    };

    //
    // Doubler, doubles the value of each sample
    //
    const Doubler = struct {
        allocator: std.mem.Allocator,
        out_segment: Segment,
        out_result: Result,
        test_samples: std.ArrayList(f32),
        test_indices: std.ArrayList(usize),

        pub fn init(
            alloc: std.mem.Allocator,
        ) !*@This() {
            var self = try alloc.create(@This());

            self.* = .{
                .allocator = alloc,
                // Number of channels and length (buffer size) must match BufferedStep definition below
                .out_segment = try Segment.initWithCapacity(alloc, 1, 1),
                .out_result = .{
                    .metadata = .{},
                    .segment = &self.out_segment,
                },
                .test_samples = std.ArrayList(f32).init(allocator),
                .test_indices = std.ArrayList(usize).init(allocator),
            };

            return self;
        }

        pub fn deinit(self: *@This()) void {
            self.out_segment.deinit();
            self.test_samples.deinit();
            self.test_indices.deinit();
            self.allocator.destroy(self);
        }

        pub fn process(
            self: *@This(),
            prev_result: *const Result,
        ) *const Result {
            if (prev_result.segment.channel_pcm_buf.len > 1) {
                @panic("Doubler received invalid number of channels");
            }

            const in_slice = prev_result.segment.channel_pcm_buf[0];
            const out_slice = self.out_segment.writablePCM()[0];

            // capture output for testing
            const test_samples_slice = self.test_samples.addManyAsSlice(out_slice.len) catch @panic("nooo");

            for (0..in_slice.len) |i| {
                out_slice[i] = in_slice[i] * 2;
                // capture output for testing
                test_samples_slice[i] = out_slice[i];
            }
            self.out_result.metadata = prev_result.metadata;
            self.out_segment.index = prev_result.segment.index;

            // capture output for testing
            const out_index = self.test_indices.addOne() catch @panic("nooo");
            out_index.* = self.out_segment.index;

            return &self.out_result;
        }
    };

    //
    // Initializing steps
    //

    // Downmixer
    var downmixer = try Downmixer.init(allocator);
    defer downmixer.deinit();

    const downmixer_step = try Self.init(
        allocator,
        "downmixer",
        .{
            .buffer_size = 2,
            .in_channels = 2,
            .out_channels = 1,
            .in_sample_rate = 16,
            .out_sample_rate = 16,
            .expect_output = true,
        },
        Processor.forContext(downmixer),
    );
    defer downmixer_step.deinit();

    // Resampler 1
    var resampler_1 = try Resampler.init(allocator, "resampler 1", 2, 2);
    defer resampler_1.deinit();

    const resampler_step_1 = try Self.init(
        allocator,
        "resampler 1",
        .{
            .buffer_size = 2,
            .in_channels = 1,
            .out_channels = 1,
            .in_sample_rate = 16,
            .out_sample_rate = 8,
            .expect_output = true,
        },
        Processor.forContext(resampler_1),
    );
    defer resampler_step_1.deinit();

    // Resampler 2
    var resampler_2 = try Resampler.init(allocator, "resampler 2", 4, 2);
    defer resampler_2.deinit();

    const resampler_step_2 = try Self.init(
        allocator,
        "resampler 2",
        .{
            .buffer_size = 4,
            .in_channels = 1,
            .out_channels = 1,
            .in_sample_rate = 8,
            .out_sample_rate = 4,
            .expect_output = true,
        },
        Processor.forContext(resampler_2),
    );
    defer resampler_step_2.deinit();

    // Doubler
    var doubler = try Doubler.init(allocator);
    defer doubler.deinit();

    const doubler_step = try Self.init(
        allocator,
        "doubler",
        .{
            .buffer_size = 1,
            .in_channels = 1,
            .out_channels = 1,
            .in_sample_rate = 4,
            .out_sample_rate = 4,
            .expect_output = false,
        },
        Processor.forContext(doubler),
    );
    defer doubler_step.deinit();

    //
    // Wiring it all together
    //

    try downmixer_step.connectTo(resampler_step_1);
    try resampler_step_1.connectTo(resampler_step_2);
    try resampler_step_2.connectTo(doubler_step);

    // Input data

    var in_segment = try Segment.initWithCapacity(allocator, 2, 8);
    defer in_segment.deinit();
    const in_left = in_segment.writablePCM()[0];
    const in_right = in_segment.writablePCM()[1];

    @memcpy(in_left, &[_]f32{ 0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7 });
    @memcpy(in_right, &[_]f32{ 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9 });

    const input = Result{
        .metadata = .{
            .volume_ratio = 0.1,
        },
        .segment = &in_segment,
    };

    // Run pipeline

    try downmixer_step.write(&input);
    in_segment.index += in_segment.length();
    try downmixer_step.write(&input);

    // Check results - pattern of samples is repeated twice because we wrote the same input twice
    // 1. channels are averaged
    //    -> 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, ... (repeated)
    // 2. stream is resampled, dropping every other sample
    //    -> 0.1, 0.3, 0.5, 0.7, ... (repeated)
    // 3. stream is resampled, dropping every other sample
    //    -> 0.1, 0.5, ... (repeated)
    // 4. each sample is doubled
    //    -> 0.2, 1, ... (repeated)
    const expected_output_samples: []const f32 = &.{ 0.2, 1, 0.2, 1 };
    for (0..expected_output_samples.len) |i| {
        try std.testing.expectApproxEqAbs(expected_output_samples[i], doubler.test_samples.items[i], 0.00001);
    }
    // std.debug.print("{d}\n", .{output_samples.items});

    // indices at final step should be relative to its own input
    const expected_output_indices: []const usize = &.{ 0, 1, 2, 3 };
    try std.testing.expectEqualSlices(usize, expected_output_indices, doubler.test_indices.items);
    // std.debug.print("{d}\n", .{output_indices.items});

    // test sample rate multiplier at final step, we halved the sample rate twice
    try std.testing.expectApproxEqAbs(0.5 * 0.5, doubler_step.rootSampleRateMultiplier(), 0.000001);
    // std.debug.print("{d}\n", .{doubler_step.rootSampleRateMultiplier()});

    // test conversion of sample indices at final step to root indices
    const sample_range_at_final_step = doubler_step.convertSampleIndexToRoot(3);
    try std.testing.expectEqual(IndexRange{ .from = 12, .to = 16 }, sample_range_at_final_step);
    // std.debug.print("{any}\n", .{sample_range_at_final_step});
}
