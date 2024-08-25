const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub fn CreateFn(comptime T: type, comptime TCreateArg: type) type {
    return fn (allocator: Allocator, create_arg: TCreateArg) Allocator.Error!T;
}

pub fn ObjectPool(comptime T: type, comptime TCreateArg: type) type {
    return struct {
        const Node = struct {
            data: T,
            next: ?*Node,
        };
        const Self = @This();

        arena: ArenaAllocator,
        head: ?*Node,
        create_fn: *const CreateFn(T, TCreateArg),
        create_arg: ?TCreateArg,
        /// Number of objects that haven't been released yet
        to_be_released: usize = 0,

        pub fn init(
            child_allocator: Allocator,
            create_fn: *const CreateFn(T, TCreateArg),
            create_arg: ?TCreateArg,
        ) !*Self {
            var arena = ArenaAllocator.init(child_allocator);

            const self = try arena.allocator().create(Self);
            self.* = Self{
                .arena = arena,
                .head = null,
                .create_fn = create_fn,
                .create_arg = create_arg,
            };
            self.arena = arena;

            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.to_be_released > 0) {
                std.debug.print(
                    "Object Pool at {*} had {d} unreleased objects during deinit()\n",
                    .{ self, self.to_be_released },
                );
            }
            self.head = null;
            self.arena.deinit();
        }

        pub fn acquire(self: *Self) !*T {
            if (self.head) |head| {
                self.head = head.next;
                head.next = null;

                self.to_be_released += 1;
                return &head.data;
            } else {
                const node = try self.create();

                self.to_be_released += 1;
                return &node.data;
            }
        }

        pub fn release(self: *Self, item: *T) void {
            var node: *Node = @fieldParentPtr("data", item);
            node.next = self.head;
            self.head = node;
            self.to_be_released -= 1;
        }

        fn create(self: *Self) !*Node {
            if (self.create_arg) |create_arg| {
                var allocator = self.arena.allocator();

                const node = try allocator.create(Node);
                errdefer allocator.destroy(node);

                const data: T = try self.create_fn(allocator, create_arg);

                node.* = Node{
                    .data = data,
                    .next = null,
                };
                return node;
            } else {
                return error.MissingCreateArg;
            }
        }
    };
}

test "ObjectPool" {
    const t = std.testing;
    const MyType = struct {
        id: u32 = 0,
        slice: []f32,

        pub fn create(allocator: Allocator, len: usize) !@This() {
            const slice = try allocator.alloc(f32, len);

            return @This(){
                .slice = slice,
            };
        }
    };

    var pool = try ObjectPool(MyType, usize).init(t.allocator, &MyType.create, 10);
    defer pool.deinit();

    var item1: *MyType = try pool.acquire();
    try t.expectEqual(item1.slice.len, 10);
    try t.expectEqual(item1.id, 0);
    item1.id = 999;

    var item2: *MyType = try pool.acquire();
    try t.expectEqual(item2.slice.len, 10);
    try t.expectEqual(item2.id, 0);
    item2.id = 123;

    try t.expectEqual(pool.to_be_released, 2);

    pool.release(item1);
    pool.release(item2);

    try t.expectEqual(pool.to_be_released, 0);

    const a = try pool.acquire();
    try t.expectEqual(a.id, 123);

    const b = try pool.acquire();
    try t.expectEqual(b.id, 999);

    const c = try pool.acquire();
    try t.expectEqual(c.id, 0);

    try t.expectEqual(pool.to_be_released, 3);

    pool.release(a);
    pool.release(b);
    pool.release(c);
}
