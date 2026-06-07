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
