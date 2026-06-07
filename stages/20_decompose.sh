#!/usr/bin/env bash
# Stage 2: Decompose — message → intent AST.
# Applies gate heuristic first; falls back to LLM only when needed.
# Outputs: AST JSON to stdout.
# Input: message, context_json, mode, session_id, request_id

set -euo pipefail

STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$STAGE_DIR")"

source "$BASE_DIR/lib/common.sh"
source "$BASE_DIR/lib/llm.sh"
source "$BASE_DIR/lib/events.sh"

# ── multi-intent heuristics ───────────────────────────────────────────────────
# Returns "multi" if likely multiple intents, "single" otherwise.
_intent_gate() {
    local msg="$1"
    local has_profile="${2:-false}"  # true if profile_facts exist

    python3 - "$msg" "$has_profile" <<'PYEOF'
import sys, re

msg        = sys.argv[1]
has_profile = sys.argv[2] == "true"

CONJUNCTIONS = ["另外", "还有", "还想问", "以及", "同时", "此外", "顺便问",
                "另，", "另，", "？还", "?还"]
PRONOUNS = ["他", "她", "它", "他们", "她们"]

# multi-intent signals
for conj in CONJUNCTIONS:
    if conj in msg:
        print("multi")
        sys.exit(0)

# multiple question marks suggest multiple questions
if msg.count("？") >= 2 or msg.count("?") >= 2:
    print("multi")
    sys.exit(0)

# pronoun + has profile → need co-ref resolution → send to decompose
if has_profile and any(p in msg for p in PRONOUNS):
    print("multi")
    sys.exit(0)

print("single")
PYEOF
}

# ── build single-intent AST without LLM ──────────────────────────────────────
_single_intent_ast() {
    local request_id="$1"
    local session_id="$2"
    local mode="$3"
    local message="$4"
    local history_turns="${5:-0}"
    local profile_facts="${6:-0}"

    python3 - "$request_id" "$session_id" "$mode" "$message" \
              "$history_turns" "$profile_facts" <<'PYEOF'
import json, sys

request_id    = sys.argv[1]
session_id    = sys.argv[2]
mode          = sys.argv[3]
message       = sys.argv[4]
history_turns = int(sys.argv[5])
profile_facts = int(sys.argv[6])

ast = {
    "v": 1,
    "request_id": request_id,
    "session": session_id,
    "mode": mode,
    "raw": message,
    "context_ref": {"history_turns": history_turns, "profile_facts": profile_facts},
    "plan": {
        "op": "parallel",
        "nodes": [{
            "id": "i1",
            "kind": "medical_query",
            "agent": "inner_all",
            "mode": mode,
            "question": message,
            "domains": [],   # empty → adapter falls back to router
            "subject": "",
            "depends_on": [],
            "deep": False,
        }]
    }
}
print(json.dumps(ast, ensure_ascii=False))
PYEOF
}

# ── LLM-based decompose ───────────────────────────────────────────────────────
_llm_decompose() {
    local message="$1"
    local context_json="$2"
    local mode="$3"
    local request_id="$4"
    local session_id="$5"

    local prompt_file="$BASE_DIR/prompts/decompose_${mode}.md"
    if [[ ! -f "$prompt_file" ]]; then
        log_warn "decompose: prompt file not found: $prompt_file, using patient"
        prompt_file="$BASE_DIR/prompts/decompose_patient.md"
    fi
    local system_prompt
    system_prompt=$(cat "$prompt_file")

    local profile_block
    profile_block=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('profile_block',''))" "$context_json")

    local history_text
    local _hw="${OS_HISTORY_WINDOW:-6}"
    history_text=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
window=int(sys.argv[2])
turns=d.get('history',[])
lines=[]
for t in turns[-window:]:
    role='用户' if t['role']=='user' else '助手'
    lines.append(f'{role}: {t[\"content\"][:200]}')
print('\n'.join(lines))
" "$context_json" "$_hw")

    local user_content
    user_content="当前消息：${message}

历史对话（最近几轮）：
${history_text:-（无历史）}

${profile_block:-}"

    local raw_response
    if ! raw_response=$(llm_call "$system_prompt" "$user_content" "${OS_DECOMPOSE_TEMP:-0}"); then
        log_warn "decompose: LLM call failed, falling back to single-intent"
        return 1
    fi

    # Extract JSON from response (LLM might wrap in ```json ... ```)
    local ast_json
    ast_json=$(python3 - "$raw_response" "$request_id" "$session_id" "$mode" "$message" <<'PYEOF'
import json, re, sys

raw        = sys.argv[1]
request_id = sys.argv[2]
session_id = sys.argv[3]
mode       = sys.argv[4]
message    = sys.argv[5]

# strip markdown code fences if present
cleaned = re.sub(r"^```(?:json)?\s*", "", raw.strip(), flags=re.MULTILINE)
cleaned = re.sub(r"\s*```$", "", cleaned.strip(), flags=re.MULTILINE)
cleaned = cleaned.strip()

try:
    nodes = json.loads(cleaned)
    if isinstance(nodes, list):
        # LLM returned nodes array directly — wrap in AST envelope
        ast = {
            "v": 1,
            "request_id": request_id,
            "session": session_id,
            "mode": mode,
            "raw": message,
            "context_ref": {},
            "plan": {"op": "parallel", "nodes": nodes}
        }
        print(json.dumps(ast, ensure_ascii=False))
    elif isinstance(nodes, dict) and "plan" in nodes:
        # LLM returned full AST
        nodes.setdefault("v", 1)
        nodes["request_id"] = request_id
        nodes["session"] = session_id
        print(json.dumps(nodes, ensure_ascii=False))
    else:
        print("PARSE_ERROR")
except Exception as e:
    print("PARSE_ERROR")
PYEOF
)

    if [[ "$ast_json" == "PARSE_ERROR" ]]; then
        log_warn "decompose: could not parse LLM response as AST"
        return 1
    fi

    echo "$ast_json"
    return 0
}

# ── main: decompose(message, context_json, mode, request_id, session_id) ──────
decompose() {
    local message="$1"
    local context_json="$2"
    local mode="$3"
    local request_id="$4"
    local session_id="$5"

    local history_turns profile_count
    history_turns=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d.get('history',[])))" "$context_json")
    profile_count=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d.get('profile_facts',[])))" "$context_json")
    local has_profile
    has_profile=$([[ $profile_count -gt 0 ]] && echo "true" || echo "false")

    local gate_result
    gate_result=$(_intent_gate "$message" "$has_profile")

    if [[ "$gate_result" == "single" ]]; then
        log_debug "decompose: gate=single, skipping LLM"
        _single_intent_ast "$request_id" "$session_id" "$mode" "$message" \
                            "$history_turns" "$profile_count"
        return 0
    fi

    log_debug "decompose: gate=multi, calling LLM"
    local ast_json
    if ast_json=$(_llm_decompose "$message" "$context_json" "$mode" "$request_id" "$session_id"); then
        # Inject correct context_ref (LLM-produced envelope may have empty {})
        ast_json=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
d['context_ref']=dict(history_turns=int(sys.argv[2]),profile_facts=int(sys.argv[3]))
print(json.dumps(d,ensure_ascii=False))
" "$ast_json" "$history_turns" "$profile_count")
        emit_event "decompose" "{\"ast\":$(echo "$ast_json" | python3 -c "import sys,json; print(json.dumps(json.loads(sys.stdin.read())))")}"
        echo "$ast_json"
    else
        log_warn "decompose: LLM failed, falling back to single-intent"
        _single_intent_ast "$request_id" "$session_id" "$mode" "$message" \
                            "$history_turns" "$profile_count"
    fi
}
