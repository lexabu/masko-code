#!/usr/bin/env bash
set -euo pipefail

if ! command -v codex >/dev/null 2>&1; then
  echo "codex CLI not found in PATH"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for this smoke test"
  exit 1
fi

TMP_DIR="${TMPDIR:-/tmp}/codex-mascot-smoke"
mkdir -p "$TMP_DIR"
OUT1="$TMP_DIR/turn1.jsonl"
OUT2="$TMP_DIR/turn2.jsonl"
OUT3="$TMP_DIR/turn3.jsonl"
ERR1="$TMP_DIR/turn1.err"
ERR2="$TMP_DIR/turn2.err"
ERR3="$TMP_DIR/turn3.err"

rm -f "$OUT1" "$OUT2" "$OUT3" "$ERR1" "$ERR2" "$ERR3"

echo "Starting 3-turn Codex conversation for mascot smoke test..."

codex exec --json "Turn 1/3: reply with exactly 'turn-one-ok'." >"$OUT1" 2>"$ERR1"
SID=$(jq -r 'select(.type=="thread.started") | .thread_id' "$OUT1" | head -n1)

if [[ -z "$SID" || "$SID" == "null" ]]; then
  echo "Failed to capture Codex session id from turn 1"
  echo "--- turn1 stderr ---"
  cat "$ERR1" || true
  exit 1
fi

codex exec resume --json "$SID" "Turn 2/3: reply with exactly 'turn-two-ok'." >"$OUT2" 2>"$ERR2"

codex exec resume --json "$SID" "Turn 3/3: ask one concise question about mascot testing and end with '[question-issued]'." >"$OUT3" 2>"$ERR3"

echo ""
echo "Session id: $SID"
echo ""

for n in 1 2 3; do
  echo "--- TURN ${n} ---"
  cat "$TMP_DIR/turn${n}.jsonl"
  if [[ -s "$TMP_DIR/turn${n}.err" ]]; then
    echo "--- TURN ${n} STDERR ---"
    cat "$TMP_DIR/turn${n}.err"
  fi
  echo ""
done

SESSION_FILE=$(find "$HOME/.codex/sessions" -name "*${SID}*.jsonl" -print | head -n1 || true)
if [[ -n "$SESSION_FILE" ]]; then
  echo "Codex session file: $SESSION_FILE"
  echo "Recent mapped record types in session file:"
  rg -n '"type":"(session_meta|event_msg|response_item|function_call|function_call_output|compacted|turn_context)"' "$SESSION_FILE" | tail -n 25 || true
else
  echo "Could not locate session file for id: $SID"
fi

echo ""
echo "Masko ingestion check command (run after ~5 seconds):"
echo "jq --arg sid \"$SID\" '[ .[] | select(.session_id==\$sid) | {hook_event_name,source,task_id,reason,last_assistant_message} ] | .[0:20]' \"$HOME/Library/Application Support/masko-desktop/events.json\""

echo ""
echo "Tip: keep focus in another app while this script runs to validate overlay notifications and mascot reactions."
