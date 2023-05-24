const std = @import("std");
const Allocator = std.mem.Allocator;
const websocket = @import("websocket");
const zbor = @import("zbor");
const AudioPipeline = @import("./AudioPipeline.zig");

pub fn start(allocator: Allocator) !void {
    var context = Context{
        .child_allocator = allocator,
    };

    const config = websocket.Config{
        .address = "0.0.0.0",
        .port = 9888,
        .max_size = 1024 * 1024,
        .buffer_size = 1024 * 64,
    };

    std.log.info("Starting server on {s}:{d}", .{ config.address, config.port });
    try websocket.listen(WebsocketHandler, allocator, &context, config);
    std.log.info("Server exiting", .{});
}

const Context = struct {
    child_allocator: std.mem.Allocator,
};

const AudioFrame = struct {
    pcm: []const []const f32,
    // metadata: @TypeOf(null),
};

const WebsocketHandler = struct {
    const Self = @This();
    client: *websocket.Client,
    context: *Context,
    arena: std.heap.ArenaAllocator = undefined,
    pipeline: *AudioPipeline,

    pub fn init(h: websocket.Handshake, client: *websocket.Client, context: *Context) !Self {
        // `h` contains the initial websocket "handshake" request
        // It can be used to apply application-specific logic to verify / allow
        // the connection (e.g. valid url, query string parameters, or headers)
        std.log.debug("Client connected", .{});

        _ = h; // we're not using this in our simple case

        var self = Self{
            .client = client,
            .context = context,
            .pipeline = undefined,
        };

        self.arena = std.heap.ArenaAllocator.init(context.child_allocator);

        // Demo/Testing: Create a new AudioPipeline
        self.pipeline = try AudioPipeline.init(
            context.child_allocator,
            .{
                .n_channels = 2,
                .sample_rate = 48000,
            },
            null,
        );

        return self;
    }

    pub fn handle(self: *Self, message: websocket.Message) !void {
        var allocator = self.arena.allocator();
        var stdout = std.io.getStdOut().writer();

        defer {
            _ = self.arena.reset(.retain_capacity);
        }

        var cbor_data = zbor.DataItem.new(message.data) catch |err| {
            try stdout.print("CBOR decode error: {any}\n", .{err});
            return;
        };

        var parsed = zbor.parse(
            AudioFrame,
            cbor_data,
            zbor.ParseOptions{
                .allocator = allocator,
                .ignore_unknown_fields = true,
            },
        ) catch |err| {
            // Resolved issue: Parsing failed when array contained 0-value samples
            // JS implementation (cborg) was encoding 0-value samples as integers
            // instead of floats
            const trace = @errorReturnTrace();
            try stdout.print("CBOR parse error: {any}\n{any}\n{any}", .{ err, cbor_data, trace });
            return;
        };

        // Demo/Testing: Push the samples to the pipeline
        _ = try self.pipeline.pushSamples(parsed.pcm);

        // try stdout.print("Client ({any}):\n{any}\n", .{ message.type, parsed });
    }

    pub fn close(self: *Self) void {
        self.pipeline.deinit();
        self.arena.deinit();
    }
};
