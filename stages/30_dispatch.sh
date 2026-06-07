#!/usr/bin/env bash
# Stage 3: Dispatch — fan-out to agent adapters; collect results.
# Reads AST, spawns adapter processes (bounded), collects result JSONs.
# ONLY outputs: results JSON array on stdout.
# Child processes are DB-silent; parent reads results after all complete.

set -euo pipefail

STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$STAGE_DIR")"

source "$BASE_DIR/lib/common.sh"
source "$BASE_DIR/lib/dispatch.sh"
source "$BASE_DIR/lib/events.sh"

# ── dispatch_all(ast_json, rundir) ────────────────────────────────────────────
# Returns: JSON array of result objects to stdout.
dispatch_all() {
    local ast_json="$1"
    local rundir="$2"

    mkdir -p "$rundir"

    local nodes_json
    nodes_json=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(json.dumps(d['plan']['nodes']))" "$ast_json")
    local node_count
    node_count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$nodes_json")

    if [[ $node_count -eq 1 ]]; then
        # single-intent fast-path: run inline (no subprocess overhead)
        local node_json
        node_json=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(json.dumps(d[0]))" "$nodes_json")
        local iid agent_id domains_json
        iid=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$node_json")
        agent_id=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('agent','inner_all'))" "$node_json")
        domains_json=$(python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1]).get('domains',[])))" "$node_json")
        emit_event "dispatch_start" "\"intent_id\":\"$iid\",\"agent_id\":\"$agent_id\",\"domains\":$domains_json"
        dispatch_intent "$node_json" "$rundir"
        local rf="$rundir/intent_${iid}.result.json"
        local d_status d_ms
        d_status=$(python3 -c "import json,sys; d=json.loads(open(sys.argv[1]).read()); print(d.get('status','ok'))" "$rf" 2>/dev/null || echo "ok")
        d_ms=$(python3 -c "import json,sys; d=json.loads(open(sys.argv[1]).read()); print(d.get('ms',0))" "$rf" 2>/dev/null || echo "0")
        emit_event "dispatch_end" "\"intent_id\":\"$iid\",\"agent_id\":\"$agent_id\",\"status\":\"$d_status\",\"ms\":$d_ms"
    else
        # bounded fan-out — emit per-node start events then parallel dispatch
        while IFS= read -r node_j; do
            local iid agent_id domains_json
            iid=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$node_j")
            agent_id=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('agent','inner_all'))" "$node_j")
            domains_json=$(python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1]).get('domains',[])))" "$node_j")
            emit_event "dispatch_start" "\"intent_id\":\"$iid\",\"agent_id\":\"$agent_id\",\"domains\":$domains_json"
        done < <(python3 -c "
import json,sys
nodes=json.loads(sys.argv[1])
for n in nodes: print(json.dumps(n))
" "$nodes_json")

        bounded_fanout "$nodes_json" "$rundir" "$OS_MAX_WORKERS"

        # emit dispatch_end per node after all workers complete
        while IFS= read -r node_j; do
            local iid agent_id
            iid=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$node_j")
            agent_id=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('agent','inner_all'))" "$node_j")
            local rf="$rundir/intent_${iid}.result.json"
            local d_status d_ms
            d_status=$(python3 -c "import json,sys; d=json.loads(open(sys.argv[1]).read()); print(d.get('status','ok'))" "$rf" 2>/dev/null || echo "ok")
            d_ms=$(python3 -c "import json,sys; d=json.loads(open(sys.argv[1]).read()); print(d.get('ms',0))" "$rf" 2>/dev/null || echo "0")
            emit_event "dispatch_end" "\"intent_id\":\"$iid\",\"agent_id\":\"$agent_id\",\"status\":\"$d_status\",\"ms\":$d_ms"
        done < <(python3 -c "
import json,sys
nodes=json.loads(sys.argv[1])
for n in nodes: print(json.dumps(n))
" "$nodes_json")
    fi

    # Collect results in node order — ONLY stdout output from this function
    python3 - "$nodes_json" "$rundir" <<'PYEOF'
import json, os, sys

nodes   = json.loads(sys.argv[1])
rundir  = sys.argv[2]
results = []

for node in nodes:
    iid = node["id"]
    rf  = os.path.join(rundir, f"intent_{iid}.result.json")
    if os.path.exists(rf):
        try:
            results.append(json.loads(open(rf).read()))
        except Exception:
            results.append({"id": iid, "status": "error", "answer": None,
                            "citations": [], "ms": 0, "exit_code": -1})
    else:
        results.append({"id": iid, "status": "error", "answer": None,
                        "citations": [], "ms": 0, "exit_code": -1,
                        "error": "result file missing"})

print(json.dumps(results, ensure_ascii=False))
PYEOF
}
