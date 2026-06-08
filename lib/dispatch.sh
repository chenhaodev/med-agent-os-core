#!/usr/bin/env bash
# Dispatch one sub-intent to one agent adapter.
# Runs the adapter as a subprocess; the adapter writes its result JSON to RUNDIR.
# This function does NOT write to the DB — parent process is the sole DB writer.
#
# Usage: dispatch_intent <node_json> <rundir>
#   node_json — one AST Node object as JSON string
#   rundir    — per-run scratch directory (var/runs/<run_id>/)
#
# Exit 0 always; callers read result from rundir.

dispatch_intent() {
    local node_json="$1"
    local rundir="$2"

    local intent_id mode question agent_id domains_str

    # Extract all node fields in a single python invocation (NUL-delimited so the
    # question field can safely contain newlines from an injected context block).
    {
        IFS= read -r -d '' intent_id
        IFS= read -r -d '' mode
        IFS= read -r -d '' question
        IFS= read -r -d '' agent_id
        IFS= read -r -d '' domains_str
    } < <(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
fields = [
    str(d['id']),
    d.get('mode', 'patient'),
    d.get('question', ''),
    d.get('agent', 'inner_all'),
    ' '.join(d.get('domains', [])),
]
sys.stdout.write('\0'.join(fields) + '\0')
" "$node_json")

    # agent=none means the OS handles this node directly (oob/chitchat/meta)
    if [[ "$agent_id" == "none" ]]; then
        local node_kind
        node_kind=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('kind','oob'))" "$node_json")
        python3 - "$intent_id" "$node_kind" > "$rundir/intent_${intent_id}.result.json" <<'PYEOF'
import json, sys
iid, kind = sys.argv[1], sys.argv[2]
status = "oob" if kind in ("oob", "chitchat") else "error"
print(json.dumps({"id": iid, "status": status, "answer": None,
                  "citations": [], "ms": 0, "exit_code": 0}))
PYEOF
        return 0
    fi

    local adapter_path="$OS_REGISTRY/adapters/${agent_id}.sh"

    if [[ ! -f "$adapter_path" ]]; then
        log_error "dispatch: adapter not found for agent '$agent_id': $adapter_path"
        python3 - "$intent_id" > "$rundir/intent_${intent_id}.result.json" <<'PYEOF'
import json, sys
print(json.dumps({"id": sys.argv[1], "status": "error",
                  "answer": None, "citations": [], "ms": 0,
                  "exit_code": -1, "error": "adapter not found"}))
PYEOF
        return 0
    fi

    export INTENT_ID="$intent_id"
    export INTENT_MODE="$mode"
    export INTENT_DOMAINS="$domains_str"
    export INTENT_QUESTION="$question"
    export RUNDIR="$rundir"

    bash "$adapter_path"
}

# ── bounded_fanout(nodes_json_array, rundir, max_workers) ────────────────────
# Dispatches all nodes with bounded parallelism.
# Waits for all to finish; returns 0.
bounded_fanout() {
    local nodes_json="$1"    # JSON array of Node objects
    local rundir="$2"
    local max_workers="${3:-${OS_MAX_WORKERS:-3}}"

    local node_count
    node_count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$nodes_json")

    local pids=()
    local active=0
    local idx=0

    while [[ $idx -lt $node_count ]]; do
        # wait if at capacity; recompute active from live pids to avoid drift
        while [[ $active -ge $max_workers ]]; do
            local new_pids=()
            for pid in ${pids[@]+"${pids[@]}"}; do
                if kill -0 "$pid" 2>/dev/null; then
                    new_pids+=("$pid")
                fi
            done
            pids=(${new_pids[@]+"${new_pids[@]}"})
            active=${#pids[@]}
            [[ $active -ge $max_workers ]] && sleep 0.1
        done

        local node_json
        node_json=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(json.dumps(d[$idx]))" "$nodes_json")

        dispatch_intent "$node_json" "$rundir" &
        pids+=($!)
        active=${#pids[@]}
        (( idx++ )) || true
    done

    # wait for all remaining
    for pid in ${pids[@]+"${pids[@]}"}; do
        wait "$pid" 2>/dev/null || true
    done
}
