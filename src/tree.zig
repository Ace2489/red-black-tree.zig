const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

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
            const nodes = try Nodes.initCapacity(allocator, capacity);
            errdefer nodes.deinit(allocator);

            const keys = try Keys.initCapacity(allocator, capacity);
            errdefer keys.deinit(allocator);

            const values = try Values.initCapacity(allocator, capacity);
            errdefer values.deinit(allocator);

            const tree = Self{
                .nodes = nodes,
                .keys = keys,
                .values = values,
                .root_idx = NULL_IDX,
            };

            return tree;
        }

        pub fn reserve(self: *Self, allocator: Allocator, count: usize) !void {
            try self.nodes.ensureUnusedCapacity(allocator, count);
            try self.keys.ensureUnusedCapacity(allocator, count);
            try self.values.ensureUnusedCapacity(allocator, count);
        }

        pub fn insert(self: *Self, kv: KV) void {
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
            std.debug.print("Got to the case outside the existing key case\n", .{});
        }

        //TODO: Is there a way to restructure this so I still have the benefits of safety but am not calling the asserts multiple times
        ///Only meant to be called from inside the insert function, relies on pre-assertions already been made
        pub fn insertNode(self: *Self, node: *Node, kv: KV) u32 {
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
            const new_idx: u32 = @truncate(self.keys.items.len); //could be any of them, really - they're all  the same
            assert(new_idx < 0xFFFFFFFF); //maximum addressable element for a u32 index
            assert(parent_idx != NULL_IDX);

            self.keys.appendAssumeCapacity(kv.key);
            self.values.appendAssumeCapacity(kv.value);

            const new_node = Node{ .key_idx = new_idx, .colour = .Red, .parent_idx = parent_idx };
            self.nodes.appendAssumeCapacity(new_node);
            branch_ptr.* = new_idx;
            return balanceTree(new_node.parent_idx, self.nodes.items);
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

        pub fn balanceTree(node_idx: u32, nodes: []Node) u32 {
            assert(node_idx != NULL_IDX);
            var node = &nodes[node_idx];

            const can_flip = blk: {
                if (node.left_idx == NULL_IDX or node.right_idx == NULL_IDX)
                    break :blk false;

                const left = &nodes[node.left_idx];
                const right = &nodes[node.right_idx];

                break :blk left.colour == .Red and right.colour == .Red;
            };

            if (can_flip) {
                colourFlip(node, nodes, true);

                if (node.parent_idx == NULL_IDX) {
                    node.colour = .Black;
                    return node_idx;
                }
                return balanceTree(node.parent_idx, nodes);
            }

            if (node.parent_idx == NULL_IDX) return node_idx;

            return balanceTree(node.parent_idx, nodes);
        }

        pub fn colourFlip(node: *Node, nodes: []Node, safety_checks: bool) void {
            const left = &nodes[node.left_idx];
            const right = &nodes[node.right_idx];

            //Extra safety checks for colour flips during insertions
            if (safety_checks) {
                assert(right.colour == .Red and left.colour == .Red);
            }

            left.*.colour = @enumFromInt(~@intFromEnum(left.colour));
            right.*.colour = @enumFromInt(~@intFromEnum(right.colour));
            node.*.colour = @enumFromInt(~@intFromEnum(node.colour));
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.nodes.deinit(allocator);
            self.keys.deinit(allocator);
            self.values.deinit(allocator);
        }
    };
}
