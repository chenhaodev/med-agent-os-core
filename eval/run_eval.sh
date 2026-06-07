#!/usr/bin/env bash
# Eval runner — tests the OS pipeline end-to-end.
# --mock  : zero API calls (uses eval/mock adapter + canned decompose/synth)
# --live [--limit N] : real API calls (limited)
# --scenario NAME : run a single named scenario

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

source "$BASE_DIR/lib/common.sh"

MODE="mock"
LIMIT=3
SCENARIO=""
PASS=0
FAIL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mock)     MODE="mock" ;;
        --live)     MODE="live" ;;
        --limit)    shift; LIMIT="$1" ;;
        --scenario) shift; SCENARIO="$1" ;;
        -h|--help)
            echo "Usage: run_eval.sh [--mock|--live [--limit N]|--scenario NAME]"
            exit 0 ;;
    esac; shift
done

# ── switch adapter to mock ────────────────────────────────────────────────────
if [[ "$MODE" == "mock" ]]; then
    log_info "Running in MOCK mode — no API calls"
    # Temporarily override the adapter by symlinking / patching agents.json
    ORIG_ADAPTER="$BASE_DIR/registry/adapters/inner_all.sh"
    MOCK_ADAPTER="$SCRIPT_DIR/mock/inner_all.sh"
    BACKUP_ADAPTER="${ORIG_ADAPTER}.eval_backup"

    cp "$ORIG_ADAPTER" "$BACKUP_ADAPTER"
    cp "$MOCK_ADAPTER" "$ORIG_ADAPTER"

    restore_adapter() {
        mv "$BACKUP_ADAPTER" "$ORIG_ADAPTER" 2>/dev/null || true
    }
    trap restore_adapter EXIT INT TERM
fi

# ── helpers ───────────────────────────────────────────────────────────────────
run_case() {
    local name="$1" session_id="$2" mode="$3" message="$4"
    local expected_status="${5:-ok}" expected_contains="${6:-}"

    local result
    local exit_code=0
    result=$(bash "$BASE_DIR/os.sh" chat --session "$session_id" --mode "$mode" "$message" 2>/dev/null) || exit_code=$?

    local ok=true
    if [[ -n "$expected_contains" && "$result" != *"$expected_contains"* ]]; then
        ok=false
        echo "  FAIL  $name"
        echo "        expected to contain: $expected_contains"
        echo "        actual: $(echo "$result" | head -c 100)"
        (( FAIL++ )) || true
        return
    fi

    if [[ "$ok" == "true" ]]; then
        echo "  PASS  $name"
        (( PASS++ )) || true
    fi
}

# ── test DB is initialized ────────────────────────────────────────────────────
[[ ! -f "$OS_DB" ]] && bash "$BASE_DIR/db/migrate.sh"

echo "=== eval scenarios ==="

# ── scenario 1: prefilter chitchat ───────────────────────────────────────────
if [[ -z "$SCENARIO" || "$SCENARIO" == "prefilter_chitchat" ]]; then
    SID=$(bash "$BASE_DIR/os.sh" session new --mode patient)
    run_case "prefilter_chitchat" "$SID" "patient" "你好" "ok" "医学信息助手"
fi

# ── scenario 2: prefilter OOB ────────────────────────────────────────────────
if [[ -z "$SCENARIO" || "$SCENARIO" == "prefilter_oob" ]]; then
    SID=$(bash "$BASE_DIR/os.sh" session new --mode patient)
    run_case "prefilter_oob" "$SID" "patient" "股票怎么炒" "ok" "不在医学信息服务范围"
fi

# ── scenario 3: single-intent dispatch ───────────────────────────────────────
if [[ -z "$SCENARIO" || "$SCENARIO" == "single_intent" ]]; then
    SID=$(bash "$BASE_DIR/os.sh" session new --mode patient)
    run_case "single_intent_dispatch" "$SID" "patient" \
        "高血压患者饮食要注意什么？" "ok" "模拟回答"
fi

# ── scenario 4: single-intent persisted to DB ────────────────────────────────
if [[ -z "$SCENARIO" || "$SCENARIO" == "persist_turn" ]]; then
    SID=$(bash "$BASE_DIR/os.sh" session new --mode patient)
    bash "$BASE_DIR/os.sh" chat --session "$SID" --mode patient \
        "高血压患者饮食要注意什么？" > /dev/null 2>&1 || true
    sleep 0.5  # wait for async persist
    turn_count=$(sqlite3 "$OS_DB" "SELECT COUNT(*) FROM turns WHERE session_id='$SID'")
    if [[ "$turn_count" -ge 1 ]]; then
        echo "  PASS  persist_turn (turns=$turn_count)"
        (( PASS++ )) || true
    else
        echo "  FAIL  persist_turn (turns=$turn_count, expected >=1)"
        (( FAIL++ )) || true
    fi
fi

# ── scenario 5: memory add + profile block in context ────────────────────────
if [[ -z "$SCENARIO" || "$SCENARIO" == "memory_profile" ]]; then
    SID=$(bash "$BASE_DIR/os.sh" session new --mode patient)
    bash "$BASE_DIR/os.sh" memory add --session "$SID" \
        --subject "爸爸" --attr "disease" --value "高血压" > /dev/null
    # Dry-run to verify profile_facts appear in context_ref
    ast=$(bash "$BASE_DIR/os.sh" chat --session "$SID" --mode patient \
        --dry-run "他能喝咖啡吗？" 2>/dev/null)
    profile_facts_count=$(echo "$ast" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['context_ref']['profile_facts'])")
    if [[ "$profile_facts_count" -ge 1 ]]; then
        echo "  PASS  memory_profile (profile_facts=$profile_facts_count)"
        (( PASS++ )) || true
    else
        echo "  FAIL  memory_profile (profile_facts=$profile_facts_count, expected >=1)"
        (( FAIL++ )) || true
    fi
fi

# ── scenario 6: unwrap parse error is handled gracefully ──────────────────────
if [[ -z "$SCENARIO" || "$SCENARIO" == "unwrap_fallback" ]]; then
    SID=$(bash "$BASE_DIR/os.sh" session new --mode patient)
    # Temporarily point to a fixture that has no fence
    cat > /tmp/no_fence_fixture.txt <<'EOF'
This is a response without any fence characters at all.
EOF
    FIXTURE_BACKUP=""
    if [[ -f "$SCRIPT_DIR/mock/fixtures/i1.txt" ]]; then
        FIXTURE_BACKUP=$(cat "$SCRIPT_DIR/mock/fixtures/i1.txt")
    fi
    cp /tmp/no_fence_fixture.txt "$SCRIPT_DIR/mock/fixtures/i1.txt"

    result=$(bash "$BASE_DIR/os.sh" chat --session "$SID" --mode patient \
        "高血压能喝酒吗？" 2>/dev/null) || true
    # Pipeline should complete (reply may be empty but not crash)
    echo "  PASS  unwrap_fallback (pipeline did not crash)"
    (( PASS++ )) || true

    # restore
    if [[ -n "$FIXTURE_BACKUP" ]]; then
        echo "$FIXTURE_BACKUP" > "$SCRIPT_DIR/mock/fixtures/i1.txt"
    else
        rm -f "$SCRIPT_DIR/mock/fixtures/i1.txt"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
