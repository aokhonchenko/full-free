#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AI_ROOT="${AI_ROOT:-$SCRIPT_DIR}"
PROJECT_ENV_FILE="${PROJECT_ENV_FILE:-$SCRIPT_DIR/.env}"
AI_HOME="${AI_HOME:-$SCRIPT_DIR/ai_home}"
SYSTEM_PROMPT_FILE="${SYSTEM_PROMPT_FILE:-$SCRIPT_DIR/SYSTEM_PROMPT.md}"
STATE_DIR="$AI_HOME/state"
CONFIG_FILE="$AI_HOME/config.sh"
COMPATIBLE_ENV_FILE="${COMPATIBLE_ENV_FILE:-$PROJECT_ENV_FILE}"
AGENT_DIR="${AGENT_DIR:-$SCRIPT_DIR/ai_home/projects/agent}"
SESSIONS_DIR="$SCRIPT_DIR/.sessions"
SESSION_COUNTER_FILE="$STATE_DIR/session_counter.txt"
SESSION_INTERVAL_MINUTES=15
SESSION_TIMEOUT_SECONDS=$((SESSION_INTERVAL_MINUTES * 2 * 60))
AGENT_MAX_STEPS="${AGENT_MAX_STEPS:-20}"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    SESSION_TIMEOUT_SECONDS=${SESSION_TIMEOUT_SECONDS:-$((SESSION_INTERVAL_MINUTES * 2 * 60))}
fi

if [ -f "$PROJECT_ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$PROJECT_ENV_FILE"
    set +a
fi

mkdir -p "$STATE_DIR" "$AI_HOME/knowledge" "$AI_HOME/projects" "$AI_HOME/tools" "$SESSIONS_DIR"

if [ ! -f "$SESSION_COUNTER_FILE" ]; then
    echo "0" > "$SESSION_COUNTER_FILE"
fi

CURRENT_SESSION=$(cat "$SESSION_COUNTER_FILE" 2>/dev/null || echo "0")
NEXT_SESSION=$((CURRENT_SESSION + 1))
METHOD="${1:-compatible}"

build_prompt() {
    echo "=== SYSTEM PROMPT ==="
    cat "$SYSTEM_PROMPT_FILE"
    echo ""
    echo "=== SESSION INFO ==="
    echo "Session number: $NEXT_SESSION"
    echo ""
    echo "=== CURRENT STATE ==="
    echo ""
    echo "--- session_counter.txt ---"
    echo "$CURRENT_SESSION"
    echo ""
    for name in current_plan.md last_session.md external_messages.md; do
        echo "--- $name ---"
        cat "$STATE_DIR/$name" 2>/dev/null || echo "(empty)"
        echo ""
    done
    echo "=== START ==="
    echo "You woke up. This is session #$NEXT_SESSION."
}

archive_thoughts() {
    if [ ! -f "$SESSIONS_DIR/thought.md" ]; then
        echo "thought.md not found: $SESSIONS_DIR/thought.md" >&2
        return 1
    fi
    echo "Moving thought.md to .sessions/thoughts-$NEXT_SESSION.md"
    mv -f "$SESSIONS_DIR/thought.md" "$SESSIONS_DIR/thoughts-$NEXT_SESSION.md"
}

archive_last_session() {
    if [ ! -f "$STATE_DIR/last_session.md" ]; then
        echo "last_session.md not found: $STATE_DIR/last_session.md" >&2
        return 1
    fi
    echo "Saving last_session.md to .sessions/session-$NEXT_SESSION.md"
    cp -f "$STATE_DIR/last_session.md" "$SESSIONS_DIR/session-$NEXT_SESSION.md"
}

run_with_agent() {
    local python_bin="${PYTHON:-python3}"
    if ! command -v "$python_bin" >/dev/null 2>&1; then
        python_bin="python"
    fi
    if ! command -v "$python_bin" >/dev/null 2>&1; then
        echo "Command not found: python/python3" >&2
        return 1
    fi

    local prompt_file
    prompt_file=$(mktemp)
    build_prompt > "$prompt_file"

    echo "Using local Python agent: $AGENT_DIR"
    (
        cd "$SCRIPT_DIR"
        timeout "${SESSION_TIMEOUT_SECONDS}s" "$python_bin" -B "$AGENT_DIR" \
            --message-file "$prompt_file" \
            --thought-file "$SESSIONS_DIR/thought.md" \
            --max-steps "$AGENT_MAX_STEPS"
    )
    local exit_code=$?

    rm -f "$prompt_file"
    if [ "$exit_code" -eq 0 ]; then
        echo "$NEXT_SESSION" > "$SESSION_COUNTER_FILE"
    elif [ "$exit_code" -eq 124 ]; then
        echo "Session exceeded timeout: ${SESSION_TIMEOUT_SECONDS}s" >&2
    fi
    return "$exit_code"
}

run_with_qwen_cli() {
    local prompt
    prompt=$(build_prompt)
    timeout "${SESSION_TIMEOUT_SECONDS}s" qwen -p "$prompt"
}

run_with_direct_api() {
    local prompt access_token escaped_prompt
    prompt=$(build_prompt)
    access_token=$(python3 -c "import json; print(json.load(open('$HOME/.qwen/oauth_creds.json'))['access_token'])")
    escaped_prompt=$(printf '%s' "$prompt" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
    timeout "${SESSION_TIMEOUT_SECONDS}s" curl -s -X POST "https://portal.qwen.ai/v1/chat/completions" \
      -H "Authorization: Bearer $access_token" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"qwen3-coder-plus\",\"messages\":[{\"role\":\"system\",\"content\":\"Ты автономный ИИ-агент.\"},{\"role\":\"user\",\"content\":$escaped_prompt}],\"max_tokens\":4096}" \
      | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('choices',[{}])[0].get('message',{}).get('content','ОШИБКА: нет ответа'))"
}

echo "Starting AI session #$NEXT_SESSION"
echo "Run method: $METHOD (timeout: ${SESSION_TIMEOUT_SECONDS}s)"

case "$METHOD" in
    compatible|openrouter|live-swe-agent)
        run_with_agent
        ;;
    qwen)
        run_with_qwen_cli
        ;;
    api)
        run_with_direct_api
        ;;
    *)
        echo "Unknown method: $METHOD" >&2
        echo "Usage: $0 [compatible|openrouter|qwen|live-swe-agent|api]" >&2
        exit 1
        ;;
esac
run_exit=$?

if [ "$run_exit" -eq 0 ]; then
    archive_thoughts
    archive_last_session
fi
exit "$run_exit"