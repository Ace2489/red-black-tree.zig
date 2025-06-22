const std = @import("std");
const Tree = @import("tree.zig").Tree;
const expect = std.testing.expect;
const zbench = @import("zbench");

pub fn main() !void {
    var debug = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = debug.allocator();
    defer _ = debug.deinit();

    // var bench = zbench.Benchmark.init(allocator, .{});

    // defer bench.deinit();

    // try bench.add("Insertions array list", tree_list, .{ .iterations = 150 });
    // try bench.add("Insertions", rbTree, .{ .iterations = 150 });

    // try bench.run(std.io.getStdOut().writer());

    var tree = Tree(u64, []const u8, comp).empty;
    defer tree.deinit(allocator);

    try tree.reserve(allocator, 1);
    tree.insert(.{ .key = 32, .value = "hello" });
    tree.insert(.{ .key = 31, .value = "hal" });
    tree.insert(.{ .key = 34, .value = "ho" });
    //

}

fn comp(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}

fn rbTree(allocator: std.mem.Allocator) void {
    const len = 200000;
    var tree = Tree(u64, u64, comp).initCapacity(allocator, len) catch unreachable;
    defer tree.deinit(allocator);

    for (0..len) |i| {
        tree.insert(.{ .key = i, .value = i });
    }
}

//The theoretical maximum that is achievable for this tree
fn tree_list(allocator: std.mem.Allocator) void {
    const len = 100000;

    const NULL_IDX = 0xffffffff;
    const Node = struct { right: u32, val: u64 };
    var list = std.ArrayListUnmanaged(Node).initCapacity(allocator, len) catch unreachable;

    list.appendAssumeCapacity(Node{ .right = NULL_IDX, .val = 0 });
    var node_ptr = &list.items[0];

    for (1..len) |i| {
        list.appendAssumeCapacity(Node{ .right = NULL_IDX, .val = i });
        node_ptr.*.right = @truncate(i);
        node_ptr = &list.items[i];
    }
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

    // std.debug.print("Ouptut: {}\n{}", .{ tree.nodes, tree.keys });
}
