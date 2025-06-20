const std = @import("std");
const Tree = @import("tree.zig").Tree;
const expect = std.testing.expect;

pub fn main() !void {
    var debug = std.heap.DebugAllocator(.{}).init;
    const allocator = debug.allocator();
    defer _ = debug.deinit();

    var tree = Tree(u64, []const u8, comp).empty;
    defer tree.deinit(allocator);

    try tree.reserve(allocator, 1);
    tree.insert(.{ .key = 32, .value = "hello" });
    tree.insert(.{ .key = 31, .value = "hal" });
    tree.insert(.{ .key = 34, .value = "ho" });
}

fn comp(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}

test "emptylist" {
    const tree = Tree(u64, u64, comp).empty;

    try expect(tree.root_idx == 0xFFFFFFFF);
    try expect(tree.keys.capacity == 0);
    try expect(tree.keys.items.len == 0);

    try expect(tree.values.capacity == 0);
    try expect(tree.values.items.len == 0);

    try expect(tree.nodes.capacity == 0);
    try expect(tree.nodes.items.len == 0);
}

test "initCapacity" {
    const cap = 200000;
    const allocator = std.testing.allocator;
    var tree = try Tree(u64, u64, comp).initCapacity(allocator, cap);
    defer tree.deinit(allocator);

    try expect(tree.root_idx == 0xFFFFFFFF);
    try expect(tree.keys.capacity >= cap);
    try expect(tree.keys.items.len == 0);

    try expect(tree.values.capacity >= cap);
    try expect(tree.values.items.len == 0);

    try expect(tree.nodes.capacity >= cap);
    try expect(tree.nodes.items.len == 0);
}

test "ascending inputs inputs" {
    const allocator = std.testing.allocator;
    const inputs = [_]u64{ 0, 5, 10, 15, 20, 25, 30, 35, 40 };

    var tree = try Tree(u64, u64, comp).initCapacity(allocator, inputs.len);
    defer tree.deinit(allocator);

    tree.insert(.{ .key = inputs[0], .value = inputs[0] * 10 });

    for (inputs[1..]) |i| {
        tree.insert(.{ .key = i, .value = i * 10 });
    }

    try expect(true);
}

test "descending inputs" {
    const allocator = std.testing.allocator;
    const inputs = [_]u64{ 40, 35, 30, 25, 20, 15, 10, 5 };

    var tree = try Tree(u64, u64, comp).initCapacity(allocator, inputs.len);
    defer tree.deinit(allocator);

    tree.insert(.{ .key = inputs[0], .value = inputs[0] * 10 });

    for (inputs[1..]) |i| {
        tree.insert(.{ .key = i, .value = i * 10 });
    }
}

test "tricky inputs" {
    const allocator = std.testing.allocator;
    const inputs = [_]u64{ 10, 20, 30, 15, 5, 22, 28, 12 };

    var tree = try Tree(u64, u64, comp).initCapacity(allocator, inputs.len);
    defer tree.deinit(allocator);

    tree.insert(.{ .key = inputs[0], .value = inputs[0] * 10 });

    for (inputs[1..]) |i| {
        tree.insert(.{ .key = i, .value = i * 10 });
    }
}
