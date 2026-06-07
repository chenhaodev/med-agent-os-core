PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA foreign_keys=ON;
PRAGMA busy_timeout=5000;

-- ── sessions ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sessions (
    session_id   TEXT PRIMARY KEY,
    title        TEXT,
    default_mode TEXT NOT NULL DEFAULT 'patient' CHECK (default_mode IN ('patient','doctor')),
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
);

-- ── messages — raw conversation stream (UI replay + history window) ───────────
CREATE TABLE IF NOT EXISTS messages (
    message_id  TEXT PRIMARY KEY,
    session_id  TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    turn_index  INTEGER NOT NULL,
    role        TEXT NOT NULL CHECK (role IN ('user','assistant')),
    mode        TEXT NOT NULL CHECK (mode IN ('patient','doctor')),
    content     TEXT NOT NULL,
    created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, turn_index);

-- ── turns — orchestration audit per user message ─────────────────────────────
CREATE TABLE IF NOT EXISTS turns (
    turn_id       TEXT PRIMARY KEY,
    session_id    TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    turn_index    INTEGER NOT NULL,
    user_message  TEXT NOT NULL,
    prefilter     TEXT,                       -- 'pass' | 'oob' | 'chitchat'
    decompose_json TEXT,                      -- full AST JSON as produced
    reply         TEXT,
    status        TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('ok','partial','error','pending')),
    total_ms      INTEGER,
    created_at    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_turns_session ON turns(session_id, turn_index);

-- ── agent_calls — fan-out dispatch audit (one row per sub-intent) ─────────────
CREATE TABLE IF NOT EXISTS agent_calls (
    call_id    TEXT PRIMARY KEY,
    turn_id    TEXT NOT NULL REFERENCES turns(turn_id) ON DELETE CASCADE,
    intent_id  TEXT NOT NULL,
    agent_id   TEXT NOT NULL,
    mode       TEXT NOT NULL,
    domains    TEXT NOT NULL,               -- space-separated tags passed to adapter
    question   TEXT NOT NULL,
    answer     TEXT,
    status     TEXT NOT NULL CHECK (status IN ('ok','oob','error','timeout')),
    exit_code  INTEGER,
    ms         INTEGER,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_calls_turn ON agent_calls(turn_id);

-- ── profile_facts — shared patient memory (structured source of truth) ────────
CREATE TABLE IF NOT EXISTS profile_facts (
    fact_id     TEXT PRIMARY KEY,
    session_id  TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    subject     TEXT NOT NULL,              -- e.g. '爸爸', '本人'
    attr        TEXT NOT NULL CHECK (attr IN ('disease','medication','allergy','age','note')),
    value       TEXT NOT NULL,
    confidence  REAL NOT NULL DEFAULT 1.0,
    source_turn TEXT REFERENCES turns(turn_id),
    status      TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','retracted')),
    created_at  TEXT NOT NULL,
    UNIQUE(session_id, subject, attr, value)
);
CREATE INDEX IF NOT EXISTS idx_profile_facts_session ON profile_facts(session_id, status);

-- ── response_cache — hash-keyed answer cache; invalidated by knowledge_version ─
CREATE TABLE IF NOT EXISTS response_cache (
    cache_key         TEXT PRIMARY KEY,     -- sha256(question||mode||domains||model)
    agent_id          TEXT NOT NULL,
    mode              TEXT NOT NULL,
    domains           TEXT NOT NULL,
    question          TEXT NOT NULL,
    answer            TEXT NOT NULL,
    citations         TEXT,                 -- JSON array
    model             TEXT NOT NULL,
    knowledge_version INTEGER NOT NULL,
    hit_count         INTEGER NOT NULL DEFAULT 0,
    created_at        TEXT NOT NULL,
    last_hit_at       TEXT NOT NULL
);
