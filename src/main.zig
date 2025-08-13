const std = @import("std");
const RBTree = @import("tree.zig");
const Tree = RBTree.Tree;
const expect = std.testing.expect;
const zbench = @import("zbench");
const NULL_IDX = RBTree.NULL_IDX;
const MAX_IDX = RBTree.MAX_IDX;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var bench = zbench.Benchmark.init(allocator, .{});

    defer bench.deinit();

    try bench.add("Insertions array list", tree_list, .{ .iterations = 150 });
    try bench.add("Insertions", rbTree, .{ .iterations = 150 });

    try bench.run(std.io.getStdOut().writer());
}

fn comp(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}

fn rbTree(allocator: std.mem.Allocator) void {
    const len = NULL_IDX;
    var tree = Tree(u64, u64, comp).initCapacity(allocator, len) catch unreachable;
    defer tree.deinit(allocator);
    var Xosh = std.Random.Xoshiro256.init(64);
    const random = Xosh.random();

    var list = std.ArrayListUnmanaged(u64).initCapacity(allocator, len) catch unreachable;

    for (0..len) |i| {
        list.appendAssumeCapacity(i);
    }

    random.shuffle(u64, list.items);

    for (list.items) |i| {
        tree.insertAssumeCapacity(.{ .key = i, .value = i }) catch unreachable;
    }
}

//The theoretical maximum that is achievable for this tree
fn tree_list(allocator: std.mem.Allocator) void {
    const len = 100000;

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

    try expect(tree.root_idx == NULL_IDX);
    try expect(tree.keys.capacity == 0);
    try expect(tree.keys.items.len == 0);

    try expect(tree.values.capacity == 0);
    try expect(tree.values.items.len == 0);

    try expect(tree.nodes.capacity == 0);
    try expect(tree.nodes.items.len == 0);

    try expect(tree.colours.capacity() == 0);
}

test "initCapacity" {
    const cap = 200000;
    const allocator = std.testing.allocator;
    var tree = try Tree(u64, u64, comp).initCapacity(allocator, cap);
    defer tree.deinit(allocator);

    try expect(tree.root_idx == NULL_IDX);
    try expect(tree.keys.capacity >= cap);
    try expect(tree.keys.items.len == 0);

    try expect(tree.values.capacity >= cap);
    try expect(tree.values.items.len == 0);

    try expect(tree.nodes.capacity >= cap);
    try expect(tree.nodes.items.len == 0);
}

test "reserveCapacity" {
    const cap = 2000000;
    const allocator = std.testing.allocator;
    var tree = Tree(u64, u64, comp).empty;
    try tree.reserveCapacity(allocator, cap);
    defer tree.deinit(allocator);

    try expect(tree.keys.capacity >= cap);
    try expect(tree.keys.items.len == 0);

    try expect(tree.values.capacity >= cap);
    try expect(tree.values.items.len == 0);

    try expect(tree.nodes.capacity >= cap);
    try expect(tree.nodes.items.len == 0);

    try expect(tree.colours.capacity() == cap);
}

test "insertion: ascending inputs" {
    const allocator = std.testing.allocator;
    const inputs = [_]u64{ 0, 5, 10, 15, 20, 25, 30, 35, 40 };

    var tree = try Tree(u64, u64, comp).initCapacity(allocator, inputs.len);
    defer tree.deinit(allocator);

    for (inputs[0..]) |i| {
        tree.insertAssumeCapacity(.{ .key = i, .value = i * 10 }) catch unreachable;
    }

    for (inputs) |i| {
        try expect(tree.get(i).? == i * 10);
    }
}

test "insertion: descending inputs" {
    const allocator = std.testing.allocator;
    const inputs = [_]u64{ 40, 35, 30, 25, 20, 15, 10, 5, 0 };

    var tree = try Tree(u64, u64, comp).initCapacity(allocator, inputs.len);
    defer tree.deinit(allocator);

    for (inputs) |i| {
        tree.insertAssumeCapacity(.{ .key = i, .value = i * 10 }) catch unreachable;
    }

    for (inputs) |i| {
        try expect(tree.get(i).? == i * 10);
    }
}

test "insertion: tricky inputs" {
    const allocator = std.testing.allocator;
    const inputs = [_]u64{ 10, 20, 30, 15, 5, 22, 28, 12 };

    var tree = try Tree(u64, u64, comp).initCapacity(allocator, inputs.len);
    defer tree.deinit(allocator);

    tree.insertAssumeCapacity(.{ .key = inputs[0], .value = inputs[0] * 10 }) catch unreachable;

    for (inputs[1..]) |i| {
        tree.insertAssumeCapacity(.{ .key = i, .value = i * 10 }) catch unreachable;
    }

    for (inputs) |i| {
        try expect(tree.get(i).? == i * 10);
    }
}

test "insertion: random inputs" {
    const allocator = std.testing.allocator;

    var PRNG = std.Random.Xoshiro256.init(@intCast(std.time.nanoTimestamp()));
    const random = PRNG.random();

    var inputs: [25]u64 = undefined;

    for (0..inputs.len) |i| {
        inputs[i] = 5 * i;
    }

    random.shuffle(u64, &inputs);
    std.debug.print("inputs for random insertion: {any}\n", .{inputs});

    var tree = try Tree(u64, u64, comp).initCapacity(allocator, inputs.len);
    defer tree.deinit(allocator);

    for (inputs) |i| {
        tree.insertAssumeCapacity(.{ .key = i, .value = i * 10 }) catch unreachable;
    }

    for (inputs) |i| {
        try expect(tree.get(i).? == i * 10);
    }
}

// for (tree.nodes.items, 0..) |i, k| {
//     std.debug.print("node: {}\nkey: {}\n,IsRed:{}\n\n", .{ i, tree.keys.items[k], !tree.colours.isSet(i.idx) });
// }

// test "deletion: moveLeftRed on the right subtree twice with no successor subtree" {
//     const allocator = std.testing.allocator;

//     const inputs = [_]u64{ 5, 10, 15, 20, 25, 30, 35, 23 };

//     var tree = try Tree(u64, u64, comp).initCapacity(allocator, inputs.len);
//     defer tree.deinit(allocator);

//     for (inputs, 0..) |i, k| {
//         tree.insertAssumeCapacity(.{ .key = i, .value = k * 10 }) catch unreachable;
//     }

//     _ = tree.delete(30);
// }

// test "deletion: significantly long subtree" {
//     const allocator = std.testing.allocator;

//     const inputs = [_]u64{ 10, 30, 5, 15, 25, 35, 2, 7, 12, 17, 23, 27, 32, 37, 31, 33 };

//     var tree = try Tree(u64, u64, comp).initCapacity(allocator, inputs.len);
//     defer tree.deinit(allocator);

//     for (inputs, 0..) |i, k| {
//         tree.insertAssumeCapacity(.{ .key = i, .value = k * 10 }) catch unreachable;
//     }

//     _ = tree.delete(30);
//     _ = tree.delete(10);

//     try expect(tree.get(10).? == 10 * 10);

//     for (inputs[2..]) |i| {
//         try expect(tree.get(i).? == i * 10);
//     }
// }

// test "deletion (right): successive deletions to test right subtree successor replacements" {
//     const allocator = std.testing.allocator;
//     var PRNG = std.Random.Xoshiro256.init(@intCast(std.time.nanoTimestamp()));
//     const random = PRNG.random();

//     var inputs: [15]u64 = undefined;

//     for (0..inputs.len) |i| {
//         inputs[i] = 5 * i;
//     }

//     random.shuffle(u64, &inputs);
//     // _ = random;
//     // _ = &inputs;
//     std.debug.print("inputs for random right deletion: {any}\n", .{inputs});
//     var tree = try Tree(u64, u64, comp).initCapacity(allocator, inputs.len);
//     defer tree.deinit(allocator);

//     for (inputs, 0..) |i, k| {
//         tree.insertAssumeCapacity(.{ .key = i, .value = k * 10 }) catch unreachable;
//     }

//     var root = &tree.nodes.items[tree.root_idx];
//     while (root.right_idx != NULL_IDX) {
//         _ = tree.delete(tree.keys.items[root.right_idx]);
//         root = &tree.nodes.items[tree.root_idx];
//     }
// }

// test "deletion: (root):  successor replacements and rebalancing" {
//     const allocator = std.testing.allocator;

//     var PRNG = std.Random.Xoshiro256.init(@intCast(std.time.nanoTimestamp()));
//     const random = PRNG.random();

//     var inputs: [15]u64 = undefined;

//     for (0..inputs.len) |i| {
//         inputs[i] = 5 * i;
//     }

//     random.shuffle(u64, &inputs);
//     // _ = random;
//     // _ = &inputs;
//     std.debug.print("inputs for random root deletion: {any}\n", .{inputs});
//     var tree = try Tree(u64, u64, comp).initCapacity(allocator, inputs.len);
//     defer tree.deinit(allocator);

//     for (inputs, 0..) |i, k| {
//         tree.insertAssumeCapacity(.{ .key = i, .value = k * 10 }) catch unreachable;
//     }

//     for (0..tree.nodes.items.len - 3) |_| {
//         _ = tree.delete(tree.keys.items[tree.root_idx]);
//     }
// }

// test "deletion (left): successor deletions to test and rebalancing" {
//     const allocator = std.testing.allocator;

//     var PRNG = std.Random.Xoshiro256.init(@intCast(std.time.nanoTimestamp()));
//     const random = PRNG.random();

//     var inputs: [15]u64 = undefined;

//     for (0..inputs.len) |i| {
//         inputs[i] = 5 * i;
//     }

//     random.shuffle(u64, &inputs);
//     // _ = &inputs;
//     // _ = random;
//     std.debug.print("inputs for random left deletion: {any}\n", .{inputs});
//     var tree = try Tree(u64, u64, comp).initCapacity(allocator, inputs.len);
//     defer tree.deinit(allocator);

//     for (inputs, 0..) |i, k| {
//         tree.insertAssumeCapacity(.{ .key = i, .value = k * 10 }) catch unreachable;
//     }

//     var root = &tree.nodes.items[tree.root_idx];
//     while (root.left_idx != NULL_IDX) {
//         _ = tree.delete(tree.keys.items[root.left_idx]);

//         root = &tree.nodes.items[tree.root_idx];
//     }

//     tree.insertAssumeCapacity(.{ .key = 45, .value = 10 }) catch unreachable;
// }

// test "deletion (children): leaf deletion" {
//     const allocator = std.testing.allocator;

//     var PRNG = std.Random.Xoshiro256.init(@intCast(std.time.nanoTimestamp()));
//     const random = PRNG.random();

//     var inputs: [15]u64 = undefined;

//     for (0..inputs.len) |i| {
//         inputs[i] = 5 * i;
//     }

//     random.shuffle(u64, &inputs);
//     _ = &inputs;
//     std.debug.print("inputs for random left deletion: {any}\n", .{inputs});

//     var tree = try Tree(u64, u64, comp).initCapacity(allocator, inputs.len);
//     defer tree.deinit(allocator);

//     for (inputs, 0..) |i, k| {
//         tree.insertAssumeCapacity(.{ .key = i, .value = k * 10 }) catch unreachable;
//     }

//     var start_direction: u4 = random.int(u1);
//     while (tree.root_idx != NULL_IDX) {
//         const root = &tree.nodes.items[tree.root_idx];

//         switch (start_direction) {
//             0 => {
//                 std.debug.print("going left\n", .{});
//                 if (root.left_idx != NULL_IDX) {
//                     while(root.key_idx )
//                     var node = &tree.nodes.items[root.left_idx];
//                 }
//             },
//         }
//     }
// }
