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
        local node_json iid agent_id domains_json
        # Extract node[0] + its id/agent/domains in one python call.
        IFS=$'\t' read -r node_json iid agent_id domains_json < <(python3 -c "
import json, sys
n = json.loads(sys.argv[1])[0]
print('\t'.join([json.dumps(n), str(n['id']), n.get('agent','inner_all'), json.dumps(n.get('domains',[]))]))
" "$nodes_json")
        emit_event "dispatch_start" "\"intent_id\":\"$iid\",\"agent_id\":\"$agent_id\",\"domains\":$domains_json"
        dispatch_intent "$node_json" "$rundir"
        local rf="$rundir/intent_${iid}.result.json"
        local d_status d_ms
        if [[ -f "$rf" ]]; then
            read -r d_status d_ms < <(python3 -c "
import json,sys
try:
    d=json.loads(open(sys.argv[1]).read())
    print(d.get('status','error'),d.get('ms',0))
except Exception:
    print('error',0)
" "$rf" 2>/dev/null || echo "error 0")
        else
            d_status="error"; d_ms="0"
        fi
        emit_event "dispatch_end" "\"intent_id\":\"$iid\",\"agent_id\":\"$agent_id\",\"status\":\"$d_status\",\"ms\":$d_ms"
    else
        # bounded fan-out — emit per-node start events then parallel dispatch.
        # One python call streams "id<TAB>agent<TAB>domains_json" per node.
        while IFS=$'\t' read -r iid agent_id domains_json; do
            emit_event "dispatch_start" "\"intent_id\":\"$iid\",\"agent_id\":\"$agent_id\",\"domains\":$domains_json"
        done < <(python3 -c "
import json,sys
for n in json.loads(sys.argv[1]):
    print('\t'.join([str(n['id']), n.get('agent','inner_all'), json.dumps(n.get('domains',[]))]))
" "$nodes_json")

        bounded_fanout "$nodes_json" "$rundir" "$OS_MAX_WORKERS"

        # emit dispatch_end per node after all workers complete
        while IFS=$'\t' read -r iid agent_id; do
            local rf="$rundir/intent_${iid}.result.json"
            local d_status d_ms
            if [[ -f "$rf" ]]; then
                read -r d_status d_ms < <(python3 -c "
import json,sys
try:
    d=json.loads(open(sys.argv[1]).read())
    print(d.get('status','error'),d.get('ms',0))
except Exception:
    print('error',0)
" "$rf" 2>/dev/null || echo "error 0")
            else
                d_status="error"; d_ms="0"
            fi
            emit_event "dispatch_end" "\"intent_id\":\"$iid\",\"agent_id\":\"$agent_id\",\"status\":\"$d_status\",\"ms\":$d_ms"
        done < <(python3 -c "
import json,sys
for n in json.loads(sys.argv[1]):
    print('\t'.join([str(n['id']), n.get('agent','inner_all')]))
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
