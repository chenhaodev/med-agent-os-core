#!/usr/bin/env bash
# OS-owned DeepSeek API caller — independent of inner-all's call_deepseek.sh.
# Used for decompose and synthesize LLM calls only.
# Source this file; do not execute directly.

# ── llm_call(system_prompt, user_content, [temperature]) ─────────────────────
# Outputs raw response text to stdout; errors to stderr.
# Returns 0 on success, 1 on failure.
llm_call() {
    local system_prompt="$1"
    local user_content="$2"
    local temperature="${3:-0}"

    if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then
        log_error "llm_call: DEEPSEEK_API_KEY is not set"
        return 1
    fi

    local model="${DEEPSEEK_MODEL:-deepseek-v4-flash}"
    local payload
    payload=$(python3 - "$system_prompt" "$user_content" "$temperature" "$model" <<'PYEOF'
import json, sys
system = sys.argv[1]
user   = sys.argv[2]
temp   = float(sys.argv[3])
model  = sys.argv[4]
print(json.dumps({
    "model": model,
    "temperature": temp,
    "messages": [
        {"role": "system", "content": system},
        {"role": "user",   "content": user},
    ]
}, ensure_ascii=False))
PYEOF
)

    local max_retries="${DEEPSEEK_MAX_RETRIES:-3}"
    local timeout="${DEEPSEEK_TIMEOUT:-60}"
    local attempt=0
    local response http_code

    while [[ $attempt -lt $max_retries ]]; do
        response=$(curl -s -w "\n__HTTP_CODE__:%{http_code}" \
            --max-time "$timeout" \
            -X POST "https://api.deepseek.com/chat/completions" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
            -d "$payload" 2>/dev/null)

        http_code=$(echo "$response" | tail -1 | sed 's/__HTTP_CODE__://')
        local body
        body=$(echo "$response" | sed '$d')

        if [[ "$http_code" == "200" ]]; then
            python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['choices'][0]['message']['content'])" "$body"
            return 0
        elif [[ "$http_code" =~ ^(429|500|502|503)$ ]]; then
            local wait=$(( (attempt + 1) * 2 ))
            log_warn "llm_call: HTTP $http_code, retrying in ${wait}s (attempt $((attempt+1))/$max_retries)"
            sleep "$wait"
        else
            log_error "llm_call: HTTP $http_code, body: $(echo "$body" | head -c 200)"
            return 1
        fi
        (( attempt++ )) || true
    done

    log_error "llm_call: all $max_retries attempts failed"
    return 1
}

# ── llm_call_stream(system_prompt, user_content, [temperature]) ──────────────
# Streams SSE from DeepSeek; emits `token` events for each delta chunk.
# In CLI (non-JSON) mode, writes deltas directly to /dev/tty so the terminal
# shows incremental output even when the caller captures stdout.
# Returns the full accumulated text on stdout (same contract as llm_call).
# Gate: only called when OS_STREAM=true; callers fall back to llm_call otherwise.
llm_call_stream() {
    local system_prompt="$1"
    local user_content="$2"
    local temperature="${3:-0}"

    if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then
        log_error "llm_call_stream: DEEPSEEK_API_KEY is not set"
        return 1
    fi

    local model="${DEEPSEEK_MODEL:-deepseek-v4-flash}"
    local payload
    payload=$(python3 - "$system_prompt" "$user_content" "$temperature" "$model" <<'PYEOF'
import json, sys
system = sys.argv[1]
user   = sys.argv[2]
temp   = float(sys.argv[3])
model  = sys.argv[4]
print(json.dumps({
    "model": model,
    "temperature": temp,
    "stream": True,
    "messages": [
        {"role": "system", "content": system},
        {"role": "user",   "content": user},
    ]
}, ensure_ascii=False))
PYEOF
)

    local timeout="${DEEPSEEK_TIMEOUT:-60}"
    local full_text=""

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == ":"* ]] && continue
        [[ "$line" != "data: "* ]] && continue
        local data="${line#data: }"
        [[ "$data" == "[DONE]" ]] && break

        local delta
        # Pass JSON via stdin to avoid argv quoting issues with special chars.
        # Use `or ''` to coerce JSON null → empty string (DeepSeek sends null
        # for role-only chunks at stream start).
        delta=$(echo "$data" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    c=d['choices'][0]['delta'].get('content') or ''
    print(c,end='')
except Exception:
    pass
" 2>/dev/null)

        if [[ -n "$delta" ]]; then
            full_text="${full_text}${delta}"
            local delta_json
            delta_json=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$delta")
            emit_event "token" "\"delta\":$delta_json"
            # In plain-CLI mode, write delta directly to terminal (bypasses subshell capture)
            if [[ "${_JSON_MODE:-false}" == "false" ]]; then
                printf '%s' "$delta" > /dev/tty 2>/dev/null || true
            fi
        fi
    done < <(curl -sN --max-time "$timeout" \
        -X POST "https://api.deepseek.com/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        -d "$payload" 2>/dev/null)

    echo "$full_text"
}
