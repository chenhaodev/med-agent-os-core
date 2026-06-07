#!/usr/bin/env bash
# Deterministic OS-level prefilter — no API calls.
# Classifies message as: pass | oob | chitchat
# Outputs: one word on stdout.

# ── chitchat keywords ─────────────────────────────────────────────────────────
_CHITCHAT_PATTERNS=(
    "你好" "您好" "hi" "hello" "早上好" "晚上好" "谢谢" "感谢" "再见" "拜拜"
    "你是谁" "你叫什么" "你能做什么" "帮助" "怎么用" "使用说明"
)

# ── non-medical clear OOB patterns ───────────────────────────────────────────
_OOB_PATTERNS=(
    "股票" "基金" "投资" "炒股" "天气" "新闻" "政治" "游戏" "娱乐"
    "写作文" "写代码" "翻译"
)

# ── medical signal keywords (any hit → let pass to decompose) ─────────────────
_MEDICAL_SIGNALS=(
    "血压" "高血压" "低血压" "血糖" "糖尿病" "血脂" "心脏" "心衰" "心梗"
    "肾" "肝" "肺" "胃" "肠" "脑" "神经" "癌" "肿瘤" "炎" "感染" "发烧"
    "药" "用药" "剂量" "治疗" "手术" "检查" "化验" "诊断" "症状" "医生"
    "饮食" "忌口" "能吃" "能喝" "禁忌" "副作用" "过敏" "并发症" "慢性"
    "痛风" "哮喘" "冠心病" "中风" "卒中" "帕金森" "阿尔茨海默" "骨质疏松"
    "甲状腺" "痛风" "贫血" "白血病" "乙肝" "丙肝" "艾滋"
)

prefilter_message() {
    local msg="$1"

    for pattern in "${_CHITCHAT_PATTERNS[@]}"; do
        if [[ "$msg" == *"$pattern"* ]]; then
            echo "chitchat"
            return 0
        fi
    done

    local has_oob=false
    for pattern in "${_OOB_PATTERNS[@]}"; do
        if [[ "$msg" == *"$pattern"* ]]; then
            has_oob=true
            break
        fi
    done

    if [[ "$has_oob" == "true" ]]; then
        # Only block if no medical signal present — mixed messages go to decompose
        for signal in "${_MEDICAL_SIGNALS[@]}"; do
            if [[ "$msg" == *"$signal"* ]]; then
                echo "pass"
                return 0
            fi
        done
        echo "oob"
        return 0
    fi

    echo "pass"
}

# ── prefilter_reply — stock replies for non-pass results ─────────────────────
prefilter_reply() {
    local result="$1"
    local mode="${2:-patient}"
    case "$result" in
        chitchat)
            echo "您好！我是医学信息助手，可以回答内科相关问题。请告诉我您想了解什么？"
            ;;
        oob)
            echo "抱歉，该问题不在医学信息服务范围内。我专注于内科疾病相关问题，如有医学方面的疑问欢迎继续咨询。"
            ;;
    esac
}
