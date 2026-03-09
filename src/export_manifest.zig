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
        \\    { "id": "tracker_pipeline_id", "title": "Pipeline ID", "description": "NullTickets pipeline handled by this NullBoiler tracker workflow", "type": "text", "required": true, "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [] },
        \\    { "id": "tracker_claim_role", "title": "Claim Role", "description": "NullTickets stage role this workflow claims", "type": "text", "required": true, "default_value": "coder", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [] },
        \\    { "id": "tracker_agent_id", "title": "Agent ID", "description": "Stable worker identity in NullTickets", "type": "text", "required": false, "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [] },
        \\    { "id": "tracker_success_trigger", "title": "Success Trigger", "description": "Transition trigger sent to NullTickets after a successful run", "type": "text", "required": true, "default_value": "complete", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [] },
        \\    { "id": "tracker_max_concurrent_tasks", "title": "Max Concurrent Tasks", "type": "number", "required": false, "default_value": "1", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [] },
        \\    { "id": "tracker_poll_interval_ms", "title": "Tracker Poll Interval", "description": "How often NullBoiler polls NullTickets for work", "type": "number", "required": false, "default_value": "10000", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [], "advanced": true },
        \\    { "id": "tracker_lease_ttl_ms", "title": "Lease TTL", "description": "Requested lease duration in milliseconds", "type": "number", "required": false, "default_value": "60000", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [], "advanced": true },
        \\    { "id": "tracker_heartbeat_interval_ms", "title": "Heartbeat Interval", "description": "Lease heartbeat interval in milliseconds", "type": "number", "required": false, "default_value": "30000", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [], "advanced": true },
        \\    { "id": "tracker_stall_timeout_ms", "title": "Stall Timeout", "description": "Fail execution if the subprocess stays idle longer than this", "type": "number", "required": false, "default_value": "300000", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [], "advanced": true },
        \\    { "id": "tracker_workspace_root", "title": "Workspace Root", "description": "Root directory for per-task workspaces", "type": "text", "required": false, "default_value": "workspaces", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [], "advanced": true },
        \\    { "id": "tracker_subprocess_command", "title": "Subprocess Command", "description": "Command used to spawn the task executor", "type": "text", "required": false, "default_value": "nullclaw", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [], "advanced": true },
        \\    { "id": "tracker_subprocess_base_port", "title": "Subprocess Base Port", "description": "First port reserved for spawned task subprocesses", "type": "number", "required": false, "default_value": "9200", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [], "advanced": true },
        \\    { "id": "tracker_subprocess_health_check_retries", "title": "Health Check Retries", "description": "Retries before marking a spawned executor unhealthy", "type": "number", "required": false, "default_value": "10", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [], "advanced": true },
        \\    { "id": "tracker_subprocess_max_turns", "title": "Subprocess Max Turns", "description": "Maximum interaction turns per claimed task", "type": "number", "required": false, "default_value": "20", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [], "advanced": true },
        \\    { "id": "tracker_subprocess_turn_timeout_ms", "title": "Turn Timeout", "description": "Max duration of one task turn in milliseconds", "type": "number", "required": false, "default_value": "600000", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [], "advanced": true },
        \\    { "id": "tracker_subprocess_continuation_prompt", "title": "Continuation Prompt", "description": "Prompt sent for follow-up turns after the first task prompt", "type": "text", "required": false, "default_value": "Continue working on this task. Your previous context is preserved.", "condition": { "step": "tracker_enabled", "equals": "true" }, "options": [], "advanced": true }
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
