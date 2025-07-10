const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const tracy = @import("tracy");

///We use indexes instead of pointers for cache locality
///
///Represents a null pointer
const NULL_IDX: u32 = 0xFFFFFFFF;

pub fn NodeGen(comptime K: type, comptime V: type) type {
    return struct {
        const Key = K;
        const Value = V;
        const KV = struct { key: K, value: V };
        const Keys = []const Key;
        const Self = @This();
        // const Nodes = []const Nodes

        right_idx: u32 = NULL_IDX,
        left_idx: u32 = NULL_IDX,
        key_idx: u32 = NULL_IDX,
        parent_idx: u32,

        colour: enum(u1) { Red, Black },
    };
}

pub fn Tree(comptime K: type, comptime V: type, compare_fn: fn (key: K, self_key: K) std.math.Order) type {
    return struct {
        pub const Key = K;
        pub const Value = V;
        pub const KV = struct { key: K, value: V };

        const Node = NodeGen(K, V);
        const Keys = std.ArrayListUnmanaged(K);
        const Values = std.ArrayListUnmanaged(V);
        const Nodes = std.ArrayListUnmanaged(Node);

        pub const cmp_fn = compare_fn;
        const Self = @This();

        pub const empty: Self = .{
            .root_idx = NULL_IDX,
            .nodes = .empty,
            .keys = .empty,
            .values = .empty,
        };

        root_idx: u32,
        nodes: Nodes,
        keys: Keys,
        values: Values,

        pub fn initCapacity(allocator: Allocator, capacity: usize) !Self {
            var nodes = try Nodes.initCapacity(allocator, capacity);
            errdefer nodes.deinit(allocator);

            var keys = try Keys.initCapacity(allocator, capacity);
            errdefer keys.deinit(allocator);

            var values = try Values.initCapacity(allocator, capacity);
            errdefer values.deinit(allocator);

            const tree = Self{
                .nodes = nodes,
                .keys = keys,
                .values = values,
                .root_idx = NULL_IDX,
            };

            return tree;
        }

        pub fn reserveCapacity(self: *Self, allocator: Allocator, count: usize) !void {
            try self.nodes.ensureUnusedCapacity(allocator, count);
            try self.keys.ensureUnusedCapacity(allocator, count);
            try self.values.ensureUnusedCapacity(allocator, count);
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.nodes.deinit(allocator);
            self.keys.deinit(allocator);
            self.values.deinit(allocator);
        }

        pub fn insertAssumeCapacity(self: *Self, kv: KV) void {
            const zone = tracy.initZone(@src(), .{ .name = "insert" });
            defer zone.deinit();

            //TODO: check for the max addressable length
            if (self.root_idx == NULL_IDX) {
                return self.insertRoot(kv);
            }

            const root = &self.nodes.items[self.root_idx];

            assert(self.keys.items.len <= self.keys.capacity - 1);
            assert(self.nodes.items.len <= self.nodes.capacity - 1);
            assert(self.values.items.len <= self.values.capacity - 1);
            assert(self.nodes.items.len == self.keys.items.len and self.nodes.items.len == self.values.items.len);

            if (self.nodes.items.len == 0xFFFFFFFF - 1) return;
            const new_root_idx = self.insertNode(root, kv);

            //The key already exists
            if (new_root_idx == NULL_IDX) return;
            self.root_idx = new_root_idx;
        }

        pub fn get(self: *Self, key: K) ?V {
            var node_idx: u32 = self.root_idx;

            while (node_idx != NULL_IDX) {
                const node = &self.nodes.items[node_idx]; //All lists have a one-to-one mapping to one another

                const comp = cmp_fn(key, self.keys.items[node_idx]);

                node_idx = switch (comp) {
                    .lt => node.left_idx,
                    .gt => node.right_idx,
                    .eq => return self.values.items[node_idx],
                };
            }
            return null;
        }
        //TODO: Is there a way to restructure this so I still have the benefits of safety but am not calling the asserts multiple times
        ///Only meant to be called from inside the insert function, relies on pre-assertions already been made
        pub fn insertNode(self: *Self, node: *Node, kv: KV) u32 {
            assert(self.keys.items.len <= self.keys.capacity - 1);
            assert(self.nodes.items.len <= self.nodes.capacity - 1);
            assert(self.values.items.len <= self.values.capacity - 1);
            assert(self.nodes.items.len == self.keys.items.len and self.nodes.items.len == self.values.items.len);

            const zone = tracy.initZone(@src(), .{ .name = "insertNode" });
            defer zone.deinit();

            const self_key = self.keys.items[node.key_idx];

            const comp = cmp_fn(kv.key, self_key);

            const branch: *u32 = switch (comp) {
                .lt => &node.*.left_idx,
                .gt => &node.*.right_idx,
                .eq => return NULL_IDX,
            };

            if (branch.* == NULL_IDX) {
                return self.insertNewNode(node.key_idx, branch, kv);
            }
            const branch_node = &self.nodes.items[branch.*];
            return self.insertNode(branch_node, kv);
        }

        ///Only meant to be called from inside the insert function, relies on pre-assertions being made already
        pub fn insertNewNode(self: *Self, parent_idx: u32, branch_ptr: *u32, kv: KV) u32 {
            assert(self.keys.items.len <= self.keys.capacity - 1);
            assert(self.nodes.items.len <= self.nodes.capacity - 1);
            assert(self.values.items.len <= self.values.capacity - 1);
            assert(self.nodes.items.len == self.keys.items.len and self.nodes.items.len == self.values.items.len);

            const zone = tracy.initZone(@src(), .{ .name = "insert New node" });

            defer zone.deinit();

            const new_idx: u32 = @truncate(self.keys.items.len); //could be any of the lists, really - they're all  the same
            assert(new_idx < 0xFFFFFFFF); //maximum addressable element for a u32 index
            assert(parent_idx != NULL_IDX);

            self.keys.appendAssumeCapacity(kv.key);
            self.values.appendAssumeCapacity(kv.value);

            const new_node = Node{ .key_idx = new_idx, .colour = .Red, .parent_idx = parent_idx };
            self.nodes.appendAssumeCapacity(new_node);
            branch_ptr.* = new_idx;
            return balanceTree(self.nodes.items, new_node.parent_idx);
        }

        pub fn insertRoot(self: *Self, kv: KV) void {
            assert(self.root_idx == NULL_IDX);

            assert(self.nodes.items.len == 0);
            assert(self.keys.items.len == 0);
            assert(self.values.items.len == 0);

            assert(self.nodes.capacity > 0);
            assert(self.keys.capacity > 0);
            assert(self.values.capacity > 0);

            const root_idx = 0;
            self.keys.appendAssumeCapacity(kv.key);
            self.values.appendAssumeCapacity(kv.value);

            const root = Node{ .key_idx = root_idx, .colour = .Black, .parent_idx = NULL_IDX };
            self.nodes.appendAssumeCapacity(root);

            self.root_idx = root_idx;
        }

        ///We always balance from the perspective of the node's parent, makes things easier to reason about
        pub fn balanceTree(nodes: []Node, idx: u32) u32 {
            const zone = tracy.initZone(@src(), .{ .name = "Balance tree" });
            defer zone.deinit();
            var parent_idx: u32 = idx;
            assert(parent_idx != NULL_IDX);
            while (true) {
                var parent_node = &nodes[parent_idx];
                const can_flip = blk: {
                    if (parent_node.left_idx == NULL_IDX or parent_node.right_idx == NULL_IDX)
                        break :blk false;

                    const left = &nodes[parent_node.left_idx];
                    const right = &nodes[parent_node.right_idx];

                    break :blk left.colour == .Red and right.colour == .Red;
                };

                if (can_flip) {
                    colourFlip(nodes, parent_node, true);
                    if (parent_node.parent_idx == NULL_IDX) {
                        parent_node.colour = .Black;
                        return parent_idx;
                    }
                    parent_idx = parent_node.parent_idx;
                    continue;
                }

                const hanging_right_link = blk: {
                    if (parent_node.right_idx == NULL_IDX) break :blk false;

                    const right = &nodes[parent_node.right_idx];

                    break :blk right.colour == .Red;
                };

                if (hanging_right_link) {
                    parent_idx = rotate_left(nodes, parent_node, true);
                    continue;
                }

                const double_red_left_links = blk: {
                    if (parent_node.left_idx == NULL_IDX) break :blk false;
                    const left = &nodes[parent_node.left_idx];

                    if (left.left_idx == NULL_IDX or left.colour != .Red) break :blk false;
                    const left_left = &nodes[left.left_idx];

                    break :blk left_left.colour == .Red;
                };

                if (double_red_left_links) {
                    parent_idx = rotate_right(nodes, parent_node, true);
                    continue;
                }
                if (parent_node.parent_idx == NULL_IDX) {
                    if (parent_node.colour != .Black) {
                        std.debug.print("Very strange scenario here: Nodes{any}\n\nBalancing node: {}\n", .{ nodes, parent_node });
                        unreachable;
                    }
                    return parent_idx;
                }
                parent_idx = parent_node.parent_idx;
            }
        }

        pub fn colourFlip(nodes: []Node, node: *Node, safety_checks_for_insertion: bool) void {
            const left = &nodes[node.left_idx];
            const right = &nodes[node.right_idx];

            //Extra safety checks for colour flips during insertions
            if (safety_checks_for_insertion) {
                assert(right.colour == .Red and left.colour == .Red);
            }

            left.*.colour = @enumFromInt(~@intFromEnum(left.colour)); //a nifty way to flip colours
            right.*.colour = @enumFromInt(~@intFromEnum(right.colour));
            node.*.colour = @enumFromInt(~@intFromEnum(node.colour));
        }

        pub fn rotate_left(nodes: []Node, node: *Node, safety_checks_for_insertion: bool) u32 {
            assert(node.right_idx != NULL_IDX);
            if (safety_checks_for_insertion) {
                const right = &nodes[node.right_idx];
                assert(right.colour == .Red);
            }
            const node_idx = node.key_idx; //All the lists maintain a direct mapping between each other, allowing us to index one with the index of another
            const right_child_idx = node.right_idx;
            const right_child = &nodes[right_child_idx];

            const node_colour = node.colour;
            const right_colour = right_child.colour;

            node.colour = right_colour;
            right_child.colour = node_colour;

            right_child.parent_idx = node.parent_idx;

            if (node.parent_idx != NULL_IDX) {
                const parent = &nodes[node.parent_idx];

                //parent re-assignment
                if (parent.right_idx == node_idx) {
                    assert(parent.left_idx != node_idx);
                    parent.right_idx = right_child_idx;
                } else {
                    assert(parent.left_idx == node_idx);
                    parent.left_idx = right_child_idx;
                }
            }
            node.parent_idx = right_child_idx;
            node.right_idx = right_child.left_idx;
            right_child.left_idx = node_idx;

            //Newly assigned right child
            if (node.right_idx != NULL_IDX) {
                const new_right = &nodes[node.right_idx];
                new_right.parent_idx = node_idx;
            }

            return right_child_idx; //the old right child is now the node's parent
        }

        pub fn rotate_right(nodes: []Node, node: *Node, safety_checks_for_insertion: bool) u32 {
            assert(node.left_idx != NULL_IDX);

            const node_idx = node.key_idx;
            const left_child_idx = node.left_idx;
            const left_child = &nodes[left_child_idx];

            if (safety_checks_for_insertion) {
                assert(left_child.colour == .Red);
            }

            const node_colour = node.colour;
            const left_child_colour = left_child.colour;

            node.colour = left_child_colour;
            left_child.colour = node_colour;

            left_child.parent_idx = node.parent_idx;
            if (node.parent_idx != NULL_IDX) {
                const parent = &nodes[node.parent_idx];

                if (parent.left_idx == node_idx) {
                    assert(parent.right_idx != node_idx);
                    parent.left_idx = left_child_idx;
                } else {
                    assert(parent.right_idx == node_idx);
                    parent.right_idx = left_child_idx;
                }
            }

            node.parent_idx = left_child_idx;
            node.left_idx = left_child.right_idx;
            left_child.right_idx = node_idx;

            //the newly assigned left index
            if (node.left_idx != NULL_IDX) {
                const new_left = &nodes[node.left_idx];
                new_left.parent_idx = node_idx;
            }
            return left_child_idx;
        }
    };
}
