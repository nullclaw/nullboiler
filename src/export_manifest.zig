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
        \\    { "id": "db_path", "title": "Database Path", "type": "text", "required": true, "options": [] }
        \\  ] },
        \\  "depends_on": [],
        \\  "connects_to": []
        \\}
    ;
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(manifest);
    try stdout.writeAll("\n");
}
