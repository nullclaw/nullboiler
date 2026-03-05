#!/usr/bin/env bash
set -euo pipefail

# Submit a multi-agent workflow to NullBoiler.
#
# Usage:
#   ./run-workflow.sh "Build a REST API for a todo app"
#   ./run-workflow.sh "Build a CLI tool" --workflow plan-build-review
#   NULLBOILER_URL=http://remote:8080 ./run-workflow.sh "Deploy a service"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_URL="${NULLBOILER_URL:-http://localhost:8080}"
WORKFLOW="plan-then-build"
GOAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workflow) WORKFLOW="$2"; shift 2 ;;
    --url)      BASE_URL="$2"; shift 2 ;;
    *)          GOAL="$1"; shift ;;
  esac
done

if [[ -z "$GOAL" ]]; then
  echo "Usage: $0 \"your goal here\" [--workflow plan-then-build|parallel-research|plan-build-review]"
  exit 1
fi

WORKFLOW_FILE="$SCRIPT_DIR/workflows/$WORKFLOW.json"
if [[ ! -f "$WORKFLOW_FILE" ]]; then
  echo "Unknown workflow: $WORKFLOW"
  echo "Available: $(ls "$SCRIPT_DIR/workflows/" | sed 's/.json$//' | tr '\n' ' ')"
  exit 1
fi

# Replace the input.goal in the workflow JSON
PAYLOAD=$(jq --arg goal "$GOAL" '.input.goal = $goal' "$WORKFLOW_FILE")

echo "Submitting '$WORKFLOW' workflow to $BASE_URL..."
echo "Goal: $GOAL"
echo ""

RESP=$(curl -s -w '\n%{http_code}' -X POST "$BASE_URL/runs" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

if [[ "$HTTP_CODE" == "201" ]]; then
  RUN_ID=$(echo "$BODY" | jq -r '.id')
  echo "Run created: $RUN_ID"
  echo ""
  echo "Monitor:"
  echo "  curl $BASE_URL/runs/$RUN_ID"
  echo "  curl $BASE_URL/runs/$RUN_ID/steps"
  echo "  curl $BASE_URL/runs/$RUN_ID/events"
else
  echo "Error (HTTP $HTTP_CODE):"
  echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
  exit 1
fi
