#!/usr/bin/env bash
# Unit tests for lib/unwrap.sh — zero API, pure function tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

source "$BASE_DIR/lib/common.sh"
source "$BASE_DIR/lib/unwrap.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS  $label"
        (( PASS++ )) || true
    else
        echo "  FAIL  $label"
        echo "        expected: $(echo "$expected" | head -3)"
        echo "        actual:   $(echo "$actual"   | head -3)"
        (( FAIL++ )) || true
    fi
}

FENCE="═══════════════════════════════════════════════════════"

echo "=== unwrap.sh unit tests ==="

# 1. normal answer
t1=$(unwrap $'\n'"$FENCE"$'\n'"高血压患者饮食建议：减盐、低脂。"$'\n'"$FENCE"$'\n')
assert_eq "normal answer — status" "ok" "$(echo "$t1" | head -1)"
assert_eq "normal answer — body" "高血压患者饮食建议：减盐、低脂。" "$(echo "$t1" | tail -n +2)"

# 2. OOB refusal
OOB_TEXT="很抱歉，您的问题超出了本系统依据《西氏内科学精要》的覆盖范围，建议咨询专科医生。"
t2=$(unwrap $'\n'"$FENCE"$'\n'"$OOB_TEXT"$'\n'"$FENCE"$'\n')
assert_eq "oob — status" "oob" "$(echo "$t2" | head -1)"
assert_eq "oob — body preserved" "$OOB_TEXT" "$(echo "$t2" | tail -n +2)"

# 3. empty body between fences
t3=$(unwrap $'\n'"$FENCE"$'\n\n'"$FENCE"$'\n')
assert_eq "empty body — status" "empty" "$(echo "$t3" | head -1)"

# 4. no fence at all
t4=$(unwrap "plain text no fence")
assert_eq "no fence — status" "parse_error" "$(echo "$t4" | head -1)"

# 5. multiline answer
MULTI="第一段内容。

第二段内容。"
t5=$(unwrap $'\n'"$FENCE"$'\n'"$MULTI"$'\n'"$FENCE"$'\n')
assert_eq "multiline — status" "ok" "$(echo "$t5" | head -1)"
assert_eq "multiline — body line1" "第一段内容。" "$(echo "$t5" | sed -n '2p')"

# 6. extra blank lines before first fence
t6=$(unwrap $'\n\n'"$FENCE"$'\n'"答案内容。"$'\n'"$FENCE"$'\n')
assert_eq "leading blanks — status" "ok" "$(echo "$t6" | head -1)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
