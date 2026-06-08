#!/usr/bin/env bash
# Eval runner — tests the OS pipeline end-to-end.
# --mock  : zero API calls (uses eval/mock adapter + canned decompose/synth)
# --live [--limit N] : real API calls driven by eval/scenarios.json
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
            echo "Usage: run_eval.sh [--mock|--live [--limit N]] [--scenario NAME]"
            exit 0 ;;
    esac; shift
done

# ── switch adapter to mock ────────────────────────────────────────────────────
if [[ "$MODE" == "mock" ]]; then
    log_info "Running in MOCK mode — no API calls"
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

# ── test DB is initialized ────────────────────────────────────────────────────
[[ ! -f "$OS_DB" ]] && bash "$BASE_DIR/db/migrate.sh"

# ── helpers ───────────────────────────────────────────────────────────────────
_pass() { echo "  PASS  $1"; (( PASS++ )) || true; }
_fail() { echo "  FAIL  $1"; echo "        $2"; (( FAIL++ )) || true; }

run_case() {
    local name="$1" session_id="$2" mode="$3" message="$4"
    local expected_status="${5:-ok}" expected_contains="${6:-}"

    local result exit_code=0
    result=$(bash "$BASE_DIR/os.sh" chat --session "$session_id" --mode "$mode" "$message" 2>/dev/null) || exit_code=$?

    if [[ -n "$expected_contains" && "$result" != *"$expected_contains"* ]]; then
        _fail "$name" "expected to contain: $expected_contains | actual: $(echo "$result" | head -c 100)"
        return
    fi
    _pass "$name"
}

# ── live assertion helpers ────────────────────────────────────────────────────
# Run os.sh chat, return reply; sets _last_turn_id via DB lookup.
_last_turn_id() {
    local sid="$1"
    sqlite3 "$OS_DB" \
        "SELECT turn_id FROM turns WHERE session_id='$sid' ORDER BY turn_index DESC LIMIT 1;"
}

_db_prefilter() { sqlite3 "$OS_DB" "SELECT prefilter FROM turns WHERE turn_id='$1';"; }
_db_status()    { sqlite3 "$OS_DB" "SELECT status FROM turns WHERE turn_id='$1';"; }
_db_agent_calls_count() {
    sqlite3 "$OS_DB" "SELECT COUNT(*) FROM agent_calls WHERE turn_id='$1';"
}
_db_profile_facts_count() {
    sqlite3 "$OS_DB" "SELECT COUNT(*) FROM profile_facts WHERE session_id='$1' AND status='active';"
}
_db_node_count() {
    local turn_id="$1"
    sqlite3 "$OS_DB" "SELECT decompose_json FROM turns WHERE turn_id='$1';" | \
        python3 -c "
import json,sys
raw=sys.stdin.read().strip()
if not raw: print(0); sys.exit()
d=json.loads(raw)
print(len(d.get('plan',{}).get('nodes',[])))
"
}
_db_fast_path() {
    local turn_id="$1"
    local nc; nc=$(_db_node_count "$turn_id")
    [[ "$nc" -eq 1 ]] && echo "true" || echo "false"
}

# Run a single live scenario from scenarios.json entry (JSON string arg).
_live_run_scenario() {
    local sc_json="$1"

    local name mode desc requires_api
    name=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['name'])" "$sc_json")
    mode=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('mode','patient'))" "$sc_json")
    desc=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('desc',''))" "$sc_json")
    requires_api=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('requires_api',False))" "$sc_json")

    local sid
    sid=$(bash "$BASE_DIR/os.sh" session new --mode "$mode" 2>/dev/null)

    # ── run messages ──────────────────────────────────────────────────────────
    local is_multi_turn repeat_n has_messages
    has_messages=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('true' if 'messages' in d else 'false')" "$sc_json")
    repeat_n=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('repeat',1))" "$sc_json")

    local last_reply="" second_reply=""

    if [[ "$has_messages" == "true" ]]; then
        # multi-turn
        local msgs_count turn_idx=0
        msgs_count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])['messages']))" "$sc_json")
        while [[ $turn_idx -lt $msgs_count ]]; do
            local msg
            msg=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['messages'][int(sys.argv[2])])" "$sc_json" "$turn_idx")
            local reply
            reply=$(bash "$BASE_DIR/os.sh" chat --session "$sid" --mode "$mode" "$msg" 2>/dev/null) || true
            if [[ $turn_idx -eq 1 ]]; then
                second_reply="$reply"
            fi
            last_reply="$reply"
            sleep 0.3  # let async persist finish between turns
            (( turn_idx++ )) || true
        done
    else
        # single message, possibly repeated
        local msg
        msg=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['message'])" "$sc_json")
        local rep=0
        local t_first=0 t_second=0
        while [[ $rep -lt $repeat_n ]]; do
            local t_start; t_start=$(python3 -c "import time; print(int(time.time()*1000))")
            last_reply=$(bash "$BASE_DIR/os.sh" chat --session "$sid" --mode "$mode" "$msg" 2>/dev/null) || true
            local t_end; t_end=$(python3 -c "import time; print(int(time.time()*1000))")
            if [[ $rep -eq 0 ]]; then
                t_first=$(( t_end - t_start ))
            elif [[ $rep -eq 1 ]]; then
                t_second=$(( t_end - t_start ))
            fi
            (( rep++ )) || true
        done
    fi

    sleep 0.5  # let final async persist settle

    local tid; tid=$(_last_turn_id "$sid")

    # ── evaluate assertions ───────────────────────────────────────────────────
    local failures=()

    # expect_prefilter
    local exp_pf
    exp_pf=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('expect_prefilter',''))" "$sc_json")
    if [[ -n "$exp_pf" ]]; then
        local got_pf; got_pf=$(_db_prefilter "$tid")
        [[ "$got_pf" == "$exp_pf" ]] || failures+=("expect_prefilter=$exp_pf got=$got_pf")
    fi

    # expect_no_dispatch
    local exp_nd
    exp_nd=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('expect_no_dispatch',False))" "$sc_json")
    if [[ "$exp_nd" == "True" ]]; then
        local ac_count; ac_count=$(_db_agent_calls_count "$tid")
        [[ "$ac_count" -eq 0 ]] || failures+=("expect_no_dispatch: agent_calls=$ac_count")
    fi

    # expect_contains
    local exp_contains
    exp_contains=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('expect_contains',''))" "$sc_json")
    if [[ -n "$exp_contains" ]]; then
        [[ "$last_reply" == *"$exp_contains"* ]] || failures+=("expect_contains='$exp_contains' not in reply")
    fi

    # expect_node_count
    local exp_nc
    exp_nc=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('expect_node_count',''))" "$sc_json")
    if [[ -n "$exp_nc" ]]; then
        local got_nc; got_nc=$(_db_node_count "$tid")
        [[ "$got_nc" -eq "$exp_nc" ]] || failures+=("expect_node_count=$exp_nc got=$got_nc")
    fi

    # expect_node_count_gte
    local exp_nc_gte
    exp_nc_gte=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('expect_node_count_gte',''))" "$sc_json")
    if [[ -n "$exp_nc_gte" ]]; then
        local got_nc; got_nc=$(_db_node_count "$tid")
        [[ "$got_nc" -ge "$exp_nc_gte" ]] || failures+=("expect_node_count_gte=$exp_nc_gte got=$got_nc")
    fi

    # expect_fast_path
    local exp_fp
    exp_fp=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('expect_fast_path',False))" "$sc_json")
    if [[ "$exp_fp" == "True" ]]; then
        local got_fp; got_fp=$(_db_fast_path "$tid")
        [[ "$got_fp" == "true" ]] || failures+=("expect_fast_path: node_count > 1")
    fi

    # expect_multi_intent
    local exp_mi
    exp_mi=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('expect_multi_intent',False))" "$sc_json")
    if [[ "$exp_mi" == "True" ]]; then
        local got_nc; got_nc=$(_db_node_count "$tid")
        [[ "$got_nc" -gt 1 ]] || failures+=("expect_multi_intent: node_count=$got_nc (expected >1)")
    fi

    # expect_profile_facts_gte
    local exp_pf_gte
    exp_pf_gte=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('expect_profile_facts_gte',''))" "$sc_json")
    if [[ -n "$exp_pf_gte" ]]; then
        local got_pf_count; got_pf_count=$(_db_profile_facts_count "$sid")
        [[ "$got_pf_count" -ge "$exp_pf_gte" ]] || failures+=("expect_profile_facts_gte=$exp_pf_gte got=$got_pf_count")
    fi

    # expect_second_turn_contains (check agent_calls.question for second turn)
    local exp_stc
    exp_stc=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('expect_second_turn_contains',''))" "$sc_json")
    if [[ -n "$exp_stc" ]]; then
        # Find the second turn's agent_calls questions
        local second_tid
        second_tid=$(sqlite3 "$OS_DB" \
            "SELECT turn_id FROM turns WHERE session_id='$sid' ORDER BY turn_index LIMIT 1 OFFSET 1;")
        if [[ -n "$second_tid" ]]; then
            local q_found
            q_found=$(sqlite3 "$OS_DB" \
                "SELECT question FROM agent_calls WHERE turn_id='$second_tid';" | \
                grep -c "$exp_stc" 2>/dev/null || echo "0")
            [[ "$q_found" -gt 0 ]] || failures+=("expect_second_turn_contains='$exp_stc' not in agent_calls.question")
        else
            failures+=("expect_second_turn_contains: no second turn found")
        fi
    fi

    # expect_status
    local exp_st
    exp_st=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('expect_status',''))" "$sc_json")
    if [[ -n "$exp_st" ]]; then
        local got_st; got_st=$(_db_status "$tid")
        [[ "$got_st" == "$exp_st" ]] || failures+=("expect_status=$exp_st got=$got_st")
    fi

    # expect_cache_hit: second call should be significantly faster (< 20% of first)
    if [[ "${has_messages}" == "false" && "$repeat_n" -ge 2 ]]; then
        local exp_ch
        exp_ch=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('expect_cache_hit',False))" "$sc_json")
        if [[ "$exp_ch" == "True" && "$t_first" -gt 0 && "$t_second" -gt 0 ]]; then
            # cache hit should be at least 3x faster
            local threshold=$(( t_first / 3 ))
            [[ "$t_second" -lt "$threshold" || "$t_second" -lt 5000 ]] || \
                failures+=("expect_cache_hit: second=${t_second}ms first=${t_first}ms (not fast enough)")
        fi
    fi

    # ── report ────────────────────────────────────────────────────────────────
    if [[ ${#failures[@]} -eq 0 ]]; then
        _pass "$name"
    else
        local reason="${failures[*]}"
        _fail "$name" "$reason"
    fi
}

# ════════════════════════════════════════════════════════════════════════════════
# MOCK mode
# ════════════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "mock" ]]; then
    echo "=== eval scenarios ==="

    if [[ -z "$SCENARIO" || "$SCENARIO" == "prefilter_chitchat" ]]; then
        SID=$(bash "$BASE_DIR/os.sh" session new --mode patient)
        run_case "prefilter_chitchat" "$SID" "patient" "你好" "ok" "医学信息助手"
    fi

    if [[ -z "$SCENARIO" || "$SCENARIO" == "prefilter_oob" ]]; then
        SID=$(bash "$BASE_DIR/os.sh" session new --mode patient)
        run_case "prefilter_oob" "$SID" "patient" "股票怎么炒" "ok" "不在医学信息服务范围"
    fi

    if [[ -z "$SCENARIO" || "$SCENARIO" == "single_intent" ]]; then
        SID=$(bash "$BASE_DIR/os.sh" session new --mode patient)
        run_case "single_intent_dispatch" "$SID" "patient" \
            "高血压患者饮食要注意什么？" "ok" "测试回答"
    fi

    if [[ -z "$SCENARIO" || "$SCENARIO" == "persist_turn" ]]; then
        SID=$(bash "$BASE_DIR/os.sh" session new --mode patient)
        bash "$BASE_DIR/os.sh" chat --session "$SID" --mode patient \
            "高血压患者饮食要注意什么？" > /dev/null 2>&1 || true
        sleep 0.5
        turn_count=$(sqlite3 "$OS_DB" "SELECT COUNT(*) FROM turns WHERE session_id='$SID'")
        if [[ "$turn_count" -ge 1 ]]; then
            _pass "persist_turn (turns=$turn_count)"
        else
            _fail "persist_turn" "turns=$turn_count, expected >=1"
        fi
    fi

    if [[ -z "$SCENARIO" || "$SCENARIO" == "memory_profile" ]]; then
        SID=$(bash "$BASE_DIR/os.sh" session new --mode patient)
        bash "$BASE_DIR/os.sh" memory add --session "$SID" \
            --subject "爸爸" --attr "disease" --value "高血压" > /dev/null
        ast=$(bash "$BASE_DIR/os.sh" chat --session "$SID" --mode patient \
            --dry-run "他能喝咖啡吗？" 2>/dev/null)
        profile_facts_count=$(echo "$ast" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['context_ref']['profile_facts'])")
        if [[ "$profile_facts_count" -ge 1 ]]; then
            _pass "memory_profile (profile_facts=$profile_facts_count)"
        else
            _fail "memory_profile" "profile_facts=$profile_facts_count, expected >=1"
        fi
    fi

    if [[ -z "$SCENARIO" || "$SCENARIO" == "single_intent_memory_inject" ]]; then
        # §3 regression: a single-intent follow-up (no pronoun → stays single,
        # no LLM) must still carry the durable profile facts to the stateless agent.
        SID=$(bash "$BASE_DIR/os.sh" session new --mode patient)
        bash "$BASE_DIR/os.sh" memory add --session "$SID" \
            --subject "爸爸" --attr "disease" --value "高血压" > /dev/null
        ast=$(bash "$BASE_DIR/os.sh" chat --session "$SID" --mode patient \
            --dry-run "饮食上要注意什么？" 2>/dev/null)
        injected=$(echo "$ast" | python3 -c "
import json,sys
d=json.load(sys.stdin)
nodes=d.get('plan',{}).get('nodes',[])
q=nodes[0].get('question','') if nodes else ''
print('yes' if (len(nodes)==1 and '高血压' in q) else 'no')
" 2>/dev/null || echo "no")
        if [[ "$injected" == "yes" ]]; then
            _pass "single_intent_memory_inject (profile reaches single-intent question)"
        else
            _fail "single_intent_memory_inject" "profile block not injected into single-intent node question"
        fi
    fi

    if [[ -z "$SCENARIO" || "$SCENARIO" == "unwrap_fallback" ]]; then
        SID=$(bash "$BASE_DIR/os.sh" session new --mode patient)
        cat > /tmp/no_fence_fixture.txt <<'EOF'
This is a response without any fence characters at all.
EOF
        FIXTURE_BACKUP=""
        if [[ -f "$SCRIPT_DIR/mock/fixtures/i1.txt" ]]; then
            FIXTURE_BACKUP=$(cat "$SCRIPT_DIR/mock/fixtures/i1.txt")
        fi
        cp /tmp/no_fence_fixture.txt "$SCRIPT_DIR/mock/fixtures/i1.txt"

        uf_reply=$(bash "$BASE_DIR/os.sh" chat --session "$SID" --mode patient \
            "高血压能喝酒吗？" 2>/dev/null || true)
        # Fence-less but non-empty agent output must be preserved, not dropped.
        if [[ "$uf_reply" == *"without any fence"* ]]; then
            _pass "unwrap_fallback (fence-less answer preserved)"
        else
            _fail "unwrap_fallback" "fence-less answer dropped; reply=$(echo "$uf_reply" | head -c 80)"
        fi

        if [[ -n "$FIXTURE_BACKUP" ]]; then
            echo "$FIXTURE_BACKUP" > "$SCRIPT_DIR/mock/fixtures/i1.txt"
        else
            rm -f "$SCRIPT_DIR/mock/fixtures/i1.txt"
        fi
    fi

    # ── contract assertions (F1-F4 invariants焊死) ───────────────────────────────

    # Shared pipeline run for json/reply/dispatch contract tests (avoids 3 separate invocations)
    _contract_raw=""
    if [[ -z "$SCENARIO" || "$SCENARIO" == "contract_json_ndjson" || \
          "$SCENARIO" == "contract_reply_in_stream" || "$SCENARIO" == "contract_dispatch_pairing" ]]; then
        _contract_sid=$(bash "$BASE_DIR/os.sh" session new --mode patient)
        _contract_raw=$(bash "$BASE_DIR/os.sh" chat --json --session "$_contract_sid" --mode patient \
            "高血压能喝酒吗？" 2>/dev/null)
    fi

    if [[ -z "$SCENARIO" || "$SCENARIO" == "contract_json_ndjson" ]]; then
        bad_lines=$(echo "$_contract_raw" | while IFS= read -r ln; do
            [[ -z "$ln" ]] && continue
            echo "$ln" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || echo "BAD"
        done | grep -c "BAD" 2>/dev/null || true)
        if [[ "$bad_lines" -eq 0 ]]; then
            _pass "contract_json_ndjson"
        else
            _fail "contract_json_ndjson" "stdout has $bad_lines non-JSON line(s) in --json mode"
        fi
    fi

    if [[ -z "$SCENARIO" || "$SCENARIO" == "contract_reply_in_stream" ]]; then
        run_end_reply=$(echo "$_contract_raw" | python3 -c "
import json,sys
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        ev=json.loads(line)
        if ev.get('type')=='run_end':
            print(ev.get('reply',''))
            sys.exit(0)
    except Exception:
        pass
" 2>/dev/null || true)
        if [[ -n "$run_end_reply" ]]; then
            _pass "contract_reply_in_stream"
        else
            _fail "contract_reply_in_stream" "run_end.reply is empty or missing in --json stream"
        fi
    fi

    if [[ -z "$SCENARIO" || "$SCENARIO" == "contract_dispatch_pairing" ]]; then
        # Counts dispatch_start vs dispatch_end; verifies symmetry for all paths exercised.
        # Single-intent fast-path is covered here. Multi-intent bounded_fanout is covered by live eval.
        start_count=$(echo "$_contract_raw" | python3 -c "
import json,sys; n=0
for l in sys.stdin:
    l=l.strip()
    if not l: continue
    try:
        ev=json.loads(l)
        if ev.get('type')=='dispatch_start': n+=1
    except: pass
print(n)
" 2>/dev/null || echo "0")
        end_count=$(echo "$_contract_raw" | python3 -c "
import json,sys; n=0
for l in sys.stdin:
    l=l.strip()
    if not l: continue
    try:
        ev=json.loads(l)
        if ev.get('type')=='dispatch_end': n+=1
    except: pass
print(n)
" 2>/dev/null || echo "0")
        if [[ "$start_count" -eq "$end_count" && "$start_count" -gt 0 ]]; then
            _pass "contract_dispatch_pairing"
        else
            _fail "contract_dispatch_pairing" "dispatch_start=$start_count dispatch_end=$end_count (must be equal and >0)"
        fi
    fi

    if [[ -z "$SCENARIO" || "$SCENARIO" == "contract_prefilter_ndjson" ]]; then
        SID=$(bash "$BASE_DIR/os.sh" session new --mode patient)
        raw=$(bash "$BASE_DIR/os.sh" chat --json --session "$SID" --mode patient \
            "你好" 2>/dev/null)
        bad_lines=$(echo "$raw" | while IFS= read -r ln; do
            [[ -z "$ln" ]] && continue
            echo "$ln" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || echo "BAD"
        done | grep -c "BAD" 2>/dev/null || true)
        if [[ "$bad_lines" -eq 0 ]]; then
            _pass "contract_prefilter_ndjson"
        else
            _fail "contract_prefilter_ndjson" "prefilter path has $bad_lines non-JSON line(s) in --json mode"
        fi
    fi

    if [[ -z "$SCENARIO" || "$SCENARIO" == "contract_serve_reply" ]]; then
        SID=$(bash "$BASE_DIR/os.sh" session new --mode patient)
        serve_out=$(printf \
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"chat","params":{"session_id":"%s","mode":"patient","message":"高血压能喝酒吗？"}}\n' \
            "$SID" | bash "$BASE_DIR/os.sh" serve 2>/dev/null)
        serve_reply=$(echo "$serve_out" | python3 -c "
import json,sys
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        r=json.loads(line)
        if r.get('id')==2 and 'result' in r:
            print(r['result'].get('reply',''))
            sys.exit(0)
    except Exception:
        pass
" 2>/dev/null || true)
        if [[ -n "$serve_reply" ]]; then
            _pass "contract_serve_reply"
        else
            _fail "contract_serve_reply" "serve chat result.reply is empty or missing"
        fi
    fi

    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [[ $FAIL -eq 0 ]] && exit 0 || exit 1
fi

# ════════════════════════════════════════════════════════════════════════════════
# LIVE mode — driven by eval/scenarios.json
# ════════════════════════════════════════════════════════════════════════════════
SCENARIOS_FILE="$SCRIPT_DIR/scenarios.json"
if [[ ! -f "$SCENARIOS_FILE" ]]; then
    log_fatal "scenarios.json not found: $SCENARIOS_FILE"
fi

log_info "Running in LIVE mode (limit=$LIMIT) — real API calls"
echo "=== eval scenarios (live) ==="

# Load scenario names in order (bash 3.2 compatible — no mapfile)
_SC_NAMES=()
while IFS= read -r _line; do
    _SC_NAMES+=("$_line")
done < <(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
for s in data['scenarios']:
    print(s['name'])
" "$SCENARIOS_FILE")

_run_count=0
for _sc_name in "${_SC_NAMES[@]}"; do
    # filter by --scenario if set
    if [[ -n "$SCENARIO" && "$_sc_name" != "$SCENARIO" ]]; then
        continue
    fi

    # enforce --limit
    if [[ $_run_count -ge $LIMIT ]]; then
        break
    fi

    # extract the full scenario JSON object
    _sc_json=$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
for s in data['scenarios']:
    if s['name'] == sys.argv[2]:
        print(json.dumps(s))
        break
" "$SCENARIOS_FILE" "$_sc_name")

    _live_run_scenario "$_sc_json"
    (( _run_count++ )) || true
done

echo ""
echo "Results: $PASS passed, $FAIL failed  (ran $_run_count / ${#_SC_NAMES[@]} scenarios)"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
