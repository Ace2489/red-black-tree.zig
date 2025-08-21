# red-black-tree.zig
An implementation of **left‑leaning red–black (LLRB)** trees in Zig.

## Table of Contents
- [Overview](#Overview)
- [Integration into other projects](#integration-into-other-projects)
- [Installation](#installation)
- [Usage](#usage)
- [Architecture](#architecture-and-design)
- [Correctness & Safety](#correctness-and-safety)
- [Property-Based Testing](#property-based-testing)

## Overview

Self‑balancing binary search trees keep operations near **O(log n)** by performing small, local transformations (rotations and color flips) as you insert and delete keys. That predictable height makes them great building blocks for ordered maps/sets, schedulers, indexes, and any workload that needs fast, ordered data.

> Note: Most database storage engines use **B/B+‑trees** (another kind of self-balancing tree) for their storage engines
### What is an LLRB tree?

An LLRB is a variant of a red–black tree that enforces two extra constraints:

1. Left‑leaning red links only.
2. **No two reds in a row** – a red node cannot have a red child.

These rules, plus standard red–black invariants, simplify code and proofs while preserving balanced‑tree guarantees.

### Invariants enforced

* **Root is black.**
* **Red nodes have black children.** (no consecutive reds)
* **Black‑height is uniform** across all root→null paths.
* **BST ordering**: `left < node < right` under the chosen comparator.
* **Left‑leaning**: no right‑red edge after fix‑ups.

### Operations & complexity

* **Search / contains**: `O(log n)` average/worst.
* **Insert**: `O(log n)` with at most a constant number of rotations per level.
* **Delete / deleteMin / deleteMax**: `O(log n)`; implemented via top‑down transformations (move‑red‑left/right, rotations, color flips) to avoid post‑recursion fix‑ups.
* **Ordered ops**: Range/filter, min/max, order.

*I recommend this [playlist](https://www.youtube.com/playlist?list=PLnp31xXvnfRrYOYhFXExoXfP8uhHHCIri) by UC Berkeley to fully understand the theory behind this data structure. It's very understandable :)*

## Integration into Other Projects
To see an example of an integration into a bigger project, I used this tree as the backing storage for an in-memory database [here](https://github.com/Ace2489/zig-comptime-db).

## Installation

Add the package to your dependencies:
```bash
zig fetch --save git+https://github.com/Ace2489/red-black-tree.zig
```

Expose the module to your application in your `build.zig` file:

```bash
// in your build.zig
const llrb = b.dependency("llrb");
exe_mod.addImport("llrb", llrb.module("llrb"));
  ```
Import and use the LLRB tree in your Zig code:

```zig
// In your Zig source file
const LLRB = @import("llrb");

pub fn main() void {
   var gpa = std.heap.DebugAllocator(.{}).init;
   const allocator = gpa.allocator();

   const Tree = LLRB.Tree;
   //More code here
}
```

## Usage
### Initialisation
```zig
const T = Tree(u64, u64, comp);

pub fn comp(a:u64, b:u64) std.math.Order{
  //body here
}
```


The first and second arguments indicate the `key` and `value` types for the tree, respectively. The comp function is a user-defined function which takes in two keys and generates the ordering (`lt`, `gt`, `eq`, see [here](https://ziglang.org/documentation/master/std/#std.math.Order)) between them. 
```zig
var tree = T.initCapacity(allocator, 10);
// or var tree = T.empty;
```

### Insertion
```zig
//Make sure to reserve space for new elements, if needed
try tree.reserveCapacity(allocator, 10);
try tree.insertAssumeCapacity(.{.key = 5, .value = 50});
```
Even though the insertion can fail, that only occurs when the maximum number of nodes which can be inserted this tree has been reached (0xFFFFFFFF if you're wondering, more on this later). 

For most cases, you can be assured that the insertion will go through — provided there's already been available memory allocated for the new insertions.

### Search
```zig
const value = tree.get(5);
//value will be set to null if the entry does not exist in the tree
```
### Deletion
```zig
const deleted_entry = tree.delete(5);
//If deletion fails, deleted_entry will be null 
```
### Range
```zig
var out_buffer: [20]Key = undefined; 
//Gets all the keys that fall between min and max
const count = tree.range(1, 100, &out_buffer);
```
### Update
Update replaces the value of an existing key.
If the key is not found, it returns an `EntryNotFound` error.

```zig
const kv = .{ .key = 10, .value = "TEN" };
const updated = try tree.update(kv);

std.debug.print("Updated key {d} -> {s}\n", .{ updated.key, updated.value });
```

### Range Iterator
You can iterate through keys between two bounds `[min, max]`.

```zig
var it = tree.rangeIterator(5, 15); 
while (it.next()) |key| {
std.debug.print("Key in range: {d}\n", .{key});
}
```
## Architecture and Design
### Nodes, Arraylists, and Indexes
Every node is a 16-byte struct, this is the same regardless of the key and value types.
```zig
pub const Node = struct {
    idx: u32 = NULL_IDX,
    left_idx: u32 = NULL_IDX,
    right_idx: u32 = NULL_IDX,
    parent_idx: u32,
};
```
In typical implementations, the left, right, and parent_pointers would be implemented as regular pointers. Here, we use u32 indexes into a backing array. Doing this has two advantages:

- Each index is half the size of a regular pointer, meaning we can fit twice as many nodes into the same space.
- A backing array allows memory management(allocation, de-allocation, and deinitialisation) to be much more straightforward — it's essentially just working with arrays. In a more typical pointer-based scenario, deinitialisation would require traversing the entire tree and freeing each node individually.

Admittedly, using a u32 value instead of the u64 pointer(on most systems) does limit the number of possible addressable elements to 4,294,967,295 (0xFFFFFFFF) elements (see where the number came from?), but for an in-memory database, that should be more than fine.


In addition, using arrays as the backing storage has the added benefit of improving cache locality and reducing thrashing. Neat!

### Keys, Values, and Colours
```zig
pub const Keys = std.ArrayListUnmanaged(K);
pub const Values = std.ArrayListUnmanaged(V);
pub const Nodes = std.ArrayListUnmanaged(Node);
pub const Colours = std.DynamicBitSetUnmanaged;

pub const Colour = struct {
    pub const Red = false;
    pub const Black = true;
};
```
All backing arrays maintain a one-to-one mapping with each other, meaning that getting the required data for a node is trivial once the index is in possession. Using an arraylist for the colours would be wasteful, as each colour element would occupy 1 byte of storage, even though only 1/8th of a byte(1 bit) is needed to store a colour. 

The `DynamicBitSetUnmanaged` is a data structure in Zig's stdlib which allows storing an "array" of bits using an integer as the backing store.

## Correctness and Safety

The biggest issue I faced with implementing this was **ensuring correctness** of the implementation. Roughly speaking, bugs fall into two main categories:

### 1. Wrong Data Order (Violating the BST Property)

This is the easier class of bug: violations occur when the insertion logic is flawed (e.g., incorrect comparisons, choosing the wrong branch, or stopping traversal too early). The actual code that traverses the tree to find the insertion branch is short and relatively easy to verify with tests.

**Mitigation:**

* Perform bulk insertions up to capacity.
* Verify that each inserted key, when queried, yields the correct value.
* Simple tests for insertion logic.

### 2. Tree Inconsistencies
This is the harder problem. Even if the BST property is correct, the balancing logic can go wrong. Issues arise during:

* Rotations
* Rebalancing
* Deletion
* Successor replacement

A single subtle bug in these operations can silently corrupt the tree. In the best case, an operation crashes and we find the cause. In the worst case, the tree silently degrades into an **O(n)** linked list, or worse, violates balance properties without detection.

**Mitigation:**

* **Unit tests** to cover the logic for most of the internal tree methods (rotations, flips, fix-ups). 
* **Property-based testing**: Random sequences of insertions/deletions are carried out on the tree. For each operation, the `verifyRBTreeInvariants` is run to verify that the tree still meets all of the constraints.
* **Assertions as final line of defense**:  Liberal use of debug assertions, compiled in `ReleaseSafe`, to fail fast instead of silently corrupting.

## Property-Based Testing

To validate structural invariants, `verifyRBTreeInvariants` traverses the entire tree and checks all LLRB properties:

* **BST property**: All left descendants < node < all right descendants.
* **No right-leaning red links**: Ensures the “left-leaning” invariant.
* **No two consecutive reds**: Red links cannot form a chain.
* **Balanced black height**: Every path from root to leaf has the same number of black links.

### Example: Catching Violations

Imagine we insert values `[1, 2, 3]`:

* Without proper balancing, the tree could degrade into a right-leaning chain: `1 → 2 → 3`.
* The invariant checker would flag this as illegal because a red link is leaning right.

Another example:

* If both a node and its left child are red (`node.red = true` and `node.left.red = true`), this forms a “double-red” violation.
* The invariant checker immediately detects and fails the test.

### Testing Strategy

1. Perform a large number of random insertions and deletions.
2. After every deletion, run the invariant-checking subroutine.
3. Crashes or assertion failures point directly to structural corruption. 

This approach has already uncovered subtle bugs that would have been very difficult to catch with unit tests alone. 

