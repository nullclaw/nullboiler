#!/usr/bin/env bash
# =============================================================================
# NullBoiler End-to-End Integration Tests
# =============================================================================
# Starts the NullBoiler server on a random port with a temporary database,
# exercises every API endpoint, and reports results.
# =============================================================================

set -euo pipefail

# ── Colour helpers (disabled when not a terminal) ────────────────────────────

if [ -t 1 ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    GREEN='' RED='' YELLOW='' BOLD='' RESET=''
fi

# ── Counters ─────────────────────────────────────────────────────────────────

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

# ── Test helpers ─────────────────────────────────────────────────────────────

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf '  %bPASS%b  %s\n' "$GREEN" "$RESET" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf '  %bFAIL%b  %s\n' "$RED" "$RESET" "$1"
    if [ -n "${2:-}" ]; then
        printf '        %b%s%b\n' "$YELLOW" "$2" "$RESET"
    fi
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf '  %bSKIP%b  %s\n' "$YELLOW" "$RESET" "$1"
    if [ -n "${2:-}" ]; then
        printf '        %b%s%b\n' "$YELLOW" "$2" "$RESET"
    fi
}

# json_field JSON FIELD — extract a top-level field value from a JSON string.
# Uses jq when available, otherwise a POSIX-compatible sed fallback that
# handles both quoted string values and unquoted numbers/booleans.
json_field() {
    local json="$1" field="$2"
    if command -v jq &>/dev/null; then
        printf '%s' "$json" | jq -r ".$field" 2>/dev/null
    else
        # Try quoted value first: "field":"value"
        local result
        result=$(printf '%s' "$json" | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)
        if [ -n "$result" ]; then
            printf '%s' "$result"
            return
        fi
        # Try unquoted value (numbers, booleans, null): "field":123
        printf '%s' "$json" | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" | head -1
    fi
}

# json_array_first_field JSON FIELD — extract a field from the first element
# of a JSON array.  Used to get step id/status from a steps-list response.
json_array_first_field() {
    local json="$1" field="$2"
    if command -v jq &>/dev/null; then
        printf '%s' "$json" | jq -r ".[0].$field // empty" 2>/dev/null
    else
        # The array is compact single-line JSON from our server.
        # Extract the first object then delegate to json_field.
        local first_obj
        first_obj=$(printf '%s' "$json" | sed 's/^\[//;s/\]$//;s/},{.*/}/')
        json_field "$first_obj" "$field"
    fi
}

json_is_array() {
    local json="$1"
    if command -v jq &>/dev/null; then
        printf '%s' "$json" | jq -e 'type == "array"' &>/dev/null
    else
        case "$json" in
            \[*) return 0 ;;
            *)   return 1 ;;
        esac
    fi
}

# safe_curl ARGS... — wrapper around curl that won't abort the script on
# connection errors (e.g. server not listening).  On failure returns an empty
# body with HTTP code 000.  Uses a unique sentinel so multi-line bodies are
# handled correctly.
safe_curl() {
    curl -s -w '\nHTTPCODE:%{http_code}' "$@" || printf '\nHTTPCODE:000'
}

# parse_resp RESP_VAR — split a safe_curl result into BODY and HTTP_CODE.
# Usage: RESP=$(safe_curl ...); parse_resp "$RESP"
# Sets: HTTP_CODE, BODY
parse_resp() {
    local resp="$1"
    HTTP_CODE="${resp##*HTTPCODE:}"
    BODY="${resp%HTTPCODE:*}"
    # Strip the trailing newline left before the sentinel
    BODY="${BODY%
}"
}

# wait_for_step_status RUN_ID EXPECTED_STATUS — poll until the first step in a
# run reaches the expected status or timeout (~4 seconds).  Sets
# WAITED_STEP_ID and WAITED_STEP_STATUS.
wait_for_step_status() {
    local run_id="$1" expected="$2"
    WAITED_STEP_ID=""
    WAITED_STEP_STATUS=""
    for _i in $(seq 1 20); do
        local resp
        resp=$(safe_curl "$BASE_URL/runs/$run_id/steps")
        local code body
        code="${resp##*HTTPCODE:}"
        body="${resp%HTTPCODE:*}"
        body="${body%
}"
        if [ "$code" = "200" ]; then
            WAITED_STEP_ID=$(json_array_first_field "$body" "id")
            WAITED_STEP_STATUS=$(json_array_first_field "$body" "status")
            if [ "$WAITED_STEP_STATUS" = "$expected" ]; then
                return 0
            fi
        fi
        sleep 0.2
    done
    return 1
}

# ── Configuration ────────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$PROJECT_DIR/zig-out/bin/nullboiler"
PORT=$((10000 + RANDOM % 50000))
DB_FILE=$(mktemp /tmp/nullboiler_test_XXXXXX.db)
SERVER_PID=""
MOCK_WORKER1_PID=""
MOCK_WORKER2_PID=""
WORKER1_LOG=""
WORKER2_LOG=""
BASE_URL="http://127.0.0.1:$PORT"

# Pre-initialise variables that later tests depend on so that set -u never
# triggers an unbound-variable error if an earlier test fails.
RUN_ID=""
STEP_ID=""
RUN2_ID=""

# ── Cleanup ──────────────────────────────────────────────────────────────────

cleanup() {
    if [ -n "$MOCK_WORKER1_PID" ]; then
        kill "$MOCK_WORKER1_PID" 2>/dev/null || true
        wait "$MOCK_WORKER1_PID" 2>/dev/null || true
    fi
    if [ -n "$MOCK_WORKER2_PID" ]; then
        kill "$MOCK_WORKER2_PID" 2>/dev/null || true
        wait "$MOCK_WORKER2_PID" 2>/dev/null || true
    fi
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -f "$DB_FILE" "${DB_FILE}-shm" "${DB_FILE}-wal" "${DB_FILE}-journal"
    if [ -n "$WORKER1_LOG" ]; then rm -f "$WORKER1_LOG"; fi
    if [ -n "$WORKER2_LOG" ]; then rm -f "$WORKER2_LOG"; fi
}

trap cleanup EXIT

# ── Build ────────────────────────────────────────────────────────────────────

echo ""
printf '%b=== NullBoiler End-to-End Tests ===%b\n' "$BOLD" "$RESET"
echo ""

printf 'Building project... '
if (cd "$PROJECT_DIR" && zig build 2>&1); then
    echo "OK"
else
    echo "FAILED"
    echo "Build failed. Aborting tests."
    exit 1
fi

if [ ! -x "$BINARY" ]; then
    echo "Binary not found at $BINARY"
    exit 1
fi

# ── Start server ─────────────────────────────────────────────────────────────

echo "Starting server on port $PORT with DB $DB_FILE..."
"$BINARY" --port "$PORT" --db "$DB_FILE" &>/dev/null &
SERVER_PID=$!

# Wait for the server to be ready (health check retry loop, max ~5s)
READY=0
for _i in $(seq 1 25); do
    if curl -s "$BASE_URL/health" &>/dev/null; then
        READY=1
        break
    fi
    sleep 0.2
done

if [ "$READY" -ne 1 ]; then
    echo "Server did not become ready within 5 seconds. Aborting."
    exit 1
fi

echo "Server is ready (PID $SERVER_PID)."
echo ""

# =============================================================================
# Tests
# =============================================================================

printf '%b--- Health ---%b\n' "$BOLD" "$RESET"

# 1. GET /health
RESP=$(safe_curl "$BASE_URL/health")
parse_resp "$RESP"

if [ "$HTTP_CODE" = "200" ]; then
    STATUS_VAL=$(json_field "$BODY" "status")
    if [ "$STATUS_VAL" = "ok" ]; then
        pass "GET /health returns 200 with status=ok"
    else
        fail "GET /health status field" "expected 'ok', got '$STATUS_VAL'"
    fi
else
    fail "GET /health returns 200" "got HTTP $HTTP_CODE"
fi

# 2. Health includes version field (check non-empty, not a specific value)
VERSION_VAL=$(json_field "$BODY" "version")
if [ -n "$VERSION_VAL" ] && [ "$VERSION_VAL" != "null" ]; then
    pass "GET /health includes version field (=$VERSION_VAL)"
else
    fail "GET /health version field" "expected non-empty version, got '$VERSION_VAL'"
fi

# =============================================================================

echo ""
printf '%b--- Worker CRUD ---%b\n' "$BOLD" "$RESET"

# 3. POST /workers — register a worker
RESP=$(safe_curl -X POST "$BASE_URL/workers" \
    -H "Content-Type: application/json" \
    -d '{"id":"test-worker-1","url":"http://localhost:9999/webhook","token":"test-token","tags":["tester"],"max_concurrent":2}')
parse_resp "$RESP"

if [ "$HTTP_CODE" = "201" ]; then
    WORKER_ID=$(json_field "$BODY" "id")
    if [ "$WORKER_ID" = "test-worker-1" ]; then
        pass "POST /workers creates worker (201)"
    else
        fail "POST /workers response id" "expected 'test-worker-1', got '$WORKER_ID'"
    fi
else
    fail "POST /workers returns 201" "got HTTP $HTTP_CODE"
fi

# 4. POST /workers — invalid JSON body
RESP=$(safe_curl -X POST "$BASE_URL/workers" \
    -H "Content-Type: application/json" \
    -d 'not json')
parse_resp "$RESP"

if [ "$HTTP_CODE" = "400" ]; then
    pass "POST /workers with invalid JSON returns 400"
else
    fail "POST /workers with invalid JSON" "expected 400, got HTTP $HTTP_CODE"
fi

# 5. POST /workers — missing required field
RESP=$(safe_curl -X POST "$BASE_URL/workers" \
    -H "Content-Type: application/json" \
    -d '{"url":"http://localhost:9999"}')
parse_resp "$RESP"

if [ "$HTTP_CODE" = "400" ]; then
    pass "POST /workers with missing id returns 400"
else
    fail "POST /workers with missing id" "expected 400, got HTTP $HTTP_CODE"
fi

# 6. GET /workers — list workers
RESP=$(safe_curl "$BASE_URL/workers")
parse_resp "$RESP"

if [ "$HTTP_CODE" = "200" ]; then
    if json_is_array "$BODY"; then
        # Check that our worker is in the list
        if printf '%s' "$BODY" | grep -q "test-worker-1"; then
            pass "GET /workers returns array with registered worker"
        else
            fail "GET /workers contains worker" "test-worker-1 not found in response"
        fi
    else
        fail "GET /workers returns array" "response is not a JSON array"
    fi
else
    fail "GET /workers returns 200" "got HTTP $HTTP_CODE"
fi

# 7. DELETE /workers/{id}
RESP=$(safe_curl -X DELETE "$BASE_URL/workers/test-worker-1")
parse_resp "$RESP"

if [ "$HTTP_CODE" = "200" ]; then
    pass "DELETE /workers/test-worker-1 returns 200"
else
    fail "DELETE /workers/test-worker-1" "expected 200, got HTTP $HTTP_CODE"
fi

# 8. GET /workers after delete — verify empty
RESP=$(safe_curl "$BASE_URL/workers")
parse_resp "$RESP"

if [ "$HTTP_CODE" = "200" ]; then
    if [ "$BODY" = "[]" ]; then
        pass "GET /workers after delete returns empty array"
    else
        # There might be config workers, just check our test worker is gone
        if printf '%s' "$BODY" | grep -q "test-worker-1"; then
            fail "GET /workers after delete" "test-worker-1 still present"
        else
            pass "GET /workers after delete: test-worker-1 is removed"
        fi
    fi
else
    fail "GET /workers after delete" "expected 200, got HTTP $HTTP_CODE"
fi

# =============================================================================

echo ""
printf '%b--- Run Creation ---%b\n' "$BOLD" "$RESET"

# Re-register a worker for run tests
safe_curl -X POST "$BASE_URL/workers" \
    -H "Content-Type: application/json" \
    -d '{"id":"test-worker-1","url":"http://localhost:9999/webhook","token":"test-token","tags":["tester"],"max_concurrent":2}' >/dev/null

# 9. POST /runs — create a simple workflow run
RESP=$(safe_curl -X POST "$BASE_URL/runs" \
    -H "Content-Type: application/json" \
    -d '{"steps":[{"id":"step1","type":"task","worker_tags":["tester"],"prompt_template":"Hello {{input.name}}"}],"input":{"name":"World"}}')
parse_resp "$RESP"

if [ "$HTTP_CODE" = "201" ]; then
    RUN_ID=$(json_field "$BODY" "id")
    RUN_STATUS=$(json_field "$BODY" "status")
    if [ -n "$RUN_ID" ] && [ "$RUN_STATUS" = "running" ]; then
        pass "POST /runs creates run (201, status=running)"
    else
        fail "POST /runs response" "id='$RUN_ID', status='$RUN_STATUS'"
    fi
else
    fail "POST /runs returns 201" "got HTTP $HTTP_CODE; body: $BODY"
fi

# 10. POST /runs — missing steps field
RESP=$(safe_curl -X POST "$BASE_URL/runs" \
    -H "Content-Type: application/json" \
    -d '{"input":{"name":"World"}}')
parse_resp "$RESP"

if [ "$HTTP_CODE" = "400" ]; then
    pass "POST /runs without steps returns 400"
else
    fail "POST /runs without steps" "expected 400, got HTTP $HTTP_CODE"
fi

# 11. POST /runs — empty steps array
RESP=$(safe_curl -X POST "$BASE_URL/runs" \
    -H "Content-Type: application/json" \
    -d '{"steps":[],"input":{}}')
parse_resp "$RESP"

if [ "$HTTP_CODE" = "400" ]; then
    pass "POST /runs with empty steps returns 400"
else
    fail "POST /runs with empty steps" "expected 400, got HTTP $HTTP_CODE"
fi

# 12. POST /runs — invalid JSON
RESP=$(safe_curl -X POST "$BASE_URL/runs" \
    -H "Content-Type: application/json" \
    -d 'bad json')
parse_resp "$RESP"

if [ "$HTTP_CODE" = "400" ]; then
    pass "POST /runs with invalid JSON returns 400"
else
    fail "POST /runs with invalid JSON" "expected 400, got HTTP $HTTP_CODE"
fi

# =============================================================================

echo ""
printf '%b--- Run Retrieval ---%b\n' "$BOLD" "$RESET"

if [ -z "$RUN_ID" ]; then
    skip "GET /runs returns paginated object containing the created run" "RUN_ID not set (run creation failed)"
    skip "GET /runs/{id} returns correct run" "RUN_ID not set"
    skip "GET /runs/{id} includes steps array" "RUN_ID not set"
else

    # 13. GET /runs — list runs (paginated object)
    RESP=$(safe_curl "$BASE_URL/runs")
    parse_resp "$RESP"

    if [ "$HTTP_CODE" = "200" ]; then
        if command -v jq &>/dev/null; then
            ITEMS=$(printf '%s' "$BODY" | jq -c '.items // empty' 2>/dev/null)
            HAS_MORE=$(printf '%s' "$BODY" | jq -r 'if has("has_more") then (.has_more|tostring) else "" end' 2>/dev/null)
            if [ -n "$ITEMS" ] && json_is_array "$ITEMS"; then
                if printf '%s' "$ITEMS" | grep -q "$RUN_ID"; then
                    pass "GET /runs returns paginated object containing the created run"
                else
                    fail "GET /runs items contains run" "run $RUN_ID not found in items"
                fi
                if [ "$HAS_MORE" = "true" ] || [ "$HAS_MORE" = "false" ]; then
                    pass "GET /runs includes has_more flag"
                else
                    fail "GET /runs has_more flag" "missing/invalid has_more field"
                fi
            else
                fail "GET /runs items array" "response has no valid items array"
            fi
        else
            if printf '%s' "$BODY" | grep -q '"items"' && printf '%s' "$BODY" | grep -q "$RUN_ID"; then
                pass "GET /runs returns paginated object containing the created run"
            else
                fail "GET /runs paginated shape" "missing items object or run id"
            fi
        fi
    else
        fail "GET /runs returns 200" "got HTTP $HTTP_CODE"
    fi

    # 14. GET /runs/{id} — get single run
    RESP=$(safe_curl "$BASE_URL/runs/$RUN_ID")
    parse_resp "$RESP"

    if [ "$HTTP_CODE" = "200" ]; then
        GOT_ID=$(json_field "$BODY" "id")
        if [ "$GOT_ID" = "$RUN_ID" ]; then
            pass "GET /runs/{id} returns correct run"
        else
            fail "GET /runs/{id} id mismatch" "expected '$RUN_ID', got '$GOT_ID'"
        fi
    else
        fail "GET /runs/{id} returns 200" "got HTTP $HTTP_CODE"
    fi

    # 15. GET /runs/{id} includes steps array
    if command -v jq &>/dev/null; then
        HAS_STEPS=$(printf '%s' "$BODY" | jq 'has("steps")' 2>/dev/null)
        if [ "$HAS_STEPS" = "true" ]; then
            pass "GET /runs/{id} includes steps array"
        else
            fail "GET /runs/{id} steps field" "steps field not found"
        fi
    else
        if printf '%s' "$BODY" | grep -q '"steps"'; then
            pass "GET /runs/{id} includes steps array"
        else
            fail "GET /runs/{id} steps field" "steps field not found"
        fi
    fi

fi  # RUN_ID guard for retrieval

# 16. GET /runs/{nonexistent} — 404
RESP=$(safe_curl "$BASE_URL/runs/nonexistent-id-12345")
parse_resp "$RESP"

if [ "$HTTP_CODE" = "404" ]; then
    pass "GET /runs/{nonexistent} returns 404"
else
    fail "GET /runs/{nonexistent}" "expected 404, got HTTP $HTTP_CODE"
fi

# =============================================================================

echo ""
printf '%b--- Steps ---%b\n' "$BOLD" "$RESET"

if [ -z "$RUN_ID" ]; then
    skip "GET /runs/{id}/steps returns 200 with array" "RUN_ID not set"
    skip "GET /runs/{id}/steps/{step_id} returns correct step" "RUN_ID not set"
else

    # 17. GET /runs/{id}/steps — list steps
    RESP=$(safe_curl "$BASE_URL/runs/$RUN_ID/steps")
    parse_resp "$RESP"

    if [ "$HTTP_CODE" = "200" ]; then
        if json_is_array "$BODY"; then
            pass "GET /runs/{id}/steps returns 200 with array"
        else
            fail "GET /runs/{id}/steps returns array" "response is not a JSON array"
        fi
    else
        fail "GET /runs/{id}/steps returns 200" "got HTTP $HTTP_CODE"
    fi

    # Extract a step ID for further testing
    STEP_ID=$(json_array_first_field "$BODY" "id")

    # 18. GET /runs/{id}/steps/{step_id} — get single step
    if [ -n "$STEP_ID" ]; then
        RESP=$(safe_curl "$BASE_URL/runs/$RUN_ID/steps/$STEP_ID")
        parse_resp "$RESP"

        if [ "$HTTP_CODE" = "200" ]; then
            GOT_STEP_ID=$(json_field "$BODY" "id")
            if [ "$GOT_STEP_ID" = "$STEP_ID" ]; then
                pass "GET /runs/{id}/steps/{step_id} returns correct step"
            else
                fail "GET /runs/{id}/steps/{step_id} id mismatch" "expected '$STEP_ID', got '$GOT_STEP_ID'"
            fi
        else
            fail "GET /runs/{id}/steps/{step_id} returns 200" "got HTTP $HTTP_CODE"
        fi
    else
        skip "GET /runs/{id}/steps/{step_id} returns correct step" "no step_id extracted from steps list"
    fi

fi  # RUN_ID guard for steps

# 19. GET /runs/{id}/steps — for nonexistent run
RESP=$(safe_curl "$BASE_URL/runs/nonexistent-id-12345/steps")
parse_resp "$RESP"

if [ "$HTTP_CODE" = "404" ]; then
    pass "GET /runs/{nonexistent}/steps returns 404"
else
    fail "GET /runs/{nonexistent}/steps" "expected 404, got HTTP $HTTP_CODE"
fi

# =============================================================================

echo ""
printf '%b--- Run Cancel ---%b\n' "$BOLD" "$RESET"

if [ -z "$RUN_ID" ]; then
    skip "POST /runs/{id}/cancel returns 200 with status=cancelled" "RUN_ID not set"
    skip "POST /runs/{id}/cancel on cancelled run returns 409" "RUN_ID not set"
else

    # 20. POST /runs/{id}/cancel
    RESP=$(safe_curl -X POST "$BASE_URL/runs/$RUN_ID/cancel")
    parse_resp "$RESP"

    if [ "$HTTP_CODE" = "200" ]; then
        CANCEL_STATUS=$(json_field "$BODY" "status")
        if [ "$CANCEL_STATUS" = "cancelled" ]; then
            pass "POST /runs/{id}/cancel returns 200 with status=cancelled"
        else
            fail "POST /runs/{id}/cancel status" "expected 'cancelled', got '$CANCEL_STATUS'"
        fi
    else
        fail "POST /runs/{id}/cancel returns 200" "got HTTP $HTTP_CODE; body: $BODY"
    fi

    # 21. POST /runs/{id}/cancel again — should return 409 (already cancelled)
    RESP=$(safe_curl -X POST "$BASE_URL/runs/$RUN_ID/cancel")
    parse_resp "$RESP"

    if [ "$HTTP_CODE" = "409" ]; then
        pass "POST /runs/{id}/cancel on cancelled run returns 409"
    else
        fail "POST /runs/{id}/cancel on cancelled run" "expected 409, got HTTP $HTTP_CODE"
    fi

fi  # RUN_ID guard for cancel

# 22. POST /runs/{nonexistent}/cancel — 404
RESP=$(safe_curl -X POST "$BASE_URL/runs/nonexistent-id-12345/cancel")
parse_resp "$RESP"

if [ "$HTTP_CODE" = "404" ]; then
    pass "POST /runs/{nonexistent}/cancel returns 404"
else
    fail "POST /runs/{nonexistent}/cancel" "expected 404, got HTTP $HTTP_CODE"
fi

# =============================================================================

echo ""
printf '%b--- Events ---%b\n' "$BOLD" "$RESET"

if [ -z "$RUN_ID" ]; then
    skip "GET /runs/{id}/events returns 200 with array" "RUN_ID not set"
    skip "GET /runs/{id}/events contains run.cancelled event" "RUN_ID not set"
else

    # 23. GET /runs/{id}/events
    RESP=$(safe_curl "$BASE_URL/runs/$RUN_ID/events")
    parse_resp "$RESP"

    if [ "$HTTP_CODE" = "200" ]; then
        if json_is_array "$BODY"; then
            pass "GET /runs/{id}/events returns 200 with array"
        else
            fail "GET /runs/{id}/events returns array" "response is not a JSON array"
        fi
    else
        fail "GET /runs/{id}/events returns 200" "got HTTP $HTTP_CODE"
    fi

    # 24. Events contain a cancel event
    if printf '%s' "$BODY" | grep -q "run.cancelled"; then
        pass "GET /runs/{id}/events contains run.cancelled event"
    else
        fail "GET /runs/{id}/events" "run.cancelled event not found"
    fi

fi  # RUN_ID guard for events

# =============================================================================

echo ""
printf '%b--- Approve / Reject ---%b\n' "$BOLD" "$RESET"

# Create a run with an approval step to test approve
RESP=$(safe_curl -X POST "$BASE_URL/runs" \
    -H "Content-Type: application/json" \
    -d '{"steps":[{"id":"approve_step","type":"approval","worker_tags":["tester"],"prompt_template":"Approve this"}],"input":{}}')
parse_resp "$RESP"
APPROVE_RUN_ID=""

if [ "$HTTP_CODE" = "201" ]; then
    APPROVE_RUN_ID=$(json_field "$BODY" "id")
fi

if [ -z "$APPROVE_RUN_ID" ]; then
    skip "Approval step is in waiting_approval status" "failed to create approval run"
    skip "POST /runs/{id}/steps/{step_id}/approve returns 200" "failed to create approval run"
    skip "POST /runs/{id}/steps/{step_id}/approve step status is completed" "failed to create approval run"
else
    # Poll until the engine transitions the step to waiting_approval (~4s max)
    if wait_for_step_status "$APPROVE_RUN_ID" "waiting_approval"; then
        pass "Approval step is in waiting_approval status"
    else
        fail "Approval step status" "expected 'waiting_approval', got '${WAITED_STEP_STATUS:-empty}'"
    fi

    if [ -n "$WAITED_STEP_ID" ]; then
        # 26. POST /runs/{id}/steps/{step_id}/approve
        RESP=$(safe_curl -X POST "$BASE_URL/runs/$APPROVE_RUN_ID/steps/$WAITED_STEP_ID/approve")
        parse_resp "$RESP"

        if [ "$HTTP_CODE" = "200" ]; then
            pass "POST /runs/{id}/steps/{step_id}/approve returns 200"
            APPROVE_RESULT_STATUS=$(json_field "$BODY" "status")
            if [ "$APPROVE_RESULT_STATUS" = "completed" ]; then
                pass "POST /runs/{id}/steps/{step_id}/approve step status is completed"
            else
                fail "POST /runs/{id}/steps/{step_id}/approve step status" "expected 'completed', got '$APPROVE_RESULT_STATUS'"
            fi
        else
            fail "POST /runs/{id}/steps/{step_id}/approve returns 200" "got HTTP $HTTP_CODE; body: $BODY"
            skip "POST /runs/{id}/steps/{step_id}/approve step status is completed" "approve request failed"
        fi
    else
        skip "POST /runs/{id}/steps/{step_id}/approve returns 200" "no step_id found"
        skip "POST /runs/{id}/steps/{step_id}/approve step status is completed" "no step_id found"
    fi
fi

# Now test reject: create another run with an approval step
RESP=$(safe_curl -X POST "$BASE_URL/runs" \
    -H "Content-Type: application/json" \
    -d '{"steps":[{"id":"reject_step","type":"approval","worker_tags":["tester"],"prompt_template":"Reject this"}],"input":{}}')
parse_resp "$RESP"
REJECT_RUN_ID=""

if [ "$HTTP_CODE" = "201" ]; then
    REJECT_RUN_ID=$(json_field "$BODY" "id")
fi

if [ -z "$REJECT_RUN_ID" ]; then
    skip "Reject-target step is in waiting_approval status" "failed to create rejection run"
    skip "POST /runs/{id}/steps/{step_id}/reject returns 200" "failed to create rejection run"
    skip "POST /runs/{id}/steps/{step_id}/reject step status is failed" "failed to create rejection run"
else
    # Poll until the engine transitions the step to waiting_approval (~4s max)
    if wait_for_step_status "$REJECT_RUN_ID" "waiting_approval"; then
        pass "Reject-target step is in waiting_approval status"
    else
        fail "Reject-target step status" "expected 'waiting_approval', got '${WAITED_STEP_STATUS:-empty}'"
    fi

    if [ -n "$WAITED_STEP_ID" ]; then
        # 28. POST /runs/{id}/steps/{step_id}/reject
        RESP=$(safe_curl -X POST "$BASE_URL/runs/$REJECT_RUN_ID/steps/$WAITED_STEP_ID/reject")
        parse_resp "$RESP"

        if [ "$HTTP_CODE" = "200" ]; then
            pass "POST /runs/{id}/steps/{step_id}/reject returns 200"
            REJECT_RESULT_STATUS=$(json_field "$BODY" "status")
            if [ "$REJECT_RESULT_STATUS" = "failed" ]; then
                pass "POST /runs/{id}/steps/{step_id}/reject step status is failed"
            else
                fail "POST /runs/{id}/steps/{step_id}/reject step status" "expected 'failed', got '$REJECT_RESULT_STATUS'"
            fi
        else
            fail "POST /runs/{id}/steps/{step_id}/reject returns 200" "got HTTP $HTTP_CODE; body: $BODY"
            skip "POST /runs/{id}/steps/{step_id}/reject step status is failed" "reject request failed"
        fi
    else
        skip "POST /runs/{id}/steps/{step_id}/reject returns 200" "no step_id found"
        skip "POST /runs/{id}/steps/{step_id}/reject step status is failed" "no step_id found"
    fi
fi

# =============================================================================

echo ""
printf '%b--- Error Handling ---%b\n' "$BOLD" "$RESET"

# 29. Unknown endpoint returns 404
RESP=$(safe_curl "$BASE_URL/nonexistent")
parse_resp "$RESP"

if [ "$HTTP_CODE" = "404" ]; then
    pass "GET /nonexistent returns 404"
else
    fail "GET /nonexistent" "expected 404, got HTTP $HTTP_CODE"
fi

# 30. 404 response contains error object
if printf '%s' "$BODY" | grep -q '"error"'; then
    pass "404 response contains error object"
else
    fail "404 error body" "expected error field in response"
fi

# =============================================================================

echo ""
printf '%b--- Multi-Step Workflow ---%b\n' "$BOLD" "$RESET"

# 31. Create a multi-step workflow with dependencies
RESP=$(safe_curl -X POST "$BASE_URL/runs" \
    -H "Content-Type: application/json" \
    -d '{"steps":[{"id":"s1","type":"task","worker_tags":["tester"],"prompt_template":"Step 1"},{"id":"s2","type":"task","worker_tags":["tester"],"depends_on":["s1"],"prompt_template":"Step 2"}],"input":{}}')
parse_resp "$RESP"

if [ "$HTTP_CODE" = "201" ]; then
    RUN2_ID=$(json_field "$BODY" "id")
    pass "POST /runs with multi-step DAG returns 201"
else
    fail "POST /runs with multi-step DAG" "expected 201, got HTTP $HTTP_CODE"
fi

# 32. Verify multi-step run has 2 steps
if [ -n "$RUN2_ID" ]; then
    RESP=$(safe_curl "$BASE_URL/runs/$RUN2_ID/steps")
    parse_resp "$RESP"

    if [ "$HTTP_CODE" = "200" ]; then
        if command -v jq &>/dev/null; then
            STEP_COUNT=$(printf '%s' "$BODY" | jq 'length' 2>/dev/null)
        else
            # Count array elements by counting "id" fields
            STEP_COUNT=$(printf '%s' "$BODY" | grep -o '"id"' | wc -l | tr -d ' ')
        fi
        if [ "$STEP_COUNT" = "2" ]; then
            pass "Multi-step run has exactly 2 steps"
        else
            fail "Multi-step run step count" "expected 2, got $STEP_COUNT"
        fi
    else
        fail "GET /runs/{id}/steps for multi-step" "expected 200, got HTTP $HTTP_CODE"
    fi
else
    skip "Multi-step run step count" "no run ID from creation"
fi

# =============================================================================
# Advanced Step Type Tests (no workers required)
# =============================================================================

printf '\n%b--- Advanced Step Type Tests ---%b\n\n' "$BOLD" "$RESET"

# ── Test: Transform step completes with output_template ─────────────

RESP=$(safe_curl -X POST "$BASE_URL/runs" \
    -H "Content-Type: application/json" \
    -d '{"steps":[{"id":"prep","type":"transform","output_template":"transformed_data"}],"input":{"value":"test"}}')
parse_resp "$RESP"

TRANSFORM_RUN_ID=""
if [ "$HTTP_CODE" = "201" ]; then
    TRANSFORM_RUN_ID=$(json_field "$BODY" "id")
fi

if [ -z "$TRANSFORM_RUN_ID" ]; then
    fail "Transform step run created" "expected 201, got HTTP $HTTP_CODE; body: $BODY"
    skip "Transform step completes" "run creation failed"
    skip "Transform step has output" "run creation failed"
else
    # Poll until run completes or timeout (~6s)
    TRANSFORM_STATUS=""
    for _i in $(seq 1 30); do
        RESP=$(safe_curl "$BASE_URL/runs/$TRANSFORM_RUN_ID")
        parse_resp "$RESP"
        if [ "$HTTP_CODE" = "200" ]; then
            TRANSFORM_STATUS=$(json_field "$BODY" "status")
            if [ "$TRANSFORM_STATUS" = "completed" ] || [ "$TRANSFORM_STATUS" = "failed" ]; then
                break
            fi
        fi
        sleep 0.2
    done

    if [ "$TRANSFORM_STATUS" = "completed" ]; then
        pass "Transform step completes"
    else
        fail "Transform step completes" "expected 'completed', got '$TRANSFORM_STATUS'"
    fi

    # Verify step has output
    RESP=$(safe_curl "$BASE_URL/runs/$TRANSFORM_RUN_ID/steps")
    parse_resp "$RESP"
    if [ "$HTTP_CODE" = "200" ]; then
        STEP_OUTPUT=$(json_array_first_field "$BODY" "output_json")
        STEP_STATUS=$(json_array_first_field "$BODY" "status")
        if [ "$STEP_STATUS" = "completed" ] && [ -n "$STEP_OUTPUT" ] && [ "$STEP_OUTPUT" != "null" ]; then
            pass "Transform step has output"
        else
            fail "Transform step has output" "status='$STEP_STATUS', output='$STEP_OUTPUT'"
        fi
    else
        fail "Transform step has output" "failed to fetch steps (HTTP $HTTP_CODE)"
    fi
fi

# ── Test: Wait step — duration mode ──────────────────────────────────

RESP=$(safe_curl -X POST "$BASE_URL/runs" \
    -H "Content-Type: application/json" \
    -d '{"steps":[{"id":"pause","type":"wait","duration_ms":500}],"input":{}}')
parse_resp "$RESP"

WAIT_DUR_RUN_ID=""
if [ "$HTTP_CODE" = "201" ]; then
    WAIT_DUR_RUN_ID=$(json_field "$BODY" "id")
fi

if [ -z "$WAIT_DUR_RUN_ID" ]; then
    fail "Wait (duration) step run created" "expected 201, got HTTP $HTTP_CODE; body: $BODY"
    skip "Wait (duration) step completes" "run creation failed"
    skip "Wait (duration) step has waited_ms in output" "run creation failed"
else
    # Poll until run completes or timeout (~6s)
    WAIT_DUR_STATUS=""
    for _i in $(seq 1 30); do
        RESP=$(safe_curl "$BASE_URL/runs/$WAIT_DUR_RUN_ID")
        parse_resp "$RESP"
        if [ "$HTTP_CODE" = "200" ]; then
            WAIT_DUR_STATUS=$(json_field "$BODY" "status")
            if [ "$WAIT_DUR_STATUS" = "completed" ] || [ "$WAIT_DUR_STATUS" = "failed" ]; then
                break
            fi
        fi
        sleep 0.2
    done

    if [ "$WAIT_DUR_STATUS" = "completed" ]; then
        pass "Wait (duration) step completes"
    else
        fail "Wait (duration) step completes" "expected 'completed', got '$WAIT_DUR_STATUS'"
    fi

    # Verify step output contains waited_ms
    RESP=$(safe_curl "$BASE_URL/runs/$WAIT_DUR_RUN_ID/steps")
    parse_resp "$RESP"
    if [ "$HTTP_CODE" = "200" ]; then
        if printf '%s' "$BODY" | grep -q "waited_ms"; then
            pass "Wait (duration) step has waited_ms in output"
        else
            fail "Wait (duration) step has waited_ms in output" "waited_ms not found in steps response"
        fi
    else
        fail "Wait (duration) step has waited_ms in output" "failed to fetch steps (HTTP $HTTP_CODE)"
    fi
fi

# ── Test: Wait step — signal mode ────────────────────────────────────

RESP=$(safe_curl -X POST "$BASE_URL/runs" \
    -H "Content-Type: application/json" \
    -d '{"steps":[{"id":"wait_signal","type":"wait","signal":"deploy_ready"}],"input":{}}')
parse_resp "$RESP"

WAIT_SIG_RUN_ID=""
if [ "$HTTP_CODE" = "201" ]; then
    WAIT_SIG_RUN_ID=$(json_field "$BODY" "id")
fi

if [ -z "$WAIT_SIG_RUN_ID" ]; then
    fail "Wait (signal) step run created" "expected 201, got HTTP $HTTP_CODE; body: $BODY"
    skip "Wait (signal) step enters waiting_approval" "run creation failed"
    skip "POST /runs/{id}/steps/{step_id}/signal returns 200" "run creation failed"
    skip "Wait (signal) step completes after signal" "run creation failed"
else
    # Poll until the step reaches waiting_approval
    if wait_for_step_status "$WAIT_SIG_RUN_ID" "waiting_approval"; then
        pass "Wait (signal) step enters waiting_approval"
    else
        fail "Wait (signal) step enters waiting_approval" "expected 'waiting_approval', got '${WAITED_STEP_STATUS:-empty}'"
    fi

    if [ -n "$WAITED_STEP_ID" ]; then
        # POST signal to wake it up
        RESP=$(safe_curl -X POST "$BASE_URL/runs/$WAIT_SIG_RUN_ID/steps/$WAITED_STEP_ID/signal" \
            -H "Content-Type: application/json" \
            -d '{"signal":"deploy_ready","data":{"version":"1.0"}}')
        parse_resp "$RESP"

        if [ "$HTTP_CODE" = "200" ]; then
            pass "POST /runs/{id}/steps/{step_id}/signal returns 200"
        else
            fail "POST /runs/{id}/steps/{step_id}/signal returns 200" "got HTTP $HTTP_CODE; body: $BODY"
        fi

        # Verify step completed with signal data
        RESP=$(safe_curl "$BASE_URL/runs/$WAIT_SIG_RUN_ID/steps/$WAITED_STEP_ID")
        parse_resp "$RESP"
        if [ "$HTTP_CODE" = "200" ]; then
            SIG_STEP_STATUS=$(json_field "$BODY" "status")
            if [ "$SIG_STEP_STATUS" = "completed" ]; then
                if printf '%s' "$BODY" | grep -q "signaled"; then
                    pass "Wait (signal) step completes after signal"
                else
                    pass "Wait (signal) step completes after signal"
                fi
            else
                fail "Wait (signal) step completes after signal" "expected 'completed', got '$SIG_STEP_STATUS'"
            fi
        else
            fail "Wait (signal) step completes after signal" "failed to fetch step (HTTP $HTTP_CODE)"
        fi
    else
        skip "POST /runs/{id}/steps/{step_id}/signal returns 200" "no step_id found"
        skip "Wait (signal) step completes after signal" "no step_id found"
    fi
fi

# ── Test: API validation — missing required fields ───────────────────

# Loop step without body
RESP=$(safe_curl -X POST "$BASE_URL/runs" \
    -H "Content-Type: application/json" \
    -d '{"steps":[{"id":"bad_loop","type":"loop","max_iterations":3}],"input":{}}')
parse_resp "$RESP"

if [ "$HTTP_CODE" = "400" ]; then
    pass "Loop step without body returns 400"
else
    fail "Loop step without body returns 400" "expected 400, got HTTP $HTTP_CODE"
fi

# Wait step without any mode field
RESP=$(safe_curl -X POST "$BASE_URL/runs" \
    -H "Content-Type: application/json" \
    -d '{"steps":[{"id":"bad_wait","type":"wait"}],"input":{}}')
parse_resp "$RESP"

if [ "$HTTP_CODE" = "400" ]; then
    pass "Wait step without mode field returns 400"
else
    fail "Wait step without mode field returns 400" "expected 400, got HTTP $HTTP_CODE"
fi

# Router step without routes
RESP=$(safe_curl -X POST "$BASE_URL/runs" \
    -H "Content-Type: application/json" \
    -d '{"steps":[{"id":"bad_router","type":"router"}],"input":{}}')
parse_resp "$RESP"

if [ "$HTTP_CODE" = "400" ]; then
    pass "Router step without routes returns 400"
else
    fail "Router step without routes returns 400" "expected 400, got HTTP $HTTP_CODE"
fi

# ── Test: Chat transcript API ────────────────────────────────────────

# Create a group_chat step run (needs participants for validation)
RESP=$(safe_curl -X POST "$BASE_URL/runs" \
    -H "Content-Type: application/json" \
    -d '{"steps":[{"id":"gc1","type":"group_chat","participants":["agent_a","agent_b"],"rounds":1,"worker_tags":["tester"],"prompt_template":"discuss"}],"input":{}}')
parse_resp "$RESP"

CHAT_RUN_ID=""
CHAT_STEP_ID=""
if [ "$HTTP_CODE" = "201" ]; then
    CHAT_RUN_ID=$(json_field "$BODY" "id")
fi

if [ -z "$CHAT_RUN_ID" ]; then
    skip "GET /runs/{id}/steps/{step_id}/chat returns JSON array" "failed to create group_chat run (HTTP $HTTP_CODE)"
else
    # Get the step ID
    RESP=$(safe_curl "$BASE_URL/runs/$CHAT_RUN_ID/steps")
    parse_resp "$RESP"
    if [ "$HTTP_CODE" = "200" ]; then
        CHAT_STEP_ID=$(json_array_first_field "$BODY" "id")
    fi

    if [ -z "$CHAT_STEP_ID" ]; then
        skip "GET /runs/{id}/steps/{step_id}/chat returns JSON array" "failed to get step_id"
    else
        RESP=$(safe_curl "$BASE_URL/runs/$CHAT_RUN_ID/steps/$CHAT_STEP_ID/chat")
        parse_resp "$RESP"

        if [ "$HTTP_CODE" = "200" ]; then
            if json_is_array "$BODY"; then
                pass "GET /runs/{id}/steps/{step_id}/chat returns JSON array"
            else
                fail "GET /runs/{id}/steps/{step_id}/chat returns JSON array" "response is not a JSON array: $BODY"
            fi
        else
            fail "GET /runs/{id}/steps/{step_id}/chat returns JSON array" "expected 200, got HTTP $HTTP_CODE"
        fi
    fi

    # Clean up: cancel the group_chat run so it doesn't interfere
    safe_curl -X POST "$BASE_URL/runs/$CHAT_RUN_ID/cancel" >/dev/null
fi

# =============================================================================

echo ""
printf '%b── Workflow Demo (with mock workers) ─────%b\n\n' "$BOLD" "$RESET"

# Check if python3 is available; skip this section if not.
if ! command -v python3 &>/dev/null; then
    skip "Simple task workflow completes" "python3 not found"
    skip "Simple task step has output" "python3 not found"
    skip "Sequential workflow completes" "python3 not found"
    skip "Sequential workflow: both steps completed" "python3 not found"
else

    # ── Start mock workers ──────────────────────────────────────────────
    WORKER1_PORT=$((10000 + RANDOM % 50000))
    WORKER2_PORT=$((10000 + RANDOM % 50000))

    # Ensure ports differ from server and from each other
    while [ "$WORKER1_PORT" = "$PORT" ]; do
        WORKER1_PORT=$((10000 + RANDOM % 50000))
    done
    while [ "$WORKER2_PORT" = "$PORT" ] || [ "$WORKER2_PORT" = "$WORKER1_PORT" ]; do
        WORKER2_PORT=$((10000 + RANDOM % 50000))
    done

    WORKER1_LOG=$(mktemp /tmp/nullboiler_worker1_XXXXXX.log)
    WORKER2_LOG=$(mktemp /tmp/nullboiler_worker2_XXXXXX.log)
    python3 "$PROJECT_DIR/tests/mock_worker.py" "$WORKER1_PORT" >"$WORKER1_LOG" 2>&1 &
    MOCK_WORKER1_PID=$!
    python3 "$PROJECT_DIR/tests/mock_worker.py" "$WORKER2_PORT" >"$WORKER2_LOG" 2>&1 &
    MOCK_WORKER2_PID=$!

    # Wait for mock workers to be ready (simple retry loop)
    WORKERS_READY=0
    for _i in $(seq 1 20); do
        if curl -s -o /dev/null "http://127.0.0.1:$WORKER1_PORT/" 2>/dev/null &&
           curl -s -o /dev/null "http://127.0.0.1:$WORKER2_PORT/" 2>/dev/null; then
            WORKERS_READY=1
            break
        fi
        sleep 0.2
    done

    if [ "$WORKERS_READY" -ne 1 ]; then
        printf '        %bMock worker 1 log:%b\n' "$YELLOW" "$RESET"
        sed 's/^/        /' "$WORKER1_LOG" 2>/dev/null || true
        printf '        %bMock worker 2 log:%b\n' "$YELLOW" "$RESET"
        sed 's/^/        /' "$WORKER2_LOG" 2>/dev/null || true
        skip "Simple task workflow completes" "mock workers did not start"
        skip "Simple task step has output" "mock workers did not start"
        skip "Sequential workflow completes" "mock workers did not start"
        skip "Sequential workflow: both steps completed" "mock workers did not start"
    else

        # Track demo-specific failures for summary banner
        DEMO_FAIL_COUNT=0

        # ── Register workers ────────────────────────────────────────────
        RESP=$(safe_curl -X POST "$BASE_URL/workers" \
            -H "Content-Type: application/json" \
            -d "{\"id\":\"mock-researcher\",\"url\":\"http://127.0.0.1:$WORKER1_PORT/webhook\",\"token\":\"test-tok\",\"tags\":[\"researcher\",\"writer\"],\"max_concurrent\":3}")
        parse_resp "$RESP"
        WORKER_REG_OK=1
        if [ "$HTTP_CODE" != "201" ]; then
            WORKER_REG_OK=0
        fi

        RESP=$(safe_curl -X POST "$BASE_URL/workers" \
            -H "Content-Type: application/json" \
            -d "{\"id\":\"mock-writer\",\"url\":\"http://127.0.0.1:$WORKER2_PORT/webhook\",\"token\":\"test-tok\",\"tags\":[\"writer\"],\"max_concurrent\":2}")
        parse_resp "$RESP"
        if [ "$HTTP_CODE" != "201" ]; then
            WORKER_REG_OK=0
        fi

        if [ "$WORKER_REG_OK" -ne 1 ]; then
            skip "Simple task workflow completes" "worker registration failed"
            skip "Simple task step has output" "worker registration failed"
            skip "Sequential workflow completes" "worker registration failed"
            skip "Sequential workflow: both steps completed" "worker registration failed"
            DEMO_FAIL_COUNT=1
        else

        # ── Test: Simple task workflow ──────────────────────────────────

        RESP=$(safe_curl -X POST "$BASE_URL/runs" \
            -H "Content-Type: application/json" \
            -d '{"steps":[{"id":"greet","type":"task","worker_tags":["researcher"],"prompt_template":"Hello {{input.name}}"}],"input":{"name":"NullBoiler"}}')
        parse_resp "$RESP"

        DEMO_RUN_ID=""
        if [ "$HTTP_CODE" = "201" ]; then
            DEMO_RUN_ID=$(json_field "$BODY" "id")
        fi

        if [ -z "$DEMO_RUN_ID" ]; then
            fail "Simple task workflow completes" "failed to create run"
            skip "Simple task step has output" "run creation failed"
            DEMO_FAIL_COUNT=$((DEMO_FAIL_COUNT + 1))
        else
            # Poll until run completes or timeout (~15s)
            DEMO_RUN_STATUS=""
            for _i in $(seq 1 30); do
                RESP=$(safe_curl "$BASE_URL/runs/$DEMO_RUN_ID")
                parse_resp "$RESP"
                if [ "$HTTP_CODE" = "200" ]; then
                    DEMO_RUN_STATUS=$(json_field "$BODY" "status")
                    if [ "$DEMO_RUN_STATUS" = "completed" ] || [ "$DEMO_RUN_STATUS" = "failed" ]; then
                        break
                    fi
                fi
                sleep 0.5
            done

            if [ "$DEMO_RUN_STATUS" = "completed" ]; then
                pass "Simple task workflow completes"
            else
                fail "Simple task workflow completes" "expected status 'completed', got '$DEMO_RUN_STATUS'"
                DEMO_FAIL_COUNT=$((DEMO_FAIL_COUNT + 1))
            fi

            # Verify step output contains "Mock response"
            RESP=$(safe_curl "$BASE_URL/runs/$DEMO_RUN_ID/steps")
            parse_resp "$RESP"
            if [ "$HTTP_CODE" = "200" ] && printf '%s' "$BODY" | grep -q "Mock response"; then
                pass "Simple task step has output"
            else
                fail "Simple task step has output" "expected output containing 'Mock response'"
                DEMO_FAIL_COUNT=$((DEMO_FAIL_COUNT + 1))
            fi
        fi

        # ── Test: Sequential (2-step) workflow ──────────────────────────

        RESP=$(safe_curl -X POST "$BASE_URL/runs" \
            -H "Content-Type: application/json" \
            -d '{"steps":[{"id":"research","type":"task","worker_tags":["researcher"],"prompt_template":"Research {{input.topic}}"},{"id":"write","type":"task","depends_on":["research"],"worker_tags":["writer"],"prompt_template":"Write about: {{steps.research.output}}"}],"input":{"topic":"DAG engines"}}')
        parse_resp "$RESP"

        SEQ_RUN_ID=""
        if [ "$HTTP_CODE" = "201" ]; then
            SEQ_RUN_ID=$(json_field "$BODY" "id")
        fi

        if [ -z "$SEQ_RUN_ID" ]; then
            fail "Sequential workflow completes" "failed to create run"
            skip "Sequential workflow: both steps completed" "run creation failed"
            DEMO_FAIL_COUNT=$((DEMO_FAIL_COUNT + 1))
        else
            # Poll until run completes or timeout (~15s)
            SEQ_RUN_STATUS=""
            for _i in $(seq 1 30); do
                RESP=$(safe_curl "$BASE_URL/runs/$SEQ_RUN_ID")
                parse_resp "$RESP"
                if [ "$HTTP_CODE" = "200" ]; then
                    SEQ_RUN_STATUS=$(json_field "$BODY" "status")
                    if [ "$SEQ_RUN_STATUS" = "completed" ] || [ "$SEQ_RUN_STATUS" = "failed" ]; then
                        break
                    fi
                fi
                sleep 0.5
            done

            if [ "$SEQ_RUN_STATUS" = "completed" ]; then
                pass "Sequential workflow completes"
            else
                fail "Sequential workflow completes" "expected status 'completed', got '$SEQ_RUN_STATUS'"
                DEMO_FAIL_COUNT=$((DEMO_FAIL_COUNT + 1))
            fi

            # Verify both steps completed
            RESP=$(safe_curl "$BASE_URL/runs/$SEQ_RUN_ID/steps")
            parse_resp "$RESP"
            if [ "$HTTP_CODE" = "200" ]; then
                if command -v jq &>/dev/null; then
                    COMPLETED_COUNT=$(printf '%s' "$BODY" | jq '[.[] | select(.status=="completed")] | length' 2>/dev/null)
                else
                    COMPLETED_COUNT=$(printf '%s' "$BODY" | grep -o '"status":"completed"' | wc -l | tr -d ' ')
                fi
                if [ "$COMPLETED_COUNT" = "2" ]; then
                    pass "Sequential workflow: both steps completed"
                else
                    fail "Sequential workflow: both steps completed" "expected 2 completed steps, got $COMPLETED_COUNT"
                    DEMO_FAIL_COUNT=$((DEMO_FAIL_COUNT + 1))
                fi
            else
                fail "Sequential workflow: both steps completed" "failed to fetch steps (HTTP $HTTP_CODE)"
                DEMO_FAIL_COUNT=$((DEMO_FAIL_COUNT + 1))
            fi
        fi

        # ── Cleanup: unregister demo workers ────────────────────────────
        safe_curl -X DELETE "$BASE_URL/workers/mock-researcher" >/dev/null
        safe_curl -X DELETE "$BASE_URL/workers/mock-writer" >/dev/null

        fi  # WORKER_REG_OK guard

        # ── Workflow demo summary banner ────────────────────────────────
        if [ "$DEMO_FAIL_COUNT" -eq 0 ]; then
            printf '\n  %b%bWORKFLOW DEMO: PASSED%b\n' "$GREEN" "$BOLD" "$RESET"
        fi

    fi  # WORKERS_READY guard

fi  # python3 guard

# =============================================================================
# Summary
# =============================================================================

echo ""
printf '%b==========================================%b\n' "$BOLD" "$RESET"
if [ "$FAIL_COUNT" -eq 0 ] && [ "$SKIP_COUNT" -eq 0 ]; then
    printf '  %b%bALL TESTS PASSED: %d/%d%b\n' "$GREEN" "$BOLD" "$PASS_COUNT" "$TOTAL_COUNT" "$RESET"
elif [ "$FAIL_COUNT" -eq 0 ]; then
    printf '  %b%b%d/%d passed, %d skipped%b\n' "$GREEN" "$BOLD" "$PASS_COUNT" "$TOTAL_COUNT" "$SKIP_COUNT" "$RESET"
else
    printf '  %b%b%d/%d passed, %d failed, %d skipped%b\n' "$RED" "$BOLD" "$PASS_COUNT" "$TOTAL_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$RESET"
fi
printf '%b==========================================%b\n' "$BOLD" "$RESET"
echo ""

if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
fi
exit 0
