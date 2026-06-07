#!/usr/bin/env bash
# Shared bootstrap: paths, .env loading, logging, utilities.
# Source this file; do not execute directly.

# ── locate project root ───────────────────────────────────────────────────────
_OS_SCRIPT="${BASH_SOURCE[0]}"
BASE_DIR="$(cd "$(dirname "$_OS_SCRIPT")/.." && pwd)"

# ── load .env (skip if already loaded) ───────────────────────────────────────
if [[ -z "${_OS_ENV_LOADED:-}" ]]; then
    if [[ -f "$BASE_DIR/.env" ]]; then
        # shellcheck disable=SC1090
        set -o allexport
        source "$BASE_DIR/.env"
        set +o allexport
    fi
    export _OS_ENV_LOADED=1
fi

# ── derived paths ─────────────────────────────────────────────────────────────
export OS_DB="${OS_DB:-$BASE_DIR/var/os.db}"
export OS_RUNS_DIR="$BASE_DIR/var/runs"
export OS_LOGS_DIR="$BASE_DIR/var/logs"
export OS_REGISTRY="$BASE_DIR/registry"

# ── resolved inner-all path ───────────────────────────────────────────────────
_raw_inner="${INNER_ALL_DIR:-../med-agent-inner-all}"
if [[ "$_raw_inner" = /* ]]; then
    export INNER_ALL_DIR="$_raw_inner"
else
    export INNER_ALL_DIR="$(cd "$BASE_DIR/$_raw_inner" 2>/dev/null && pwd || echo "$BASE_DIR/$_raw_inner")"
fi

# ── tuning defaults ───────────────────────────────────────────────────────────
export OS_MAX_WORKERS="${OS_MAX_WORKERS:-3}"
export OS_AGENT_TIMEOUT="${OS_AGENT_TIMEOUT:-90}"
export OS_HISTORY_WINDOW="${OS_HISTORY_WINDOW:-6}"
export OS_DECOMPOSE_TEMP="${OS_DECOMPOSE_TEMP:-0}"
export OS_CACHE_ENABLED="${OS_CACHE_ENABLED:-true}"
export OS_KNOWLEDGE_VERSION="${OS_KNOWLEDGE_VERSION:-1}"
export DEEPSEEK_MODEL="${DEEPSEEK_MODEL:-deepseek-v4-flash}"

# ── logging ───────────────────────────────────────────────────────────────────
# All diagnostic output goes to stderr; never pollute stdout.
_OS_VERBOSE="${OS_VERBOSE:-false}"

log_info()  { echo "[INFO]  $*" >&2; }
log_debug() { [[ "$_OS_VERBOSE" == "true" ]] && echo "[DEBUG] $*" >&2 || true; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }
log_fatal() { echo "[FATAL] $*" >&2; exit 1; }

# ── uuid ──────────────────────────────────────────────────────────────────────
gen_uuid() {
    python3 -c "import uuid; print(str(uuid.uuid4()))"
}

# ── iso timestamp ─────────────────────────────────────────────────────────────
now_iso() {
    python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3]+'Z')"
}

# ── epoch milliseconds ────────────────────────────────────────────────────────
now_ms() {
    python3 -c "import time; print(int(time.time()*1000))"
}

# ── json string escape ────────────────────────────────────────────────────────
# Usage: json_escape "some \"string\"" → properly escaped JSON string value (no outer quotes)
json_escape() {
    python3 -c "import json,sys; print(json.dumps(sys.stdin.read())[1:-1])" <<< "$1"
}

# ── sha256 of concatenated args ───────────────────────────────────────────────
sha256_args() {
    python3 -c "import hashlib,sys; print(hashlib.sha256(''.join(sys.argv[1:]).encode()).hexdigest())" -- "$@"
}
