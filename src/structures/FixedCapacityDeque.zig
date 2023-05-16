const std = @import("std");
const Allocator = std.mem.Allocator;

fn optUToI(unsigned: ?usize) ?isize {
    return if (unsigned) |u| @intCast(isize, u) else null;
}

fn uToI(u: usize) isize {
    return @intCast(isize, u);
}

fn iToU(i: isize) usize {
    return @intCast(usize, i);
}

pub fn FixedCapacityDeque(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        data: []T,
        head: ?usize = null,
        tail: ?usize = null,

        pub fn init(allocator: Allocator, max_capacity: usize) !Self {
            var data = try allocator.alloc(T, max_capacity);
            errdefer allocator.free(data);

            return Self{
                .allocator = allocator,
                .data = data,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.data);
        }

        pub fn pushBack(self: *Self, element: T) !void {
            if (self.remainingCapacity() == 0) {
                return error.Full;
            }

            const next_tail = @mod((self.tail orelse 0) + self.capacity() - 1, self.capacity());

            self.data[next_tail] = element;
            self.tail = next_tail;

            if (self.head == null) {
                self.head = self.tail;
            }
        }

        pub fn pushFront(self: *Self, element: T) !void {
            if (self.remainingCapacity() == 0) {
                return error.Full;
            }

            const next_head = @mod((self.head orelse 0) + 1, self.capacity());

            self.data[next_head] = element;
            self.head = next_head;

            if (self.tail == null) {
                self.tail = self.head;
            }
        }

        pub fn popBack(self: *Self) !T {
            const len = self.length();
            if (len == 0) {
                return error.Empty;
            }

            const el = self.data[self.tail.?];

            if (len == 1) {
                self.head = null;
                self.tail = null;
            } else {
                self.tail = (self.tail.? + 1) % self.capacity();
            }

            return el;
        }

        pub fn popFront(self: *Self) !T {
            const len = self.length();
            if (len == 0) {
                return error.Empty;
            }

            const el = self.data[self.head.?];

            if (len == 1) {
                self.head = null;
                self.tail = null;
            } else {
                const head_i = uToI(self.head.?);
                const capacity_i = uToI(self.capacity());
                const next_head_i = @mod(head_i - 1, capacity_i);
                self.head = iToU(next_head_i);
            }

            return el;
        }

        pub fn peekBack(self: *Self) !T {
            if (self.length() == 0) {
                return error.Empty;
            }

            return self.data[self.tail.?];
        }

        pub fn peekFront(self: *Self) !T {
            if (self.length() == 0) {
                return error.Empty;
            }

            return self.data[self.head.?];
        }

        pub fn capacity(self: *Self) usize {
            return self.data.len;
        }

        pub fn length(self: *Self) usize {
            return self.capacity() - self.remainingCapacity();
        }

        pub fn remainingCapacity(self: *Self) usize {
            if (self.head == null) {
                return self.data.len;
            }

            const head = @intCast(isize, self.head.?);
            const tail = @intCast(isize, self.tail.?);
            const cap = @intCast(isize, self.capacity());

            if (head >= tail) {
                return @intCast(usize, tail + cap - head - 1);
            } else {
                return @intCast(usize, tail - head - 1);
            }
        }

        pub fn nextHeadIndex(self: *Self) usize {
            _ = self;
        }
    };
}

//
// Tests
//

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const test_allocator = std.testing.allocator;

test "remainingCapacity - empty" {
    var deque = try FixedCapacityDeque(i32).init(test_allocator, 10);
    defer deque.deinit();

    deque.head = null;
    deque.tail = null;
    try expectEqual(deque.remainingCapacity(), 10);
}

test "remainingCapacity - head > tail" {
    var deque = try FixedCapacityDeque(i32).init(test_allocator, 10);
    defer deque.deinit();

    deque.head = 9;
    deque.tail = 0;
    // free indices: none
    try expectEqual(deque.remainingCapacity(), 0);

    deque.head = 8;
    deque.tail = 0;
    // free indices: #9
    try expectEqual(deque.remainingCapacity(), 1);

    deque.head = 8;
    deque.tail = 2;
    // free indices: #9, #0, #1
    try expectEqual(deque.remainingCapacity(), 3);

    deque.head = 9;
    deque.tail = 5;
    // free indices: #0, #1, #2, #3, #4
    try expectEqual(deque.remainingCapacity(), 5);
}

test "remainingCapacity - head = tail" {
    var deque = try FixedCapacityDeque(i32).init(test_allocator, 10);
    defer deque.deinit();

    deque.head = 9;
    deque.tail = 9;
    try expectEqual(deque.remainingCapacity(), 9);

    deque.head = 0;
    deque.tail = 0;
    try expectEqual(deque.remainingCapacity(), 9);

    deque.head = 5;
    deque.tail = 5;
    try expectEqual(deque.remainingCapacity(), 9);
}

test "remainingCapacity - head < tail" {
    var deque = try FixedCapacityDeque(i32).init(test_allocator, 10);
    defer deque.deinit();

    deque.head = 1;
    deque.tail = 3;
    // free indices: #2
    try expectEqual(deque.remainingCapacity(), 1);

    deque.head = 5;
    deque.tail = 6;
    // free indices: none
    try expectEqual(deque.remainingCapacity(), 0);

    deque.head = 3;
    deque.tail = 7;
    // free indices: #4, #5, #6
    try expectEqual(deque.remainingCapacity(), 3);
}

test "pushBack() - empty" {
    var deque = try FixedCapacityDeque(i32).init(test_allocator, 10);
    defer deque.deinit();

    try deque.pushBack(1);
    try expectEqual(deque.remainingCapacity(), 9);
}

test "pushBack() - filling" {
    var deque = try FixedCapacityDeque(i32).init(test_allocator, 3);
    defer deque.deinit();

    try deque.pushBack(999);
    try expectEqual(deque.remainingCapacity(), 2);

    try deque.pushBack(999);
    try expectEqual(deque.remainingCapacity(), 1);

    try deque.pushBack(999);
    try expectEqual(deque.remainingCapacity(), 0);

    try expectError(error.Full, deque.pushBack(999));
}

test "pushFront() - empty" {
    var deque = try FixedCapacityDeque(i32).init(test_allocator, 10);
    defer deque.deinit();

    try deque.pushFront(1);
    try expectEqual(deque.remainingCapacity(), 9);
}

test "pushFront() - filling" {
    var deque = try FixedCapacityDeque(i32).init(test_allocator, 3);
    defer deque.deinit();

    try deque.pushFront(999);
    try expectEqual(deque.remainingCapacity(), 2);

    try deque.pushFront(999);
    try expectEqual(deque.remainingCapacity(), 1);

    try deque.pushFront(999);
    try expectEqual(deque.remainingCapacity(), 0);

    try expectError(error.Full, deque.pushFront(999));
}

test "popFront() - empty" {
    var deque = try FixedCapacityDeque(i32).init(test_allocator, 10);
    defer deque.deinit();

    try expectError(error.Empty, deque.popFront());
}

test "popFront() - emptying" {
    var deque = try FixedCapacityDeque(i32).init(test_allocator, 10);
    defer deque.deinit();

    try deque.pushBack(10);
    try deque.pushBack(20);
    try deque.pushBack(30);

    try expectEqual(deque.popFront(), 10);
    try expectEqual(deque.popFront(), 20);
    try expectEqual(deque.popFront(), 30);
    try expectError(error.Empty, deque.popFront());
}

test "popBack() - empty" {
    var deque = try FixedCapacityDeque(i32).init(test_allocator, 10);
    defer deque.deinit();

    try expectError(error.Empty, deque.popBack());
}

test "popBack() - emptying" {
    var deque = try FixedCapacityDeque(i32).init(test_allocator, 10);
    defer deque.deinit();

    try deque.pushBack(10);
    try deque.pushBack(20);
    try deque.pushBack(30);

    try expectEqual(deque.popBack(), 30);
    try expectEqual(deque.popBack(), 20);
    try expectEqual(deque.popBack(), 10);
    try expectError(error.Empty, deque.popBack());
}


test "peekFront() - empty" {
    var deque = try FixedCapacityDeque(i32).init(test_allocator, 10);
    defer deque.deinit();

    try expectError(error.Empty, deque.peekFront());
}

test "peekFront() - filling" {
    var deque = try FixedCapacityDeque(i32).init(test_allocator, 10);
    defer deque.deinit();

    try expectError(error.Empty, deque.peekFront());

    try deque.pushBack(10);
    try expectEqual(deque.peekFront(), 10);

    try deque.pushBack(20);
    try expectEqual(deque.peekFront(), 10);

    try deque.pushBack(30);
    try expectEqual(deque.peekFront(), 10);

    try expectEqual(deque.length(), 3);
}

test "peekBack() - empty" {
    var deque = try FixedCapacityDeque(i32).init(test_allocator, 10);
    defer deque.deinit();

    try expectError(error.Empty, deque.peekBack());
}

test "peekBack() - filling" {
    var deque = try FixedCapacityDeque(i32).init(test_allocator, 10);
    defer deque.deinit();

    try expectError(error.Empty, deque.peekBack());

    try deque.pushBack(10);
    try expectEqual(deque.peekBack(), 10);

    try deque.pushBack(20);
    try expectEqual(deque.peekBack(), 20);

    try deque.pushBack(30);
    try expectEqual(deque.peekBack(), 30);

    try expectEqual(deque.length(), 3);
}