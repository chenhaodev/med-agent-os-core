#!/usr/bin/env bash
# Async profile fact extraction — used by single-intent fast-path.
# Multi-intent path folds this into synthesize (zero extra LLM call).
# Source this file; do not execute directly.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/llm.sh"

_PROFILE_EXTRACT_SYSTEM='你是医学信息提取助手。从对话中提取患者/相关人员的健康信息。

只提取**明确陈述**的事实（不推断），输出 JSON 数组。没有新信息时输出 []。

格式：
```json
[{"op":"add","subject":"人物名称","attr":"disease|medication|allergy|age|note","value":"具体值","confidence":0.9}]
```

- subject: 本人 / 爸爸 / 妈妈 / 具体姓名 等
- attr 枚举: disease(疾病) / medication(药物) / allergy(过敏) / age(年龄) / note(其他注意事项)
- 只输出 JSON，不要其他文字'

# ── extract_profile_async(message, answer, session_id, turn_id) ───────────────
# Run in background (&) after reply is delivered.
# Writes profile_delta facts directly to DB (only caller is this function = safe).
extract_profile_async() {
    local message="$1"
    local answer="$2"
    local session_id="$3"
    local turn_id="$4"

    local user_content
    user_content="用户消息：${message}

系统回答（截取）：${answer:0:800}"

    local raw
    if ! raw=$(llm_call "$_PROFILE_EXTRACT_SYSTEM" "$user_content" 0); then
        return 0  # silent fail — profile extraction is best-effort
    fi

    python3 - "$OS_DB" "$session_id" "$turn_id" "$raw" <<'PYEOF' 2>/dev/null || true
import json, re, sqlite3, sys, uuid
from datetime import datetime, timezone

db,sid,tid,raw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]+"Z"

cleaned = re.sub(r"^```(?:json)?\s*","",raw.strip(),flags=re.MULTILINE)
cleaned = re.sub(r"\s*```$","",cleaned.strip(),flags=re.MULTILINE).strip()

try:
    facts = json.loads(cleaned)
    if not isinstance(facts, list): facts = []
except Exception:
    facts = []

VALID_ATTRS = {"disease","medication","allergy","age","note"}
conn = sqlite3.connect(db, timeout=10)
conn.execute("PRAGMA foreign_keys=ON")
for f in facts:
    op   = f.get("op","add")
    subj = str(f.get("subject","")).strip()
    attr = str(f.get("attr","")).strip()
    val  = str(f.get("value","")).strip()
    conf = float(f.get("confidence",0.9))
    if not (subj and attr and val): continue
    if attr not in VALID_ATTRS: continue
    if op == "add":
        conn.execute("""
            INSERT OR IGNORE INTO profile_facts
                (fact_id,session_id,subject,attr,value,confidence,source_turn,status,created_at)
            VALUES (?,?,?,?,?,?,?,'active',?)
        """, (str(uuid.uuid4()),sid,subj,attr,val,conf,tid,now))
conn.commit(); conn.close()
PYEOF
}
