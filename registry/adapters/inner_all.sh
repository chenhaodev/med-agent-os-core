#!/usr/bin/env bash
# Adapter: med-agent-inner-all
# Contract: called by lib/dispatch.sh with env vars set; writes result JSON to RUNDIR.
#
# Required env:
#   INTENT_ID, INTENT_MODE, INTENT_DOMAINS, INTENT_QUESTION
#   RUNDIR, INNER_ALL_DIR
# Optional: OS_CACHE_ENABLED, OS_NO_CACHE, OS_KNOWLEDGE_VERSION, OS_DB

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_DIR="$(dirname "$SCRIPT_DIR")"
BASE_DIR="$(dirname "$REGISTRY_DIR")"

source "$BASE_DIR/lib/common.sh"
source "$BASE_DIR/lib/unwrap.sh"

DOMAINS_FILE="$REGISTRY_DIR/inner_all_domains.txt"
ASK_SH="$INNER_ALL_DIR/bin/ask.sh"

result_file="$RUNDIR/intent_${INTENT_ID}.result.json"
stderr_file="$RUNDIR/intent_${INTENT_ID}.stderr"

# ── helpers ───────────────────────────────────────────────────────────────────
_write_result() {
    python3 - "$INTENT_ID" "$1" "$2" "$3" "$4" "$5" > "$result_file" <<'PYEOF'
import json, sys
print(json.dumps({
    "id":        sys.argv[1],
    "status":    sys.argv[2],
    "answer":    sys.argv[3] if sys.argv[2] in ("ok","oob") else None,
    "citations": [],
    "ms":        int(sys.argv[4]),
    "exit_code": int(sys.argv[5]),
    "domains":   sys.argv[6],
}, ensure_ascii=False))
PYEOF
}

_cache_lookup() {
    python3 - "$1" "$2" "$3" <<'PYEOF'
import sqlite3, sys
db, key, kv = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    conn = sqlite3.connect(db, timeout=5)
    row = conn.execute(
        "SELECT answer FROM response_cache WHERE cache_key=? AND knowledge_version=?",
        (key, kv)).fetchone()
    conn.close()
    print(row[0] if row and row[0] else "MISS")
except Exception:
    print("MISS")
PYEOF
}

_cache_hit_update() {
    python3 - "$1" "$2" <<'PYEOF'
import sqlite3, sys
from datetime import datetime, timezone
db, key = sys.argv[1], sys.argv[2]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]+"Z"
try:
    conn = sqlite3.connect(db, timeout=5)
    conn.execute("UPDATE response_cache SET hit_count=hit_count+1, last_hit_at=? WHERE cache_key=?", (now,key))
    conn.commit(); conn.close()
except Exception:
    pass
PYEOF
}

_cache_write() {
    python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" <<'PYEOF'
import sqlite3, sys, json
from datetime import datetime, timezone
db,key,agent,mode,domains,question,answer,model,kv = sys.argv[1:]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]+"Z"
kv = int(kv)
try:
    conn = sqlite3.connect(db, timeout=5)
    conn.execute("""
        INSERT OR IGNORE INTO response_cache
            (cache_key,agent_id,mode,domains,question,answer,citations,
             model,knowledge_version,hit_count,created_at,last_hit_at)
        VALUES (?,?,?,?,?,?,?,?,?,0,?,?)
    """, (key,agent,mode,domains,question,answer,"[]",model,kv,now,now))
    conn.commit(); conn.close()
except Exception:
    pass
PYEOF
}

# ── validate ask.sh ───────────────────────────────────────────────────────────
if [[ ! -x "$ASK_SH" ]]; then
    log_error "inner_all adapter: ask.sh not found: $ASK_SH"
    _write_result "error" "" "0" "-1" ""
    exit 0
fi

# ── validate and filter domains ───────────────────────────────────────────────
valid_domains=""
if [[ -n "${INTENT_DOMAINS:-}" ]]; then
    valid_tags=$(grep -v '^#' "$DOMAINS_FILE" | grep -v '^$')
    for tag in $INTENT_DOMAINS; do
        if echo "$valid_tags" | grep -qx "$tag"; then
            valid_domains="${valid_domains:+$valid_domains }$tag"
        else
            log_warn "inner_all: unknown domain tag '$tag', dropping"
        fi
    done
fi

# ── cache lookup ──────────────────────────────────────────────────────────────
use_cache="${OS_CACHE_ENABLED:-true}"
no_cache="${OS_NO_CACHE:-false}"
model="${DEEPSEEK_MODEL:-deepseek-v4-flash}"
kv="${OS_KNOWLEDGE_VERSION:-1}"
cache_key=""

if [[ "$use_cache" == "true" && "$no_cache" != "true" && -f "${OS_DB:-}" ]]; then
    cache_key=$(sha256_args "$INTENT_QUESTION" "$INTENT_MODE" "$valid_domains" "$model")
    cached=$(_cache_lookup "$OS_DB" "$cache_key" "$kv")
    if [[ "$cached" != "MISS" && -n "$cached" ]]; then
        log_debug "inner_all[$INTENT_ID] cache HIT"
        _cache_hit_update "$OS_DB" "$cache_key" &
        _write_result "ok" "$cached" "0" "0" "$valid_domains"
        exit 0
    fi
fi

# ── call ask.sh ───────────────────────────────────────────────────────────────
ask_args=("--mode" "$INTENT_MODE")
[[ -n "$valid_domains" ]] && ask_args+=("--domain" "$valid_domains")

t_start=$(now_ms)
raw_stdout=""
ec=0

set +e
raw_stdout=$(timeout "$OS_AGENT_TIMEOUT" \
    "$ASK_SH" "${ask_args[@]}" "$INTENT_QUESTION" 2>"$stderr_file")
ec=$?
set -e

elapsed=$(( $(now_ms) - t_start ))

# ── determine status ──────────────────────────────────────────────────────────
if [[ $ec -eq 124 ]]; then
    status="timeout"; answer=""
elif [[ $ec -ne 0 ]]; then
    status="error"; answer=""
else
    unwrap_out=$(unwrap "$raw_stdout")
    unwrap_status=$(echo "$unwrap_out" | head -1)
    answer=$(echo "$unwrap_out" | tail -n +2)
    case "$unwrap_status" in
        ok)    status="ok" ;;
        oob)   status="oob" ;;
        *)     status="error" ;;
    esac
fi

_write_result "$status" "$answer" "$elapsed" "$ec" "$valid_domains"

# ── cache write (async, ok only) ──────────────────────────────────────────────
if [[ "$status" == "ok" && "$use_cache" == "true" && "$no_cache" != "true" \
      && -f "${OS_DB:-}" && -n "$cache_key" ]]; then
    _cache_write "$OS_DB" "$cache_key" \
        "inner_all" "$INTENT_MODE" "$valid_domains" \
        "$INTENT_QUESTION" "$answer" "$model" "$kv" &
fi

log_debug "inner_all[$INTENT_ID] status=$status ms=$elapsed domains='$valid_domains'"
exit 0
