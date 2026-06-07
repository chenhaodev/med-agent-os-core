#!/usr/bin/env bash
# Parse the ═══ fence format produced by inner-all's ask.sh.
# ask.sh wraps both normal answers (line 219-223) and OOB refusals (line 92-97)
# inside two lines of ═══ box-drawing characters.
#
# Outputs to stdout: two lines
#   Line 1: status — ok | oob | empty | parse_error
#   Line 2: extracted answer text (may be multi-line; rest of output)
#
# Exit 0 always; callers check line 1 for status.

# ── OOB marker text written by ask.sh:88 ─────────────────────────────────────
_OOB_MARKER="超出了本系统依据《西氏内科学精要》的覆盖范围"
_FENCE_CHAR="═"   # U+2550 BOX DRAWINGS DOUBLE HORIZONTAL

# ── unwrap(raw_stdout) ────────────────────────────────────────────────────────
# Call as: unwrap "$raw_stdout_content"
# Prints status on line 1, then answer text.
unwrap() {
    local raw="$1"
    python3 - "$raw" "$_FENCE_CHAR" "$_OOB_MARKER" <<'PYEOF'
import sys

raw     = sys.argv[1]
fence   = sys.argv[2]    # ═ (U+2550)
oob_mrk = sys.argv[3]

lines = raw.splitlines()

# Find fence lines (lines that consist solely of fence chars)
fence_idxs = [i for i, ln in enumerate(lines) if ln.strip() and all(c == fence for c in ln.strip())]

if len(fence_idxs) < 2:
    print("parse_error")
    print("")
    sys.exit(0)

start = fence_idxs[0] + 1
end   = fence_idxs[1]
body  = "\n".join(lines[start:end]).strip()

if not body:
    print("empty")
    print("")
    sys.exit(0)

if oob_mrk in body:
    print("oob")
else:
    print("ok")
print(body)
PYEOF
}

# ── unwrap_file(path) — unwrap from a file ────────────────────────────────────
unwrap_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "parse_error"
        echo "file not found: $path"
        return 0
    fi
    unwrap "$(cat "$path")"
}
