#!/usr/bin/env bash
# Stage 4: Synthesize — merge sub-answers into one reply; extract profile_delta.
# Single-intent fast-path: skip LLM synthesis (return sub-answer directly).
# Outputs: JSON {reply, profile_delta, status} to stdout.

set -euo pipefail

STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$STAGE_DIR")"

source "$BASE_DIR/lib/common.sh"
source "$BASE_DIR/lib/llm.sh"
source "$BASE_DIR/lib/events.sh"

# ── fast-path: single ok/oob result — no LLM ────────────────────────────────
_fast_reply() {
    local results_json="$1"

    python3 - "$results_json" <<'PYEOF'
import json, sys
results = json.loads(sys.argv[1])
r = results[0]
status = "ok" if r["status"] == "ok" else ("partial" if r["status"] == "oob" else "error")
print(json.dumps({
    "reply": r.get("answer") or "",
    "profile_delta": [],
    "status": status,
    "fast_path": True,
}, ensure_ascii=False))
PYEOF
}

# ── LLM synthesis ────────────────────────────────────────────────────────────
_llm_synthesize() {
    local results_json="$1"
    local context_json="$2"
    local mode="$3"
    local original_message="$4"

    local prompt_file="$BASE_DIR/prompts/synthesize_${mode}.md"
    if [[ ! -f "$prompt_file" ]]; then
        log_warn "synthesize: prompt file not found: $prompt_file, using patient"
        prompt_file="$BASE_DIR/prompts/synthesize_patient.md"
    fi
    local system_prompt
    system_prompt=$(cat "$prompt_file")

    local profile_block
    profile_block=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('profile_block',''))" "$context_json")

    local sub_answers_text
    sub_answers_text=$(python3 - "$results_json" <<'PYEOF'
import json, sys
results = json.loads(sys.argv[1])
parts = []
for r in results:
    ans = r.get("answer") or ""
    status = r["status"]
    if status == "ok" and ans:
        parts.append(f"[子答案 {r['id']}]\n{ans}")
    elif status == "oob":
        parts.append(f"[子答案 {r['id']}]\n（该问题超出医学信息系统覆盖范围，建议咨询专科医生。）")
    else:
        parts.append(f"[子答案 {r['id']}]\n（该子问题查询失败，请稍后重试。）")
print("\n\n".join(parts))
PYEOF
)

    local user_content
    user_content="用户原始问题：${original_message}

${profile_block:-}

各专科子答案：
${sub_answers_text}"

    emit_event "synthesize_start" ""

    local raw_response
    if [[ "${OS_STREAM:-false}" == "true" ]]; then
        if ! raw_response=$(llm_call_stream "$system_prompt" "$user_content" "${OS_SYNTHESIZE_TEMP:-0.3}"); then
            log_error "synthesize: streaming LLM call failed"
            return 1
        fi
    elif ! raw_response=$(llm_call "$system_prompt" "$user_content" "${OS_SYNTHESIZE_TEMP:-0.3}"); then
        log_error "synthesize: LLM call failed"
        return 1
    fi

    # Parse response — expect JSON {reply, profile_delta}
    python3 - "$raw_response" <<'PYEOF'
import json, re, sys

raw = sys.argv[1]

cleaned = re.sub(r"^```(?:json)?\s*", "", raw.strip(), flags=re.MULTILINE)
cleaned = re.sub(r"\s*```$", "", cleaned.strip(), flags=re.MULTILINE)
cleaned = cleaned.strip()

try:
    d = json.loads(cleaned)
    result = {
        "reply": d.get("reply", ""),
        "profile_delta": d.get("profile_delta", []),
        "status": "ok",
        "fast_path": False,
    }
    print(json.dumps(result, ensure_ascii=False))
except Exception:
    # fallback: return raw text as reply
    print(json.dumps({
        "reply": raw,
        "profile_delta": [],
        "status": "ok",
        "fast_path": False,
    }, ensure_ascii=False))
PYEOF
}

# ── synthesize(ast_json, results_json, context_json, mode, message) ───────────
synthesize() {
    local ast_json="$1"
    local results_json="$2"
    local context_json="$3"
    local mode="$4"
    local message="$5"

    local node_count
    node_count=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d['plan']['nodes']))" "$ast_json")

    # Determine overall dispatch status
    local any_ok any_error any_oob
    any_ok=$(python3 -c "import json,sys; r=json.loads(sys.argv[1]); print('true' if any(x['status']=='ok' for x in r) else 'false')" "$results_json")
    any_error=$(python3 -c "import json,sys; r=json.loads(sys.argv[1]); print('true' if any(x['status'] in ('error','timeout') for x in r) else 'false')" "$results_json")
    any_oob=$(python3 -c "import json,sys; r=json.loads(sys.argv[1]); print('true' if any(x['status']=='oob' for x in r) else 'false')" "$results_json")

    if [[ $node_count -eq 1 ]]; then
        # Fast-path: return sub-answer directly
        _fast_reply "$results_json"
        return 0
    fi

    # Multi-intent: LLM merge
    local synth_json
    if synth_json=$(_llm_synthesize "$results_json" "$context_json" "$mode" "$message"); then
        # Adjust status if any dispatch was partial (error, timeout, or oob)
        if [[ "$any_error" == "true" || "$any_oob" == "true" ]]; then
            synth_json=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
d['status']='partial'
print(json.dumps(d,ensure_ascii=False))
" "$synth_json")
        fi
        echo "$synth_json"
    else
        # Fallback: concatenate sub-answers
        python3 - "$results_json" <<'PYEOF'
import json, sys
results = json.loads(sys.argv[1])
parts = [r.get("answer","") for r in results if r.get("answer")]
print(json.dumps({
    "reply": "\n\n".join(parts) if parts else "（查询部分失败，请重试。）",
    "profile_delta": [],
    "status": "partial",
    "fast_path": False,
}, ensure_ascii=False))
PYEOF
    fi
}
