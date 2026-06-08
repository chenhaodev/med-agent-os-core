#!/usr/bin/env bash
# Mock adapter for eval/testing — returns canned ═══-wrapped responses without calling ask.sh.
# Reads mock fixture from eval/mock/fixtures/<INTENT_ID>.txt if it exists,
# otherwise returns a generic placeholder answer.
#
# Uses same env contract as adapters/inner_all.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$BASE_DIR/lib/common.sh"
source "$BASE_DIR/lib/unwrap.sh"

FENCE="═══════════════════════════════════════════════════════"
# Anchor to the repo's fixtures dir, not $SCRIPT_DIR — the eval harness copies this
# adapter into registry/adapters/, so $SCRIPT_DIR/fixtures would not exist and the
# canned fixtures would be silently skipped. BASE_DIR resolves to the repo root from
# either location (eval/mock/../.. or registry/adapters/../..).
FIXTURES_DIR="$BASE_DIR/eval/mock/fixtures"

result_file="$RUNDIR/intent_${INTENT_ID}.result.json"

t_start=$(now_ms)

# Try specific fixture, fall back to generic
fixture_file="$FIXTURES_DIR/${INTENT_ID}.txt"
if [[ ! -f "$fixture_file" ]]; then
    fixture_file="$FIXTURES_DIR/default.txt"
fi

if [[ -f "$fixture_file" ]]; then
    raw_stdout=$(cat "$fixture_file")
else
    # generic placeholder
    raw_stdout="
$FENCE
【模拟回答】针对问题「${INTENT_QUESTION}」的占位答案。
本回答为测试用途，仅验证管线流转。
$FENCE
"
fi

t_end=$(now_ms)
elapsed=$(( t_end - t_start ))

unwrap_out=$(unwrap "$raw_stdout")
unwrap_status=$(echo "$unwrap_out" | head -1)
answer=$(echo "$unwrap_out" | tail -n +2)

case "$unwrap_status" in
    ok)           status="ok" ;;
    oob)          status="oob" ;;
    *)
        # Mirror adapters/inner_all.sh: fence-less but non-empty output is kept
        # as the answer rather than silently dropped.
        if [[ -n "${raw_stdout//[[:space:]]/}" ]]; then
            status="ok"
            answer=$(printf '%s' "$raw_stdout" | python3 -c "import sys; print(sys.stdin.read().strip())")
        else
            status="error"; answer=""
        fi
        ;;
esac

python3 - "$INTENT_ID" "$status" "$answer" "$elapsed" > "$result_file" <<'PYEOF'
import json, sys
print(json.dumps({
    "id":        sys.argv[1],
    "status":    sys.argv[2],
    "answer":    sys.argv[3] if sys.argv[2] == "ok" else None,
    "citations": [],
    "ms":        int(sys.argv[4]),
    "exit_code": 0,
}, ensure_ascii=False))
PYEOF

log_debug "mock_inner_all[$INTENT_ID] status=$status ms=$elapsed"
exit 0
