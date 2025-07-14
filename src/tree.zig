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

        pub fn get(self: *Self, key: K) ?V {
            const node_idx = self.getIdx(key) orelse return null;
            return self.values[node_idx];
        }

        pub fn getIdx(self: *Self, key: K) ?u32 {
            var node_idx: u32 = self.root_idx;

            while (node_idx != NULL_IDX) {
                const node = &self.nodes.items[node_idx]; //All lists have a one-to-one mapping to one another

                const comp = cmp_fn(key, self.keys.items[node_idx]);

                node_idx = switch (comp) {
                    .lt => node.left_idx,
                    .gt => node.right_idx,
                    .eq => return node_idx,
                };
            }
            return null;
        }

        pub fn delete(self: *Self, key: K) ?KV {
            const removed_idx = self.getIdx(key) orelse return null;

            assert(self.root_idx != NULL_IDX);

            const new_root_idx = deleteNode(self.nodes.items, self.keys.items, self.root_idx, key);

            if (self.root_idx == NULL_IDX) return null; //We deleted the only node in tree

            self.root_idx = new_root_idx;

            const removed_node = self.nodes.swapRemove(removed_idx);
            std.debug.print("\nRemoved: {}\n", .{removed_node});
            const removed_key = self.keys.swapRemove(removed_idx);
            const removed_value = self.values.swapRemove(removed_idx);

            assert(removed_key == key);

            if (removed_idx == self.nodes.items.len) return .{ .key = removed_key, .value = removed_value };

            var swapped_node = &self.nodes.items[removed_idx];
            swapped_node.key_idx = removed_idx;

            //Re-linking parent and child nodes

            if (swapped_node.left_idx != NULL_IDX) {
                var left = &self.nodes.items[swapped_node.left_idx];
                left.parent_idx = removed_idx;
            }
            if (swapped_node.right_idx != NULL_IDX) {
                var right = &self.nodes.items[swapped_node.right_idx];
                right.parent_idx = removed_idx;
            }

            if (swapped_node.parent_idx != NULL_IDX) {
                var parent = &self.nodes.items[swapped_node.parent_idx];
                switch (cmp_fn(self.keys.items[swapped_node.key_idx], self.keys.items[parent.key_idx])) {
                    .lt => parent.left_idx = swapped_node.key_idx,
                    .gt => parent.right_idx = swapped_node.key_idx,
                    .eq => unreachable,
                }
            }
            // std.debug.print("\nNodes: {}\n\nKeys: {}\nRoot: {}\n", .{ self.nodes, self.keys, self.nodes.items[self.root_idx] });
            return .{ .key = removed_key, .value = removed_value };
        }

        pub fn insertAssumeCapacity(self: *Self, kv: KV) void {
            errdefer comptime unreachable;
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
                    parent_idx = rotateLeft(nodes, parent_node, true);
                    continue;
                }

                const double_red_left_links = blk: {
                    if (parent_node.left_idx == NULL_IDX) break :blk false;
                    const left = &nodes[parent_node.left_idx];
                    // if (left.colour != .Red) break :blk false; //This is a bug. Test it.

                    if (left.left_idx == NULL_IDX or left.colour != .Red) break :blk false;
                    const left_left = &nodes[left.left_idx];

                    break :blk left_left.colour == .Red;
                };

                if (double_red_left_links) {
                    parent_idx = rotateRight(nodes, parent_node, true);
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

        ///This method assumes there is a node to delete
        ///
        /// Make sure to verify that the node exists with a search first, before calling this
        pub fn deleteNode(nodes: []Node, keys: []const Key, start_idx: u32, key: K) u32 {
            assert(start_idx != NULL_IDX);
            var cmp = cmp_fn(key, keys[start_idx]);
            std.debug.print("\n\nDeleteNode called for {}\n", .{start_idx});

            if (cmp == .lt) {
                var node = &nodes[start_idx];
                assert(node.left_idx != NULL_IDX);
                node.left_idx = deleteFromLeftSubtree(nodes, keys, start_idx, key);
                if (node.left_idx != NULL_IDX) {
                    const left = &nodes[node.left_idx];
                    left.parent_idx = node.key_idx;
                }
                const node_idx = fixUp(nodes, start_idx);
                assert(node_idx != NULL_IDX);
                const fixed_node = &nodes[node_idx];
                if (fixed_node.parent_idx == NULL_IDX) {
                    fixed_node.colour = .Black;
                }
                return fixed_node.key_idx;
            }

            std.debug.print("We fell through the check with the node carrying the key {}\n", .{keys[start_idx]});
            var node = &nodes[start_idx];
            const rotate_right = node.left_idx != NULL_IDX and (&nodes[node.left_idx]).colour == .Red;
            if (rotate_right) {
                std.debug.print("Rotating right from deleteNode\n", .{});
                const subtree_head = rotateRight(nodes, node, false);
                assert(subtree_head != NULL_IDX);
                node = &nodes[subtree_head];
                cmp = cmp_fn(key, keys[node.key_idx]); //Recompute this because we've changed the node being worked on
            }

            const matched_to_leaf = cmp == .eq and node.right_idx == NULL_IDX;
            if (matched_to_leaf) {
                std.debug.print("Deleting leaf: {}\n", .{keys[start_idx]});
                return NULL_IDX;
            }
            // std.process.exit(0);

            assert(node.right_idx != NULL_IDX);

            //This modifies the node being pointed to in-place
            handleRightSubtree(nodes, keys, node.key_idx, key);

            const node_idx = fixUp(nodes, node.key_idx);
            assert(node_idx != NULL_IDX);
            const fixed_node = &nodes[node_idx];
            if (fixed_node.parent_idx == NULL_IDX) {
                node.colour = .Black;
            }
            return fixed_node.key_idx;
        }

        pub inline fn deleteFromLeftSubtree(nodes: []Node, keys: []const Key, start_idx: u32, key: K) u32 {
            assert(start_idx != NULL_IDX);
            std.debug.print("Delete from LT .start key: {}\n", .{keys[start_idx]});
            var node = &nodes[start_idx];
            assert(node.left_idx != NULL_IDX);
            const move_left_red = blk: {
                const left = &nodes[node.left_idx];
                if (left.colour == .Red) break :blk false;

                //This will short-circuit and return true without trying the second one if the first condition is met. Neat!
                break :blk left.left_idx == NULL_IDX or (&nodes[left.left_idx]).colour == .Black;
            };

            if (move_left_red) {
                std.debug.print("Moving left and to the red\n", .{});
                const moved_idx = moveLeftRed(nodes, node.key_idx);
                assert(moved_idx != NULL_IDX);
                node = &nodes[moved_idx];
            }
            return deleteNode(nodes, keys, node.left_idx, key);
        }

        pub inline fn moveLeftRed(nodes: []Node, node_idx: u32) u32 {
            std.debug.print("Move left red idx {}\n", .{node_idx});
            assert(node_idx != NULL_IDX);

            var node = &nodes[node_idx];
            colourFlip(nodes, node, false);

            const right_left_red = blk: {
                if (node.right_idx == NULL_IDX) break :blk false;
                const right = &nodes[node.right_idx];
                break :blk right.left_idx != NULL_IDX and (&nodes[right.left_idx]).colour == .Red;
            };

            if (right_left_red) {
                const right_node = &nodes[node.right_idx];
                const right_idx = rotateRight(nodes, right_node, false);
                assert(right_idx != NULL_IDX);
                node.right_idx = right_idx;

                const subtree_root = rotateLeft(nodes, node, false);
                assert(subtree_root != NULL_IDX);
                node = &nodes[subtree_root];
                colourFlip(nodes, node, false);
            }
            return node.key_idx;
        }

        pub inline fn handleRightSubtree(nodes: []Node, keys: []const Key, start_idx: u32, key: K) void {
            assert(start_idx != NULL_IDX);
            std.debug.print("\n\nHandle Right subtree for {}\n", .{start_idx});
            const move_right_red = blk: {
                const node = &nodes[start_idx];
                if (node.right_idx == NULL_IDX) break :blk true;
                const right = &nodes[node.right_idx];
                if (right.colour == .Red) break :blk false;

                break :blk right.left_idx == NULL_IDX or (&nodes[right.left_idx]).colour == .Black;
            };

            var node = &nodes[start_idx];
            if (move_right_red) {
                std.debug.print("Moving right red for {}\n", .{start_idx});
                colourFlip(nodes, node, false);
                const left_left_red = blk: {
                    if (node.left_idx == NULL_IDX) break :blk false;
                    const left = &nodes[node.left_idx];
                    break :blk left.left_idx != NULL_IDX and (&nodes[left.left_idx]).colour == .Red;
                };

                if (left_left_red) {
                    std.debug.print("Left left red for {}\n", .{start_idx});
                    const node_idx = rotateRight(nodes, node, false);
                    assert(node_idx != NULL_IDX);
                    node = &nodes[node_idx];
                    colourFlip(nodes, node, false);
                }
            }

            const cmp_result = cmp_fn(key, keys[node.key_idx]);
            if (cmp_result == .eq) {
                replaceWithSuccessor(nodes, node);
                return;
            }
            node.right_idx = deleteNode(nodes, keys, node.right_idx, key);
            assert(node.right_idx != NULL_IDX);
            const right = &nodes[node.right_idx];
            right.parent_idx = node.key_idx;
        }

        pub inline fn replaceWithSuccessor(nodes: []Node, node: *Node) void {
            std.debug.print("\n\nReplacing with successor", .{});
            assert(node.right_idx != NULL_IDX);

            var successor_idx: u32 = NULL_IDX;

            node.right_idx = removeSuccessorNode(nodes, node.right_idx, &successor_idx);

            assert(successor_idx != NULL_IDX);

            const replacement_node = &nodes[successor_idx];

            replacement_node.left_idx = node.left_idx;
            replacement_node.right_idx = node.right_idx;
            replacement_node.parent_idx = node.parent_idx;
            replacement_node.colour = node.colour;
            //can't I just do node.key_idx = replacement_node.key_idx here?

            //set node's parent and children's parent pointers to the new replacement node

            if (node.right_idx != NULL_IDX) {
                const right = &nodes[node.right_idx];
                right.parent_idx = replacement_node.key_idx;
            }

            if (node.left_idx != NULL_IDX) {
                const left = &nodes[node.left_idx];
                left.parent_idx = replacement_node.key_idx;
            }

            node.* = replacement_node.*;
            if (node.parent_idx == NULL_IDX) {
                return;
            }

            const parent = &nodes[node.parent_idx];

            //Todo: Rigorously prove this on paper
            assert(parent.right_idx == node.key_idx);
            parent.right_idx = replacement_node.key_idx;
            return;
        }

        pub fn removeSuccessorNode(
            nodes: []Node,
            start_idx: u32,
            index_ptr: *u32, //An index which will be populated with the deleted node's index
        ) u32 {
            std.debug.print("\n\nRemove successor node for {}\n", .{start_idx});
            var node = &nodes[start_idx];
            if (node.left_idx == NULL_IDX) {
                index_ptr.* = node.key_idx;
                return NULL_IDX;
            }
            const move_left_red = blk: {
                const left = &nodes[node.left_idx];
                if (left.colour == .Red) break :blk false;
                break :blk left.left_idx == NULL_IDX or (&nodes[left.left_idx]).colour == .Black;
            };
            if (move_left_red) {
                const moved_idx = moveLeftRed(nodes, node.key_idx);
                assert(moved_idx != NULL_IDX);
                node = &nodes[moved_idx];
            }

            node.left_idx = removeSuccessorNode(nodes, node.left_idx, index_ptr);

            if (node.left_idx != NULL_IDX) {
                const left = &nodes[node.left_idx];
                left.parent_idx = node.key_idx;
            }

            const node_idx = fixUp(nodes, node.key_idx);
            assert(node_idx != NULL_IDX);
            return node_idx;
        }

        ///Fixes up the sub-tree after a delete operation
        ///
        /// We always balance/fix-up from the perspective of the parent.. It makes things easier to reason about
        pub fn fixUp(nodes: []Node, parent_idx: u32) u32 {
            std.debug.print("Fix upping(lol) for idx {}\n\n", .{parent_idx});
            assert(parent_idx != NULL_IDX);

            {
                const parent_node = &nodes[parent_idx];
                const can_flip = blk: {
                    if (parent_node.left_idx == NULL_IDX or parent_node.right_idx == NULL_IDX) break :blk false;
                    break :blk (&nodes[parent_node.left_idx]).colour == .Red and (&nodes[parent_node.right_idx]).colour == .Red;
                };

                std.debug.print("Can flip {}\n", .{can_flip});

                if (can_flip) {
                    std.debug.print("Flipping for can_flip {}\n", .{can_flip});
                    colourFlip(nodes, parent_node, true);
                    return parent_idx; //After a colour flip, no more balancing needs to be done on the sub-tree
                }
            }

            var parent_node = &nodes[parent_idx];
            const hanging_right_link = blk: {
                if (parent_node.right_idx == NULL_IDX) break :blk false;
                break :blk (&nodes[parent_node.right_idx]).colour == .Red;
            };

            std.debug.print("Hanging right link {}\n", .{hanging_right_link});
            if (hanging_right_link) {
                std.debug.print("Resolving Hanging right link {}\n", .{hanging_right_link});
                const new_parent_idx = rotateLeft(nodes, parent_node, true);
                assert(new_parent_idx != NULL_IDX);
                parent_node = &nodes[new_parent_idx];
            }

            const double_left_red = blk: {
                if (parent_node.left_idx == NULL_IDX) break :blk false;
                const left = &nodes[parent_node.left_idx];
                if (left.colour != .Red) break :blk false;
                break :blk left.left_idx != NULL_IDX and (&nodes[left.left_idx]).colour == .Red;
            };

            std.debug.print("double_left_red {}\n", .{double_left_red});

            if (double_left_red) {
                std.debug.print("Resolving double left red {}\n", .{double_left_red});
                const new_parent_idx = rotateRight(nodes, parent_node, true);
                assert(new_parent_idx != NULL_IDX);
                parent_node = &nodes[new_parent_idx];
                colourFlip(nodes, parent_node, true); //After resolving a double left red, we always need a colour flip
            }

            return parent_node.key_idx;
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

        pub fn rotateLeft(nodes: []Node, node: *Node, safety_checks_for_insertion: bool) u32 {
            std.debug.print("Rotating left for {}\n", .{node.key_idx});
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

        pub fn rotateRight(nodes: []Node, node: *Node, safety_checks_for_insertion: bool) u32 {
            assert(node.left_idx != NULL_IDX);
            std.debug.print("Rotating right for {}\n", .{node.key_idx});

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

            //The left child is now at the root of the subtree
            return left_child_idx;
        }
    };
}
