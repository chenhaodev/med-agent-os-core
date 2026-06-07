#!/usr/bin/env bash
# Stage 1: Load context from DB — history window + patient profile block.
# Outputs: context JSON to stdout.
# Input env: OS_SESSION_ID, OS_DB, OS_HISTORY_WINDOW

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

build_context() {
    local session_id="$1"
    local mode="${2:-patient}"

    python3 - "$session_id" "$OS_DB" "$OS_HISTORY_WINDOW" "$mode" <<'PYEOF'
import json, sqlite3, sys

session_id  = sys.argv[1]
db_path     = sys.argv[2]
window      = int(sys.argv[3])
mode        = sys.argv[4]

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row

# history window (last N turns, chronological)
rows = conn.execute("""
    SELECT role, content FROM messages
    WHERE session_id = ?
    ORDER BY turn_index DESC
    LIMIT ?
""", (session_id, window * 2)).fetchall()
history = [{"role": r["role"], "content": r["content"]} for r in reversed(rows)]

# active profile facts
fact_rows = conn.execute("""
    SELECT subject, attr, value, confidence
    FROM profile_facts
    WHERE session_id = ? AND status = 'active'
    ORDER BY subject, attr
""", (session_id,)).fetchall()

facts = [{"subject": r["subject"], "attr": r["attr"],
          "value": r["value"], "confidence": r["confidence"]}
         for r in fact_rows]

# render profile block — MemGPT-style human block
subjects = {}
for f in facts:
    subjects.setdefault(f["subject"], []).append(f["value"])

profile_block = ""
if subjects:
    lines = []
    for subj, values in sorted(subjects.items()):
        lines.append(f"{subj}：{'、'.join(values)}")
    profile_block = "【患者/相关人员信息】\n" + "\n".join(lines)

conn.close()

print(json.dumps({
    "session_id":    session_id,
    "mode":          mode,
    "history":       history,
    "profile_facts": facts,
    "profile_block": profile_block,
}, ensure_ascii=False))
PYEOF
}
