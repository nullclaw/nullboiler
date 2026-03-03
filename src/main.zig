const std = @import("std");
const Store = @import("store.zig").Store;
const api = @import("api.zig");
const config = @import("config.zig");
const engine_mod = @import("engine.zig");
const ids = @import("ids.zig");
const metrics_mod = @import("metrics.zig");
const worker_protocol = @import("worker_protocol.zig");
const c = @cImport({
    @cInclude("signal.h");
});

const version = "2026.3.2";
const max_request_size: usize = 8 * 1024 * 1024;
const request_read_chunk: usize = 4096;
var shutdown_requested = std.atomic.Value(bool).init(false);

fn onSignal(sig: c_int) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .seq_cst);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    // Collect all args into a slice for manifest protocol checks
    var arg_list: std.ArrayListUnmanaged([:0]const u8) = .empty;
    defer arg_list.deinit(allocator);
    while (args.next()) |a| {
        try arg_list.append(allocator, a);
    }
    const all_args = arg_list.items;

    // Check for manifest protocol flags first (early exit, no config needed)
    if (all_args.len >= 1) {
        if (std.mem.eql(u8, all_args[0], "--export-manifest")) {
            try @import("export_manifest.zig").run();
            return;
        }
        if (std.mem.eql(u8, all_args[0], "--from-json")) {
            try @import("from_json.zig").run(allocator, all_args[1..]);
            return;
        }
    }

    var host_override: ?[]const u8 = null;
    var port_override: ?u16 = null;
    var db_override: ?[:0]const u8 = null;
    var token_override: ?[]const u8 = null;
    var config_path: []const u8 = "config.json";

    var i: usize = 0;
    while (i < all_args.len) : (i += 1) {
        const arg = all_args[i];
        if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i < all_args.len) {
                host_override = all_args[i];
            }
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i < all_args.len) {
                port_override = std.fmt.parseInt(u16, all_args[i], 10) catch {
                    std.debug.print("invalid port: {s}\n", .{all_args[i]});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--db")) {
            i += 1;
            if (i < all_args.len) {
                db_override = all_args[i];
            }
        } else if (std.mem.eql(u8, arg, "--token")) {
            i += 1;
            if (i < all_args.len) {
                token_override = all_args[i];
            }
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i < all_args.len) {
                config_path = all_args[i];
            }
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("nullboiler v{s}\n", .{version});
            return;
        }
    }

    // Load configuration
    var cfg_arena = std.heap.ArenaAllocator.init(allocator);
    defer cfg_arena.deinit();
    const cfg = config.loadFromFile(cfg_arena.allocator(), config_path) catch |err| {
        std.debug.print("failed to load config from {s}: {}\n", .{ config_path, err });
        return;
    };

    // Determine bind host, port, and db path (CLI overrides config)
    const bind_host = host_override orelse cfg.host;
    const port = port_override orelse cfg.port;
    const api_token = token_override orelse cfg.api_token;
    const db_path: [:0]const u8 = db_override orelse blk: {
        // Need to convert cfg.db ([]const u8) to [:0]const u8
        const db_z = cfg_arena.allocator().allocSentinel(u8, cfg.db.len, 0) catch {
            std.debug.print("out of memory\n", .{});
            return;
        };
        @memcpy(db_z, cfg.db);
        break :blk db_z;
    };

    std.debug.print("nullboiler v{s}\n", .{version});
    std.debug.print("opening database: {s}\n", .{db_path});
    if (api_token != null) {
        std.debug.print("API auth: bearer token enabled\n", .{});
    } else {
        std.debug.print("API auth: disabled\n", .{});
    }

    var store = try Store.init(allocator, db_path);
    defer store.deinit();
    var metrics = metrics_mod.Metrics{};
    var drain_mode = std.atomic.Value(bool).init(false);

    // Seed workers from config
    store.deleteWorkersBySource("config") catch |err| {
        std.debug.print("warning: failed to clean config workers: {}\n", .{err});
    };

    for (cfg.workers) |w| {
        const protocol = worker_protocol.parse(w.protocol) orelse {
            std.debug.print("warning: skipped config worker {s}: unsupported protocol {s}\n", .{ w.id, w.protocol });
            continue;
        };

        if (worker_protocol.requiresModel(protocol) and w.model == null) {
            std.debug.print("warning: skipped config worker {s}: openai_chat protocol requires model\n", .{w.id});
            continue;
        }
        if (!worker_protocol.validateUrlForProtocol(w.url, protocol)) {
            std.debug.print("warning: skipped config worker {s}: webhook protocol requires explicit URL path (for example /webhook)\n", .{w.id});
            continue;
        }

        // Serialize tags to JSON array string
        const tags_json = serializeTagsJson(cfg_arena.allocator(), w.tags) catch |err| {
            std.debug.print("warning: failed to serialize tags for worker {s}: {}\n", .{ w.id, err });
            continue;
        };

        store.insertWorker(w.id, w.url, w.token, w.protocol, w.model, tags_json, @intCast(w.max_concurrent), "config") catch |err| {
            std.debug.print("warning: failed to insert config worker {s}: {}\n", .{ w.id, err });
        };
        std.debug.print("registered config worker: {s}\n", .{w.id});
    }

    const addr = std.net.Address.resolveIp(bind_host, port) catch |err| {
        std.debug.print("failed to resolve bind address {s}:{d}: {}\n", .{ bind_host, port, err });
        return;
    };
    var server = addr.listen(.{ .reuse_address = true }) catch |err| {
        std.debug.print("failed to listen on {s}:{d}: {}\n", .{ bind_host, port, err });
        return;
    };
    defer server.deinit();

    // SIGINT/SIGTERM should switch process into drain/shutdown mode.
    _ = c.signal(c.SIGINT, onSignal);
    _ = c.signal(c.SIGTERM, onSignal);

    // Start DAG engine on a background thread
    const poll_ms: u64 = cfg.engine.poll_interval_ms;
    var engine = engine_mod.Engine.init(&store, allocator, poll_ms);
    engine.configure(.{
        .health_check_interval_ms = @as(i64, @intCast(cfg.engine.health_check_interval_ms)),
        .worker_failure_threshold = @as(i64, @intCast(cfg.engine.worker_failure_threshold)),
        .worker_circuit_breaker_ms = @as(i64, @intCast(cfg.engine.worker_circuit_breaker_ms)),
        .retry_base_delay_ms = @as(i64, @intCast(cfg.engine.retry_base_delay_ms)),
        .retry_max_delay_ms = @as(i64, @intCast(cfg.engine.retry_max_delay_ms)),
        .retry_jitter_ms = @as(i64, @intCast(cfg.engine.retry_jitter_ms)),
        .retry_max_elapsed_ms = @as(i64, @intCast(cfg.engine.retry_max_elapsed_ms)),
    }, &metrics);
    const engine_thread = try std.Thread.spawn(.{}, engine_mod.Engine.run, .{&engine});

    std.debug.print("listening on http://{s}:{d}\n", .{ bind_host, port });
    std.debug.print("engine started (poll_interval={d}ms)\n", .{poll_ms});

    defer {
        engine.stop();
        engine_thread.join();
        std.debug.print("engine stopped\n", .{});
    }

    while (true) {
        if (shutdown_requested.load(.acquire)) {
            drain_mode.store(true, .release);
            std.debug.print("shutdown signal received, draining runs\n", .{});
            break;
        }

        var poll_fds = [_]std.posix.pollfd{
            .{
                .fd = server.stream.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };
        const ready = std.posix.poll(&poll_fds, 50) catch {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        if (ready == 0) continue;

        var conn = server.accept() catch |err| {
            std.debug.print("accept error: {}\n", .{err});
            continue;
        };
        defer conn.stream.close();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const req_alloc = arena.allocator();

        const request = readHttpRequest(req_alloc, &conn.stream, max_request_size) catch |err| {
            std.debug.print("request read error: {}\n", .{err});
            continue;
        } orelse continue;

        var ctx = api.Context{
            .store = &store,
            .allocator = req_alloc,
            .required_api_token = api_token,
            .request_bearer_token = request.bearer_token,
            .request_idempotency_key = request.idempotency_key,
            .request_id = request.request_id,
            .traceparent = request.traceparent,
            .metrics = &metrics,
            .drain_mode = &drain_mode,
        };
        const response = api.handleRequest(&ctx, request.method, request.target, request.body);

        const header = std.fmt.allocPrint(req_alloc, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nX-Request-Id: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ response.status, response.content_type, request.request_id, response.body.len }) catch continue;

        conn.stream.writeAll(header) catch continue;
        conn.stream.writeAll(response.body) catch continue;
    }

    const drain_deadline = ids.nowMs() + @as(i64, @intCast(cfg.engine.shutdown_grace_ms));
    while (ids.nowMs() < drain_deadline) {
        var drain_arena = std.heap.ArenaAllocator.init(allocator);
        defer drain_arena.deinit();
        const active = store.getActiveRuns(drain_arena.allocator()) catch break;
        if (active.len == 0) break;
        std.Thread.sleep(200 * std.time.ns_per_ms);
    }
}

fn serializeTagsJson(allocator: std.mem.Allocator, tags: []const []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, tags, .{});
}

const ParsedHttpRequest = struct {
    method: []const u8,
    target: []const u8,
    body: []const u8,
    bearer_token: ?[]const u8,
    idempotency_key: ?[]const u8,
    request_id: []const u8,
    traceparent: ?[]const u8,
};

fn readHttpRequest(allocator: std.mem.Allocator, stream: *std.net.Stream, max_bytes: usize) !?ParsedHttpRequest {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);

    var header_end: ?usize = null;
    var content_len: usize = 0;
    var chunk: [request_read_chunk]u8 = undefined;

    while (true) {
        const n = try stream.read(&chunk);
        if (n == 0) return null;

        try buffer.appendSlice(allocator, chunk[0..n]);
        if (buffer.items.len > max_bytes) return error.RequestTooLarge;

        if (header_end == null) {
            const hdr_end = std.mem.indexOf(u8, buffer.items, "\r\n\r\n") orelse continue;
            header_end = hdr_end;
            content_len = parseContentLength(buffer.items[0..hdr_end]) orelse return error.InvalidContentLength;

            const required = hdr_end + 4 + content_len;
            if (required > max_bytes) return error.RequestTooLarge;
            if (buffer.items.len >= required) break;
            continue;
        }

        const required = header_end.? + 4 + content_len;
        if (buffer.items.len >= required) break;
    }

    const req_total = header_end.? + 4 + content_len;
    const req_bytes = try allocator.dupe(u8, buffer.items[0..req_total]);

    const first_line_end = std.mem.indexOf(u8, req_bytes, "\r\n") orelse return error.InvalidRequestLine;
    const first_line = req_bytes[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');

    const method = parts.next() orelse return error.InvalidRequestLine;
    const target = parts.next() orelse return error.InvalidRequestLine;
    const body = req_bytes[header_end.? + 4 .. req_total];
    const headers_raw = req_bytes[0..header_end.?];
    const bearer_token = parseBearerToken(headers_raw);
    const idempotency_key = parseHeaderValue(headers_raw, "Idempotency-Key");
    const traceparent = parseHeaderValue(headers_raw, "Traceparent");
    const request_id = parseHeaderValue(headers_raw, "X-Request-Id") orelse blk: {
        const rid_buf = ids.generateId();
        break :blk try allocator.dupe(u8, &rid_buf);
    };

    return .{
        .method = method,
        .target = target,
        .body = body,
        .bearer_token = bearer_token,
        .idempotency_key = idempotency_key,
        .request_id = request_id,
        .traceparent = traceparent,
    };
}

fn parseContentLength(headers_raw: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers_raw, "\r\n");
    _ = lines.next(); // request line

    while (lines.next()) |line| {
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;

        const raw_value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, raw_value, 10) catch null;
    }

    return 0;
}

fn parseBearerToken(headers_raw: []const u8) ?[]const u8 {
    const raw_value = parseHeaderValue(headers_raw, "Authorization") orelse return null;
    const space_idx = std.mem.indexOfScalar(u8, raw_value, ' ') orelse return null;
    const scheme = std.mem.trim(u8, raw_value[0..space_idx], " \t");
    if (!std.ascii.eqlIgnoreCase(scheme, "Bearer")) return null;

    const token = std.mem.trim(u8, raw_value[space_idx + 1 ..], " \t");
    if (token.len == 0) return null;
    return token;
}

fn parseHeaderValue(headers_raw: []const u8, name_query: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers_raw, "\r\n");
    _ = lines.next(); // request line

    while (lines.next()) |line| {
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, name_query)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

test "serializeTagsJson escapes special chars" {
    const allocator = std.testing.allocator;
    const tags = [_][]const u8{
        "dev\"ops",
        "path\\with\\slashes",
        "line\nbreak",
    };

    const got = try serializeTagsJson(allocator, &tags);
    defer allocator.free(got);

    try std.testing.expectEqualStrings("[\"dev\\\"ops\",\"path\\\\with\\\\slashes\",\"line\\nbreak\"]", got);
}

test "parseContentLength returns zero when missing header" {
    const headers = "POST /runs HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Type: application/json";
    try std.testing.expectEqual(@as(?usize, 0), parseContentLength(headers));
}

test "parseContentLength parses header case-insensitively with whitespace" {
    const headers = "POST /runs HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "content-length:   123  ";
    try std.testing.expectEqual(@as(?usize, 123), parseContentLength(headers));
}

test "parseContentLength returns null for invalid number" {
    const headers = "POST /runs HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Length: not-a-number";
    try std.testing.expectEqual(@as(?usize, null), parseContentLength(headers));
}

test "parseBearerToken extracts bearer token from Authorization header" {
    const headers = "POST /runs HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Authorization: Bearer token-123\r\n" ++
        "Content-Length: 0";
    const token = parseBearerToken(headers);
    try std.testing.expect(token != null);
    try std.testing.expectEqualStrings("token-123", token.?);
}

test "parseBearerToken returns null for malformed Authorization header" {
    const headers = "POST /runs HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Authorization: Basic abc\r\n" ++
        "Content-Length: 0";
    try std.testing.expectEqual(@as(?[]const u8, null), parseBearerToken(headers));
}

test "parseBearerToken accepts case-insensitive bearer scheme" {
    const headers = "POST /runs HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Authorization: bearer token-xyz\r\n" ++
        "Content-Length: 0";
    const token = parseBearerToken(headers);
    try std.testing.expect(token != null);
    try std.testing.expectEqualStrings("token-xyz", token.?);
}

test "worker_protocol hasExplicitPath identifies explicit path URLs" {
    try std.testing.expect(!worker_protocol.hasExplicitPath("http://localhost:3000"));
    try std.testing.expect(!worker_protocol.hasExplicitPath("http://localhost:3000/"));
    try std.testing.expect(worker_protocol.hasExplicitPath("http://localhost:3000/webhook"));
}

comptime {
    _ = @import("ids.zig");
    _ = @import("types.zig");
    _ = @import("store.zig");
    _ = @import("api.zig");
    _ = @import("templates.zig");
    _ = @import("dispatch.zig");
    _ = @import("config.zig");
    _ = @import("engine.zig");
    _ = @import("callbacks.zig");
    _ = @import("workflow_validation.zig");
    _ = @import("worker_protocol.zig");
    _ = @import("worker_response.zig");
    _ = @import("metrics.zig");
    _ = @import("export_manifest.zig");
    _ = @import("from_json.zig");
}
