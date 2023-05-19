const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub fn CreateFn(comptime T: type, comptime CreateArg: type) type {
    return fn (allocator: Allocator, arg: CreateArg) Allocator.Error!T;
}

pub fn DirtyMemPool(
    comptime T: type,
    comptime CreateArg: type,
    comptime create_fn: CreateFn(T, CreateArg),
) type {
    return struct {
        const Node = struct {
            data: T,
            next: ?*Node,
        };
        const Self = @This();

        arena: ArenaAllocator,
        head: ?*Node,
        remaining: usize = 0,
        create_arg: CreateArg,

        pub fn init(child_allocator: Allocator, arg: CreateArg) !Self {
            var self = Self{
                .arena = ArenaAllocator.init(child_allocator),
                .head = null,
                .create_arg = arg,
            };

            var first = try self.create();
            self.head = first;

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.head = null;
            self.arena.deinit();
        }

        pub fn acquire(self: *Self) !*T {
            if (self.head) |head| {
                self.head = head.next;
                head.next = null;

                self.remaining += 1;
                return &head.data;
            } else {
                const node = try self.create();

                self.remaining += 1;
                return &node.data;
            }
        }

        pub fn release(self: *Self, item: *T) void {
            var node: *Node = @fieldParentPtr(Node, "data", item);
            node.next = self.head;
            self.head = node;
            self.remaining -= 1;
        }

        fn create(self: *Self) !*Node {
            var allocator = self.arena.allocator();

            const node = try allocator.create(Node);
            errdefer allocator.destroy(node);

            var data: T = try create_fn(allocator, self.create_arg);

            node.* = Node{
                .data = data,
                .next = null,
            };

            return node;
        }
    };
}

test "DirtyMemPool" {
    const t = std.testing;
    const MyType = struct {
        id: u32 = 0,
        slice: []f32,

        pub fn create(allocator: Allocator, len: usize) !@This() {
            var slice = try allocator.alloc(f32, len);

            return @This(){
                .slice = slice,
            };
        }
    };

    var pool = try DirtyMemPool(MyType, usize, MyType.create).init(t.allocator, 10);
    defer pool.deinit();

    var item1: *MyType = try pool.acquire();
    try t.expectEqual(item1.slice.len, 10);
    try t.expectEqual(item1.id, 0);
    item1.id = 999;

    var item2: *MyType = try pool.acquire();
    try t.expectEqual(item2.slice.len, 10);
    try t.expectEqual(item2.id, 0);
    item2.id = 123;

    try t.expectEqual(pool.remaining, 2);

    pool.release(item1);
    pool.release(item2);

    try t.expectEqual(pool.remaining, 0);

    var reacquired: *MyType = undefined;
    reacquired = try pool.acquire();
    try t.expectEqual(reacquired.id, 123);

    reacquired = try pool.acquire();
    try t.expectEqual(reacquired.id, 999);

    reacquired = try pool.acquire();
    try t.expectEqual(reacquired.id, 0);

    try t.expectEqual(pool.remaining, 3);
}
