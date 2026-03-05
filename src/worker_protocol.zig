const std = @import("std");

pub const Protocol = enum {
    webhook,
    api_chat,
    openai_chat,
    mqtt,
    redis_stream,
};

pub fn parse(raw: []const u8) ?Protocol {
    if (std.mem.eql(u8, raw, "webhook")) return .webhook;
    if (std.mem.eql(u8, raw, "api_chat")) return .api_chat;
    if (std.mem.eql(u8, raw, "openai_chat")) return .openai_chat;
    if (std.mem.eql(u8, raw, "mqtt")) return .mqtt;
    if (std.mem.eql(u8, raw, "redis_stream")) return .redis_stream;
    return null;
}

pub fn requiresModel(protocol: Protocol) bool {
    return switch (protocol) {
        .openai_chat => true,
        .webhook, .api_chat, .mqtt, .redis_stream => false,
    };
}

pub fn requiresExplicitPath(protocol: Protocol) bool {
    return switch (protocol) {
        .webhook => true,
        .api_chat, .openai_chat, .mqtt, .redis_stream => false,
    };
}

pub fn validateUrlForProtocol(url: []const u8, protocol: Protocol) bool {
    // mqtt and redis_stream URLs are validated by their own parsers
    if (protocol == .mqtt or protocol == .redis_stream) return true;
    if (!requiresExplicitPath(protocol)) return true;
    return hasExplicitPath(url);
}

pub fn buildRequestUrl(
    allocator: std.mem.Allocator,
    worker_url: []const u8,
    protocol: Protocol,
) ![]const u8 {
    const trimmed = std.mem.trimRight(u8, worker_url, "/");
    if (requiresExplicitPath(protocol) and !hasExplicitPath(trimmed)) {
        return error.WebhookUrlPathRequired;
    }
    return try allocator.dupe(u8, trimmed);
}

pub fn hasExplicitPath(url: []const u8) bool {
    const trimmed = std.mem.trimRight(u8, url, "/");
    if (std.mem.startsWith(u8, trimmed, "/")) return true;

    const scheme_idx = std.mem.indexOf(u8, trimmed, "://") orelse return false;
    const host_start = scheme_idx + 3;
    const slash_idx = std.mem.indexOfScalarPos(u8, trimmed, host_start, '/') orelse return false;
    return slash_idx + 1 < trimmed.len;
}

pub const MqttUrlParts = struct {
    host: []const u8,
    port: u16,
    topic: []const u8,
    response_topic: []const u8, // allocator-owned: topic ++ "/responses"
};

pub fn parseMqttUrl(allocator: std.mem.Allocator, url: []const u8) !MqttUrlParts {
    const scheme = "mqtt://";
    if (!std.mem.startsWith(u8, url, scheme)) return error.InvalidMqttUrl;

    const after_scheme = url[scheme.len..];

    // Find the colon separating host from port
    const colon_idx = std.mem.indexOfScalar(u8, after_scheme, ':') orelse return error.InvalidMqttUrl;
    const host = after_scheme[0..colon_idx];
    if (host.len == 0) return error.InvalidMqttUrl;

    const after_colon = after_scheme[colon_idx + 1 ..];

    // Find the slash separating port from topic
    const slash_idx = std.mem.indexOfScalar(u8, after_colon, '/') orelse return error.InvalidMqttUrl;
    const port_str = after_colon[0..slash_idx];
    const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidMqttUrl;

    const topic = after_colon[slash_idx + 1 ..];
    if (topic.len == 0) return error.InvalidMqttUrl;

    const response_topic = try std.fmt.allocPrint(allocator, "{s}/responses", .{topic});

    return MqttUrlParts{
        .host = host,
        .port = port,
        .topic = topic,
        .response_topic = response_topic,
    };
}

pub const RedisUrlParts = struct {
    host: []const u8,
    port: u16,
    stream_key: []const u8,
    response_stream: []const u8, // allocator-owned: key ++ ":responses"
};

pub fn parseRedisUrl(allocator: std.mem.Allocator, url: []const u8) !RedisUrlParts {
    const scheme = "redis://";
    if (!std.mem.startsWith(u8, url, scheme)) return error.InvalidRedisUrl;

    const after_scheme = url[scheme.len..];

    // Find the colon separating host from port
    const colon_idx = std.mem.indexOfScalar(u8, after_scheme, ':') orelse return error.InvalidRedisUrl;
    const host = after_scheme[0..colon_idx];
    if (host.len == 0) return error.InvalidRedisUrl;

    const after_colon = after_scheme[colon_idx + 1 ..];

    // Find the slash separating port from stream key
    const slash_idx = std.mem.indexOfScalar(u8, after_colon, '/') orelse return error.InvalidRedisUrl;
    const port_str = after_colon[0..slash_idx];
    const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidRedisUrl;

    const stream_key = after_colon[slash_idx + 1 ..];
    if (stream_key.len == 0) return error.InvalidRedisUrl;

    const response_stream = try std.fmt.allocPrint(allocator, "{s}:responses", .{stream_key});

    return RedisUrlParts{
        .host = host,
        .port = port,
        .stream_key = stream_key,
        .response_stream = response_stream,
    };
}

test "parse protocol supports known values" {
    try std.testing.expectEqual(Protocol.webhook, parse("webhook").?);
    try std.testing.expectEqual(Protocol.api_chat, parse("api_chat").?);
    try std.testing.expectEqual(Protocol.openai_chat, parse("openai_chat").?);
    try std.testing.expect(parse("unknown") == null);
}

test "hasExplicitPath only accepts explicit path" {
    try std.testing.expect(!hasExplicitPath("http://localhost:3000"));
    try std.testing.expect(!hasExplicitPath("http://localhost:3000/"));
    try std.testing.expect(hasExplicitPath("http://localhost:3000/webhook"));
    try std.testing.expect(hasExplicitPath("/webhook"));
}

test "buildRequestUrl enforces explicit webhook path" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.WebhookUrlPathRequired,
        buildRequestUrl(allocator, "http://localhost:3000", .webhook),
    );

    const webhook_url = try buildRequestUrl(allocator, "http://localhost:3000/webhook", .webhook);
    defer allocator.free(webhook_url);
    try std.testing.expectEqualStrings("http://localhost:3000/webhook", webhook_url);

    const api_url = try buildRequestUrl(allocator, "http://localhost:42617/api/chat/", .api_chat);
    defer allocator.free(api_url);
    try std.testing.expectEqualStrings("http://localhost:42617/api/chat", api_url);
}

test "validateUrlForProtocol enforces protocol-specific constraints" {
    try std.testing.expect(!validateUrlForProtocol("http://localhost:3000", .webhook));
    try std.testing.expect(validateUrlForProtocol("http://localhost:3000/webhook", .webhook));
    try std.testing.expect(validateUrlForProtocol("http://localhost:42617/api/chat", .api_chat));
    try std.testing.expect(validateUrlForProtocol("mqtt://broker:1883/topic", .mqtt));
    try std.testing.expect(validateUrlForProtocol("redis://redis:6379/stream", .redis_stream));
}

test "parse supports mqtt and redis_stream" {
    try std.testing.expectEqual(Protocol.mqtt, parse("mqtt").?);
    try std.testing.expectEqual(Protocol.redis_stream, parse("redis_stream").?);
}

test "parseMqttUrl extracts host, port, topic" {
    const result = try parseMqttUrl(std.testing.allocator, "mqtt://broker.local:1883/nullclaw/planner/requests");
    defer std.testing.allocator.free(result.response_topic);
    try std.testing.expectEqualStrings("broker.local", result.host);
    try std.testing.expectEqual(@as(u16, 1883), result.port);
    try std.testing.expectEqualStrings("nullclaw/planner/requests", result.topic);
    try std.testing.expectEqualStrings("nullclaw/planner/requests/responses", result.response_topic);
}

test "parseRedisUrl extracts host, port, stream key" {
    const result = try parseRedisUrl(std.testing.allocator, "redis://redis.local:6379/nullclaw:builder:requests");
    defer std.testing.allocator.free(result.response_stream);
    try std.testing.expectEqualStrings("redis.local", result.host);
    try std.testing.expectEqual(@as(u16, 6379), result.port);
    try std.testing.expectEqualStrings("nullclaw:builder:requests", result.stream_key);
    try std.testing.expectEqualStrings("nullclaw:builder:requests:responses", result.response_stream);
}

test "parseMqttUrl rejects invalid urls" {
    try std.testing.expectError(error.InvalidMqttUrl, parseMqttUrl(std.testing.allocator, "http://broker:1883/topic"));
    try std.testing.expectError(error.InvalidMqttUrl, parseMqttUrl(std.testing.allocator, "mqtt://broker:1883/"));
    try std.testing.expectError(error.InvalidMqttUrl, parseMqttUrl(std.testing.allocator, "mqtt://:1883/topic"));
    try std.testing.expectError(error.InvalidMqttUrl, parseMqttUrl(std.testing.allocator, "mqtt://broker:abc/topic"));
}

test "parseRedisUrl rejects invalid urls" {
    try std.testing.expectError(error.InvalidRedisUrl, parseRedisUrl(std.testing.allocator, "http://redis:6379/stream"));
    try std.testing.expectError(error.InvalidRedisUrl, parseRedisUrl(std.testing.allocator, "redis://redis:6379/"));
    try std.testing.expectError(error.InvalidRedisUrl, parseRedisUrl(std.testing.allocator, "redis://:6379/stream"));
    try std.testing.expectError(error.InvalidRedisUrl, parseRedisUrl(std.testing.allocator, "redis://redis:abc/stream"));
}
