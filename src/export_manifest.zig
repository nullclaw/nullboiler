const std = @import("std");

pub fn run() !void {
    const manifest =
        \\{
        \\  "schema_version": 1,
        \\  "name": "nullboiler",
        \\  "display_name": "NullBoiler",
        \\  "description": "DAG-based workflow orchestrator",
        \\  "icon": "orchestrator",
        \\  "repo": "nullclaw/nullboiler",
        \\  "platforms": {
        \\    "aarch64-macos": { "asset": "nullboiler-macos-aarch64", "binary": "nullboiler" },
        \\    "x86_64-macos": { "asset": "nullboiler-macos-x86_64", "binary": "nullboiler" },
        \\    "x86_64-linux": { "asset": "nullboiler-linux-x86_64", "binary": "nullboiler" },
        \\    "aarch64-linux": { "asset": "nullboiler-linux-aarch64", "binary": "nullboiler" },
        \\    "riscv64-linux": { "asset": "nullboiler-linux-riscv64", "binary": "nullboiler" },
        \\    "x86_64-windows": { "asset": "nullboiler-windows-x86_64.exe", "binary": "nullboiler.exe" },
        \\    "aarch64-windows": { "asset": "nullboiler-windows-aarch64.exe", "binary": "nullboiler.exe" }
        \\  },
        \\  "build_from_source": {
        \\    "zig_version": "0.15.2",
        \\    "command": "zig build -Doptimize=ReleaseSmall",
        \\    "output": "zig-out/bin/nullboiler"
        \\  },
        \\  "launch": { "command": "nullboiler", "args": [] },
        \\  "health": { "endpoint": "/health", "port_from_config": "port" },
        \\  "ports": [{ "name": "api", "config_key": "port", "default": 8080, "protocol": "http" }],
        \\  "wizard": { "steps": [
        \\    { "id": "port", "title": "API Port", "type": "number", "required": true, "options": [] },
        \\    { "id": "api_token", "title": "API Token", "description": "Optional bearer token for API auth", "type": "secret", "required": false, "options": [] },
        \\    { "id": "db_path", "title": "Database Path", "type": "text", "required": true, "options": [] },
        \\    { "id": "tracker_enabled", "title": "Enable NullTickets Pull Mode", "description": "Let NullBoiler claim work directly from NullTickets", "type": "toggle", "required": false, "options": [] },
        \\    { "id": "tracker_url", "title": "NullTickets URL", "type": "text", "required": true, "default_value": "http://127.0.0.1:7700", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [] },
        \\    { "id": "tracker_api_token", "title": "NullTickets API Token", "description": "Optional bearer token for NullTickets auth", "type": "secret", "required": false, "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [] },
        \\    { "id": "tracker_agent_role", "title": "Agent Role", "description": "NullTickets role to claim", "type": "text", "required": true, "default_value": "coder", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [] },
        \\    { "id": "tracker_agent_id", "title": "Agent ID", "description": "Stable worker identity in NullTickets", "type": "text", "required": false, "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [] },
        \\    { "id": "tracker_success_trigger", "title": "Success Trigger", "description": "Optional transition trigger after a successful run", "type": "text", "required": false, "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [] },
        \\    { "id": "tracker_max_concurrent_tasks", "title": "Max Concurrent Tasks", "type": "number", "required": false, "default_value": "1", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [] }
        \\  ] },
        \\  "depends_on": [],
        \\  "connects_to": [
        \\    { "component": "nulltickets", "role": "tracker", "description": "Claims work from NullTickets" }
        \\  ]
        \\}
    ;
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(manifest);
    try stdout.writeAll("\n");
}
