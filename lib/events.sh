#!/usr/bin/env bash
# Structured event stream — emit_event writes one NDJSON line to stdout.
# All other output (diagnostics) must go to stderr.
# Source this file; do not execute directly.

# ── event types (contract with ui-core / LSP daemon) ─────────────────────────
# prefilter       — {type, result: pass|oob|chitchat, reply?}
# decompose       — {type, ast: <AST JSON>}
# dispatch_start  — {type, intent_id, agent_id, domains}
# dispatch_end    — {type, intent_id, agent_id, status: ok|oob|error|timeout, ms}
# synthesize_start— {type}
# token           — {type, delta} (reserved for streaming; MVP emits whole reply)
# profile_delta   — {type, facts: [{subject,attr,value,confidence,op:add|retract}]}
# run_end         — {type, status: ok|partial|error, total_ms}

# _OS_JSON_EVENTS is set by os.sh when --json is passed
_OS_JSON_EVENTS="${_OS_JSON_EVENTS:-false}"

# ── emit_event(type, data_json) ───────────────────────────────────────────────
# data_json: a valid JSON object string, WITHOUT outer {} (will be merged)
# Outputs: {"ts":"...","type":"...","session":"...",...data fields...}
emit_event() {
    local type="$1"
    local data="${2:-}"
    [[ "$_OS_JSON_EVENTS" != "true" ]] && return 0

    local ts
    ts=$(now_iso)
    local sess="${OS_SESSION_ID:-}"
    local req="${OS_REQUEST_ID:-}"

    # Build envelope; merge data fields by stripping outer {} from data
    if [[ -n "$data" ]]; then
        local inner="${data#\{}"
        inner="${inner%\}}"
        printf '{"ts":"%s","type":"%s","session":"%s","request_id":"%s",%s}\n' \
            "$ts" "$type" "$sess" "$req" "$inner"
    else
        printf '{"ts":"%s","type":"%s","session":"%s","request_id":"%s"}\n' \
            "$ts" "$type" "$sess" "$req"
    fi
}
