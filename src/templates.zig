/// Template engine for prompt rendering.
/// Resolves `{{...}}` expressions against workflow context.
///
/// Supported expressions:
///   - `{{input.X}}`          -- look up key X in the workflow input JSON
///   - `{{steps.ID.output}}`  -- output of a single completed step
///   - `{{steps.ID.outputs}}` -- JSON array of outputs from map/fan_out child steps
///   - `{{item}}`             -- current item string for map iterations

const std = @import("std");

// ── Context ───────────────────────────────────────────────────────────

pub const Context = struct {
    input_json: []const u8, // raw JSON string of workflow input
    step_outputs: []const StepOutput, // completed step outputs
    item: ?[]const u8, // current map item (null if not in map)
    debate_responses: ?[]const u8 = null, // JSON array string for debate judge template
    chat_history: ?[]const u8 = null, // formatted chat transcript for group_chat round_template
    role: ?[]const u8 = null, // participant role for group_chat round_template

    pub const StepOutput = struct {
        step_id: []const u8,
        output: ?[]const u8, // single output (for task steps)
        outputs: ?[]const []const u8, // array of outputs (for fan_out/map parent)
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

// ── render() ──────────────────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, template: []const u8, ctx: Context) RenderError![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var pos: usize = 0;

    while (pos < template.len) {
        // Look for next `{{`
        if (std.mem.indexOfPos(u8, template, pos, "{{")) |open| {
            // Append literal text before the `{{`
            result.appendSlice(allocator, template[pos..open]) catch return error.OutOfMemory;

            // Find matching `}}`
            const after_open = open + 2;
            if (std.mem.indexOfPos(u8, template, after_open, "}}")) |close| {
                const raw_expr = template[after_open..close];
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
            result.appendSlice(allocator, template[pos..]) catch return error.OutOfMemory;
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

    if (std.mem.eql(u8, expr, "debate_responses")) {
        if (ctx.debate_responses) |dr| {
            return allocator.dupe(u8, dr) catch return error.OutOfMemory;
        }
        return allocator.dupe(u8, "[]") catch return error.OutOfMemory;
    }

    if (std.mem.eql(u8, expr, "chat_history")) {
        if (ctx.chat_history) |ch| {
            return allocator.dupe(u8, ch) catch return error.OutOfMemory;
        }
        return allocator.dupe(u8, "") catch return error.OutOfMemory;
    }

    if (std.mem.eql(u8, expr, "role")) {
        if (ctx.role) |r| {
            return allocator.dupe(u8, r) catch return error.OutOfMemory;
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

    return error.UnknownExpression;
}

fn resolveInputField(allocator: std.mem.Allocator, input_json: []const u8, field_name: []const u8) RenderError![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input_json, .{}) catch {
        return error.InvalidInputJson;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidInputJson;

    const val = root.object.get(field_name) orelse return error.InputFieldNotFound;

    return jsonValueToString(allocator, val);
}

fn resolveStepRef(allocator: std.mem.Allocator, rest: []const u8, step_outputs: []const Context.StepOutput) RenderError![]const u8 {
    // rest is "ID.output" or "ID.outputs"
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
            if (std.mem.eql(u8, field, "outputs")) {
                return serializeOutputs(allocator, so.outputs);
            }
            return error.UnknownExpression;
        }
    }

    return error.StepNotFound;
}

fn serializeOutputs(allocator: std.mem.Allocator, outputs: ?[]const []const u8) RenderError![]const u8 {
    const items = outputs orelse {
        return allocator.dupe(u8, "[]") catch return error.OutOfMemory;
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    buf.append(allocator, '[') catch return error.OutOfMemory;
    for (items, 0..) |item, i| {
        if (i > 0) {
            buf.append(allocator, ',') catch return error.OutOfMemory;
        }
        // Write JSON-escaped string
        buf.append(allocator, '"') catch return error.OutOfMemory;
        for (item) |c| {
            switch (c) {
                '"' => buf.appendSlice(allocator, "\\\"") catch return error.OutOfMemory,
                '\\' => buf.appendSlice(allocator, "\\\\") catch return error.OutOfMemory,
                '\n' => buf.appendSlice(allocator, "\\n") catch return error.OutOfMemory,
                '\r' => buf.appendSlice(allocator, "\\r") catch return error.OutOfMemory,
                '\t' => buf.appendSlice(allocator, "\\t") catch return error.OutOfMemory,
                else => buf.append(allocator, c) catch return error.OutOfMemory,
            }
        }
        buf.append(allocator, '"') catch return error.OutOfMemory;
    }
    buf.append(allocator, ']') catch return error.OutOfMemory;

    return buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
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

// ── Tests ─────────────────────────────────────────────────────────────

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

test "render step output" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "Result: {{steps.s1.output}}", .{
        .input_json = "{}",
        .step_outputs = &.{
            .{ .step_id = "s1", .output = "found data", .outputs = null },
        },
        .item = null,
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Result: found data", result);
}

test "render step outputs array" {
    const allocator = std.testing.allocator;
    const outputs: []const []const u8 = &.{ "result1", "result2" };
    const result = try render(allocator, "All: {{steps.s1.outputs}}", .{
        .input_json = "{}",
        .step_outputs = &.{
            .{ .step_id = "s1", .output = null, .outputs = outputs },
        },
        .item = null,
    });
    defer allocator.free(result);
    // Should produce a JSON array like: ["result1","result2"]
    try std.testing.expect(std.mem.indexOf(u8, result, "result1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "result2") != null);
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

test "render debate_responses expression" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "Pick best:\n{{debate_responses}}", .{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .debate_responses = "[\"resp1\",\"resp2\"]",
    });
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "resp1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "resp2") != null);
}

test "render chat_history and role expressions" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "Previous:\n{{chat_history}}\nYour role: {{role}}", .{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .chat_history = "Architect: design first",
        .role = "Frontend Dev",
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Previous:\nArchitect: design first\nYour role: Frontend Dev", result);
}

test "debate_responses defaults to empty array when not set" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "{{debate_responses}}", .{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("[]", result);
}
