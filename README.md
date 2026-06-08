# med-agent-os-core

An orchestration kernel for `med-agent-inner-all` (and future `med-agent-*` siblings) that adds multi-intent decomposition, multi-turn memory, dual patient/doctor mode, and a structured event stream — built entirely with bash + python3 stdlib + sqlite3 + curl.

## What it solves

`med-agent-inner-all` is stateless and single-turn, and its router hard-caps routing at 2 `specialty:disease` tags. This kernel sits above it as a thin OS layer:

| Problem | Solution |
|---|---|
| Single-turn, no memory | SQLite session + profile facts across turns |
| 2-domain tag cap | Decompose into N sub-intents; each calls inner-all with explicit `--domain`, bypassing the router |
| One message → one question | Multi-intent gate + LLM decompose → parallel fan-out |
| No patient/doctor distinction | Dual-mode prompts throughout pipeline |
| `deepseek-chat` deprecation (2026-07-24) | Upgraded to `deepseek-v4-flash` everywhere |

## Architecture

```
os.sh chat --session S --mode M "message"
      │
      ├─ prefilter   (keyword gate — no API; blocks pure chitchat/OOB)
      ├─ context     (sqlite read: sliding history window + profile facts → block)
      ├─ decompose   (gate heuristic → single fast-path OR LLM decompose → AST)
      ├─ dispatch    (bounded parallel fan-out → inner-all adapter per sub-intent)
      ├─ synthesize  (single-intent: pass-through; multi: LLM merge + profile_delta)
      └─ persist     (parent-only single-writer; async after reply delivered)
```

**Single-intent fast-path**: when the decompose gate classifies the message as single-intent, decompose LLM and synthesize LLM are both skipped — the answer passes through directly. Zero extra API calls beyond the one inner-all call. The durable profile block is still prepended to the dispatched question (deterministically, no LLM) so the stateless agent keeps multi-turn memory.

**Decompose gate**: only calls the decompose LLM when multi-intent is suspected (conjunctions 另外/还有/以及…, multiple `？`, or a pronoun with existing context — profile facts or prior history). Otherwise routes as single-intent.

**Bounded fan-out**: `OS_MAX_WORKERS=3` caps parallel inner-all calls to avoid 429 thundering herd.

**Single-writer DB**: child dispatch processes write only to per-run JSON files. The parent is the sole SQLite writer (`persist_turn`), eliminating lock contention.

## Directory structure

```
med-agent-os-core/
├── os.sh                        # Entry point — noun-verb CLI + five-stage pipeline
├── .env / .env.example          # Config (API key, model, tuning knobs)
├── lib/
│   ├── common.sh                # Paths, .env loading, logging, uuid, sha256
│   ├── llm.sh                   # DeepSeek API caller (retry on 429/5xx)
│   ├── events.sh                # NDJSON event emitter (--json mode)
│   ├── prefilter.sh             # Deterministic OOB/chitchat gate (no API)
│   ├── dispatch.sh              # dispatch_intent + bounded_fanout
│   ├── unwrap.sh                # Parse inner-all ═══ fence output
│   └── profile.sh               # Async profile fact extraction (single-intent path)
├── stages/
│   ├── 10_context.sh            # Build context JSON: history window + profile block
│   ├── 20_decompose.sh          # Intent gate + LLM decompose → AST
│   ├── 30_dispatch.sh           # Fan-out to adapters; collect results
│   ├── 40_synthesize.sh         # Fast-path or LLM merge; status (ok/partial/error)
│   └── 50_persist.sh            # Single-transaction DB write (turns/messages/facts)
├── registry/
│   ├── agents.json              # Agent registry
│   ├── inner_all_domains.txt    # Valid specialty:disease tags for inner-all
│   └── adapters/inner_all.sh   # Adapter: env vars → ask.sh call + response cache
├── prompts/
│   ├── decompose_{patient,doctor}.md
│   └── synthesize_{patient,doctor}.md
├── db/
│   ├── schema.sql               # 6 tables: sessions, messages, turns, agent_calls,
│   │                            #           profile_facts, response_cache
│   └── migrate.sh
├── schema/ast.schema.json       # JSON Schema for Request AST + NodeResult
├── eval/
│   ├── scenarios.json           # 12 live scenarios (consumed by run_eval.sh --live)
│   ├── scenarios.yaml           # human-readable reference mirror (not parsed)
│   ├── run_eval.sh              # --mock (zero API, 12 cases) or --live --limit N
│   ├── test_unwrap.sh           # 9 unit tests for unwrap.sh
│   └── mock/                    # Canned adapter + fixtures for --mock mode
└── var/                         # gitignored: os.db, runs/, logs/
```

## Setup

```bash
cp .env.example .env
# edit .env: set DEEPSEEK_API_KEY, verify INNER_ALL_DIR path

bash os.sh db init
```

Requires: bash 3.2+, python3, curl, sqlite3. No external packages.

> **Two `.env` files for live mode.** This kernel's `.env` powers the decompose/synthesize
> LLM calls. The dispatched agent (`med-agent-inner-all`) is a separate project with its
> **own** `.env` — set `DEEPSEEK_API_KEY` there too, or `bin/ask.sh` calls will fail and
> sub-intents return `status:error`. `--mock` eval needs neither key.

## Usage

### Chat

```bash
SID=$(bash os.sh session new --mode patient)
bash os.sh chat --session "$SID" --mode patient "我爸高血压，饮食要注意什么？另外他能喝酒吗？"

# doctor mode
bash os.sh chat --session "$SID" --mode doctor "高血压合并CKD3期，ACEI和ARB哪个首选？"

# preview intent decomposition without dispatching
bash os.sh plan --session "$SID" --mode patient "我爸有高血压、糖尿病、还有痛风，饮食注意和用药禁忌？"

# decompose only, print AST, no dispatch (same as plan, via chat)
bash os.sh chat --session "$SID" --dry-run "高血压、糖尿病饮食注意？"

# skip cache for this call
bash os.sh chat --session "$SID" --no-cache "高血压能喝咖啡吗？"

# structured NDJSON event stream (for ui-core)
bash os.sh chat --session "$SID" --json "..."

# stream synthesis tokens to the terminal
bash os.sh chat --session "$SID" --stream "高血压、糖尿病的饮食和用药注意？"

# use an alternate database
bash os.sh --db /tmp/test.db chat --session "$SID" "..."
```

Global flags (before the subcommand or anywhere): `--json`, `--stream`, `--db PATH`,
`-q/--quiet`, `--verbose`. Use `--` to end flag parsing when a message starts with `-`.

### Session management

```bash
bash os.sh session list
bash os.sh session show "$SID" --turns
bash os.sh session set "$SID" --title "爸爸高血压随访"
bash os.sh session export "$SID"
bash os.sh session rm "$SID"
bash os.sh session purge --before 2026-01-01
```

### Memory (patient profile facts)

```bash
bash os.sh memory list --session "$SID"
bash os.sh memory add  --session "$SID" --subject "爸爸" --attr disease --value "高血压"
bash os.sh memory retract --session "$SID" --id <fact_id>   # soft delete
bash os.sh memory rm      --session "$SID" --id <fact_id>   # hard delete
bash os.sh memory export  --session "$SID"
```

Profile facts are also extracted automatically from each conversation turn (async, after reply is delivered).

### History

```bash
bash os.sh history show --session "$SID"
bash os.sh history show --session "$SID" --turn 2
bash os.sh history replay --session "$SID"
```

### Cache

```bash
bash os.sh cache stats
bash os.sh cache list --limit 20
bash os.sh cache invalidate --agent inner_all
bash os.sh cache clear
```

### Agent registry

```bash
bash os.sh agent list
bash os.sh agent validate
bash os.sh agent test inner_all "高血压患者血压控制目标是多少？"
bash os.sh agent set inner_all --enabled false
```

### Config / DB

```bash
bash os.sh config list
bash os.sh config set OS_MAX_WORKERS 5
bash os.sh config path

bash os.sh db status
bash os.sh db backup --out backup.db
bash os.sh db vacuum
```

### Eval

```bash
bash os.sh eval run --mock            # zero-API, 12 scenarios (functional + contract)
bash os.sh eval run --live --limit 3  # real API, up to 3 of 12 scenarios.json
bash eval/test_unwrap.sh              # 9 unit tests for unwrap.sh
```

## How it bypasses the 2-domain cap

`med-agent-inner-all`'s `router.sh` clips domain tags to 2. The OS avoids this by:

1. Decomposing a multi-disease message into N sub-intents (one per disease/domain group)
2. Passing each sub-intent to the inner-all adapter with an explicit `--domain` flag
3. When `--domain` is provided, `build_prompt.sh` skips the router entirely

Example: "高血压、糖尿病、痛风 饮食和用药禁忌" → 3 parallel sub-intents, each with its own `specialty:disease` tag.

## Coreference resolution

`med-agent-inner-all` is stateless — each call must be self-contained. The decompose LLM prompt explicitly rewrites pronouns using profile context before dispatch:

- Turn 1: "我爸有高血压，今年68岁"
- Turn 2 input: "他能喝咖啡吗？"
- Dispatched: "父亲有高血压，今年68岁，他能喝咖啡吗？"

## Response cache

The inner-all adapter caches answers in SQLite keyed by `sha256(question + mode + domains + model)`, invalidated by `OS_KNOWLEDGE_VERSION`. Cache miss: ~16s (full inner-all round-trip). Cache hit: ~3.6s (bash/python3 startup overhead only).

The cache is **global and content-addressed** (no session column), so identical questions from different sessions share answers. Note that `question` is the *dispatched* question: on the single-intent path it includes the prepended profile block, so the key is context-aware. A consequence is that once a session accumulates profile facts, its subsequent questions re-key away from the anonymous cache entries — this is intentional, since a personalized question must not collide with a generic one (e.g. "他能喝咖啡吗" for a hypertensive father vs. a diabetic mother).

## Adding a new agent

1. Create `registry/adapters/<agent_id>.sh` — receives env vars `INTENT_ID`, `INTENT_MODE`, `INTENT_DOMAINS`, `INTENT_QUESTION`, `RUNDIR`; writes `$RUNDIR/intent_${INTENT_ID}.result.json`
2. Add entry to `registry/agents.json`
3. Add valid domain tags to a `<agent_id>_domains.txt` if needed

No changes to `stages/` required.

## Event stream (NDJSON, for ui-core)

Pass `--json` to get one JSON object per line on stdout:

```jsonc
{"type":"prefilter","data":"pass","ts":"..."}
{"type":"decompose","data":{"ast":{...}},"ts":"..."}
{"type":"dispatch_start","data":"intent_id:i1","ts":"..."}
{"type":"dispatch_end","data":"intent_id:i1","ts":"..."}
{"type":"synthesize_start","data":"","ts":"..."}
{"type":"run_end","data":{"status":"ok","ms":12340},"ts":"..."}
```

Schema defined in `schema/ast.schema.json`.

### Token streaming

Pass `--stream` (or set `OS_STREAM=true`) to stream synthesis tokens. In `--json`
mode each delta is emitted as a `token` event (`{"type":"token","delta":"..."}`); in
plain CLI mode deltas are written incrementally to the terminal. Streaming only applies
to the multi-intent LLM synthesis step (the single-intent fast-path has no LLM call).

## JSON-RPC daemon (`os.sh serve`)

`os.sh serve` is a stdio JSON-RPC 2.0 daemon: one request object per line in, one
response object per line out. Streaming events are delivered as `$/progress`
notifications carrying the same NDJSON event objects.

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"chat","params":{"session_id":"S","mode":"patient","message":"高血压能喝酒吗？"}}' \
  | bash os.sh serve
```

Methods: `initialize` (returns version + capabilities), `plan` (decompose only),
`chat` (full pipeline, progress-streamed), `session` (`verb`: new/list/history —
`new` accepts an optional `session_id`), `memory` (`verb`: get/update), `cancel`
(by request id). Timeout per chat: `OS_SERVE_TIMEOUT` seconds (default 120).

## Out of scope (MVP)

- Other `med-agent-*` agents (only `inner_all` registered; add via adapter)
- AST sequence/DAG execution (grammar supports it, executor not built)
- Cross-session or multi-user concurrency
