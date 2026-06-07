#!/usr/bin/env bash
# med-agent-os-core — agent OS kernel entry point.
# Usage: os.sh <resource> <verb> [args]  |  os.sh chat ...  |  os.sh plan ...
set -eo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="0.1.0"

source "$BASE_DIR/lib/common.sh"
source "$BASE_DIR/lib/events.sh"
source "$BASE_DIR/lib/prefilter.sh"

# ── global flags ──────────────────────────────────────────────────────────────
_JSON_MODE=false
_QUIET=false
_VERBOSE=false
_DB_OVERRIDE=""

_usage() {
    cat >&2 <<'USAGE'
med-agent-os-core v0.1.0

Usage:
  os.sh chat   --session ID [--mode patient|doctor] [--json] [--no-cache] [--dry-run] "message"
  os.sh plan   --session ID [--mode M] "message"          # decompose only, no dispatch
  os.sh session new|list|show|set|rm|clear|export|purge ...
  os.sh history show|rm|replay ...
  os.sh memory  list|show|add|set|retract|rm|clear|export ...
  os.sh agent   list|show|test|validate|set|reload ...
  os.sh cache   stats|list|show|rm|clear|invalidate ...
  os.sh config  list|get|set|path
  os.sh db      init|migrate|status|vacuum|backup|reset
  os.sh eval    run|list|show ...
  os.sh version
  os.sh help [COMMAND]

Global flags:
  --db PATH      Use alternate database path
  --json         Emit NDJSON event stream to stdout
  -q, --quiet    Suppress info output
  --verbose      Enable debug logging
  -h, --help     Show help
  --version      Show version

Exit codes: 0=ok  2=usage  3=partial  4=agent_error  5=db_error
USAGE
    exit 2
}

# ── parse global flags (before subcommand) ────────────────────────────────────
_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --db)       _DB_OVERRIDE="$2"; shift 2 ;;
        --json)     _JSON_MODE=true;   shift ;;
        -q|--quiet) _QUIET=true;       shift ;;
        --verbose)  _VERBOSE=true; export OS_VERBOSE=true; shift ;;
        -h|--help)  _usage ;;
        --version)  echo "med-agent-os-core $VERSION"; exit 0 ;;
        *)          _args+=("$1");     shift ;;
    esac
done

[[ ${#_args[@]} -eq 0 ]] && _usage
export _OS_JSON_EVENTS="$_JSON_MODE"
[[ -n "$_DB_OVERRIDE" ]] && export OS_DB="$_DB_OVERRIDE"

resource="${_args[0]}"
verb="${_args[1]:-}"
rest=("${_args[@]:2}")

# ── version / help shortcuts ──────────────────────────────────────────────────
[[ "$resource" == "version" ]] && { echo "med-agent-os-core $VERSION"; exit 0; }
[[ "$resource" == "help"    ]] && _usage

# ════════════════════════════════════════════════════════════════════════════════
# CHAT — five-stage pipeline
# ════════════════════════════════════════════════════════════════════════════════
_cmd_chat() {
    source "$BASE_DIR/stages/10_context.sh"
    source "$BASE_DIR/stages/20_decompose.sh"
    source "$BASE_DIR/stages/30_dispatch.sh"
    source "$BASE_DIR/stages/40_synthesize.sh"
    source "$BASE_DIR/stages/50_persist.sh"

    local session_id="" mode="patient" no_cache=false dry_run=false
    local message=""
    local args=("$@")

    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --session) (( i++ )) || true; session_id="${args[$i]}" ;;
            --mode)    (( i++ )) || true; mode="${args[$i]}" ;;
            --no-cache) no_cache=true ;;
            --dry-run)  dry_run=true ;;
            *)
                if [[ -z "$message" ]]; then
                    message="${args[$i]}"
                fi
                ;;
        esac
        (( i++ )) || true
    done

    # read from stdin if message is empty
    if [[ -z "$message" ]]; then
        message=$(cat)
    fi

    [[ -z "$message" ]]    && { log_error "chat: message is required"; exit 2; }
    [[ -z "$session_id" ]] && { log_error "chat: --session is required"; exit 2; }

    # ensure DB exists
    if [[ ! -f "$OS_DB" ]]; then
        log_info "Initializing database at $OS_DB"
        bash "$BASE_DIR/db/migrate.sh"
    fi

    # ensure session exists
    python3 - "$OS_DB" "$session_id" "$mode" <<'PYEOF'
import sqlite3, sys, uuid
from datetime import datetime, timezone
db_path    = sys.argv[1]
session_id = sys.argv[2]
mode       = sys.argv[3]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]+"Z"
conn = sqlite3.connect(db_path, timeout=10)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("PRAGMA foreign_keys=ON")
conn.execute("""
    INSERT OR IGNORE INTO sessions (session_id, title, default_mode, created_at, updated_at)
    VALUES (?,?,?,?,?)
""", (session_id, session_id[:20], mode, now, now))
conn.commit(); conn.close()
PYEOF

    export OS_SESSION_ID="$session_id"
    export OS_REQUEST_ID="r-$(gen_uuid)"
    export OS_NO_CACHE="$no_cache"

    local t_start; t_start=$(now_ms)

    # ── turn index + id (atomic reserve — no race between concurrent turns) ────
    local _reserve turn_index turn_id
    _reserve=$(reserve_turn "$session_id" "$mode")
    turn_index=$(echo "$_reserve" | cut -f1)
    turn_id=$(echo "$_reserve" | cut -f2)

    # ── stage 0: prefilter ─────────────────────────────────────────────────────
    local pf_result
    pf_result=$(prefilter_message "$message")
    emit_event "prefilter" "\"result\":\"$pf_result\""

    if [[ "$pf_result" != "pass" ]]; then
        local pf_reply
        pf_reply=$(prefilter_reply "$pf_result" "$mode")
        if [[ "$_JSON_MODE" == "true" ]]; then
            emit_event "run_end" "\"status\":\"ok\",\"total_ms\":$(($(now_ms)-t_start))"
        fi

        if [[ "$dry_run" == "false" ]]; then
            # persist prefilter turn async; errors go to persist.err (not /dev/null)
            (
                OS_SESSION_ID="$session_id"
                persist_turn "$turn_id" "$turn_index" "$message" "$pf_result" \
                             "" "[]" "{\"reply\":\"$pf_reply\",\"profile_delta\":[],\"status\":\"ok\"}" \
                             "$(($(now_ms)-t_start))" "$mode"
            ) 2>>"$OS_LOGS_DIR/persist.err" &
        fi

        echo "$pf_reply"
        exit 0
    fi

    # ── stage 1: context ───────────────────────────────────────────────────────
    local context_json
    context_json=$(build_context "$session_id" "$mode")

    # ── stage 2: decompose ─────────────────────────────────────────────────────
    local ast_json
    ast_json=$(decompose "$message" "$context_json" "$mode" "$OS_REQUEST_ID" "$session_id")
    log_debug "AST: $ast_json"

    if [[ "$dry_run" == "true" ]]; then
        echo "$ast_json"
        exit 0
    fi

    # ── stage 3: dispatch ──────────────────────────────────────────────────────
    local run_id="run-$(gen_uuid)"
    local rundir="$OS_RUNS_DIR/$run_id"
    mkdir -p "$rundir"

    local results_json
    results_json=$(dispatch_all "$ast_json" "$rundir")

    # ── stage 4: synthesize ────────────────────────────────────────────────────
    local synth_json is_fast_path
    synth_json=$(synthesize "$ast_json" "$results_json" "$context_json" "$mode" "$message")
    is_fast_path=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('fast_path',False))" "$synth_json")

    local total_ms=$(( $(now_ms) - t_start ))
    local reply status
    reply=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('reply',''))" "$synth_json")
    status=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('status','ok'))" "$synth_json")

    # ── emit profile_delta event ───────────────────────────────────────────────
    local profile_delta_json
    profile_delta_json=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(json.dumps(d.get('profile_delta',[])))" "$synth_json")
    if [[ "$profile_delta_json" != "[]" ]]; then
        emit_event "profile_delta" "\"facts\":$profile_delta_json"
    fi

    emit_event "run_end" "\"status\":\"$status\",\"total_ms\":$total_ms"

    # ── output reply ───────────────────────────────────────────────────────────
    if [[ "$_JSON_MODE" == "false" ]]; then
        echo "$reply"
    fi

    # ── stage 5: persist + async profile extraction ────────────────────────────
    (
        persist_turn "$turn_id" "$turn_index" "$message" "pass" \
                     "$ast_json" "$results_json" "$synth_json" "$total_ms" "$mode"
    ) 2>>"$OS_LOGS_DIR/persist.err" &

    # fast-path: synthesize didn't extract profile_delta (skipped LLM merge),
    # so extract profile facts from the reply in background
    if [[ "$is_fast_path" == "True" && "$status" == "ok" ]]; then
        source "$BASE_DIR/lib/profile.sh"
        extract_profile_async "$message" "$reply" "$session_id" "$turn_id" &
    fi

    # set exit code based on status
    case "$status" in
        ok)      exit 0 ;;
        partial) exit 3 ;;
        error)   exit 4 ;;
        *)       exit 0 ;;
    esac
}

# ════════════════════════════════════════════════════════════════════════════════
# PLAN — decompose only (no dispatch)
# ════════════════════════════════════════════════════════════════════════════════
_cmd_plan() {
    source "$BASE_DIR/stages/10_context.sh"
    source "$BASE_DIR/stages/20_decompose.sh"

    local session_id="" mode="patient" message=""
    local args=("$@")
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --session) (( i++ )) || true; session_id="${args[$i]}" ;;
            --mode)    (( i++ )) || true; mode="${args[$i]}" ;;
            *)         [[ -z "$message" ]] && message="${args[$i]}" ;;
        esac
        (( i++ )) || true
    done
    [[ -z "$message" ]] && message=$(cat)
    [[ -z "$message" ]]    && { log_error "plan: message is required"; exit 2; }
    [[ -z "$session_id" ]] && { log_error "plan: --session is required"; exit 2; }

    export OS_SESSION_ID="$session_id"
    export OS_REQUEST_ID="r-$(gen_uuid)"

    [[ ! -f "$OS_DB" ]] && bash "$BASE_DIR/db/migrate.sh"

    local context_json
    context_json=$(build_context "$session_id" "$mode")
    local ast_json
    ast_json=$(decompose "$message" "$context_json" "$mode" "$OS_REQUEST_ID" "$session_id")
    echo "$ast_json" | python3 -c "import json,sys; print(json.dumps(json.loads(sys.stdin.read()),indent=2,ensure_ascii=False))"
}

# ════════════════════════════════════════════════════════════════════════════════
# SESSION commands
# ════════════════════════════════════════════════════════════════════════════════
_cmd_session() {
    local action="${1:-list}"; shift || true
    [[ ! -f "$OS_DB" ]] && bash "$BASE_DIR/db/migrate.sh"

    case "$action" in
        new)
            local mode="patient" title=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --mode)  shift; mode="$1" ;;
                    --title) shift; title="$1" ;;
                esac
                shift
            done
            python3 - "$OS_DB" "$mode" "$title" <<'PYEOF'
import sqlite3, sys, uuid
from datetime import datetime, timezone
db,mode,title = sys.argv[1], sys.argv[2], sys.argv[3]
sid  = str(uuid.uuid4())
now  = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]+"Z"
title= title or sid[:8]
conn = sqlite3.connect(db); conn.execute("PRAGMA foreign_keys=ON")
conn.execute("INSERT INTO sessions VALUES (?,?,?,?,?)", (sid,title,mode,now,now))
conn.commit(); conn.close()
print(sid)
PYEOF
            ;;
        list)
            local limit=20
            [[ "${1:-}" == "--limit" ]] && { shift; limit="$1"; shift; }
            python3 - "$OS_DB" "$limit" <<'PYEOF'
import sqlite3, sys, json
db,limit = sys.argv[1], int(sys.argv[2])
conn = sqlite3.connect(db); conn.row_factory = sqlite3.Row
rows = conn.execute("SELECT * FROM sessions ORDER BY updated_at DESC LIMIT ?", (limit,)).fetchall()
for r in rows:
    print(json.dumps(dict(r), ensure_ascii=False))
conn.close()
PYEOF
            ;;
        show)
            local sid="${1:-}"; [[ -z "$sid" ]] && { log_error "session show: ID required"; exit 2; }
            local show_turns=false
            [[ "${2:-}" == "--turns" ]] && show_turns=true
            python3 - "$OS_DB" "$sid" "$show_turns" <<'PYEOF'
import sqlite3, sys, json
db,sid,turns = sys.argv[1], sys.argv[2], sys.argv[3]=="true"
conn = sqlite3.connect(db); conn.row_factory = sqlite3.Row
s = conn.execute("SELECT * FROM sessions WHERE session_id=?", (sid,)).fetchone()
if not s: print("{}"); sys.exit(0)
out = dict(s)
if turns:
    ts = conn.execute("SELECT turn_id,turn_index,status,total_ms,created_at FROM turns WHERE session_id=? ORDER BY turn_index", (sid,)).fetchall()
    out["turns"] = [dict(t) for t in ts]
print(json.dumps(out, ensure_ascii=False, indent=2))
conn.close()
PYEOF
            ;;
        set)
            local sid="${1:-}"; [[ -z "$sid" ]] && { log_error "session set: ID required"; exit 2; }
            shift
            local mode="" title=""
            while [[ $# -gt 0 ]]; do
                case "$1" in --mode) shift; mode="$1" ;; --title) shift; title="$1" ;; esac; shift
            done
            python3 - "$OS_DB" "$sid" "$mode" "$title" <<'PYEOF'
import sqlite3, sys
from datetime import datetime, timezone
db,sid,mode,title = sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]+"Z"
conn = sqlite3.connect(db); conn.execute("PRAGMA foreign_keys=ON")
if mode:  conn.execute("UPDATE sessions SET default_mode=?,updated_at=? WHERE session_id=?", (mode,now,sid))
if title: conn.execute("UPDATE sessions SET title=?,updated_at=? WHERE session_id=?", (title,now,sid))
conn.commit(); conn.close(); print("ok")
PYEOF
            ;;
        rm)
            local sid="${1:-}"; [[ -z "$sid" ]] && { log_error "session rm: ID required"; exit 2; }
            local yes=false
            [[ "${2:-}" == "--yes" ]] && yes=true
            if [[ "$yes" == "false" ]]; then
                read -r -p "Delete session $sid and all its data? [y/N] " ans
                [[ "$ans" != "y" ]] && exit 0
            fi
            python3 - "$OS_DB" "$sid" <<'PYEOF'
import sqlite3, sys
db,sid = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db); conn.execute("PRAGMA foreign_keys=ON")
conn.execute("DELETE FROM sessions WHERE session_id=?", (sid,))
conn.commit(); conn.close(); print("deleted")
PYEOF
            ;;
        clear)
            local sid="${1:-}"; [[ -z "$sid" ]] && { log_error "session clear: ID required"; exit 2; }
            python3 - "$OS_DB" "$sid" <<'PYEOF'
import sqlite3, sys
db,sid = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db); conn.execute("PRAGMA foreign_keys=ON")
conn.execute("DELETE FROM messages WHERE session_id=?",      (sid,))
conn.execute("DELETE FROM agent_calls WHERE turn_id IN (SELECT turn_id FROM turns WHERE session_id=?)", (sid,))
conn.execute("DELETE FROM turns WHERE session_id=?",         (sid,))
conn.execute("DELETE FROM profile_facts WHERE session_id=?", (sid,))
conn.commit(); conn.close(); print("cleared")
PYEOF
            ;;
        export)
            local sid="${1:-}"; [[ -z "$sid" ]] && { log_error "session export: ID required"; exit 2; }
            local out_file=""
            [[ "${2:-}" == "--out" ]] && out_file="${3:-}"
            local export_data
            export_data=$(python3 - "$OS_DB" "$sid" <<'PYEOF'
import sqlite3, sys, json
db,sid = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db); conn.row_factory = sqlite3.Row
s  = conn.execute("SELECT * FROM sessions WHERE session_id=?", (sid,)).fetchone()
ms = conn.execute("SELECT * FROM messages WHERE session_id=? ORDER BY turn_index", (sid,)).fetchall()
fs = conn.execute("SELECT * FROM profile_facts WHERE session_id=?", (sid,)).fetchall()
out = {"session": dict(s) if s else {}, "messages": [dict(m) for m in ms], "profile_facts": [dict(f) for f in fs]}
print(json.dumps(out, ensure_ascii=False, indent=2))
conn.close()
PYEOF
)
            if [[ -n "$out_file" ]]; then
                echo "$export_data" > "$out_file"
                log_info "Exported to $out_file"
            else
                echo "$export_data"
            fi
            ;;
        purge)
            local before="" all=false
            while [[ $# -gt 0 ]]; do
                case "$1" in --before) shift; before="$1" ;; --all) all=true ;; esac; shift
            done
            read -r -p "Purge sessions? [y/N] " ans; [[ "$ans" != "y" ]] && exit 0
            python3 - "$OS_DB" "$before" "$all" <<'PYEOF'
import sqlite3, sys
db,before,all_flag = sys.argv[1], sys.argv[2], sys.argv[3]=="true"
conn = sqlite3.connect(db); conn.execute("PRAGMA foreign_keys=ON")
if all_flag:
    conn.execute("DELETE FROM sessions")
elif before:
    conn.execute("DELETE FROM sessions WHERE updated_at < ?", (before,))
conn.commit()
n = conn.total_changes; conn.close(); print(f"purged {n} rows")
PYEOF
            ;;
        *)  log_error "session: unknown action '$action'"; exit 2 ;;
    esac
}

# ════════════════════════════════════════════════════════════════════════════════
# HISTORY commands
# ════════════════════════════════════════════════════════════════════════════════
_cmd_history() {
    local action="${1:-show}"; shift || true
    [[ ! -f "$OS_DB" ]] && bash "$BASE_DIR/db/migrate.sh"
    local sid="" turn_n=""
    while [[ $# -gt 0 ]]; do
        case "$1" in --session) shift; sid="$1" ;; --turn) shift; turn_n="$1" ;; esac; shift
    done
    [[ -z "$sid" ]] && { log_error "history: --session required"; exit 2; }

    case "$action" in
        show)
            python3 - "$OS_DB" "$sid" "$turn_n" <<'PYEOF'
import sqlite3, sys, json
db,sid,turn = sys.argv[1], sys.argv[2], sys.argv[3]
conn = sqlite3.connect(db); conn.row_factory = sqlite3.Row
q = "SELECT * FROM messages WHERE session_id=?"
p = [sid]
if turn: q += " AND turn_index=?"; p.append(int(turn))
q += " ORDER BY turn_index, role"
for r in conn.execute(q, p).fetchall():
    print(json.dumps(dict(r), ensure_ascii=False))
conn.close()
PYEOF
            ;;
        rm)
            [[ -z "$turn_n" ]] && { log_error "history rm: --turn required"; exit 2; }
            python3 - "$OS_DB" "$sid" "$turn_n" <<'PYEOF'
import sqlite3, sys
db,sid,turn = sys.argv[1], sys.argv[2], int(sys.argv[3])
conn = sqlite3.connect(db); conn.execute("PRAGMA foreign_keys=ON")
conn.execute("DELETE FROM messages WHERE session_id=? AND turn_index=?", (sid,turn))
conn.commit(); conn.close(); print("deleted")
PYEOF
            ;;
        replay)
            python3 - "$OS_DB" "$sid" "$turn_n" <<'PYEOF'
import sqlite3, sys, json
db,sid,turn = sys.argv[1], sys.argv[2], sys.argv[3]
conn = sqlite3.connect(db); conn.row_factory = sqlite3.Row
q = "SELECT role, content FROM messages WHERE session_id=?"
p = [sid]
if turn: q += " AND turn_index=?"; p.append(int(turn))
q += " ORDER BY turn_index, role"
for r in conn.execute(q, p):
    label = "用户" if r["role"] == "user" else "助手"
    print(f"[{label}] {r['content']}\n")
conn.close()
PYEOF
            ;;
        *)  log_error "history: unknown action '$action'"; exit 2 ;;
    esac
}

# ════════════════════════════════════════════════════════════════════════════════
# MEMORY commands
# ════════════════════════════════════════════════════════════════════════════════
_cmd_memory() {
    local action="${1:-list}"; shift || true
    [[ ! -f "$OS_DB" ]] && bash "$BASE_DIR/db/migrate.sh"

    local sid="" fid="" subject="" attr="" value="" conf="1.0" status_filter="active"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session)    shift; sid="$1" ;;
            --id)         shift; fid="$1" ;;
            --subject)    shift; subject="$1" ;;
            --attr)       shift; attr="$1" ;;
            --value)      shift; value="$1" ;;
            --confidence) shift; conf="$1" ;;
            --status)     shift; status_filter="$1" ;;
        esac; shift
    done
    [[ -z "$sid" ]] && { log_error "memory: --session required"; exit 2; }

    case "$action" in
        list)
            python3 - "$OS_DB" "$sid" "$subject" "$status_filter" <<'PYEOF'
import sqlite3, sys, json
db,sid,subj,st = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
conn = sqlite3.connect(db); conn.row_factory = sqlite3.Row
q = "SELECT * FROM profile_facts WHERE session_id=?"
p = [sid]
if subj: q += " AND subject=?"; p.append(subj)
if st != "all": q += " AND status=?"; p.append(st)
q += " ORDER BY subject, attr"
for r in conn.execute(q, p).fetchall():
    print(json.dumps(dict(r), ensure_ascii=False))
conn.close()
PYEOF
            ;;
        show)
            [[ -z "$fid" ]] && { log_error "memory show: --id required"; exit 2; }
            python3 - "$OS_DB" "$fid" <<'PYEOF'
import sqlite3, sys, json
db,fid = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db); conn.row_factory = sqlite3.Row
r = conn.execute("SELECT * FROM profile_facts WHERE fact_id=?", (fid,)).fetchone()
print(json.dumps(dict(r) if r else {}, ensure_ascii=False, indent=2))
conn.close()
PYEOF
            ;;
        add)
            [[ -z "$subject" || -z "$attr" || -z "$value" ]] && {
                log_error "memory add: --subject, --attr, --value required"; exit 2; }
            python3 - "$OS_DB" "$sid" "$subject" "$attr" "$value" "$conf" <<'PYEOF'
import sqlite3, sys, uuid
from datetime import datetime, timezone
db,sid,subj,attr,val,conf = sys.argv[1:]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]+"Z"
conn = sqlite3.connect(db); conn.execute("PRAGMA foreign_keys=ON")
fid = str(uuid.uuid4())
conn.execute("""INSERT OR IGNORE INTO profile_facts
    (fact_id,session_id,subject,attr,value,confidence,source_turn,status,created_at)
    VALUES (?,?,?,?,?,?,NULL,'active',?)""", (fid,sid,subj,attr,val,float(conf),now))
conn.commit(); conn.close(); print(fid)
PYEOF
            ;;
        set)
            [[ -z "$fid" ]] && { log_error "memory set: --id required"; exit 2; }
            python3 - "$OS_DB" "$fid" "$value" "$conf" <<'PYEOF'
import sqlite3, sys
db,fid,val,conf = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
conn = sqlite3.connect(db)
if val:  conn.execute("UPDATE profile_facts SET value=? WHERE fact_id=?", (val,fid))
if conf: conn.execute("UPDATE profile_facts SET confidence=? WHERE fact_id=?", (float(conf),fid))
conn.commit(); conn.close(); print("ok")
PYEOF
            ;;
        retract)
            [[ -z "$fid" ]] && { log_error "memory retract: --id required"; exit 2; }
            python3 - "$OS_DB" "$fid" <<'PYEOF'
import sqlite3, sys
db,fid = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db)
conn.execute("UPDATE profile_facts SET status='retracted' WHERE fact_id=?", (fid,))
conn.commit(); conn.close(); print("retracted")
PYEOF
            ;;
        rm)
            [[ -z "$fid" ]] && { log_error "memory rm: --id required"; exit 2; }
            python3 - "$OS_DB" "$fid" <<'PYEOF'
import sqlite3, sys
db,fid = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db)
conn.execute("DELETE FROM profile_facts WHERE fact_id=?", (fid,))
conn.commit(); conn.close(); print("deleted")
PYEOF
            ;;
        clear)
            read -r -p "Clear all memory facts for session $sid? [y/N] " ans
            [[ "$ans" != "y" ]] && exit 0
            python3 - "$OS_DB" "$sid" <<'PYEOF'
import sqlite3, sys
db,sid = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db)
conn.execute("DELETE FROM profile_facts WHERE session_id=?", (sid,))
conn.commit(); conn.close(); print("cleared")
PYEOF
            ;;
        export)
            python3 - "$OS_DB" "$sid" <<'PYEOF'
import sqlite3, sys, json
db,sid = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db); conn.row_factory = sqlite3.Row
rows = conn.execute("SELECT * FROM profile_facts WHERE session_id=? ORDER BY subject,attr", (sid,)).fetchall()
print(json.dumps([dict(r) for r in rows], ensure_ascii=False, indent=2))
conn.close()
PYEOF
            ;;
        *)  log_error "memory: unknown action '$action'"; exit 2 ;;
    esac
}

# ════════════════════════════════════════════════════════════════════════════════
# AGENT commands
# ════════════════════════════════════════════════════════════════════════════════
_cmd_agent() {
    local action="${1:-list}"; shift || true
    local agent_id="" mode="patient" enabled=""
    local probe_question=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)    shift; mode="$1" ;;
            --enabled) shift; enabled="$1" ;;
            *)
                if [[ -z "$agent_id" && "$1" != "validate" && "$1" != "reload" ]]; then
                    agent_id="$1"
                elif [[ -z "$probe_question" ]]; then
                    probe_question="$1"
                fi
                ;;
        esac; shift
    done

    case "$action" in
        list)
            python3 - "$BASE_DIR/registry/agents.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for a in d["agents"]:
    print(json.dumps(a, ensure_ascii=False))
PYEOF
            ;;
        show)
            [[ -z "$agent_id" ]] && { log_error "agent show: ID required"; exit 2; }
            python3 - "$BASE_DIR/registry/agents.json" "$agent_id" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
agents = {a["id"]: a for a in d["agents"]}
a = agents.get(sys.argv[2])
print(json.dumps(a or {}, ensure_ascii=False, indent=2))
PYEOF
            ;;
        test)
            [[ -z "$agent_id" ]] && { log_error "agent test: ID required"; exit 2; }
            [[ -z "$probe_question" ]] && probe_question="高血压患者的血压控制目标是多少？"
            log_info "Smoke-testing agent '$agent_id' with question: $probe_question"
            local adapter="$BASE_DIR/registry/adapters/${agent_id}.sh"
            [[ ! -f "$adapter" ]] && { log_error "Adapter not found: $adapter"; exit 4; }
            export INTENT_ID="test-1"
            export INTENT_MODE="$mode"
            export INTENT_DOMAINS=""
            export INTENT_QUESTION="$probe_question"
            export RUNDIR="/tmp/os-agent-test-$$"
            mkdir -p "$RUNDIR"
            bash "$adapter"
            if [[ -f "$RUNDIR/intent_test-1.result.json" ]]; then
                cat "$RUNDIR/intent_test-1.result.json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'status={d[\"status\"]} ms={d[\"ms\"]}'); print(d.get('answer','')[:300])"
            fi
            rm -rf "$RUNDIR"
            ;;
        validate)
            local ok=true
            log_info "Validating agent registry..."
            python3 - "$BASE_DIR/registry/agents.json" "$BASE_DIR" <<'PYEOF'
import json, os, sys
d = json.load(open(sys.argv[1]))
base = sys.argv[2]
for a in d["agents"]:
    adapter = os.path.join(base, "registry", a["adapter"])
    df = os.path.join(base, "registry", a.get("domains_file",""))
    issues = []
    if not os.path.exists(adapter): issues.append(f"adapter missing: {adapter}")
    if a.get("domains_file") and not os.path.exists(df): issues.append(f"domains_file missing: {df}")
    status = "OK" if not issues else "FAIL"
    print(f"{status}  {a['id']}: " + ("; ".join(issues) if issues else "adapter+domains OK"))
PYEOF
            ;;
        set)
            [[ -z "$agent_id" ]] && { log_error "agent set: ID required"; exit 2; }
            python3 - "$BASE_DIR/registry/agents.json" "$agent_id" "$enabled" <<'PYEOF'
import json, sys
path, aid, enabled = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
for a in d["agents"]:
    if a["id"] == aid and enabled:
        a["enabled"] = enabled.lower() == "true"
with open(path,"w") as f: json.dump(d, f, ensure_ascii=False, indent=2)
print("ok")
PYEOF
            ;;
        reload) log_info "Registry reloaded (no daemon in MVP)" ;;
        *)  log_error "agent: unknown action '$action'"; exit 2 ;;
    esac
}

# ════════════════════════════════════════════════════════════════════════════════
# CACHE commands
# ════════════════════════════════════════════════════════════════════════════════
_cmd_cache() {
    local action="${1:-stats}"; shift || true
    [[ ! -f "$OS_DB" ]] && bash "$BASE_DIR/db/migrate.sh"
    local limit=20 cache_key="" agent_filter="" domain_filter=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit)  shift; limit="$1" ;;
            --agent)  shift; agent_filter="$1" ;;
            --domain) shift; domain_filter="$1" ;;
            *)        cache_key="$1" ;;
        esac; shift
    done

    case "$action" in
        stats)
            python3 - "$OS_DB" <<'PYEOF'
import sqlite3, sys, json
db = sys.argv[1]; conn = sqlite3.connect(db); conn.row_factory = sqlite3.Row
total = conn.execute("SELECT COUNT(*) FROM response_cache").fetchone()[0]
hits  = conn.execute("SELECT COALESCE(SUM(hit_count),0) FROM response_cache").fetchone()[0]
print(json.dumps({"total_entries": total, "total_hits": hits}, indent=2))
conn.close()
PYEOF
            ;;
        list)
            python3 - "$OS_DB" "$limit" <<'PYEOF'
import sqlite3, sys, json
db,limit = sys.argv[1], int(sys.argv[2])
conn = sqlite3.connect(db); conn.row_factory = sqlite3.Row
for r in conn.execute("SELECT cache_key,agent_id,mode,hit_count,created_at FROM response_cache ORDER BY last_hit_at DESC LIMIT ?", (limit,)).fetchall():
    print(json.dumps(dict(r), ensure_ascii=False))
conn.close()
PYEOF
            ;;
        show)
            [[ -z "$cache_key" ]] && { log_error "cache show: KEY required"; exit 2; }
            python3 - "$OS_DB" "$cache_key" <<'PYEOF'
import sqlite3, sys, json
db,key = sys.argv[1], sys.argv[2]; conn = sqlite3.connect(db); conn.row_factory = sqlite3.Row
r = conn.execute("SELECT * FROM response_cache WHERE cache_key=?", (key,)).fetchone()
print(json.dumps(dict(r) if r else {}, ensure_ascii=False, indent=2)); conn.close()
PYEOF
            ;;
        rm)
            [[ -z "$cache_key" ]] && { log_error "cache rm: KEY required"; exit 2; }
            python3 - "$OS_DB" "$cache_key" <<'PYEOF'
import sqlite3, sys
db,key = sys.argv[1], sys.argv[2]; conn = sqlite3.connect(db)
conn.execute("DELETE FROM response_cache WHERE cache_key=?", (key,)); conn.commit(); conn.close(); print("deleted")
PYEOF
            ;;
        clear)
            read -r -p "Clear entire response cache? [y/N] " ans; [[ "$ans" != "y" ]] && exit 0
            python3 - "$OS_DB" <<'PYEOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1]); conn.execute("DELETE FROM response_cache"); conn.commit(); conn.close(); print("cleared")
PYEOF
            ;;
        invalidate)
            python3 - "$OS_DB" "$agent_filter" "$domain_filter" <<'PYEOF'
import sqlite3, sys
db,agent,domain = sys.argv[1], sys.argv[2], sys.argv[3]
conn = sqlite3.connect(db)
if agent:  conn.execute("DELETE FROM response_cache WHERE agent_id=?", (agent,))
elif domain: conn.execute("DELETE FROM response_cache WHERE domains LIKE ?", (f"%{domain}%",))
else: conn.execute("DELETE FROM response_cache")
conn.commit(); print(f"invalidated {conn.total_changes} entries"); conn.close()
PYEOF
            ;;
        *)  log_error "cache: unknown action '$action'"; exit 2 ;;
    esac
}

# ════════════════════════════════════════════════════════════════════════════════
# CONFIG commands
# ════════════════════════════════════════════════════════════════════════════════
_cmd_config() {
    local action="${1:-list}"; shift || true
    case "$action" in
        list)
            [[ -f "$BASE_DIR/.env" ]] && grep -v '^#' "$BASE_DIR/.env" | grep '=' || echo "(no .env)"
            ;;
        get)
            local key="${1:-}"; [[ -z "$key" ]] && { log_error "config get: KEY required"; exit 2; }
            [[ -f "$BASE_DIR/.env" ]] && grep "^${key}=" "$BASE_DIR/.env" | cut -d= -f2- || echo "(not set)"
            ;;
        set)
            local key="${1:-}" val="${2:-}"
            [[ -z "$key" ]] && { log_error "config set: KEY VALUE required"; exit 2; }
            if [[ -f "$BASE_DIR/.env" ]] && grep -q "^${key}=" "$BASE_DIR/.env"; then
                sed -i.bak "s|^${key}=.*|${key}=${val}|" "$BASE_DIR/.env"
            else
                echo "${key}=${val}" >> "$BASE_DIR/.env"
            fi
            echo "ok"
            ;;
        path)
            echo "env:  $BASE_DIR/.env"
            echo "db:   $OS_DB"
            echo "runs: $OS_RUNS_DIR"
            echo "logs: $OS_LOGS_DIR"
            ;;
        *)  log_error "config: unknown action '$action'"; exit 2 ;;
    esac
}

# ════════════════════════════════════════════════════════════════════════════════
# DB commands
# ════════════════════════════════════════════════════════════════════════════════
_cmd_db() {
    local action="${1:-status}"; shift || true
    case "$action" in
        init|migrate) bash "$BASE_DIR/db/migrate.sh" ;;
        status)
            if [[ -f "$OS_DB" ]]; then
                sqlite3 "$OS_DB" ".tables"
                sqlite3 "$OS_DB" "SELECT COUNT(*) || ' sessions' FROM sessions;"
                sqlite3 "$OS_DB" "SELECT COUNT(*) || ' turns' FROM turns;"
            else
                echo "DB not initialized. Run: os.sh db init"
            fi
            ;;
        vacuum)
            [[ -f "$OS_DB" ]] && sqlite3 "$OS_DB" "VACUUM;" && echo "vacuumed"
            ;;
        backup)
            local out_file="${1:-.os_backup_$(date +%Y%m%d_%H%M%S).db}"
            [[ "${1:-}" == "--out" ]] && out_file="${2:-}"
            sqlite3 "$OS_DB" ".backup $out_file" && echo "Backed up to $out_file"
            ;;
        reset)
            local force=false
            [[ "${1:-}" == "--force" ]] && force=true
            if [[ "$force" == "false" ]]; then
                read -r -p "RESET database? All data will be lost. [y/N] " ans
                [[ "$ans" != "y" ]] && exit 0
            fi
            rm -f "$OS_DB" "${OS_DB}-wal" "${OS_DB}-shm"
            bash "$BASE_DIR/db/migrate.sh"
            echo "reset"
            ;;
        *)  log_error "db: unknown action '$action'"; exit 2 ;;
    esac
}

# ════════════════════════════════════════════════════════════════════════════════
# EVAL commands
# ════════════════════════════════════════════════════════════════════════════════
_cmd_eval() {
    local action="${1:-list}"; shift || true
    case "$action" in
        run)  bash "$BASE_DIR/eval/run_eval.sh" "$@" ;;
        list) ls "$BASE_DIR/eval/scenarios.json" "$BASE_DIR/eval/scenarios.yaml" 2>/dev/null || echo "no scenarios" ;;
        show) cat "$BASE_DIR/eval/scenarios.json" 2>/dev/null || cat "$BASE_DIR/eval/scenarios.yaml" 2>/dev/null || echo "no scenarios" ;;
        *)    log_error "eval: unknown action '$action'"; exit 2 ;;
    esac
}

# ════════════════════════════════════════════════════════════════════════════════
# SERVE — stdio NDJSON JSON-RPC 2.0 daemon
# Each request: one JSON object per line → one response per line
# Notifications use method "$/progress"
# ════════════════════════════════════════════════════════════════════════════════
_cmd_serve() {
    [[ ! -f "$OS_DB" ]] && bash "$BASE_DIR/db/migrate.sh" >&2

    # Write serve loop to a temp file so python3's stdin stays connected to the caller
    local _srv_tmp
    _srv_tmp=$(mktemp /tmp/os_serve_XXXXXX.py)
    trap "rm -f '$_srv_tmp'" EXIT INT TERM

    cat > "$_srv_tmp" <<'PYEOF'
import json, os, subprocess, sys

base_dir = sys.argv[1]
os_db    = sys.argv[2]
os_sh    = os.path.join(base_dir, "os.sh")

_active = {}  # request_id → subprocess

def send(obj):
    print(json.dumps(obj, ensure_ascii=False), flush=True)

def ok(id, result):
    send({"jsonrpc": "2.0", "id": id, "result": result})

def err(id, code, msg):
    send({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": msg}})

def notify(id, event):
    send({"jsonrpc": "2.0", "method": "$/progress", "params": {"id": id, "event": event}})

def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)

def handle_initialize(id, p):
    ok(id, {
        "version": "0.1.0",
        "modes": ["patient", "doctor"],
        "event_types": ["prefilter", "decompose", "dispatch_start", "dispatch_end",
                        "synthesize_start", "token", "profile_delta", "run_end"],
        "methods": ["initialize", "plan", "chat", "session", "memory", "cancel"],
    })

def handle_plan(id, p):
    sid  = p.get("session_id", "")
    msg  = p.get("message", "")
    mode = p.get("mode", "patient")
    r = run(["bash", os_sh, "chat", "--session", sid, "--mode", mode, "--dry-run", msg])
    if r.returncode == 0:
        try:
            ok(id, {"ast": json.loads(r.stdout)})
        except Exception:
            ok(id, {"ast": None, "raw": r.stdout.strip()})
    else:
        err(id, -32000, r.stderr[:300] or "plan failed")

def handle_chat(id, p):
    sid       = p.get("session_id", "")
    msg       = p.get("message", "")
    mode      = p.get("mode", "patient")
    no_cache  = p.get("no_cache", False)

    cmd = ["bash", os_sh, "chat", "--session", sid, "--mode", mode, "--json"]
    if no_cache:
        cmd.append("--no-cache")
    cmd.append(msg)

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    _active[id] = proc
    final = None
    try:
        for line in proc.stdout:
            line = line.rstrip()
            if not line:
                continue
            try:
                event = json.loads(line)
                if event.get("type") == "run_end":
                    final = event
                else:
                    notify(id, event)
            except Exception:
                pass
        proc.wait()
    finally:
        _active.pop(id, None)

    if final:
        ok(id, {
            "status":   final.get("status", final.get("data", {}).get("status", "ok")),
            "total_ms": final.get("total_ms", final.get("data", {}).get("total_ms", 0)),
        })
    else:
        err(id, -32000, "no run_end event from chat subprocess")

def handle_session(id, p):
    verb = p.get("verb", "list")
    sid  = p.get("session_id", "")
    mode = p.get("mode", "patient")
    if verb == "new":
        cmd = ["bash", os_sh, "session", "new", "--mode", mode]
        if sid:
            cmd += ["--session", sid]
        r = run(cmd)
        ok(id, {"session_id": r.stdout.strip()})
    elif verb == "list":
        r = run(["bash", os_sh, "session", "list"])
        ok(id, {"output": r.stdout.strip()})
    elif verb == "history":
        r = run(["bash", os_sh, "history", "show", "--session", sid])
        ok(id, {"output": r.stdout.strip()})
    else:
        err(id, -32601, f"session/{verb} not supported")

def handle_memory(id, p):
    verb = p.get("verb", "get")
    sid  = p.get("session_id", "")
    if verb == "get":
        r = run(["bash", os_sh, "memory", "list", "--session", sid])
        ok(id, {"output": r.stdout.strip()})
    elif verb == "update":
        subject = p.get("subject", "")
        attr    = p.get("attr", "")
        value   = p.get("value", "")
        op      = p.get("op", "add")
        cmd = ["bash", os_sh, "memory", op, "--session", sid,
               "--subject", subject, "--attr", attr, "--value", value]
        r = run(cmd)
        ok(id, {"ok": r.returncode == 0})
    else:
        err(id, -32601, f"memory/{verb} not supported")

def handle_cancel(id, p):
    target = p.get("id", "")
    proc = _active.get(target)
    if proc:
        try:
            proc.terminate()
        except Exception:
            pass
        ok(id, {"cancelled": True})
    else:
        ok(id, {"cancelled": False})

HANDLERS = {
    "initialize": handle_initialize,
    "plan":       handle_plan,
    "chat":       handle_chat,
    "session":    handle_session,
    "memory":     handle_memory,
    "cancel":     handle_cancel,
}

for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        req = json.loads(raw)
    except Exception:
        send({"jsonrpc": "2.0", "id": None,
              "error": {"code": -32700, "message": "Parse error"}})
        continue

    rid    = req.get("id")
    method = req.get("method", "")
    params = req.get("params") or {}

    handler = HANDLERS.get(method)
    if not handler:
        err(rid, -32601, f"Method not found: {method}")
        continue
    try:
        handler(rid, params)
    except Exception as e:
        err(rid, -32000, str(e))
PYEOF

    python3 "$_srv_tmp" "$BASE_DIR" "$OS_DB"
}

# ════════════════════════════════════════════════════════════════════════════════
# Route to subcommand
# ════════════════════════════════════════════════════════════════════════════════
_r() { [[ ${#rest[@]} -gt 0 ]] && printf '%s\0' "${rest[@]}" | xargs -0 "$@" || "$@"; }

case "$resource" in
    chat)    _cmd_chat    "$verb" ${rest[@]+"${rest[@]}"} ;;
    plan)    _cmd_plan    "$verb" ${rest[@]+"${rest[@]}"} ;;
    session) _cmd_session "$verb" ${rest[@]+"${rest[@]}"} ;;
    history) _cmd_history "$verb" ${rest[@]+"${rest[@]}"} ;;
    memory)  _cmd_memory  "$verb" ${rest[@]+"${rest[@]}"} ;;
    agent)   _cmd_agent   "$verb" ${rest[@]+"${rest[@]}"} ;;
    cache)   _cmd_cache   "$verb" ${rest[@]+"${rest[@]}"} ;;
    config)  _cmd_config  "$verb" ${rest[@]+"${rest[@]}"} ;;
    db)      _cmd_db      "$verb" ${rest[@]+"${rest[@]}"} ;;
    eval)    _cmd_eval    "$verb" ${rest[@]+"${rest[@]}"} ;;
    serve)   _cmd_serve ;;
    *)
        log_error "Unknown command: $resource"
        _usage
        ;;
esac
