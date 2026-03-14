/// Template engine for prompt rendering.
/// Resolves `{{...}}` expressions against workflow context.
///
/// Legacy Context + render():
///   - `{{input.X}}`          -- look up key X in the workflow input JSON
///   - `{{input.X.Y}}`        -- nested object lookups inside workflow input JSON
///   - `{{item}}`             -- current item string for map iterations
///   - `{{task.X}}`           -- look up field X in the NullTickets task JSON
///   - `{{attempt}}`          -- current retry attempt number
///
/// State-based renderTemplate():
///   - `{{state.X}}`          -- look up key X in the unified state JSON
///   - `{{state.X.Y}}`        -- nested paths with optional [-1] array indexing
///   - `{{input.X}}`          -- look up key X in the workflow input JSON
///   - `{{item}}`             -- current item string for send iterations
///
/// Conditional blocks:
///   - `{% if <expr> %}...{% endif %}`
///   - `{% if <expr> %}...{% else %}...{% endif %}`
///   Conditionals are processed before expression substitution.
///   Truthiness: non-null, non-empty, not "false", not "null" string values are truthy.

const std = @import("std");

// ── Context ───────────────────────────────────────────────────────────

pub const Context = struct {
    input_json: []const u8, // raw JSON string of workflow input
    step_outputs: []const StepOutput, // completed step outputs (legacy, for tracker.zig)
    item: ?[]const u8, // current item string (null if not in map/send)
    task_json: ?[]const u8 = null, // raw JSON string of NullTickets task data
    attempt: ?u32 = null, // current retry attempt number

    pub const StepOutput = struct {
        step_id: []const u8,
        output: ?[]const u8, // single output (for task steps)
    };
};

// ── Errors ────────────────────────────────────────────────────────────

pub const RenderError = error{
    UnterminatedExpression,
    UnknownExpression,
    InputFieldNotFound,
    StepNotFound,
    ItemNotAvailable,
    InvalidInputJson,
    OutOfMemory,
};

// ── Conditional processing ────────────────────────────────────────────

/// Evaluate whether an expression is "truthy" in the given context.
/// An expression is truthy if it resolves to a non-null, non-empty,
/// not "false", not "null" string value.
fn isTruthy(allocator: std.mem.Allocator, expr: []const u8, ctx: Context) bool {
    const value = resolveExpression(allocator, expr, ctx) catch return false;
    defer allocator.free(value);

    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "false")) return false;
    if (std.mem.eql(u8, value, "null")) return false;
    return true;
}

/// Preprocess conditional blocks in a template. Strips or keeps content
/// based on expression truthiness. Handles nested conditionals.
/// Called before `{{expression}}` substitution.
fn processConditionals(allocator: std.mem.Allocator, template: []const u8, ctx: Context) RenderError![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var pos: usize = 0;

    while (pos < template.len) {
        // Look for next `{%`
        if (std.mem.indexOfPos(u8, template, pos, "{%")) |open| {
            // Append literal text before the tag
            result.appendSlice(allocator, template[pos..open]) catch return error.OutOfMemory;

            // Find closing `%}`
            const after_open = open + 2;
            const close = std.mem.indexOfPos(u8, template, after_open, "%}") orelse
                return error.UnterminatedExpression;
            const tag_content = std.mem.trim(u8, template[after_open..close], " \t\n\r");
            const after_tag = close + 2;

            if (std.mem.startsWith(u8, tag_content, "if ")) {
                const expr = std.mem.trim(u8, tag_content["if ".len..], " \t\n\r");

                // Find the matching {% else %} and {% endif %} at this nesting level
                var depth: usize = 0;
                var scan: usize = after_tag;
                var else_start: ?usize = null; // start of {% else %} tag
                var else_end: ?usize = null; // position after {% else %} tag
                var endif_start: ?usize = null; // start of {% endif %} tag
                var endif_end: ?usize = null; // position after {% endif %} tag

                while (scan < template.len) {
                    if (std.mem.indexOfPos(u8, template, scan, "{%")) |inner_open| {
                        const inner_after = inner_open + 2;
                        const inner_close = std.mem.indexOfPos(u8, template, inner_after, "%}") orelse
                            return error.UnterminatedExpression;
                        const inner_tag = std.mem.trim(u8, template[inner_after..inner_close], " \t\n\r");
                        const inner_after_tag = inner_close + 2;

                        if (std.mem.startsWith(u8, inner_tag, "if ")) {
                            depth += 1;
                            scan = inner_after_tag;
                        } else if (std.mem.eql(u8, inner_tag, "else") and depth == 0) {
                            else_start = inner_open;
                            else_end = inner_after_tag;
                            scan = inner_after_tag;
                        } else if (std.mem.eql(u8, inner_tag, "endif")) {
                            if (depth == 0) {
                                endif_start = inner_open;
                                endif_end = inner_after_tag;
                                break;
                            }
                            depth -= 1;
                            scan = inner_after_tag;
                        } else {
                            scan = inner_after_tag;
                        }
                    } else {
                        break;
                    }
                }

                if (endif_end == null) {
                    return error.UnterminatedExpression;
                }

                // Determine which branch content to include
                const truthy = isTruthy(allocator, expr, ctx);

                if (truthy) {
                    // If-branch: from after_tag to else_start (or endif_start)
                    const branch_end = else_start orelse endif_start.?;
                    const branch = template[after_tag..branch_end];
                    // Recursively process nested conditionals
                    const processed = try processConditionals(allocator, branch, ctx);
                    defer allocator.free(processed);
                    result.appendSlice(allocator, processed) catch return error.OutOfMemory;
                } else {
                    // Else-branch (if it exists)
                    if (else_end) |ee| {
                        const branch = template[ee..endif_start.?];
                        const processed = try processConditionals(allocator, branch, ctx);
                        defer allocator.free(processed);
                        result.appendSlice(allocator, processed) catch return error.OutOfMemory;
                    }
                    // If no else branch, nothing is appended (content is stripped)
                }

                pos = endif_end.?;
            } else {
                // Not an "if" tag -- keep it as literal text
                result.appendSlice(allocator, template[open..after_tag]) catch return error.OutOfMemory;
                pos = after_tag;
            }
        } else {
            // No more tags; append the rest
            result.appendSlice(allocator, template[pos..]) catch return error.OutOfMemory;
            break;
        }
    }

    return result.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

// ── render() ──────────────────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, template: []const u8, ctx: Context) RenderError![]const u8 {
    // Phase 1: Process conditional blocks
    const preprocessed = try processConditionals(allocator, template, ctx);
    defer allocator.free(preprocessed);

    // Phase 2: Resolve {{expression}} substitutions
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var pos: usize = 0;

    while (pos < preprocessed.len) {
        // Look for next `{{`
        if (std.mem.indexOfPos(u8, preprocessed, pos, "{{")) |open| {
            // Append literal text before the `{{`
            result.appendSlice(allocator, preprocessed[pos..open]) catch return error.OutOfMemory;

            // Find matching `}}`
            const after_open = open + 2;
            if (std.mem.indexOfPos(u8, preprocessed, after_open, "}}")) |close| {
                const raw_expr = preprocessed[after_open..close];
                const expr = std.mem.trim(u8, raw_expr, " \t\n\r");

                const value = try resolveExpression(allocator, expr, ctx);
                defer allocator.free(value);

                result.appendSlice(allocator, value) catch return error.OutOfMemory;
                pos = close + 2;
            } else {
                return error.UnterminatedExpression;
            }
        } else {
            // No more expressions; append the rest
            result.appendSlice(allocator, preprocessed[pos..]) catch return error.OutOfMemory;
            break;
        }
    }

    return result.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

// ── Expression resolution ─────────────────────────────────────────────

fn resolveExpression(allocator: std.mem.Allocator, expr: []const u8, ctx: Context) RenderError![]const u8 {
    if (std.mem.eql(u8, expr, "item")) {
        if (ctx.item) |item| {
            return allocator.dupe(u8, item) catch return error.OutOfMemory;
        }
        return error.ItemNotAvailable;
    }

    if (std.mem.eql(u8, expr, "attempt")) {
        if (ctx.attempt) |a| {
            return std.fmt.allocPrint(allocator, "{d}", .{a}) catch return error.OutOfMemory;
        }
        return allocator.dupe(u8, "") catch return error.OutOfMemory;
    }

    if (std.mem.startsWith(u8, expr, "input.")) {
        const field_name = expr["input.".len..];
        return resolveInputField(allocator, ctx.input_json, field_name);
    }

    if (std.mem.startsWith(u8, expr, "steps.")) {
        return resolveStepRef(allocator, expr["steps.".len..], ctx.step_outputs);
    }

    if (std.mem.startsWith(u8, expr, "task.")) {
        const field = expr["task.".len..];
        if (ctx.task_json) |tj| {
            return resolveTaskField(allocator, tj, field);
        }
        return error.UnknownExpression;
    }

    return error.UnknownExpression;
}

fn resolveInputField(allocator: std.mem.Allocator, input_json: []const u8, field_name: []const u8) RenderError![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input_json, .{}) catch {
        return error.InvalidInputJson;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidInputJson;

    var current = root;
    var parts = std.mem.splitScalar(u8, field_name, '.');
    while (parts.next()) |segment| {
        current = switch (current) {
            .object => |obj| obj.get(segment) orelse return error.InputFieldNotFound,
            else => return error.InputFieldNotFound,
        };
    }

    return jsonValueToString(allocator, current);
}

fn resolveStepRef(allocator: std.mem.Allocator, rest: []const u8, step_outputs: []const Context.StepOutput) RenderError![]const u8 {
    // rest is "ID.output"
    const dot_pos = std.mem.lastIndexOfScalar(u8, rest, '.') orelse return error.UnknownExpression;
    const step_id = rest[0..dot_pos];
    const field = rest[dot_pos + 1 ..];

    // Find the step
    for (step_outputs) |so| {
        if (std.mem.eql(u8, so.step_id, step_id)) {
            if (std.mem.eql(u8, field, "output")) {
                if (so.output) |output| {
                    return allocator.dupe(u8, output) catch return error.OutOfMemory;
                }
                return allocator.dupe(u8, "") catch return error.OutOfMemory;
            }
            return error.UnknownExpression;
        }
    }

    return error.StepNotFound;
}

fn resolveTaskField(allocator: std.mem.Allocator, task_json: []const u8, field_path: []const u8) RenderError![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, task_json, .{}) catch {
        return error.InvalidInputJson;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidInputJson;

    // Handle nested paths like "metadata.repo_url"
    var current = root;
    var path_iter = std.mem.splitScalar(u8, field_path, '.');
    while (path_iter.next()) |segment| {
        if (current != .object) return error.InputFieldNotFound;
        current = current.object.get(segment) orelse return error.InputFieldNotFound;
    }

    return jsonValueToString(allocator, current);
}

fn jsonValueToString(allocator: std.mem.Allocator, val: std.json.Value) RenderError![]const u8 {
    switch (val) {
        .string => |s| {
            return allocator.dupe(u8, s) catch return error.OutOfMemory;
        },
        .integer => |n| {
            var buf_arr: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf_arr, "{d}", .{n}) catch return error.OutOfMemory;
            return allocator.dupe(u8, s) catch return error.OutOfMemory;
        },
        .float => |f| {
            var buf_arr: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf_arr, "{d}", .{f}) catch return error.OutOfMemory;
            return allocator.dupe(u8, s) catch return error.OutOfMemory;
        },
        .number_string => |s| {
            return allocator.dupe(u8, s) catch return error.OutOfMemory;
        },
        .bool => |b| {
            return allocator.dupe(u8, if (b) "true" else "false") catch return error.OutOfMemory;
        },
        .null => {
            return allocator.dupe(u8, "null") catch return error.OutOfMemory;
        },
        .object, .array => {
            // Serialize back to JSON string using Zig 0.15 Stringify API
            var out: std.io.Writer.Allocating = .init(allocator);
            errdefer out.deinit();
            var jw: std.json.Stringify = .{ .writer = &out.writer };
            jw.write(val) catch return error.OutOfMemory;
            return out.toOwnedSlice() catch return error.OutOfMemory;
        },
    }
}

// ── New state-based template engine ───────────────────────────────────

const state_mod = @import("state.zig");
const Allocator = std.mem.Allocator;

/// Strip surrounding double quotes from a JSON string value.
/// `"hello"` -> `hello`, `42` -> `42`, `[1,2]` -> `[1,2]`
fn stripJsonQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

/// Look up a value from a JSON blob by dotted path (no prefix stripping).
/// E.g. lookupJsonPath(alloc, '{"topic":"AI"}', "topic") -> "AI"
fn lookupJsonPath(alloc: Allocator, json_bytes: []const u8, path: []const u8) !?[]const u8 {
    // Reuse state_mod.getStateValue but without "state." prefix.
    // getStateValue strips "state." if present, otherwise uses path as-is.
    return try state_mod.getStateValue(alloc, json_bytes, path);
}

/// Resolve a template expression (the text inside `{{ }}`) to a string value.
/// Handles state.X, input.X, item, item.X expressions.
fn resolveNewExpression(
    alloc: Allocator,
    expr: []const u8,
    state_json: []const u8,
    input_json: ?[]const u8,
    item_json: ?[]const u8,
) ![]const u8 {
    if (std.mem.startsWith(u8, expr, "state.")) {
        // Use getStateValue which handles "state." prefix, nested paths, [-1] indexing
        const raw = try state_mod.getStateValue(alloc, state_json, expr);
        if (raw) |r| {
            // Strip quotes for strings; leave numbers/bools/arrays/objects as-is
            const stripped = stripJsonQuotes(r);
            if (stripped.ptr != r.ptr or stripped.len != r.len) {
                // It was a quoted string — dupe the unquoted version and free the original
                const result = alloc.dupe(u8, stripped) catch return error.OutOfMemory;
                alloc.free(r);
                return result;
            }
            return r;
        }
        return alloc.dupe(u8, "") catch return error.OutOfMemory;
    }

    if (std.mem.startsWith(u8, expr, "input.")) {
        const ij = input_json orelse {
            return alloc.dupe(u8, "") catch return error.OutOfMemory;
        };
        const field = expr["input.".len..];
        const raw = try lookupJsonPath(alloc, ij, field);
        if (raw) |r| {
            const stripped = stripJsonQuotes(r);
            if (stripped.ptr != r.ptr or stripped.len != r.len) {
                const result = alloc.dupe(u8, stripped) catch return error.OutOfMemory;
                alloc.free(r);
                return result;
            }
            return r;
        }
        return alloc.dupe(u8, "") catch return error.OutOfMemory;
    }

    if (std.mem.eql(u8, expr, "item")) {
        if (item_json) |ij| {
            const stripped = stripJsonQuotes(ij);
            return alloc.dupe(u8, stripped) catch return error.OutOfMemory;
        }
        return alloc.dupe(u8, "") catch return error.OutOfMemory;
    }

    if (std.mem.startsWith(u8, expr, "item.")) {
        const ij = item_json orelse {
            return alloc.dupe(u8, "") catch return error.OutOfMemory;
        };
        const field = expr["item.".len..];
        const raw = try lookupJsonPath(alloc, ij, field);
        if (raw) |r| {
            const stripped = stripJsonQuotes(r);
            if (stripped.ptr != r.ptr or stripped.len != r.len) {
                const result = alloc.dupe(u8, stripped) catch return error.OutOfMemory;
                alloc.free(r);
                return result;
            }
            return r;
        }
        return alloc.dupe(u8, "") catch return error.OutOfMemory;
    }

    // {{config.X}} — alias for {{state.__config.X}}
    if (std.mem.startsWith(u8, expr, "config.")) {
        const config_path = try std.fmt.allocPrint(alloc, "state.__config.{s}", .{expr["config.".len..]});
        defer alloc.free(config_path);
        const raw = try state_mod.getStateValue(alloc, state_json, config_path);
        if (raw) |r| {
            const stripped = stripJsonQuotes(r);
            if (stripped.ptr != r.ptr or stripped.len != r.len) {
                const result = alloc.dupe(u8, stripped) catch return error.OutOfMemory;
                alloc.free(r);
                return result;
            }
            return r;
        }
        return alloc.dupe(u8, "") catch return error.OutOfMemory;
    }

    // Unknown expression — return empty
    return alloc.dupe(u8, "") catch return error.OutOfMemory;
}

/// Check if a condition expression is truthy for the new template engine.
/// Truthy: non-null, non-empty, not "false", not "0", not "null", not empty array "[]"
fn isNewTruthy(
    alloc: Allocator,
    expr: []const u8,
    state_json: []const u8,
    input_json: ?[]const u8,
    item_json: ?[]const u8,
) bool {
    const value = resolveNewExpression(alloc, expr, state_json, input_json, item_json) catch return false;
    defer alloc.free(value);

    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "false")) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.mem.eql(u8, value, "null")) return false;
    if (std.mem.eql(u8, value, "[]")) return false;
    return true;
}

/// Process `{% if expr %}...{% endif %}` conditional blocks for the new engine.
fn processNewConditionals(
    alloc: Allocator,
    template: []const u8,
    state_json: []const u8,
    input_json: ?[]const u8,
    item_json: ?[]const u8,
) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(alloc);

    var pos: usize = 0;

    while (pos < template.len) {
        if (std.mem.indexOfPos(u8, template, pos, "{%")) |open| {
            result.appendSlice(alloc, template[pos..open]) catch return error.OutOfMemory;

            const after_open = open + 2;
            const close = std.mem.indexOfPos(u8, template, after_open, "%}") orelse
                return error.OutOfMemory;
            const tag_content = std.mem.trim(u8, template[after_open..close], " \t\n\r");
            const after_tag = close + 2;

            if (std.mem.startsWith(u8, tag_content, "if ")) {
                const expr = std.mem.trim(u8, tag_content["if ".len..], " \t\n\r");

                // Find matching {% endif %} at this nesting level
                var depth: usize = 0;
                var scan: usize = after_tag;
                var else_start: ?usize = null;
                var else_end: ?usize = null;
                var endif_start: ?usize = null;
                var endif_end: ?usize = null;

                while (scan < template.len) {
                    if (std.mem.indexOfPos(u8, template, scan, "{%")) |inner_open| {
                        const inner_after = inner_open + 2;
                        const inner_close = std.mem.indexOfPos(u8, template, inner_after, "%}") orelse
                            return error.OutOfMemory;
                        const inner_tag = std.mem.trim(u8, template[inner_after..inner_close], " \t\n\r");
                        const inner_after_tag = inner_close + 2;

                        if (std.mem.startsWith(u8, inner_tag, "if ")) {
                            depth += 1;
                            scan = inner_after_tag;
                        } else if (std.mem.eql(u8, inner_tag, "else") and depth == 0) {
                            else_start = inner_open;
                            else_end = inner_after_tag;
                            scan = inner_after_tag;
                        } else if (std.mem.eql(u8, inner_tag, "endif")) {
                            if (depth == 0) {
                                endif_start = inner_open;
                                endif_end = inner_after_tag;
                                break;
                            }
                            depth -= 1;
                            scan = inner_after_tag;
                        } else {
                            scan = inner_after_tag;
                        }
                    } else {
                        break;
                    }
                }

                if (endif_end == null) {
                    return error.OutOfMemory;
                }

                const truthy = isNewTruthy(alloc, expr, state_json, input_json, item_json);

                if (truthy) {
                    const branch_end = else_start orelse endif_start.?;
                    const branch = template[after_tag..branch_end];
                    const processed = try processNewConditionals(alloc, branch, state_json, input_json, item_json);
                    defer alloc.free(processed);
                    result.appendSlice(alloc, processed) catch return error.OutOfMemory;
                } else {
                    if (else_end) |ee| {
                        const branch = template[ee..endif_start.?];
                        const processed = try processNewConditionals(alloc, branch, state_json, input_json, item_json);
                        defer alloc.free(processed);
                        result.appendSlice(alloc, processed) catch return error.OutOfMemory;
                    }
                }

                pos = endif_end.?;
            } else {
                result.appendSlice(alloc, template[open..after_tag]) catch return error.OutOfMemory;
                pos = after_tag;
            }
        } else {
            result.appendSlice(alloc, template[pos..]) catch return error.OutOfMemory;
            break;
        }
    }

    return result.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

/// Render a template using the new state-based interpolation syntax.
///
/// Supported expressions:
///   - `{{state.X}}` — state key value
///   - `{{state.X.Y}}` — nested state access
///   - `{{state.X[-1]}}` — last array element from state
///   - `{{input.X}}` — original input (read-only)
///   - `{{item}}` — current item in send context
///   - `{{item.X}}` — nested access on item
///   - `{% if state.X %}...{% endif %}` — conditionals
///
/// Processing order:
///   1. Process `{% if ... %}...{% endif %}` blocks
///   2. Process `{{...}}` interpolations
pub fn renderTemplate(
    alloc: Allocator,
    template: []const u8,
    state_json: []const u8,
    input_json: ?[]const u8,
    item_json: ?[]const u8,
) ![]const u8 {
    // Phase 1: Process conditional blocks
    const preprocessed = try processNewConditionals(alloc, template, state_json, input_json, item_json);
    defer alloc.free(preprocessed);

    // Phase 2: Resolve {{expression}} substitutions
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(alloc);

    var pos: usize = 0;

    while (pos < preprocessed.len) {
        if (std.mem.indexOfPos(u8, preprocessed, pos, "{{")) |open| {
            result.appendSlice(alloc, preprocessed[pos..open]) catch return error.OutOfMemory;

            const after_open = open + 2;
            if (std.mem.indexOfPos(u8, preprocessed, after_open, "}}")) |close| {
                const raw_expr = preprocessed[after_open..close];
                const expr = std.mem.trim(u8, raw_expr, " \t\n\r");

                const value = try resolveNewExpression(alloc, expr, state_json, input_json, item_json);
                defer alloc.free(value);

                result.appendSlice(alloc, value) catch return error.OutOfMemory;
                pos = close + 2;
            } else {
                // Unterminated — just append the rest as literal
                result.appendSlice(alloc, preprocessed[pos..]) catch return error.OutOfMemory;
                break;
            }
        } else {
            result.appendSlice(alloc, preprocessed[pos..]) catch return error.OutOfMemory;
            break;
        }
    }

    return result.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

// ── New template engine tests ─────────────────────────────────────────

test "template state interpolation" {
    const alloc = std.testing.allocator;
    const s = "{\"name\":\"test\",\"count\":42}";
    const result = try renderTemplate(alloc, "Hello {{state.name}}, count={{state.count}}", s, null, null);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("Hello test, count=42", result);
}

test "template input interpolation" {
    const alloc = std.testing.allocator;
    const result = try renderTemplate(alloc, "Topic: {{input.topic}}", "{}", "{\"topic\":\"AI\"}", null);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("Topic: AI", result);
}

test "template item interpolation" {
    const alloc = std.testing.allocator;
    const result = try renderTemplate(alloc, "File: {{item.path}}", "{}", null, "{\"path\":\"main.py\"}");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("File: main.py", result);
}

test "template conditional true" {
    const alloc = std.testing.allocator;
    const result = try renderTemplate(alloc, "{% if state.name %}Hi {{state.name}}{% endif %}", "{\"name\":\"Bob\"}", null, null);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("Hi Bob", result);
}

test "template conditional false" {
    const alloc = std.testing.allocator;
    const result = try renderTemplate(alloc, "{% if state.missing %}hidden{% endif %}visible", "{}", null, null);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("visible", result);
}

test "template no interpolation" {
    const alloc = std.testing.allocator;
    const result = try renderTemplate(alloc, "plain text", "{}", null, null);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("plain text", result);
}

// ── Old template engine tests ─────────────────────────────────────────

test "render literal text unchanged" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "Hello world", .{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello world", result);
}

test "render input variable" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "Hello {{input.name}}", .{
        .input_json = "{\"name\":\"World\"}",
        .step_outputs = &.{},
        .item = null,
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello World", result);
}

test "render nested input variable" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "Repo {{input.task.metadata.repo}}", .{
        .input_json = "{\"task\":{\"metadata\":{\"repo\":\"nullboiler\"}}}",
        .step_outputs = &.{},
        .item = null,
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Repo nullboiler", result);
}

test "render step output" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "Result: {{steps.s1.output}}", .{
        .input_json = "{}",
        .step_outputs = &.{
            .{ .step_id = "s1", .output = "found data" },
        },
        .item = null,
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Result: found data", result);
}

test "render item in map context" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "Research: {{item}}", .{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = "AI safety",
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Research: AI safety", result);
}

test "render with no template expressions" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "No templates here", .{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("No templates here", result);
}

test "render empty template" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "", .{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "unterminated expression returns error" {
    const allocator = std.testing.allocator;
    const err = render(allocator, "Hello {{input.name", .{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
    });
    try std.testing.expectError(error.UnterminatedExpression, err);
}

test "render multiple expressions" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "{{input.greeting}} {{input.name}}!", .{
        .input_json = "{\"greeting\":\"Hello\",\"name\":\"World\"}",
        .step_outputs = &.{},
        .item = null,
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello World!", result);
}

test "render expression with whitespace trimmed" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "Hello {{ input.name }}", .{
        .input_json = "{\"name\":\"World\"}",
        .step_outputs = &.{},
        .item = null,
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello World", result);
}

test "render input integer value" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "Count: {{input.count}}", .{
        .input_json = "{\"count\":42}",
        .step_outputs = &.{},
        .item = null,
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Count: 42", result);
}

test "render input object as JSON" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "Data: {{input.config}}", .{
        .input_json = "{\"config\":{\"key\":\"val\"}}",
        .step_outputs = &.{},
        .item = null,
    });
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "key") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "val") != null);
}

test "unknown step returns error" {
    const allocator = std.testing.allocator;
    const err = render(allocator, "{{steps.missing.output}}", .{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
    });
    try std.testing.expectError(error.StepNotFound, err);
}

test "item without map context returns error" {
    const allocator = std.testing.allocator;
    const err = render(allocator, "{{item}}", .{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
    });
    try std.testing.expectError(error.ItemNotAvailable, err);
}

test "render task.title variable" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "Work on: {{task.title}}", .{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .task_json = "{\"title\":\"Fix login bug\",\"description\":\"Users cannot log in\"}",
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Work on: Fix login bug", result);
}

test "render task.description variable" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "{{task.description}}", .{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .task_json = "{\"title\":\"Fix\",\"description\":\"Users cannot log in\"}",
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Users cannot log in", result);
}

test "render task.metadata.X nested variable" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "Repo: {{task.metadata.repo_url}}", .{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .task_json = "{\"title\":\"T\",\"description\":\"D\",\"metadata\":{\"repo_url\":\"https://github.com/org/repo\"}}",
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Repo: https://github.com/org/repo", result);
}

test "render attempt variable" {
    const allocator = std.testing.allocator;
    const template = "Attempt: {{attempt}}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = 3,
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Attempt: 3", result);
}

test "render attempt variable when null" {
    const allocator = std.testing.allocator;
    const template = "Attempt: {{attempt}}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = null,
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Attempt: ", result);
}

// ── Conditional block tests ───────────────────────────────────────────

test "conditional block with truthy value" {
    const allocator = std.testing.allocator;
    const template = "{% if attempt %}Retry #{{attempt}}{% endif %}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = 3,
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Retry #3", result);
}

test "conditional block with falsy value strips content" {
    const allocator = std.testing.allocator;
    const template = "{% if attempt %}Retry #{{attempt}}{% endif %}Done";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = null,
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Done", result);
}

test "conditional block with else branch" {
    const allocator = std.testing.allocator;
    const template = "{% if attempt %}Retry{% else %}First run{% endif %}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = null,
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("First run", result);
}

test "conditional block with task.description truthy" {
    const allocator = std.testing.allocator;
    const template = "{% if task.description %}Desc: {{task.description}}{% else %}No description{% endif %}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .task_json = "{\"description\": \"Fix bug\"}",
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Desc: Fix bug", result);
}

test "conditional block with task.description falsy" {
    const allocator = std.testing.allocator;
    const template = "{% if task.description %}Desc: {{task.description}}{% else %}No description{% endif %}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .task_json = "{}",
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("No description", result);
}

test "nested conditional blocks" {
    const allocator = std.testing.allocator;
    const template = "{% if attempt %}Retry{% if task.description %}: {{task.description}}{% endif %}{% else %}New{% endif %}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = 2,
        .task_json = "{\"description\": \"Fix it\"}",
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Retry: Fix it", result);
}

test "conditional block with false string is falsy" {
    const allocator = std.testing.allocator;
    const template = "{% if input.enabled %}ON{% else %}OFF{% endif %}";
    const ctx = Context{
        .input_json = "{\"enabled\": false}",
        .step_outputs = &.{},
        .item = null,
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("OFF", result);
}

test "conditional block with null string is falsy" {
    const allocator = std.testing.allocator;
    const template = "{% if input.val %}YES{% else %}NO{% endif %}";
    const ctx = Context{
        .input_json = "{\"val\": null}",
        .step_outputs = &.{},
        .item = null,
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("NO", result);
}

test "multiple consecutive conditional blocks" {
    const allocator = std.testing.allocator;
    const template = "{% if attempt %}A{% endif %}{% if task.title %}B{% endif %}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = 1,
        .task_json = "{\"title\": \"x\"}",
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("AB", result);
}

test "unterminated conditional block returns error" {
    const allocator = std.testing.allocator;
    const template = "{% if attempt %}content";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = 3,
    };
    const result = render(allocator, template, ctx);
    try std.testing.expectError(error.UnterminatedExpression, result);
}
