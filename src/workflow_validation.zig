const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Legacy validation (used by api.zig for POST /runs) ────────────────

pub const ValidateError = error{
    StepMustBeObject,
    StepIdMissingOrNotString,
    StepIdEmpty,
    StepIdDuplicate,
    DependsOnNotArray,
    DependsOnItemNotString,
    DependsOnDuplicate,
    DependsOnUnknownStepId,
    RetryMustBeObject,
    MaxAttemptsMustBePositiveInteger,
    TimeoutMsMustBePositiveInteger,
    OutOfMemory,
};

/// Validate steps payload for POST /runs.
/// Ensures structure is internally consistent before DB writes.
pub fn validateStepsForCreateRun(
    allocator: std.mem.Allocator,
    steps_array: []const std.json.Value,
) ValidateError!void {
    var step_defs = std.StringHashMap(void).init(allocator);
    defer step_defs.deinit();

    for (steps_array) |step_val| {
        if (step_val != .object) return error.StepMustBeObject;
        const step_obj = step_val.object;

        const def_step_id = getJsonString(step_obj, "id") orelse return error.StepIdMissingOrNotString;
        if (def_step_id.len == 0) return error.StepIdEmpty;
        if (step_defs.contains(def_step_id)) return error.StepIdDuplicate;
        step_defs.put(def_step_id, {}) catch return error.OutOfMemory;

        const step_type = getJsonString(step_obj, "type") orelse "task";
        validateStepTypeRules(step_type, step_obj) catch |err| return err;
        validateExecutionControls(step_obj) catch |err| return err;
        validateDependsOnTypes(allocator, step_obj) catch |err| return err;
    }

    for (steps_array) |step_val| {
        const step_obj = step_val.object;
        const deps_val = step_obj.get("depends_on") orelse continue;
        for (deps_val.array.items) |dep_item| {
            if (!step_defs.contains(dep_item.string)) {
                return error.DependsOnUnknownStepId;
            }
        }
    }
}

fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    if (val == .string) return val.string;
    return null;
}

fn validateStepTypeRules(step_type: []const u8, step_obj: std.json.ObjectMap) ValidateError!void {
    // No specific rules for current step types (task, route, interrupt, agent, send, transform, subgraph)
    _ = step_type;
    _ = step_obj;
}

fn validateDependsOnTypes(allocator: std.mem.Allocator, step_obj: std.json.ObjectMap) ValidateError!void {
    if (step_obj.get("depends_on")) |deps_val| {
        if (deps_val != .array) return error.DependsOnNotArray;
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        for (deps_val.array.items) |dep_item| {
            if (dep_item != .string) return error.DependsOnItemNotString;
            if (seen.contains(dep_item.string)) return error.DependsOnDuplicate;
            seen.put(dep_item.string, {}) catch return error.OutOfMemory;
        }
    }
}

fn validateExecutionControls(step_obj: std.json.ObjectMap) ValidateError!void {
    if (step_obj.get("retry")) |retry_val| {
        if (retry_val != .object) return error.RetryMustBeObject;
        if (retry_val.object.get("max_attempts")) |ma| {
            if (ma != .integer or ma.integer < 1) {
                return error.MaxAttemptsMustBePositiveInteger;
            }
        }
    }

    if (step_obj.get("timeout_ms")) |timeout_val| {
        if (timeout_val != .integer or timeout_val.integer < 1) {
            return error.TimeoutMsMustBePositiveInteger;
        }
    }
}

// ── New graph-based workflow validation ───────────────────────────────

pub const ValidationError = struct {
    err_type: []const u8,
    node: ?[]const u8,
    key: ?[]const u8,
    message: []const u8,
};

/// Validate a workflow definition JSON (new graph format).
/// Returns a slice of ValidationError; caller must free with alloc.free().
/// Individual string fields inside each ValidationError point into the
/// parsed JSON tree (or are literals) and do not need separate freeing.
pub fn validate(alloc: Allocator, definition_json: []const u8) ![]ValidationError {
    var errors: std.ArrayListUnmanaged(ValidationError) = .empty;
    defer errors.deinit(alloc);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, definition_json, .{}) catch {
        try errors.append(alloc, .{
            .err_type = "parse_error",
            .node = null,
            .key = null,
            .message = "failed to parse workflow JSON",
        });
        return errors.toOwnedSlice(alloc);
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try errors.append(alloc, .{
            .err_type = "parse_error",
            .node = null,
            .key = null,
            .message = "workflow must be a JSON object",
        });
        return errors.toOwnedSlice(alloc);
    }
    const root = parsed.value.object;

    // Extract nodes map
    const nodes_val = root.get("nodes") orelse {
        try errors.append(alloc, .{
            .err_type = "missing_field",
            .node = null,
            .key = "nodes",
            .message = "workflow must have a 'nodes' object",
        });
        return errors.toOwnedSlice(alloc);
    };
    if (nodes_val != .object) {
        try errors.append(alloc, .{
            .err_type = "missing_field",
            .node = null,
            .key = "nodes",
            .message = "'nodes' must be an object",
        });
        return errors.toOwnedSlice(alloc);
    }
    const nodes = nodes_val.object;

    // Extract edges array
    const edges_val = root.get("edges") orelse {
        try errors.append(alloc, .{
            .err_type = "missing_field",
            .node = null,
            .key = "edges",
            .message = "workflow must have an 'edges' array",
        });
        return errors.toOwnedSlice(alloc);
    };
    if (edges_val != .array) {
        try errors.append(alloc, .{
            .err_type = "missing_field",
            .node = null,
            .key = "edges",
            .message = "'edges' must be an array",
        });
        return errors.toOwnedSlice(alloc);
    }
    const edges = edges_val.array.items;

    // Extract state_schema (may be absent or empty object)
    var state_schema: ?std.json.ObjectMap = null;
    if (root.get("state_schema")) |ss_val| {
        if (ss_val == .object) state_schema = ss_val.object;
    }

    // --- Collect send target_nodes (exempt from reachability) ---
    var send_targets = std.StringHashMap(void).init(alloc);
    defer send_targets.deinit();
    var node_it = nodes.iterator();
    while (node_it.next()) |entry| {
        const nobj = entry.value_ptr.*;
        if (nobj != .object) continue;
        const ntype = getJsonStringFromObj(nobj.object, "type") orelse continue;
        if (std.mem.eql(u8, ntype, "send")) {
            if (getJsonStringFromObj(nobj.object, "target_node")) |tn| {
                try send_targets.put(tn, {});
            }
        }
    }

    // --- Check 1: nodes_in_edges_exist ---
    // Build adjacency list while we're at it
    // Edge source format: "node" or "node:route_value"
    // We'll parse edge sources to get the actual node name
    var edge_sources: std.ArrayListUnmanaged([]const u8) = .empty;
    defer edge_sources.deinit(alloc);
    var edge_targets: std.ArrayListUnmanaged([]const u8) = .empty;
    defer edge_targets.deinit(alloc);

    for (edges) |edge_val| {
        if (edge_val != .array or edge_val.array.items.len < 2) continue;
        const src_raw = if (edge_val.array.items[0] == .string) edge_val.array.items[0].string else continue;
        const tgt = if (edge_val.array.items[1] == .string) edge_val.array.items[1].string else continue;

        // Parse "node:route_value" -> node name
        const src_node = edgeSourceNode(src_raw);

        try edge_sources.append(alloc, src_raw);
        try edge_targets.append(alloc, tgt);

        // Check source node exists (skip __start__, __end__)
        if (!isReserved(src_node)) {
            if (!nodes.contains(src_node)) {
                try errors.append(alloc, .{
                    .err_type = "nodes_in_edges_exist",
                    .node = src_node,
                    .key = null,
                    .message = "edge source node does not exist in nodes map",
                });
            }
        }
        // Check target node exists (skip __start__, __end__)
        if (!isReserved(tgt)) {
            if (!nodes.contains(tgt)) {
                try errors.append(alloc, .{
                    .err_type = "nodes_in_edges_exist",
                    .node = tgt,
                    .key = null,
                    .message = "edge target node does not exist in nodes map",
                });
            }
        }
    }

    // --- Build reachability set from __start__ ---
    // We do a BFS/DFS using static edges only (not send target_nodes).
    var reachable = std.StringHashMap(void).init(alloc);
    defer reachable.deinit();
    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(alloc);

    try reachable.put("__start__", {});
    try queue.append(alloc, "__start__");

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const current = queue.items[qi];
        for (edge_sources.items, edge_targets.items) |src_raw, tgt| {
            const src_node = edgeSourceNode(src_raw);
            if (std.mem.eql(u8, src_node, current) or std.mem.eql(u8, src_raw, current)) {
                if (!reachable.contains(tgt)) {
                    try reachable.put(tgt, {});
                    try queue.append(alloc, tgt);
                }
            }
        }
    }

    // --- Check 2: unreachable_node ---
    node_it = nodes.iterator();
    while (node_it.next()) |entry| {
        const nname = entry.key_ptr.*;
        if (reachable.contains(nname)) continue;
        // Exempt send target_nodes
        if (send_targets.contains(nname)) continue;
        try errors.append(alloc, .{
            .err_type = "unreachable_node",
            .node = nname,
            .key = null,
            .message = "node is not reachable from __start__",
        });
    }

    // --- Check 3: end_unreachable ---
    // __end__ must be reachable from __start__ (simple check: it appears in
    // reachable set, or at least one edge targets __end__).
    // For leaf nodes that are not send_targets, there should be a path to __end__.
    // We do a simplified check: __end__ must be in the reachable set.
    if (!reachable.contains("__end__")) {
        try errors.append(alloc, .{
            .err_type = "end_unreachable",
            .node = null,
            .key = null,
            .message = "__end__ is not reachable from __start__",
        });
    }

    // --- Check 4: unintentional_cycle ---
    // Detect cycles via DFS. Edges from route nodes (src contains ':') back to
    // earlier nodes are intentional. Other back-edges are cycles (errors).
    {
        const CycleState = enum { unvisited, in_stack, done };
        var cycle_state = std.StringHashMap(CycleState).init(alloc);
        defer cycle_state.deinit();

        // Initialize all known nodes
        node_it = nodes.iterator();
        while (node_it.next()) |entry| {
            try cycle_state.put(entry.key_ptr.*, .unvisited);
        }
        try cycle_state.put("__start__", .unvisited);
        try cycle_state.put("__end__", .unvisited);

        // We need to track which src_raw produced the edge to know if it's a route edge
        // Build adjacency: node -> list of (tgt, src_raw_is_route)
        const EdgeInfo = struct { tgt: []const u8, from_route: bool };
        var adj = std.StringHashMap(std.ArrayListUnmanaged(EdgeInfo)).init(alloc);
        defer {
            var adj_it = adj.iterator();
            while (adj_it.next()) |e| e.value_ptr.deinit(alloc);
            adj.deinit();
        }

        for (edge_sources.items, edge_targets.items) |src_raw, tgt| {
            const src_node = edgeSourceNode(src_raw);
            const is_route_edge = std.mem.indexOfScalar(u8, src_raw, ':') != null;
            const res = try adj.getOrPut(src_node);
            if (!res.found_existing) {
                res.value_ptr.* = .empty;
            }
            try res.value_ptr.append(alloc, .{ .tgt = tgt, .from_route = is_route_edge });
        }

        // Iterative DFS
        var visited_for_dfs = std.StringHashMap(CycleState).init(alloc);
        defer visited_for_dfs.deinit();

        // Initialize
        var cs_it = cycle_state.iterator();
        while (cs_it.next()) |e| {
            try visited_for_dfs.put(e.key_ptr.*, .unvisited);
        }

        var dfs_nodes: std.ArrayListUnmanaged([]const u8) = .empty;
        defer dfs_nodes.deinit(alloc);
        var cs_it2 = cycle_state.iterator();
        while (cs_it2.next()) |e| {
            try dfs_nodes.append(alloc, e.key_ptr.*);
        }

        for (dfs_nodes.items) |start_node| {
            const s = visited_for_dfs.get(start_node) orelse .unvisited;
            if (s != .unvisited) continue;

            // DFS iterative with path tracking
            var path = std.StringHashMap(void).init(alloc);
            defer path.deinit();

            const DfsEntry = struct { node: []const u8, child_idx: usize };
            var stack: std.ArrayListUnmanaged(DfsEntry) = .empty;
            defer stack.deinit(alloc);

            try stack.append(alloc, .{ .node = start_node, .child_idx = 0 });
            try path.put(start_node, {});
            visited_for_dfs.put(start_node, .in_stack) catch {};

            while (stack.items.len > 0) {
                const top = &stack.items[stack.items.len - 1];
                const neighbors = adj.get(top.node);
                if (neighbors == null or top.child_idx >= neighbors.?.items.len) {
                    // Done with this node
                    _ = path.remove(top.node);
                    visited_for_dfs.put(top.node, .done) catch {};
                    _ = stack.pop();
                    continue;
                }
                const neighbor = neighbors.?.items[top.child_idx];
                top.child_idx += 1;

                const tgt = neighbor.tgt;
                const from_route = neighbor.from_route;

                // Skip reserved endpoints for cycle detection
                if (isReserved(tgt)) continue;

                const tgt_state = visited_for_dfs.get(tgt) orelse .unvisited;
                if (tgt_state == .in_stack) {
                    // Back edge found — cycle
                    if (!from_route) {
                        // Report cycle error only once per target
                        var already_reported = false;
                        for (errors.items) |e| {
                            if (std.mem.eql(u8, e.err_type, "unintentional_cycle") and
                                e.node != null and std.mem.eql(u8, e.node.?, tgt))
                            {
                                already_reported = true;
                                break;
                            }
                        }
                        if (!already_reported) {
                            try errors.append(alloc, .{
                                .err_type = "unintentional_cycle",
                                .node = tgt,
                                .key = null,
                                .message = "cycle detected: non-route edge creates a cycle",
                            });
                        }
                    }
                    // Intentional route cycle — skip
                } else if (tgt_state == .unvisited) {
                    visited_for_dfs.put(tgt, .in_stack) catch {};
                    try path.put(tgt, {});
                    try stack.append(alloc, .{ .node = tgt, .child_idx = 0 });
                }
                // .done: already processed, no cycle through this path
            }
        }
    }

    // --- Check 5: undefined_state_key ---
    if (state_schema) |schema| {
        node_it = nodes.iterator();
        while (node_it.next()) |entry| {
            const nname = entry.key_ptr.*;
            const nval = entry.value_ptr.*;
            if (nval != .object) continue;
            const nobj = nval.object;

            // Check prompt field
            if (getJsonStringFromObj(nobj, "prompt")) |prompt| {
                try checkStateRefs(alloc, &errors, schema, nname, prompt);
            }
            // Check message field (interrupt)
            if (getJsonStringFromObj(nobj, "message")) |msg| {
                try checkStateRefs(alloc, &errors, schema, nname, msg);
            }
        }
    }

    // --- Check 6: invalid_route_target ---
    node_it = nodes.iterator();
    while (node_it.next()) |entry| {
        const nname = entry.key_ptr.*;
        const nval = entry.value_ptr.*;
        if (nval != .object) continue;
        const nobj = nval.object;
        const ntype = getJsonStringFromObj(nobj, "type") orelse continue;
        if (!std.mem.eql(u8, ntype, "route")) continue;

        const routes_val = nobj.get("routes") orelse continue;
        if (routes_val != .object) continue;
        var routes_it = routes_val.object.iterator();
        while (routes_it.next()) |re| {
            const target = if (re.value_ptr.* == .string) re.value_ptr.*.string else continue;
            if (!nodes.contains(target)) {
                try errors.append(alloc, .{
                    .err_type = "invalid_route_target",
                    .node = nname,
                    .key = re.key_ptr.*,
                    .message = "route target node does not exist",
                });
            }
            if (!hasRouteEdge(edge_sources.items, edge_targets.items, nname, re.key_ptr.*, target)) {
                try errors.append(alloc, .{
                    .err_type = "missing_route_edge",
                    .node = nname,
                    .key = re.key_ptr.*,
                    .message = "route key is declared in routes but has no matching conditional edge",
                });
            }
        }

        if (getJsonStringFromObj(nobj, "default")) |default_route| {
            if (!routes_val.object.contains(default_route)) {
                try errors.append(alloc, .{
                    .err_type = "invalid_route_default",
                    .node = nname,
                    .key = "default",
                    .message = "route default must reference a declared routes key",
                });
            }
        }
    }

    // --- Check 7: invalid_send_target ---
    node_it = nodes.iterator();
    while (node_it.next()) |entry| {
        const nname = entry.key_ptr.*;
        const nval = entry.value_ptr.*;
        if (nval != .object) continue;
        const nobj = nval.object;
        const ntype = getJsonStringFromObj(nobj, "type") orelse continue;
        if (!std.mem.eql(u8, ntype, "send")) continue;

        if (getJsonStringFromObj(nobj, "target_node")) |tn| {
            if (!nodes.contains(tn)) {
                try errors.append(alloc, .{
                    .err_type = "invalid_send_target",
                    .node = nname,
                    .key = "target_node",
                    .message = "send target_node does not exist in nodes map",
                });
            }
        }
    }

    // The errors list contains slices pointing into `parsed` which will be
    // freed by `defer parsed.deinit()`. We need to copy all strings into
    // alloc-owned memory before returning.
    const result = try copyErrors(alloc, errors.items);
    return result;
}

// ── Helpers ───────────────────────────────────────────────────────────

fn isReserved(name: []const u8) bool {
    return std.mem.eql(u8, name, "__start__") or std.mem.eql(u8, name, "__end__");
}

/// Given a raw edge source like "node:route_value", return "node".
/// If no colon, returns the whole string.
fn edgeSourceNode(src_raw: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, src_raw, ':')) |colon_pos| {
        return src_raw[0..colon_pos];
    }
    return src_raw;
}

fn hasRouteEdge(edge_sources: []const []const u8, edge_targets: []const []const u8, node_name: []const u8, route_key: []const u8, target: []const u8) bool {
    for (edge_sources, edge_targets) |src_raw, edge_target| {
        if (!std.mem.eql(u8, edge_target, target)) continue;
        const colon_pos = std.mem.indexOfScalar(u8, src_raw, ':') orelse continue;
        if (!std.mem.eql(u8, src_raw[0..colon_pos], node_name)) continue;
        if (std.mem.eql(u8, src_raw[colon_pos + 1 ..], route_key)) return true;
    }
    return false;
}

fn getJsonStringFromObj(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    if (val == .string) return val.string;
    return null;
}

/// Scan `text` for {{state.KEY}} references and check them against schema.
fn checkStateRefs(
    alloc: Allocator,
    errors: *std.ArrayListUnmanaged(ValidationError),
    schema: std.json.ObjectMap,
    node_name: []const u8,
    text: []const u8,
) !void {
    var pos: usize = 0;
    while (pos < text.len) {
        // Find "{{"
        const open = std.mem.indexOfPos(u8, text, pos, "{{") orelse break;
        const close = std.mem.indexOfPos(u8, text, open + 2, "}}") orelse break;
        const expr = text[open + 2 .. close];
        pos = close + 2;

        // Check if it's "state.KEY"
        if (std.mem.startsWith(u8, expr, "state.")) {
            const key = expr["state.".len..];
            if (key.len > 0 and !schema.contains(key)) {
                // Copy strings to avoid dangling references after parsed.deinit()
                // (We'll do a bulk copy in copyErrors later, but here we need
                // to store enough info. We store literals or slices into
                // node_name/field_name which come from the parsed JSON tree;
                // copyErrors will deep-copy them.)
                try errors.append(alloc, .{
                    .err_type = "undefined_state_key",
                    .node = node_name,
                    .key = key,
                    .message = "state key referenced in template is not defined in state_schema",
                });
            }
        }
    }
}

/// Deep-copy all strings in the error list into alloc-owned memory.
/// This is needed because the source strings point into a parsed JSON tree
/// that will be freed after validate() returns.
fn copyErrors(alloc: Allocator, src: []const ValidationError) ![]ValidationError {
    const result = try alloc.alloc(ValidationError, src.len);
    for (src, 0..) |e, i| {
        result[i] = .{
            .err_type = try alloc.dupe(u8, e.err_type),
            .node = if (e.node) |n| try alloc.dupe(u8, n) else null,
            .key = if (e.key) |k| try alloc.dupe(u8, k) else null,
            .message = try alloc.dupe(u8, e.message),
        };
    }
    return result;
}

// ── Tests: legacy ─────────────────────────────────────────────────────

test "validateStepsForCreateRun: valid workflow" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task"},
        \\  {"id":"b","type":"task","depends_on":["a"]}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try validateStepsForCreateRun(allocator, parsed.value.array.items);
}

test "validateStepsForCreateRun: rejects unknown dependency" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task","depends_on":["missing"]}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.DependsOnUnknownStepId, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects duplicate ids" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task"},
        \\  {"id":"a","type":"task"}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.StepIdDuplicate, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects non-object step item" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  "not-an-object"
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.StepMustBeObject, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects missing string id" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"type":"task"}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.StepIdMissingOrNotString, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects non-array depends_on" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task","depends_on":"x"}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.DependsOnNotArray, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects non-string depends_on item" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task","depends_on":[1]}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.DependsOnItemNotString, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects duplicate depends_on item" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task"},
        \\  {"id":"b","type":"task","depends_on":["a","a"]}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.DependsOnDuplicate, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects non-object retry field" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task","retry":1}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.RetryMustBeObject, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects non-positive max_attempts" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task","retry":{"max_attempts":0}}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.MaxAttemptsMustBePositiveInteger, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects non-positive timeout_ms" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task","timeout_ms":0}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.TimeoutMsMustBePositiveInteger, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

// ── Tests: new graph validation ────────────────────────────────────────

test "validate valid simple workflow" {
    const alloc = std.testing.allocator;
    const wf =
        \\{"state_schema":{"msg":{"type":"string","reducer":"last_value"}},"nodes":{"a":{"type":"task","prompt":"{{state.msg}}"}},"edges":[["__start__","a"],["a","__end__"]]}
    ;
    const errors = try validate(alloc, wf);
    defer {
        for (errors) |e| {
            alloc.free(e.err_type);
            if (e.node) |n| alloc.free(n);
            if (e.key) |k| alloc.free(k);
            alloc.free(e.message);
        }
        alloc.free(errors);
    }
    try std.testing.expectEqual(@as(usize, 0), errors.len);
}

test "validate unreachable node" {
    const alloc = std.testing.allocator;
    const wf =
        \\{"state_schema":{},"nodes":{"a":{"type":"task","prompt":"x"},"orphan":{"type":"task","prompt":"y"}},"edges":[["__start__","a"],["a","__end__"]]}
    ;
    const errors = try validate(alloc, wf);
    defer {
        for (errors) |e| {
            alloc.free(e.err_type);
            if (e.node) |n| alloc.free(n);
            if (e.key) |k| alloc.free(k);
            alloc.free(e.message);
        }
        alloc.free(errors);
    }
    try std.testing.expect(errors.len > 0);
    try std.testing.expectEqualStrings("unreachable_node", errors[0].err_type);
}

test "validate undefined state key" {
    const alloc = std.testing.allocator;
    const wf =
        \\{"state_schema":{"msg":{"type":"string","reducer":"last_value"}},"nodes":{"a":{"type":"task","prompt":"{{state.typo}}"}},"edges":[["__start__","a"],["a","__end__"]]}
    ;
    const errors = try validate(alloc, wf);
    defer {
        for (errors) |e| {
            alloc.free(e.err_type);
            if (e.node) |n| alloc.free(n);
            if (e.key) |k| alloc.free(k);
            alloc.free(e.message);
        }
        alloc.free(errors);
    }
    try std.testing.expect(errors.len > 0);
    try std.testing.expectEqualStrings("undefined_state_key", errors[0].err_type);
}

test "validate send target exempt from reachability" {
    const alloc = std.testing.allocator;
    const wf =
        \\{"state_schema":{"items":{"type":"array","reducer":"last_value"},"results":{"type":"array","reducer":"append"}},"nodes":{"s":{"type":"send","items_key":"state.items","target_node":"worker","output_key":"results"},"worker":{"type":"task","prompt":"do work"}},"edges":[["__start__","s"],["s","__end__"]]}
    ;
    const errors = try validate(alloc, wf);
    defer {
        for (errors) |e| {
            alloc.free(e.err_type);
            if (e.node) |n| alloc.free(n);
            if (e.key) |k| alloc.free(k);
            alloc.free(e.message);
        }
        alloc.free(errors);
    }
    try std.testing.expectEqual(@as(usize, 0), errors.len);
}

test "validate invalid route target" {
    const alloc = std.testing.allocator;
    const wf =
        \\{"state_schema":{"x":{"type":"string","reducer":"last_value"}},"nodes":{"r":{"type":"route","input":"state.x","routes":{"a":"nonexistent"}}},"edges":[["__start__","r"],["r:a","nonexistent"]]}
    ;
    const errors = try validate(alloc, wf);
    defer {
        for (errors) |e| {
            alloc.free(e.err_type);
            if (e.node) |n| alloc.free(n);
            if (e.key) |k| alloc.free(k);
            alloc.free(e.message);
        }
        alloc.free(errors);
    }
    // Should have error about nonexistent node (either in route target or edge target)
    try std.testing.expect(errors.len > 0);
}

test "validate route requires matching conditional edges for declared routes" {
    const alloc = std.testing.allocator;
    const wf =
        \\{"state_schema":{"x":{"type":"string","reducer":"last_value"}},"nodes":{"r":{"type":"route","input":"state.x","routes":{"yes":"approved"},"default":"yes"},"approved":{"type":"task","prompt":"approve"}},"edges":[["__start__","r"],["r:no","approved"],["approved","__end__"]]}
    ;
    const errors = try validate(alloc, wf);
    defer {
        for (errors) |e| {
            alloc.free(e.err_type);
            if (e.node) |n| alloc.free(n);
            if (e.key) |k| alloc.free(k);
            alloc.free(e.message);
        }
        alloc.free(errors);
    }
    var found_missing_route_edge = false;
    for (errors) |err| {
        if (std.mem.eql(u8, err.err_type, "missing_route_edge")) {
            found_missing_route_edge = true;
            break;
        }
    }
    try std.testing.expect(found_missing_route_edge);
}
