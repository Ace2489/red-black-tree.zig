const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const tracy = @import("tracy");

///We use indexes instead of pointers for cache locality
///
///Represents a null pointer
pub const NULL_IDX: u32 = 0xFFFFFFFF;
pub const MAX_IDX: u32 = 0xFFFFFFFF - 1;
pub const Colour = struct {
    pub const Red = false;
    pub const Black = true;
};

pub const Node = struct {
    idx: u32 = NULL_IDX,
    left_idx: u32 = NULL_IDX,
    right_idx: u32 = NULL_IDX,
    parent_idx: u32,
};

pub fn Tree(
    comptime K: type,
    comptime V: type,
    /// A comparison function that returns the ordering(equal, less than, or greater than) between two keys.
    /// Take note of the parameter order to prevent inverted trees
    compare_fn: fn (key: K, self_key: K) std.math.Order,
) type {
    return struct {
        pub const Key = K;
        pub const Value = V;
        pub const KV = struct { key: K, value: V };

        pub const Keys = std.ArrayListUnmanaged(K);
        pub const Values = std.ArrayListUnmanaged(V);
        pub const Nodes = std.ArrayListUnmanaged(Node);
        pub const Colours = std.DynamicBitSetUnmanaged;

        pub const cmp_fn = compare_fn;
        const Self = @This();

        pub const empty: Self = .{
            .root_idx = NULL_IDX,
            .nodes = .empty,
            .keys = .empty,
            .values = .empty,
            .colours = .{},
        };

        root_idx: u32,
        nodes: Nodes,
        keys: Keys,
        values: Values,
        colours: Colours,

        pub fn initCapacity(allocator: Allocator, capacity: usize) !Self {
            var nodes = try Nodes.initCapacity(allocator, capacity);
            errdefer nodes.deinit(allocator);

            var keys = try Keys.initCapacity(allocator, capacity);
            errdefer keys.deinit(allocator);

            var values = try Values.initCapacity(allocator, capacity);
            errdefer values.deinit(allocator);

            const colours = try Colours.initFull(allocator, capacity);

            const tree = Self{
                .nodes = nodes,
                .keys = keys,
                .values = values,
                .colours = colours,
                .root_idx = NULL_IDX,
            };

            return tree;
        }

        pub fn reserveCapacity(self: *Self, allocator: Allocator, count: usize) !void {
            try self.nodes.ensureUnusedCapacity(allocator, count);
            try self.keys.ensureUnusedCapacity(allocator, count);
            try self.values.ensureUnusedCapacity(allocator, count);
            try self.colours.resize(allocator, self.colours.capacity() + count, Colour.Black);
        }

        pub fn insertAssumeCapacity(self: *Self, kv: KV) error{FullTree}!void {
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
            assert(self.colours.capacity() >= self.nodes.items.len + 1);

            if (self.nodes.items.len == MAX_IDX) return error.FullTree;

            errdefer comptime unreachable;
            const new_root_idx = self.insertNode(root, kv);

            //The key already exists
            if (new_root_idx == NULL_IDX) return;
            self.root_idx = new_root_idx;
            assert(self.nodes.items.len == self.keys.items.len and self.nodes.items.len == self.values.items.len and self.colours.capacity() >= self.nodes.items.len);
        }

        pub fn insertNode(self: *Self, node: *Node, kv: KV) u32 {
            assert(self.keys.items.len <= self.keys.capacity - 1);
            assert(self.nodes.items.len <= self.nodes.capacity - 1);
            assert(self.values.items.len <= self.values.capacity - 1);
            assert(self.colours.capacity() >= self.nodes.items.len + 1);
            assert(self.nodes.items.len == self.keys.items.len and self.nodes.items.len == self.values.items.len);

            const zone = tracy.initZone(@src(), .{ .name = "insertNode" });
            defer zone.deinit();

            const self_key = self.keys.items[node.idx];

            const comp = cmp_fn(kv.key, self_key);

            const branch: *u32 = switch (comp) {
                .lt => &node.*.left_idx,
                .gt => &node.*.right_idx,
                .eq => return NULL_IDX,
            };

            if (branch.* == NULL_IDX) {
                const new_idx: u32 = @truncate(self.keys.items.len); //could be any of the lists, really - they're all  the same length
                assert(new_idx < 0xFFFFFFFF); //maximum addressable element for a u32 index

                self.keys.appendAssumeCapacity(kv.key);
                self.values.appendAssumeCapacity(kv.value);

                const new_node = Node{ .idx = new_idx, .parent_idx = node.idx };
                self.nodes.appendAssumeCapacity(new_node);
                self.colours.setValue(new_idx, Colour.Red);
                branch.* = new_idx;
                return balanceTree(self.nodes.items, &self.colours, new_node.parent_idx);
            }
            const branch_node = &self.nodes.items[branch.*];
            return self.insertNode(branch_node, kv);
        }

        pub fn insertRoot(self: *Self, kv: KV) void {
            assert(self.root_idx == NULL_IDX);

            assert(self.nodes.items.len == 0);
            assert(self.keys.items.len == 0);
            assert(self.values.items.len == 0);

            assert(self.nodes.capacity > 0);
            assert(self.keys.capacity > 0);
            assert(self.values.capacity > 0);
            assert(self.colours.capacity() > 0);

            const root_idx = 0;
            self.keys.appendAssumeCapacity(kv.key);
            self.values.appendAssumeCapacity(kv.value);

            const root = Node{ .idx = root_idx, .parent_idx = NULL_IDX };
            self.nodes.appendAssumeCapacity(root);
            self.colours.setValue(root_idx, Colour.Black);

            self.root_idx = root_idx;
        }

        ///We always balance from the perspective of the node's parent, makes things easier to reason about
        pub fn balanceTree(nodes: []Node, colours: *Colours, idx: u32) u32 {
            const zone = tracy.initZone(@src(), .{ .name = "Balance tree" });
            defer zone.deinit();
            var parent_idx: u32 = idx;
            assert(parent_idx != NULL_IDX);
            while (true) {
                const parent_node = &nodes[parent_idx];

                const can_flip = blk: {
                    if (parent_node.left_idx == NULL_IDX or parent_node.right_idx == NULL_IDX)
                        break :blk false;

                    break :blk isRed(colours, parent_node.left_idx) and isRed(colours, parent_node.right_idx);
                };

                if (can_flip) {
                    colourFlip(colours, parent_node, true);
                    if (parent_node.parent_idx == NULL_IDX) {
                        colours.setValue(parent_node.idx, Colour.Black);
                        // parent_node.colour = .Black;
                        return parent_idx;
                    }
                    parent_idx = parent_node.parent_idx;
                    continue;
                }

                const hanging_right_link = blk: {
                    if (parent_node.right_idx == NULL_IDX) break :blk false;

                    break :blk isRed(colours, parent_node.right_idx);
                };

                if (hanging_right_link) {
                    parent_idx = rotateLeft(nodes, colours, parent_node, true);
                    continue;
                }

                const double_red_left_links = blk: {
                    //This will short-circuit and return without trying the second one if the first condition is met. Neat!
                    if (parent_node.left_idx == NULL_IDX or !isRed(colours, parent_node.left_idx)) break :blk false;
                    // if (left.colour != .Red) break :blk false; //This is a bug. Test it.

                    const left = &nodes[parent_node.left_idx];

                    break :blk (left.left_idx != NULL_IDX and isRed(colours, left.left_idx));
                };

                if (double_red_left_links) {
                    parent_idx = rotateRight(nodes, colours, parent_node, true);
                    continue;
                }
                if (parent_node.parent_idx == NULL_IDX) { //This is the root of the tree
                    assert(!isRed(colours, parent_node.idx));
                    return parent_idx;
                }
                parent_idx = parent_node.parent_idx;
            }
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.nodes.deinit(allocator);
            self.keys.deinit(allocator);
            self.values.deinit(allocator);
            self.colours.deinit(allocator);
        }

        pub fn get(self: *Self, key: K) ?V {
            const node_idx = self.getIdx(key) orelse return null;
            return self.values.items[node_idx];
        }

        pub fn getIdx(self: *Self, key: K) ?u32 {
            var node_idx: u32 = self.root_idx;

            while (node_idx != NULL_IDX) {
                const node = &self.nodes.items[node_idx];

                const comp = cmp_fn(key, self.keys.items[node_idx]); //All lists have a one-to-one mapping to one another

                node_idx = switch (comp) {
                    .lt => node.left_idx,
                    .gt => node.right_idx,
                    .eq => return node_idx,
                };
            }
            return null;
        }

        // pub fn delete(self: *Self, key: K) ?KV {
        //     const removed_idx = self.getIdx(key) orelse return null;

        //     assert(self.root_idx != NULL_IDX);

        //     self.root_idx = deleteNode(self.nodes.items, self.keys.items, self.root_idx, key);

        //     _ = self.nodes.swapRemove(removed_idx);
        //     const removed_key = self.keys.swapRemove(removed_idx);
        //     const removed_value = self.values.swapRemove(removed_idx);

        //     assert(removed_key == key);

        //     if (removed_idx == self.nodes.items.len) { //The removed index was the last in the list, there's no need to re-arrange the elements
        //         return .{ .key = removed_key, .value = removed_value };
        //     }

        //     var swapped_node = &self.nodes.items[removed_idx];

        //     swapped_node.idx = removed_idx;

        //     //Re-linking parent and child nodes

        //     if (swapped_node.left_idx != NULL_IDX) {
        //         var left = &self.nodes.items[swapped_node.left_idx];

        //         left.parent_idx = removed_idx;
        //     }
        //     if (swapped_node.right_idx != NULL_IDX) {
        //         var right = &self.nodes.items[swapped_node.right_idx];
        //         right.parent_idx = removed_idx;
        //     }

        //     if (swapped_node.parent_idx != NULL_IDX) {
        //         var parent = &self.nodes.items[swapped_node.parent_idx];
        //         switch (cmp_fn(self.keys.items[swapped_node.idx], self.keys.items[parent.idx])) {
        //             .lt => parent.left_idx = swapped_node.idx,
        //             .gt => parent.right_idx = swapped_node.idx,
        //             .eq => unreachable,
        //         }
        //     }

        //     if (self.root_idx == self.nodes.items.len) {
        //         self.root_idx = removed_idx;
        //     }

        //     assert(self.root_idx != NULL_IDX);
        //     return .{ .key = removed_key, .value = removed_value };
        // }

        pub fn range(self: *Self, min: K, max: K, out_buffer: []K) u32 {
            if (self.root_idx == NULL_IDX) return 0;
            assert(self.nodes.items.len < MAX_IDX);

            const root = &self.nodes.items[self.root_idx];
            const count = rangeNodes(self.nodes.items, self.keys.items, root, min, max, out_buffer, 0);
            assert(count <= out_buffer.len);
            return count;
        }

        pub fn rangeNodes(nodes: []Node, keys: []const Key, start_node: *Node, min: K, max: K, out_buffer: []K, collected_elements: u32) u32 {
            if (collected_elements == out_buffer.len) return collected_elements;
            assert(collected_elements < out_buffer.len);

            var idx = collected_elements;
            const min_comparison = cmp_fn(min, keys[start_node.idx]);

            if (min_comparison == .lt) { // min < current_key
                const left_idx = start_node.left_idx;
                if (left_idx != NULL_IDX) {
                    const left = &nodes[start_node.left_idx];
                    idx = rangeNodes(nodes, keys, left, min, max, out_buffer, idx);
                    if (idx == out_buffer.len) return idx;
                }
            }

            const max_comparison = cmp_fn(max, keys[start_node.idx]);

            if (min_comparison != .gt and max_comparison != .lt) { // min <= current_key and max >= current_key
                out_buffer[idx] = keys[start_node.idx];
                idx += 1;
                if (idx == out_buffer.len) return idx; // Check after adding current node
            }

            if (max_comparison == .gt) { //max > current_key
                const right_idx = start_node.right_idx;
                if (right_idx != NULL_IDX) {
                    const right = &nodes[right_idx];
                    idx = rangeNodes(nodes, keys, right, min, max, out_buffer, idx);
                }
            }

            return idx;
        }

        pub fn update(self: *Self, kv: KV) error{EntryNotFound}!KV {
            const val_idx = self.getIdx(kv.key) orelse return error.EntryNotFound;

            self.values.items[val_idx] = kv.value;
            return .{ .key = kv.key, .value = kv.value };
        }

        ///This method assumes there is a node to delete
        ///
        ///Make sure to verify that the node exists with a search first before calling this
        pub fn deleteNode(nodes: []Node, colours: *Colours, keys: []const Key, start_idx: u32, key: K) u32 {
            assert(start_idx != NULL_IDX);
            var cmp = cmp_fn(key, keys[start_idx]);
            // std.debug.print("\n\nDeleteNode called for {} at {}\n", .{ key, keys[start_idx] });

            if (cmp == .lt) {
                var node = &nodes[start_idx];
                assert(node.left_idx != NULL_IDX);

                const move_left_red = blk: {
                    // if (left.colour == .Red) break :blk false;
                    if (isRed(colours, node.left_idx)) break :blk false;
                    const left = &nodes[node.left_idx];

                    //This will short-circuit and return true without trying the second one if the first condition is met. Neat!
                    // break :blk left.left_idx == NULL_IDX or (&nodes[left.left_idx]).colour == .Black;
                    break :blk left.left_idx == NULL_IDX or !isRed(colours, left.left_idx);
                };

                if (move_left_red) {
                    const moved_idx = moveLeftRed(nodes, colours, node.idx);
                    assert(moved_idx != NULL_IDX);
                    node = &nodes[moved_idx];
                }

                node.left_idx = deleteNode(nodes, colours, keys, node.left_idx, key);
                //
                if (node.left_idx != NULL_IDX) {
                    const left = &nodes[node.left_idx];
                    left.parent_idx = node.idx;
                }
                const node_idx = fixUp(nodes, colours, node.idx);
                assert(node_idx != NULL_IDX);
                node = &nodes[node_idx];
                if (node.parent_idx == NULL_IDX) {
                    // node.colour = .Black;
                    colours.setValue(node.idx, Colour.Red);
                }
                return node.idx;
            }

            var node = &nodes[start_idx];
            // const rotate_right = node.left_idx != NULL_IDX and (&nodes[node.left_idx]).colour == .Red;
            const rotate_right = node.left_idx != NULL_IDX and isRed(colours, node.left_idx);
            if (rotate_right) {
                const subtree_head = rotateRight(nodes, colours, node, false);
                assert(subtree_head != NULL_IDX);
                node = &nodes[subtree_head];
                cmp = cmp_fn(key, keys[node.idx]); //Recompute this because we've changed the node being worked on
            }

            const matched_to_leaf = cmp == .eq and node.right_idx == NULL_IDX;
            if (matched_to_leaf) {
                return NULL_IDX;
            }

            assert(node.right_idx != NULL_IDX);

            const move_right_red = blk: {
                if (node.right_idx == NULL_IDX) break :blk true;
                // if (right.colour == .Red) break :blk false;
                if (isRed(colours, node.right_idx)) break :blk false;
                const right = &nodes[node.right_idx];
                // break :blk right.left_idx == NULL_IDX or (&nodes[right.left_idx]).colour == .Black;
                break :blk right.left_idx == NULL_IDX or !isRed(colours, right.left_idx);
            };

            if (move_right_red) {
                colourFlip(colours, nodes, node, false);
                const left_left_red = blk: {
                    if (node.left_idx == NULL_IDX) break :blk false;
                    const left = &nodes[node.left_idx];
                    // break :blk left.left_idx != NULL_IDX and (&nodes[left.left_idx]).colour == .Red;
                    break :blk left.left_idx != NULL_IDX and isRed(colours, left.left_idx);
                };

                if (left_left_red) {
                    const node_idx = rotateRight(nodes, colours, node, false);
                    assert(node_idx != NULL_IDX);
                    node = &nodes[node_idx];
                    colourFlip(colours, nodes, node, false);
                }
            }

            cmp = cmp_fn(key, keys[node.idx]);
            if (cmp == .eq) {
                node = replaceWithSuccessor(nodes, colours, node);
                const node_idx = fixUp(nodes, colours, node.idx);
                assert(node_idx != NULL_IDX);
                node = &nodes[node_idx];

                colourFlip(nodes, colours, node, false);

                const right_left_red = blk: {
                    if (node.right_idx == NULL_IDX) break :blk false;
                    const right = &nodes[node.right_idx];
                    // break :blk right.left_idx != NULL_IDX and (&nodes[right.left_idx]).colour == .Red;
                    break :blk right.left_idx != NULL_IDX and isRed(colours, right.left_idx);
                };

                if (right_left_red) {
                    var right_node = &nodes[node.right_idx];
                    const right_idx = rotateRight(nodes, colours, right_node, false);
                    assert(right_idx != NULL_IDX);

                    //todo: shouldn't this have already been done by the rotateRight function?
                    node.right_idx = right_idx;
                    right_node = &nodes[node.right_idx];
                    right_node.parent_idx = node.idx;

                    const subtree_root = rotateLeft(nodes, colours, node, false);
                    assert(subtree_root != NULL_IDX);
                    node = &nodes[subtree_root];
                    colourFlip(nodes, colours, node, false);
                }

                if (node.parent_idx == NULL_IDX) {
                    // node.colour = .Black;
                    colours.setValue(node.idx, Colour.Black);
                }
                return node_idx;
            }
            node.right_idx = deleteNode(nodes, colours, keys, node.right_idx, key);

            if (node.right_idx != NULL_IDX) {
                const right = &nodes[node.right_idx];
                right.parent_idx = node.idx;
            }

            const node_idx = fixUp(nodes, colours, node.idx);
            assert(node_idx != NULL_IDX);
            node = &nodes[node_idx];
            if (node.parent_idx == NULL_IDX) {
                // node.colour = .Black;
                colours.setValue(node.idx, Colour.Black);
            }

            return node.idx;
        }

        pub inline fn moveLeftRed(nodes: []Node, colours: *Colours, node_idx: u32) u32 {
            assert(node_idx != NULL_IDX);

            var node = &nodes[node_idx];
            colourFlip(colours, node, false);

            const right_left_red = blk: {
                if (node.right_idx == NULL_IDX) break :blk false;
                const right = &nodes[node.right_idx];
                // break :blk right.left_idx != NULL_IDX and (&nodes[right.left_idx]).colour == .Red;
                break :blk right.left_idx != NULL_IDX and isRed(colours, right.left_idx);
            };

            if (right_left_red) {
                const right_node = &nodes[node.right_idx];
                const right_idx = rotateRight(nodes, colours, right_node, false);
                assert(right_idx != NULL_IDX);

                // node.right_idx = right_idx;
                // right_node = &nodes[node.right_idx];
                // right_node.parent_idx = node.idx;

                const subtree_root = rotateLeft(nodes, colours, node, false);
                assert(subtree_root != NULL_IDX);
                node = &nodes[subtree_root];
                colourFlip(colours, node, false);
            }
            return node.idx;
        }

        pub inline fn replaceWithSuccessor(nodes: []Node, colours: *Colours, node: *Node) *Node {
            assert(node.right_idx != NULL_IDX);

            var successor_idx: u32 = NULL_IDX;

            node.right_idx = removeSuccessorNode(nodes, node.right_idx, &successor_idx);

            assert(successor_idx != NULL_IDX);

            const replacement_node = &nodes[successor_idx];

            replacement_node.left_idx = node.left_idx;
            replacement_node.right_idx = node.right_idx;
            replacement_node.parent_idx = node.parent_idx;
            // replacement_node.colour = node.colour;
            colours.setValue(replacement_node.idx, colours.isSet(node.idx));
            //can't I just do node.key_idx = replacement_node.key_idx here?

            //set node's parent and children's parent pointers to the new replacement node

            if (node.right_idx != NULL_IDX) {
                const right = &nodes[node.right_idx];
                right.parent_idx = replacement_node.idx;
            }

            if (node.left_idx != NULL_IDX) {
                const left = &nodes[node.left_idx];
                left.parent_idx = replacement_node.idx;
            }

            if (node.parent_idx != NULL_IDX) {
                assert(node.parent_idx != node.idx); //I'm in a lot of trouble if this happens
                const parent = &nodes[node.parent_idx];

                if (parent.right_idx == node.idx) {
                    assert(parent.left_idx != node.idx);
                    parent.right_idx = replacement_node.idx;
                } else {
                    assert(parent.left_idx == node.idx);
                    parent.left_idx = replacement_node.idx;
                }
            }

            @memset(node[0..1], undefined); //Make sure to trigger an error if this is used elsewhere

            return replacement_node;
        }

        pub fn removeSuccessorNode(
            nodes: []Node,
            colours: *Colours,
            start_idx: u32,
            ///An index variable which will be populated with the deleted node's index
            index_ptr: *u32,
        ) u32 {
            var node = &nodes[start_idx];
            if (node.left_idx == NULL_IDX) {
                index_ptr.* = node.idx;
                return NULL_IDX;
            }
            const move_left_red = blk: {
                // if (left.colour == .Red) break :blk false;
                if (isRed(colours, node.left_idx)) break :blk false;
                const left = &nodes[node.left_idx];
                // break :blk left.left_idx == NULL_IDX or (&nodes[left.left_idx]).colour == .Black;
                break :blk left.left_idx == NULL_IDX or !isRed(colours, left.left_idx);
            };
            if (move_left_red) {
                const moved_idx = moveLeftRed(nodes, colours, node.idx);
                assert(moved_idx != NULL_IDX);
                node = &nodes[moved_idx];
            }

            node.left_idx = removeSuccessorNode(nodes, colours, node.left_idx, index_ptr);

            //todo: This might be redundant. Do more testing to confirm
            if (node.left_idx != NULL_IDX) {
                const left = &nodes[node.left_idx];
                left.parent_idx = node.idx;
            }

            const balanced_idx = fixUp(nodes, colours, node.idx);
            assert(balanced_idx != NULL_IDX);
            return balanced_idx;
        }

        ///Fixes up the sub-tree after a delete operation
        ///
        /// We always balance/fix-up from the perspective of the parent - It makes things easier to reason about
        pub fn fixUp(nodes: []Node, colours: *Colours, parent_idx: u32) u32 {
            assert(parent_idx != NULL_IDX);

            {
                const parent_node = &nodes[parent_idx];

                const can_flip = blk: {
                    if (parent_node.left_idx == NULL_IDX or parent_node.right_idx == NULL_IDX) break :blk false;
                    break :blk isRed(colours, parent_node.left_idx) and isRed(colours, parent_node.right_idx);
                    // break :blk (&nodes[parent_node.left_idx]).colour == .Red and (&nodes[parent_node.right_idx]).colour == .Red;
                };

                if (can_flip) {
                    colourFlip(colours, parent_node, true);
                    return parent_idx; //After a colour flip, no more balancing needs to be done on the sub-tree
                }
            }

            var parent_node = &nodes[parent_idx];
            const hanging_right_link = blk: {
                if (parent_node.right_idx == NULL_IDX) break :blk false;
                // break :blk (&nodes[parent_node.right_idx]).colour == .Red;
                break :blk isRed(colours, parent_node.right_idx);
            };

            if (hanging_right_link) {
                const new_parent_idx = rotateLeft(nodes, colours, parent_node, true);
                assert(new_parent_idx != NULL_IDX);
                parent_node = &nodes[new_parent_idx];
                const can_flip = blk: {
                    if (parent_node.right_idx == NULL_IDX) break :blk false;
                    // break :blk left.colour == .Red and (&nodes[parent_node.right_idx]).colour == .Red;

                    //Because we just rotated left, we are guaranteed to have a left child
                    break :blk isRed(colours, parent_node.left_idx) and isRed(colours, parent_node.right_idx);
                };

                //This should never happen, but catch this in case it does and verify the logic
                assert(can_flip == false);
            }

            const double_left_red = blk: {
                if (parent_node.left_idx == NULL_IDX) break :blk false;
                // if (left.colour != .Red) break :blk false;
                if (!isRed(colours, parent_node.left_idx)) break :blk false;

                const left = &nodes[parent_node.left_idx];
                // break :blk left.left_idx != NULL_IDX and (&nodes[left.left_idx]).colour == .Red;
                break :blk left.left_idx != NULL_IDX and isRed(colours, left.left_idx);
            };

            if (double_left_red) {
                const new_parent_idx = rotateRight(nodes, colours, parent_node, true);
                assert(new_parent_idx != NULL_IDX);
                parent_node = &nodes[new_parent_idx];
                colourFlip(colours, parent_node, true); //After resolving a double left red, we always need a colour flip
            }

            return parent_node.idx;
        }

        pub fn colourFlip(colours: *Colours, node: *Node, safety_checks_for_insertion: bool) void {
            assert(node.right_idx != NULL_IDX);
            assert(node.left_idx != NULL_IDX);
            //Extra safety checks for colour flips during insertions
            if (safety_checks_for_insertion) {
                assert(isRed(colours, node.left_idx) and isRed(colours, node.right_idx));
            }

            colours.toggle(node.left_idx);
            colours.toggle(node.right_idx);
            colours.toggle(node.idx);
        }

        pub fn rotateLeft(nodes: []Node, colours: *Colours, node: *Node, safety_checks_for_insertion: bool) u32 {
            assert(node.right_idx != NULL_IDX);
            if (safety_checks_for_insertion) {
                assert(isRed(colours, node.right_idx));
            }
            const node_idx = node.idx; //All the lists maintain a direct mapping between each other, allowing us to index one with the index of another
            const right_child_idx = node.right_idx;
            const right_child = &nodes[right_child_idx];

            const node_colour = colours.isSet(node.idx);
            const right_colour = colours.isSet(right_child_idx);

            colours.setValue(node.idx, right_colour);
            colours.setValue(right_child_idx, node_colour);

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

        pub fn rotateRight(nodes: []Node, colours: *Colours, node: *Node, safety_checks_for_insertion: bool) u32 {
            assert(node.left_idx != NULL_IDX);

            const node_idx = node.idx;
            const left_child_idx = node.left_idx;
            const left_child = &nodes[left_child_idx];

            if (safety_checks_for_insertion) {
                assert(isRed(colours, left_child_idx));
                // assert(left_child.colour == .Red);
            }

            const node_colour = colours.isSet(node_idx);
            const left_child_colour = colours.isSet(left_child_idx);

            colours.setValue(node_idx, left_child_colour);
            colours.setValue(left_child_idx, node_colour);
            // node.colour = left_child_colour;
            // left_child.colour = node_colour;

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

        pub inline fn isRed(colours: *const Colours, idx: u32) bool {
            assert(idx != NULL_IDX);
            return !colours.isSet(idx);
        }
    };
}

// ----------------- Tests -----------------

fn test_cmp(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}
const T = Tree(u64, u64, test_cmp);
const expect = std.testing.expect;

test "isRed" {
    const allocator = std.testing.allocator;
    var colours = try T.Colours.initEmpty(allocator, 10);
    defer colours.deinit(allocator);
    colours.setValue(0, Colour.Red);

    try std.testing.expect(T.isRed(&colours, 0) == true);
}

test "rotateRight with parent and varying right_child cases" {
    const allocator = std.testing.allocator;
    const isRed = T.isRed;

    var nodes = try T.Nodes.initCapacity(allocator, 5);
    var colours = try T.Colours.initFull(allocator, 5); //Sets all nodes to black;
    defer nodes.deinit(allocator);
    defer colours.deinit(allocator);

    {
        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = NULL_IDX, .parent_idx = NULL_IDX };
        const subtree_root = Node{ .idx = 1, .left_idx = 2, .right_idx = NULL_IDX, .parent_idx = root.idx }; //The node to be rotated
        const sub_left = Node{ .idx = 2, .left_idx = 3, .right_idx = 4, .parent_idx = subtree_root.idx };
        const sub_left_left = Node{ .idx = 3, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = sub_left.idx };
        const sub_left_right = Node{ .idx = 4, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = sub_left.idx };

        nodes.appendSliceAssumeCapacity(([_]Node{ root, subtree_root, sub_left, sub_left_left, sub_left_right })[0..]);
        colours.setValue(sub_left.idx, Colour.Red);
        colours.setValue(sub_left_left.idx, Colour.Red);

        const new_subtree_root = T.rotateRight(nodes.items, &colours, &nodes.items[subtree_root.idx], true);
        try expect(new_subtree_root == sub_left.idx);

        try expect(nodes.items[root.idx].parent_idx == NULL_IDX);
        try expect(nodes.items[root.idx].left_idx == sub_left.idx);
        try expect(nodes.items[root.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, root.idx) == false);

        try expect(nodes.items[sub_left.idx].parent_idx == root.idx);
        try expect(nodes.items[sub_left.idx].left_idx == sub_left_left.idx);
        try expect(nodes.items[sub_left.idx].right_idx == subtree_root.idx);
        try expect(isRed(&colours, sub_left.idx) == false);

        try expect(nodes.items[sub_left_left.idx].parent_idx == sub_left.idx);
        try expect(nodes.items[sub_left_left.idx].left_idx == NULL_IDX);
        try expect(nodes.items[sub_left_left.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, sub_left_left.idx) == true);

        try expect(nodes.items[subtree_root.idx].parent_idx == sub_left.idx);
        try expect(nodes.items[subtree_root.idx].left_idx == sub_left_right.idx);
        try expect(nodes.items[subtree_root.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, subtree_root.idx) == true);

        try expect(nodes.items[sub_left_right.idx].parent_idx == subtree_root.idx);
        try expect(nodes.items[sub_left_right.idx].left_idx == NULL_IDX);
        try expect(nodes.items[sub_left_right.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, sub_left_right.idx) == false);
    }

    {
        nodes.clearRetainingCapacity();
        colours.setAll();
        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = NULL_IDX, .parent_idx = NULL_IDX };
        const subtree_root = Node{ .idx = 1, .left_idx = 2, .right_idx = NULL_IDX, .parent_idx = root.idx }; //The node to be rotated
        const sub_left = Node{ .idx = 2, .left_idx = 3, .right_idx = NULL_IDX, .parent_idx = subtree_root.idx };
        const sub_left_left = Node{ .idx = 3, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = sub_left.idx };

        nodes.appendSliceAssumeCapacity(([_]Node{ root, subtree_root, sub_left, sub_left_left })[0..]);
        colours.setValue(sub_left.idx, Colour.Red);
        colours.setValue(sub_left_left.idx, Colour.Red);

        const new_subtree_root = T.rotateRight(nodes.items, &colours, &nodes.items[subtree_root.idx], true);
        try expect(new_subtree_root == sub_left.idx);
        try expect(nodes.items[subtree_root.idx].left_idx == NULL_IDX);
    }
}

test "rotateRight with no parent and varying left_child cases" {
    const allocator = std.testing.allocator;
    const isRed = T.isRed;

    var nodes = try T.Nodes.initCapacity(allocator, 5);
    var colours = try T.Colours.initFull(allocator, 5); //Sets all nodes to black;
    defer nodes.deinit(allocator);
    defer colours.deinit(allocator);

    {
        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = NULL_IDX, .parent_idx = NULL_IDX };
        const left = Node{ .idx = 1, .left_idx = 2, .right_idx = 3, .parent_idx = 0 };
        const left_left = Node{ .idx = 2, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = left.idx };
        const left_right = Node{ .idx = 3, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = left.idx };

        nodes.appendSliceAssumeCapacity(([_]Node{ root, left, left_left, left_right })[0..]);
        colours.setValue(left.idx, Colour.Red);
        colours.setValue(left_left.idx, Colour.Red);

        const new_root = T.rotateRight(nodes.items, &colours, &nodes.items[root.idx], true);
        try expect(new_root == left.idx);

        try expect(new_root == left.idx);

        try expect(nodes.items[left.idx].parent_idx == NULL_IDX);
        try expect(nodes.items[left.idx].left_idx == left_left.idx);
        try expect(nodes.items[left.idx].right_idx == root.idx);
        try expect(isRed(&colours, left.idx) == false);

        try expect(nodes.items[left_left.idx].parent_idx == left.idx);
        try expect(nodes.items[left_left.idx].left_idx == NULL_IDX);
        try expect(nodes.items[left_left.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, left_left.idx) == true);

        try expect(nodes.items[root.idx].parent_idx == left.idx);
        try expect(nodes.items[root.idx].left_idx == left_right.idx);
        try expect(nodes.items[root.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, root.idx) == true);

        try expect(nodes.items[left_right.idx].parent_idx == root.idx);
        try expect(nodes.items[left_right.idx].left_idx == NULL_IDX);
        try expect(nodes.items[left_right.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, left_right.idx) == false);
    }

    {
        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = NULL_IDX, .parent_idx = NULL_IDX };
        const left = Node{ .idx = 1, .left_idx = 2, .right_idx = NULL_IDX, .parent_idx = 0 };
        const left_left = Node{ .idx = 2, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = left.idx };

        nodes.clearRetainingCapacity();
        colours.setAll();

        nodes.appendSliceAssumeCapacity(([_]Node{ root, left, left_left })[0..]);
        colours.setValue(left.idx, Colour.Red);
        colours.setValue(left_left.idx, Colour.Red);

        const new_root = T.rotateRight(nodes.items, &colours, &nodes.items[root.idx], true);
        try expect(new_root == left.idx);

        try expect(nodes.items[root.idx].left_idx == NULL_IDX);
    }
}

test "balanceTree colour flip" {
    const allocator = std.testing.allocator;
    const isRed = T.isRed;

    var nodes = try T.Nodes.initCapacity(allocator, 5);
    var colours = try T.Colours.initFull(allocator, 5); //Sets all nodes to black;
    defer nodes.deinit(allocator);
    defer colours.deinit(allocator);

    //Flipping the root
    {
        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = 2, .parent_idx = NULL_IDX };
        const left = Node{ .idx = 1, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 0 };
        const right = Node{ .idx = 2, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 0 };

        nodes.appendSliceAssumeCapacity(([_]Node{ root, left, right })[0..]);
        colours.setValue(left.idx, Colour.Red);
        colours.setValue(right.idx, Colour.Red);

        const new_root_idx = T.balanceTree(nodes.items, &colours, root.idx);
        try expect(new_root_idx == root.idx);

        try expect(nodes.items[root.idx].left_idx == left.idx);
        try expect(nodes.items[root.idx].right_idx == right.idx);
        try expect(nodes.items[root.idx].parent_idx == NULL_IDX);

        try expect(isRed(&colours, root.idx) == false);
        try expect(isRed(&colours, left.idx) == false);
        try expect(isRed(&colours, right.idx) == false);
    }

    //Non-root
    {
        nodes.clearRetainingCapacity();
        colours.setAll();
        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = NULL_IDX, .parent_idx = NULL_IDX };
        const subtree_root = Node{ .idx = 1, .left_idx = 2, .right_idx = 3, .parent_idx = root.idx };
        const sub_left = Node{ .idx = 2, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 1 };
        const sub_right = Node{ .idx = 3, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 1 };

        nodes.appendSliceAssumeCapacity(([_]Node{ root, subtree_root, sub_left, sub_right })[0..]);
        colours.setValue(sub_left.idx, Colour.Red);
        colours.setValue(sub_right.idx, Colour.Red);

        const new_root_idx = T.balanceTree(nodes.items, &colours, subtree_root.idx);
        try expect(new_root_idx == root.idx);

        try expect(isRed(&colours, root.idx) == false);
        try expect(isRed(&colours, subtree_root.idx) == true);
        try expect(isRed(&colours, sub_left.idx) == false);
        try expect(isRed(&colours, sub_right.idx) == false);
    }
}

test "balanceTree rotateLeft" {
    const allocator = std.testing.allocator;
    const isRed = T.isRed;

    var nodes = try T.Nodes.initCapacity(allocator, 5);
    var colours = try T.Colours.initFull(allocator, 5); //Sets all nodes to black;
    defer nodes.deinit(allocator);
    defer colours.deinit(allocator);

    //rotateLeft with parent and present right_left child
    {
        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = NULL_IDX, .parent_idx = NULL_IDX };
        const subtree_root = Node{ .idx = 1, .left_idx = 2, .right_idx = 3, .parent_idx = root.idx }; //The node to be rotated
        const subtree_left = Node{ .idx = 2, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = subtree_root.idx };
        const subtree_right = Node{ .idx = 3, .left_idx = 4, .right_idx = NULL_IDX, .parent_idx = subtree_root.idx };
        const subtree_right_left = Node{ .idx = 4, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = subtree_right.idx };

        nodes.appendSliceAssumeCapacity(([_]Node{ root, subtree_root, subtree_left, subtree_right, subtree_right_left })[0..]);
        try expect(isRed(&colours, root.idx) == false); //Just in case someone flips the logic for which bit is red or black

        colours.setValue(subtree_right.idx, Colour.Red);

        const new_root_idx = T.balanceTree(nodes.items, &colours, subtree_root.idx);
        try expect(new_root_idx == root.idx);

        try expect(nodes.items[root.idx].parent_idx == NULL_IDX);
        try expect(nodes.items[root.idx].left_idx == subtree_right.idx);
        try expect(nodes.items[root.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, root.idx) == false);

        try expect(nodes.items[subtree_right.idx].parent_idx == root.idx);
        try expect(nodes.items[subtree_right.idx].left_idx == subtree_root.idx);
        try expect(nodes.items[subtree_right.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, subtree_right.idx) == false);

        try expect(nodes.items[subtree_root.idx].parent_idx == subtree_right.idx);
        try expect(nodes.items[subtree_root.idx].left_idx == subtree_left.idx);
        try expect(nodes.items[subtree_root.idx].right_idx == subtree_right_left.idx);
        try expect(isRed(&colours, subtree_root.idx) == true);

        try expect(nodes.items[subtree_left.idx].parent_idx == subtree_root.idx);
        try expect(nodes.items[subtree_left.idx].left_idx == NULL_IDX);
        try expect(nodes.items[subtree_left.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, subtree_left.idx) == false);

        try expect(nodes.items[subtree_right_left.idx].parent_idx == subtree_root.idx);
        try expect(nodes.items[subtree_right_left.idx].left_idx == NULL_IDX);
        try expect(nodes.items[subtree_right_left.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, subtree_right_left.idx) == false);
    }

    //rotateLeft with parent and absent right_left child
    {
        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = NULL_IDX, .parent_idx = NULL_IDX };
        const subtree_root = Node{ .idx = 1, .left_idx = 2, .right_idx = 3, .parent_idx = root.idx }; //The node to be rotated
        const subtree_left = Node{ .idx = 2, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = subtree_root.idx };
        const subtree_right = Node{ .idx = 3, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = subtree_root.idx };

        nodes.clearRetainingCapacity();
        colours.setAll();

        nodes.appendSliceAssumeCapacity(([_]Node{ root, subtree_root, subtree_left, subtree_right })[0..]);
        colours.setValue(subtree_right.idx, Colour.Red);

        const new_root_idx = T.balanceTree(nodes.items, &colours, subtree_root.idx);
        try expect(new_root_idx == root.idx);

        try expect(nodes.items[subtree_root.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, subtree_root.idx) == true);
    }

    //rotateLeft with no parent and present right_left child
    {
        nodes.clearRetainingCapacity();
        colours.setAll();

        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = 2, .parent_idx = NULL_IDX };
        const root_left = Node{ .idx = 1, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = root.idx };
        const root_right = Node{ .idx = 2, .left_idx = 3, .right_idx = NULL_IDX, .parent_idx = root.idx };
        const root_right_left = Node{ .idx = 3, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = root_right.idx };

        colours.setValue(root.right_idx, Colour.Red);
        nodes.appendSliceAssumeCapacity(([_]Node{ root, root_left, root_right, root_right_left })[0..]);
        const new_root_idx = T.balanceTree(nodes.items, &colours, root.idx);

        try expect(new_root_idx == root_right.idx);

        try expect(nodes.items[root_right.idx].parent_idx == NULL_IDX);
        try expect(nodes.items[root_right.idx].left_idx == root.idx);
        try expect(nodes.items[root_right.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, root_right.idx) == false);

        try expect(nodes.items[root.idx].parent_idx == root_right.idx);
        try expect(nodes.items[root.idx].left_idx == root_left.idx);
        try expect(nodes.items[root.idx].right_idx == root_right_left.idx);
        try expect(isRed(&colours, root.idx) == true);

        try expect(nodes.items[root_left.idx].parent_idx == root.idx);
        try expect(nodes.items[root_left.idx].left_idx == NULL_IDX);
        try expect(nodes.items[root_left.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, root_left.idx) == false);

        try expect(nodes.items[root_right_left.idx].parent_idx == root.idx);
        try expect(nodes.items[root_right_left.idx].left_idx == NULL_IDX);
        try expect(nodes.items[root_right_left.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, root_right_left.idx) == false);
    }

    //rotateLeft with parent and no present right_left child
    {
        nodes.clearRetainingCapacity();
        colours.setAll();

        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = 2, .parent_idx = NULL_IDX };
        const root_left = Node{ .idx = 1, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = root.idx };
        const root_right = Node{ .idx = 2, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = root.idx };

        colours.setValue(root.right_idx, Colour.Red);
        nodes.appendSliceAssumeCapacity(([_]Node{ root, root_left, root_right })[0..]);
        const new_root_idx = T.balanceTree(nodes.items, &colours, root.idx);

        try expect(new_root_idx == root_right.idx);

        try expect(nodes.items[root.idx].right_idx == NULL_IDX);
    }
}

test "balanceTree rotateRight" {
    const allocator = std.testing.allocator;
    const isRed = T.isRed;

    var nodes = try T.Nodes.initCapacity(allocator, 5);
    var colours = try T.Colours.initFull(allocator, 5); //sets all nodes to black
    defer nodes.deinit(allocator);
    defer colours.deinit(allocator);

    //rotateRight with parent and present left_right child
    {
        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = NULL_IDX, .parent_idx = NULL_IDX };
        const subtree_root = Node{ .idx = 1, .left_idx = 2, .right_idx = NULL_IDX, .parent_idx = root.idx }; //The node to be rotated
        const sub_left = Node{ .idx = 2, .left_idx = 3, .right_idx = 4, .parent_idx = subtree_root.idx };
        const sub_left_left = Node{ .idx = 3, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = sub_left.idx };
        const sub_left_right = Node{ .idx = 4, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = sub_left.idx };

        nodes.appendSliceAssumeCapacity(([_]Node{ root, subtree_root, sub_left, sub_left_left, sub_left_right })[0..]);
        colours.setValue(sub_left.idx, Colour.Red);
        colours.setValue(sub_left_left.idx, Colour.Red);

        const new_subtree_root_idx = T.balanceTree(nodes.items, &colours, subtree_root.idx);
        try expect(new_subtree_root_idx == root.idx);

        try expect(nodes.items[root.idx].parent_idx == NULL_IDX);
        try expect(nodes.items[root.idx].left_idx == sub_left.idx);
        try expect(nodes.items[root.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, root.idx) == false);

        try expect(nodes.items[sub_left.idx].parent_idx == root.idx);
        try expect(nodes.items[sub_left.idx].left_idx == sub_left_left.idx);
        try expect(nodes.items[sub_left.idx].right_idx == subtree_root.idx);
        try expect(isRed(&colours, sub_left.idx) == true);

        try expect(nodes.items[sub_left_left.idx].parent_idx == sub_left.idx);
        try expect(nodes.items[sub_left_left.idx].left_idx == NULL_IDX);
        try expect(nodes.items[sub_left_left.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, sub_left_left.idx) == false);

        try expect(nodes.items[subtree_root.idx].parent_idx == sub_left.idx);
        try expect(nodes.items[subtree_root.idx].left_idx == sub_left_right.idx);
        try expect(nodes.items[subtree_root.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, subtree_root.idx) == false);

        try expect(nodes.items[sub_left_right.idx].parent_idx == subtree_root.idx);
        try expect(nodes.items[sub_left_right.idx].left_idx == NULL_IDX);
        try expect(nodes.items[sub_left_right.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, sub_left_right.idx) == false);
    }

    //rotateRight with parent and absent left_right child
    {
        nodes.clearRetainingCapacity();
        colours.setAll();

        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = NULL_IDX, .parent_idx = NULL_IDX };
        const subtree_root = Node{ .idx = 1, .left_idx = 2, .right_idx = NULL_IDX, .parent_idx = root.idx }; //The node to be rotated
        const sub_left = Node{ .idx = 2, .left_idx = 3, .right_idx = NULL_IDX, .parent_idx = subtree_root.idx };
        const sub_left_left = Node{ .idx = 3, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = sub_left.idx };

        nodes.appendSliceAssumeCapacity(([_]Node{ root, subtree_root, sub_left, sub_left_left })[0..]);
        colours.setValue(sub_left.idx, Colour.Red);
        colours.setValue(sub_left_left.idx, Colour.Red);

        const new_subtree_root_idx = T.balanceTree(nodes.items, &colours, subtree_root.idx);
        try expect(new_subtree_root_idx == root.idx);
        try expect(nodes.items[subtree_root.idx].left_idx == NULL_IDX);
    }

    //rotateRight with no parent and present left_right child
    {
        nodes.clearRetainingCapacity();
        colours.setAll();

        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = NULL_IDX, .parent_idx = NULL_IDX };
        const left = Node{ .idx = 1, .left_idx = 2, .right_idx = 3, .parent_idx = 0 };
        const left_left = Node{ .idx = 2, .right_idx = NULL_IDX, .left_idx = NULL_IDX, .parent_idx = 1 };
        const left_right = Node{ .idx = 3, .right_idx = NULL_IDX, .left_idx = NULL_IDX, .parent_idx = 1 };

        nodes.appendSliceAssumeCapacity(([_]Node{ root, left, left_left, left_right })[0..]);
        colours.setValue(left.idx, Colour.Red);
        colours.setValue(left_left.idx, Colour.Red);

        const new_root_idx = T.balanceTree(nodes.items, &colours, root.idx);
        try expect(new_root_idx == left.idx);

        try expect(nodes.items[left.idx].parent_idx == NULL_IDX);
        try expect(nodes.items[left.idx].left_idx == left_left.idx);
        try expect(nodes.items[left.idx].right_idx == root.idx);
        try expect(isRed(&colours, left.idx) == false);

        try expect(nodes.items[left_left.idx].parent_idx == left.idx);
        try expect(nodes.items[left_left.idx].left_idx == NULL_IDX);
        try expect(nodes.items[left_left.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, left_left.idx) == false);

        try expect(nodes.items[root.idx].parent_idx == left.idx);
        try expect(nodes.items[root.idx].left_idx == left_right.idx);
        try expect(nodes.items[root.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, root.idx) == false);

        try expect(nodes.items[left_right.idx].parent_idx == root.idx);
        try expect(nodes.items[left_right.idx].left_idx == NULL_IDX);
        try expect(nodes.items[left_right.idx].right_idx == NULL_IDX);
        try expect(isRed(&colours, left_right.idx) == false);
    }
}

test "moveLeftRed" {
    const allocator = std.testing.allocator;
    const isRed = T.isRed;

    var nodes = try T.Nodes.initCapacity(allocator, 10);
    var colours = try T.Colours.initFull(allocator, 10); //Sets all nodes to black;
    defer nodes.deinit(allocator);
    defer colours.deinit(allocator);

    //No right_left_red
    {
        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = 2, .parent_idx = NULL_IDX };
        const left = Node{ .idx = 1, .left_idx = 3, .right_idx = 4, .parent_idx = 0 };
        const right = Node{ .idx = 2, .left_idx = 5, .right_idx = 6, .parent_idx = 0 };

        const left_left = Node{ .idx = 3, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 1 };
        const left_right = Node{ .idx = 4, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 1 };

        const right_left = Node{ .idx = 5, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 2 };
        const right_right = Node{ .idx = 6, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 2 };

        nodes.appendSliceAssumeCapacity(([_]Node{ root, left, right, left_left, left_right, right_left, right_right })[0..]);

        const new_root_idx = T.moveLeftRed(nodes.items, &colours, root.idx);
        try expect(new_root_idx == root.idx);

        try expect(isRed(&colours, root.idx) == true);
        try expect(isRed(&colours, left.idx) == true);
        try expect(isRed(&colours, right.idx) == true);

        try expect(isRed(&colours, left_left.idx) == false);
        try expect(isRed(&colours, left_right.idx) == false);

        try expect(isRed(&colours, right_left.idx) == false);
        try expect(isRed(&colours, right_right.idx) == false);
    }

    // With right_left_red
    {
        nodes.clearRetainingCapacity();
        colours.setAll(); //sets all nodes to black

        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = 2, .parent_idx = NULL_IDX };
        const left = Node{ .idx = 1, .left_idx = 3, .right_idx = 4, .parent_idx = 0 };
        const right = Node{ .idx = 2, .left_idx = 5, .right_idx = 6, .parent_idx = 0 };

        const left_left = Node{ .idx = 3, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 1 };
        const left_right = Node{ .idx = 4, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 1 };

        const right_left = Node{ .idx = 5, .left_idx = 7, .right_idx = 8, .parent_idx = 2 };
        const right_right = Node{ .idx = 6, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 2 };

        const right_left_left = Node{ .idx = 7, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 5 };
        const right_left_right = Node{ .idx = 8, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 5 };

        nodes.appendSliceAssumeCapacity(([_]Node{
            root,
            left,
            right,
            left_left,
            left_right,
            right_left,
            right_right,
            right_left_left,
            right_left_right,
        })[0..]);
        colours.setValue(right_left.idx, Colour.Red);

        const new_root_idx = T.moveLeftRed(nodes.items, &colours, root.idx);
        try expect(new_root_idx == right_left.idx);
        try expect(nodes.items[right_left.idx].right_idx == right.idx);
        try expect(isRed(&colours, right_left.idx) == false);

        try expect(nodes.items[right.idx].parent_idx == right_left.idx);
        try expect(isRed(&colours, right.idx) == false);

        try expect(isRed(&colours, right_left.left_idx) == false);
    }
}

test "fixUp" {
    const allocator = std.testing.allocator;
    const isRed = T.isRed;

    var nodes = try T.Nodes.initCapacity(allocator, 7);
    var colours = try T.Colours.initFull(allocator, 7); //Sets all nodes to black;
    defer nodes.deinit(allocator);
    defer colours.deinit(allocator);

    //fixup colour flip
    {
        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = 2, .parent_idx = NULL_IDX };
        const left = Node{ .idx = 1, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 0 };
        const right = Node{ .idx = 2, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 0 };

        colours.setValue(left.idx, Colour.Red);
        colours.setValue(right.idx, Colour.Red);

        nodes.appendSliceAssumeCapacity(&[_]Node{ root, left, right });

        const new_root_idx = T.fixUp(nodes.items, &colours, root.idx);

        try expect(new_root_idx == root.idx);
        try expect(nodes.items[root.idx].left_idx == left.idx);
        try expect(nodes.items[root.idx].right_idx == right.idx);

        try expect(isRed(&colours, root.idx) == true);
        try expect(isRed(&colours, left.idx) == false);
        try expect(isRed(&colours, right.idx) == false);
    }

    //fixup hanging right red link
    {
        nodes.clearRetainingCapacity();
        colours.setAll();

        const root = Node{ .idx = 0, .left_idx = NULL_IDX, .right_idx = 1, .parent_idx = NULL_IDX };
        const right = Node{ .idx = 1, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 0 };
        colours.setValue(right.idx, Colour.Red);

        nodes.appendSliceAssumeCapacity(&[_]Node{ root, right });

        const new_root_idx = T.fixUp(nodes.items, &colours, root.idx);
        try expect(new_root_idx == right.idx);

        try expect(isRed(&colours, right.idx) == false);
        try expect(isRed(&colours, root.idx) == true);
    }

    //fixup double red left links
    {
        nodes.clearRetainingCapacity();
        colours.setAll();

        const root = Node{ .idx = 0, .left_idx = 1, .right_idx = NULL_IDX, .parent_idx = NULL_IDX };
        const left = Node{ .idx = 1, .left_idx = 2, .right_idx = NULL_IDX, .parent_idx = 0 };
        const left_left = Node{ .idx = 2, .left_idx = NULL_IDX, .right_idx = NULL_IDX, .parent_idx = 1 };

        nodes.appendSliceAssumeCapacity(&[_]Node{ root, left, left_left });
        colours.setValue(left.idx, Colour.Red);
        colours.setValue(left_left.idx, Colour.Red);

        const new_root_idx = T.fixUp(nodes.items, &colours, root.idx);

        try expect(new_root_idx == left.idx);
        try expect(isRed(&colours, left.idx) == true);
        try expect(isRed(&colours, left_left.idx) == false);
        try expect(isRed(&colours, root.idx) == false);
    }
}

test "removeSuccessorNode" {
    const allocator = std.testing.allocator;

    var tree = try T.initCapacity(allocator, 17);
    defer tree.deinit(allocator);

    //With left_idx and moveLeftRed
    {
        for (0..7) |i| {
            try tree.insertAssumeCapacity(.{ .key = @intCast(i * 5), .value = i * 10 });
        }

        var index_ptr: u32 = NULL_IDX;

        // const keys = [_]u6{ 15, 5, 25, 0, 10, 5, 30 };
        // nodes.appendSliceAssumeCapacity(([_]Node{ root, left, right, left_left, left_right, right_left, right_right })[0..]);

        const new_root_idx = T.removeSuccessorNode(tree.nodes.items, &tree.colours, tree.root_idx, &index_ptr);
        // for (tree.nodes.items) |node| {
        //     std.debug.print("\nNode:{}\nKey:{}. isRed:{}\n", .{ node, tree.keys.items[node.idx], T.isRed(&tree.colours, node.idx) });
        // }
        try expect(index_ptr == 0);
        try expect(tree.keys.items[new_root_idx] == 25);
        try expect(T.isRed(&tree.colours, new_root_idx) == true);

        const new_root_left_idx = 3;
        const successor_parent_idx = 1;

        try expect(tree.nodes.items[new_root_idx].left_idx == new_root_left_idx);
        try expect(tree.nodes.items[successor_parent_idx].left_idx == NULL_IDX);
    }
}
