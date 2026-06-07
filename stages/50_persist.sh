#!/usr/bin/env bash
# Stage 5: Persist — single-writer DB commit (turn + messages + agent_calls + profile_facts).
# Called by the parent process after reply is delivered; may run async for fast-path.
# Input env: OS_DB, OS_SESSION_ID
# Arguments: turn_id, turn_index, user_message, prefilter_result,
#            ast_json, results_json, synth_json, total_ms

set -euo pipefail

STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$STAGE_DIR")"

source "$BASE_DIR/lib/common.sh"

persist_turn() {
    local turn_id="$1"
    local turn_index="$2"
    local user_message="$3"
    local prefilter_result="$4"
    local ast_json="$5"
    local results_json="$6"
    local synth_json="$7"
    local total_ms="$8"

    python3 - \
        "$OS_DB" \
        "$OS_SESSION_ID" \
        "$turn_id" \
        "$turn_index" \
        "$user_message" \
        "$prefilter_result" \
        "$ast_json" \
        "$results_json" \
        "$synth_json" \
        "$total_ms" \
        <<'PYEOF'
import json, sqlite3, sys
from datetime import datetime, timezone

db_path      = sys.argv[1]
session_id   = sys.argv[2]
turn_id      = sys.argv[3]
turn_index   = int(sys.argv[4])
user_message = sys.argv[5]
prefilter    = sys.argv[6]
ast_json_str = sys.argv[7]
results_str  = sys.argv[8]
synth_str    = sys.argv[9]
total_ms     = int(sys.argv[10])

now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

synth    = json.loads(synth_str) if synth_str else {}
reply    = synth.get("reply", "")
status   = synth.get("status", "ok")
p_delta  = synth.get("profile_delta", [])
results  = json.loads(results_str) if results_str else []

conn = sqlite3.connect(db_path, timeout=10)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("PRAGMA foreign_keys=ON")

try:
    conn.execute("BEGIN IMMEDIATE")

    # 1. turn row
    conn.execute("""
        INSERT OR REPLACE INTO turns
            (turn_id, session_id, turn_index, user_message, prefilter,
             decompose_json, reply, status, total_ms, created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?)
    """, (turn_id, session_id, turn_index, user_message, prefilter,
          ast_json_str, reply, status, total_ms, now))

    # 2. user message row
    import uuid
    conn.execute("""
        INSERT OR IGNORE INTO messages
            (message_id, session_id, turn_index, role, mode, content, created_at)
        VALUES (?,?,?,?,?,?,?)
    """, (str(uuid.uuid4()), session_id, turn_index, "user", "patient", user_message, now))

    # 3. assistant message row
    conn.execute("""
        INSERT OR IGNORE INTO messages
            (message_id, session_id, turn_index, role, mode, content, created_at)
        VALUES (?,?,?,?,?,?,?)
    """, (str(uuid.uuid4()), session_id, turn_index, "assistant", "patient", reply, now))

    # 4. agent_calls
    try:
        ast = json.loads(ast_json_str) if ast_json_str else {}
        nodes = {n["id"]: n for n in ast.get("plan", {}).get("nodes", [])}
    except Exception:
        nodes = {}

    for r in results:
        iid     = r["id"]
        node    = nodes.get(iid, {})
        domains = " ".join(node.get("domains", []))
        conn.execute("""
            INSERT OR IGNORE INTO agent_calls
                (call_id, turn_id, intent_id, agent_id, mode, domains,
                 question, answer, status, exit_code, ms, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        """, (str(uuid.uuid4()), turn_id, iid,
              node.get("agent", "inner_all"),
              node.get("mode", "patient"),
              domains,
              node.get("question", ""),
              r.get("answer"),
              r.get("status", "error"),
              r.get("exit_code"),
              r.get("ms"),
              now))

    # 5. profile_facts from profile_delta
    for fact in p_delta:
        op      = fact.get("op", "add")
        subject = fact.get("subject", "")
        attr    = fact.get("attr", "")
        value   = fact.get("value", "")
        conf    = float(fact.get("confidence", 1.0))

        if op == "add" and subject and attr and value:
            conn.execute("""
                INSERT OR IGNORE INTO profile_facts
                    (fact_id, session_id, subject, attr, value,
                     confidence, source_turn, status, created_at)
                VALUES (?,?,?,?,?,?,?,'active',?)
            """, (str(uuid.uuid4()), session_id, subject, attr, value, conf, turn_id, now))

        elif op == "retract" and subject and attr:
            conn.execute("""
                UPDATE profile_facts
                SET status='retracted'
                WHERE session_id=? AND subject=? AND attr=?
                  AND value=? AND status='active'
            """, (session_id, subject, attr, value))

    # 6. update session.updated_at
    conn.execute("""
        UPDATE sessions SET updated_at=? WHERE session_id=?
    """, (now, session_id))

    conn.commit()
except Exception as e:
    conn.rollback()
    raise
finally:
    conn.close()
PYEOF
}
