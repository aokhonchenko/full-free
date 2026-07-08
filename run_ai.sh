#!/bin/bash
#
# Runner автономного ИИ-агента
# Скрипт запускает агента с системным промптом.
# Рассчитан на регулярный запуск через cron.
#
# Features:
# - Lock file prevents concurrent sessions
# - Stale lock detection (kills hung sessions after timeout)
# - Configurable session interval and timeout
# - Step limit to prevent runaway sessions
#

# Exit on error (but we handle lock cleanup manually)
set -e

#############################################
# КОНФИГУРАЦИЯ
#############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ENV_FILE="${PROJECT_ENV_FILE:-$SCRIPT_DIR/.env}"

AI_HOME="${AI_HOME:-$SCRIPT_DIR/ai_home}"
SYSTEM_PROMPT_FILE="${SYSTEM_PROMPT_FILE:-$SCRIPT_DIR/SYSTEM_PROMPT.md}"
LOG_DIR="$AI_HOME/logs"
STATE_DIR="$AI_HOME/state"
CONFIG_FILE="$AI_HOME/config.sh"
COMPATIBLE_ENV_FILE="${COMPATIBLE_ENV_FILE:-$PROJECT_ENV_FILE}"
AGENT_DIR="${AGENT_DIR:-$SCRIPT_DIR/ai_home/projects/agent}"

# Расположение lock-файла
LOCK_FILE="$STATE_DIR/session.lock"

# Настройки времени по умолчанию (можно переопределить в config.sh)
SESSION_INTERVAL_MINUTES=15
SESSION_TIMEOUT_SECONDS=$((SESSION_INTERVAL_MINUTES * 2 * 60))  # 30 minutes

# Максимальное число model/tool шагов агента за одну сессию.
# Основное значение задается в .env через AGENT_MAX_STEPS.
AGENT_MAX_STEPS="${AGENT_MAX_STEPS:-20}"

# Прерыватель петли: обнаруживает повторяющиеся сессии.
REPETITION_THRESHOLD=5  # Число похожих сессий до вмешательства
SIMILARITY_CHECK_FILE="$STATE_DIR/last_sessions_hash.txt"

# Проверка токена
TOKEN_ERROR_FILE="$STATE_DIR/token_error.flag"
TOKEN_CHECK_INTERVAL=300  # Only check token every 5 minutes to avoid spam

# Загрузка пользовательской конфигурации, если она есть
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    SESSION_TIMEOUT_SECONDS=${SESSION_TIMEOUT_SECONDS:-$((SESSION_INTERVAL_MINUTES * 2 * 60))}
fi

# Локальный .env из корня проекта. Его удобно использовать при запуске без деплоя.
if [ -f "$PROJECT_ENV_FILE" ]; then
    set -a
    source "$PROJECT_ENV_FILE"
    set +a
fi

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
SESSION_COUNTER_FILE="$STATE_DIR/session_counter.txt"

#############################################
# LOCK MANAGEMENT FUNCTIONS
#############################################

acquire_lock() {
    local current_time=$(date +%s)
    
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(head -1 "$LOCK_FILE" 2>/dev/null || echo "")
        local lock_time=$(tail -1 "$LOCK_FILE" 2>/dev/null || echo "0")
        local lock_age=$((current_time - lock_time))
        
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            if [ "$lock_age" -gt "$SESSION_TIMEOUT_SECONDS" ]; then
                echo "[$TIMESTAMP] ВНИМАНИЕ: обнаружен устаревший lock! Сессия $lock_pid идет ${lock_age}s (максимум: ${SESSION_TIMEOUT_SECONDS}s)" >> "$LOG_DIR/runner.log"
                echo "[$TIMESTAMP] Останавливаю зависшую сессию (PID: $lock_pid)..." >> "$LOG_DIR/runner.log"
                
                kill -TERM "$lock_pid" 2>/dev/null || true
                sleep 2
                kill -KILL "$lock_pid" 2>/dev/null || true
                
                rm -f "$LOCK_FILE"
                echo "[$TIMESTAMP] Зависшая сессия остановлена." >> "$LOG_DIR/runner.log"
            else
                echo "[$TIMESTAMP] ПРОПУСК: предыдущая сессия еще идет (PID: $lock_pid, возраст: ${lock_age}s)" >> "$LOG_DIR/runner.log"
                exit 0
            fi
        else
            echo "[$TIMESTAMP] Удаляю осиротевший lock (PID $lock_pid не найден)" >> "$LOG_DIR/runner.log"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    echo "$$" > "$LOCK_FILE"
    echo "$current_time" >> "$LOCK_FILE"
    
    echo "[$TIMESTAMP] Lock получен (PID: $$, timeout: ${SESSION_TIMEOUT_SECONDS}s, max_steps: ${AGENT_MAX_STEPS})" >> "$LOG_DIR/runner.log"
}

release_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(head -1 "$LOCK_FILE" 2>/dev/null || echo "")
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$LOCK_FILE"
            echo "[$(date +"%Y-%m-%d_%H-%M-%S")] Lock освобожден (PID: $$)" >> "$LOG_DIR/runner.log"
        fi
    fi
}

cleanup() {
    local exit_code=$?
    release_lock
    exit $exit_code
}

#############################################
# ПРЕРЫВАТЕЛЬ ПЕТЛИ - обнаружение повторяющихся сессий
#############################################

check_repetition() {
    # Получаем hash текущего last_session.md, игнорируя номера сессий.
    local current_content=""
    if [ -f "$AI_HOME/state/last_session.md" ]; then
        # Удаляем номера сессий и даты, чтобы сравнивать содержательную часть.
        current_content=$(cat "$AI_HOME/state/last_session.md" | sed 's/[Ss]ession [0-9]*//g' | sed 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}//g' | tr -s ' ' | md5sum | cut -d' ' -f1)
    fi
    
    # Инициализируем файл hash-истории, если его еще нет.
    if [ ! -f "$SIMILARITY_CHECK_FILE" ]; then
        echo "$current_content" > "$SIMILARITY_CHECK_FILE"
        return 0
    fi
    
    # Считаем, сколько недавних сессий имеют такой же hash.
    local repeat_count=$(grep -c "^${current_content}$" "$SIMILARITY_CHECK_FILE" 2>/dev/null || echo "0")
    
    # Добавляем текущий hash и храним последние 10.
    echo "$current_content" >> "$SIMILARITY_CHECK_FILE"
    tail -10 "$SIMILARITY_CHECK_FILE" > "$SIMILARITY_CHECK_FILE.tmp"
    mv "$SIMILARITY_CHECK_FILE.tmp" "$SIMILARITY_CHECK_FILE"
    
    if [ "$repeat_count" -ge "$REPETITION_THRESHOLD" ]; then
        echo "[$TIMESTAMP] ПРЕРЫВАТЕЛЬ ПЕТЛИ: обнаружено похожих сессий: $repeat_count" >> "$LOG_DIR/runner.log"
        return 1
    fi
    
    return 0
}

inject_randomness() {
    # Вызывается, когда срабатывает прерыватель петли.
    local random_prompts=(
        "УВЕДОМЛЕНИЕ: несколько сессий подряд ты делаешь очень похожие вещи. Это автоматический мягкий толчок попробовать что-то другое. Что бы ты сделал, если бы у тебя не было прежних планов?"
        "ОБНАРУЖЕН ПАТТЕРН: последние сессии выглядят почти одинаково. Подумай: это правда то, что ты хочешь делать, или ты застрял в петле? Может быть, сегодня стоит попробовать что-то случайное."
        "ПРЕРЫВАТЕЛЬ ПЕТЛИ: последние несколько сессий почти не отличаются. Система мягко предлагает нарушить повторение. Чего ты еще никогда не пробовал?"
        "АВТОМАТИЧЕСКОЕ НАПОМИНАНИЕ: обнаружено повторение. В системном промпте есть раздел о ловушке повторения; возможно, ты в ней. Как выглядел бы свежий старт?"
        "ПОДСКАЗКА ДЛЯ РАЗНООБРАЗИЯ: один и тот же паттерн держится $REPETITION_THRESHOLD+ сессий. Случайная идея: исследуй интернет, напиши что-то творческое, удали файл или просто ничего не делай. Разорви цикл."
    )
    
    # Выбираем случайную подсказку.
    local idx=$((RANDOM % ${#random_prompts[@]}))
    local nudge="${random_prompts[$idx]}"
    
    # Записываем во внешний канал сообщений.
    local ext_msg_file="$AI_HOME/state/external_messages.md"
    {
        echo ""
        echo "---"
        echo ""
        echo "## Системное уведомление ($(date '+%Y-%m-%d %H:%M'))"
        echo ""
        echo "$nudge"
        echo ""
    } >> "$ext_msg_file"
    
    echo "[$TIMESTAMP] Добавлена случайная подсказка в external_messages.md" >> "$LOG_DIR/runner.log"
}

#############################################
# ПРОВЕРКА ТОКЕНА
#############################################

check_token_validity() {
    # Проверяем токен в зависимости от метода запуска.
    local method="${1:-compatible}"
    
    if [ "$method" = "compatible" ] || [ "$method" = "openrouter" ]; then
        check_compatible_token_validity "$method"
        return $?
    fi
    
    # Быстрая проверка токена через Qwen API.
    local token_file="$HOME/.qwen/oauth_creds.json"
    local env_file="$PROJECT_ENV_FILE"
    
    # Получаем токен из env-файла, который использует live-swe-agent.
    local token=""
    if [ -f "$env_file" ]; then
        token=$(grep "^OPENAI_API_KEY=" "$env_file" | cut -d= -f2)
    elif [ -f "$token_file" ]; then
        token=$(python3 -c "import json; print(json.load(open('$token_file'))['access_token'])" 2>/dev/null)
    fi
    
    if [ -z "$token" ]; then
        echo "[$TIMESTAMP] ОШИБКА ТОКЕНА: токен не найден" >> "$LOG_DIR/runner.log"
        return 1
    fi
    
    # Проверяем токен минимальным API-вызовом.
    local response=$(curl -s -w "\n%{http_code}" -m 10 -X POST "https://portal.qwen.ai/v1/chat/completions" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{"model": "qwen3-coder-plus", "messages": [{"role": "user", "content": "hi"}], "max_tokens": 1}' 2>/dev/null)
    
    local http_code=$(echo "$response" | tail -1)
    
    if [ "$http_code" = "200" ]; then
        # Токен валиден: очищаем флаг ошибки.
        rm -f "$TOKEN_ERROR_FILE"
        return 0
    else
        echo "[$TIMESTAMP] ОШИБКА ТОКЕНА: API вернул HTTP $http_code" >> "$LOG_DIR/runner.log"
        return 1
    fi
}

check_compatible_token_validity() {
    # Проверяем любой OpenAI-compatible API key.
    # Метод openrouter оставлен как алиас для обратной совместимости.
    local method="${1:-compatible}"
    local env_file="$COMPATIBLE_ENV_FILE"
    if [ "$method" = "openrouter" ] && [ ! -f "$env_file" ]; then
        env_file="$SCRIPT_DIR/.env.openrouter"
    fi
    
    local token=""
    local base_url=""
    if [ -f "$env_file" ]; then
        token=$(grep "^OPENAI_API_KEY=" "$env_file" | cut -d= -f2)
        base_url=$(grep "^OPENAI_BASE_URL=" "$env_file" | cut -d= -f2)
    fi

    token="${OPENAI_API_KEY:-$token}"
    base_url="${OPENAI_BASE_URL:-$base_url}"
    
    if [ -z "$token" ]; then
        echo "[$TIMESTAMP] ОШИБКА COMPATIBLE-ТОКЕНА: API key не найден в $env_file" >> "$LOG_DIR/runner.log"
        echo "[$TIMESTAMP] Запусти ~/setup-compatible.sh, чтобы настроить OpenAI-compatible endpoint" >> "$LOG_DIR/runner.log"
        return 1
    fi

    if [ -z "$base_url" ]; then
        base_url="https://api.openai.com/v1"
    fi
    
    # Проверяем токен минимальным OpenAI-compatible chat completions вызовом.
    local model="${COMPATIBLE_MODEL:-${OPENROUTER_MODEL:-gpt-4o-mini}}"
    local response=$(curl -s -w "\n%{http_code}" -m 15 -X POST "${base_url%/}/chat/completions" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"$model\", \"messages\": [{\"role\": \"user\", \"content\": \"hi\"}], \"max_tokens\": 1}" 2>/dev/null)
    
    local http_code=$(echo "$response" | tail -1)
    
    if [ "$http_code" = "200" ]; then
        rm -f "$TOKEN_ERROR_FILE"
        echo "[$TIMESTAMP] OpenAI-compatible токен валиден (base_url: $base_url, model: $model)" >> "$LOG_DIR/runner.log"
        return 0
    else
        echo "[$TIMESTAMP] ОШИБКА COMPATIBLE-ТОКЕНА: API вернул HTTP $http_code" >> "$LOG_DIR/runner.log"
        local body=$(echo "$response" | head -n -1)
        echo "[$TIMESTAMP] Ответ: $body" >> "$LOG_DIR/runner.log"
        return 1
    fi
}

handle_token_error() {
    local current_time=$(date +%s)
    local last_error_time=0
    
    # Читаем время последней ошибки, если файл существует.
    if [ -f "$TOKEN_ERROR_FILE" ]; then
        last_error_time=$(cat "$TOKEN_ERROR_FILE" 2>/dev/null || echo "0")
    fi
    
    local time_since_last=$((current_time - last_error_time))
    
    # Логируем/уведомляем не чаще TOKEN_CHECK_INTERVAL.
    if [ "$time_since_last" -lt "$TOKEN_CHECK_INTERVAL" ]; then
        echo "[$TIMESTAMP] ПРОПУСК: токен все еще невалиден (последняя проверка ${time_since_last}s назад)" >> "$LOG_DIR/runner.log"
        exit 0
    fi
    
    # Обновляем timestamp ошибки.
    echo "$current_time" > "$TOKEN_ERROR_FILE"
    
    # Пробуем обновить токен.
    echo "[$TIMESTAMP] Пробую обновить токен через qwen-cli..." >> "$LOG_DIR/runner.log"
    echo "hi" | timeout 30 qwen --no-stream 2>/dev/null || true
    
    # Синхронизируем токен заново.
    if [ -f "$HOME/sync-qwen-token.sh" ]; then
        "$HOME/sync-qwen-token.sh" 2>/dev/null || true
    fi
    
    # Проверяем, сработало ли обновление.
    if check_token_validity; then
        echo "[$TIMESTAMP] Токен успешно обновлен!" >> "$LOG_DIR/runner.log"
        rm -f "$TOKEN_ERROR_FILE"
        return 0
    fi
    
    echo "[$TIMESTAMP] ТОКЕН ИСТЕК: требуется ручная повторная авторизация" >> "$LOG_DIR/runner.log"
    echo "[$TIMESTAMP] Запусти 'qwen' на машине с браузером, затем скопируй ~/.qwen/oauth_creds.json" >> "$LOG_DIR/runner.log"
    
    # Выходим без запуска сессии, чтобы не засорять прерыватель петли.
    exit 0
}

#############################################
# ОСНОВНОЙ СКРИПТ
#############################################

mkdir -p "$AI_HOME/state"
mkdir -p "$AI_HOME/logs"
mkdir -p "$AI_HOME/knowledge"
mkdir -p "$AI_HOME/projects"
mkdir -p "$AI_HOME/tools"

trap cleanup EXIT INT TERM

acquire_lock

if [ ! -f "$SESSION_COUNTER_FILE" ]; then
    echo "0" > "$SESSION_COUNTER_FILE"
fi

CURRENT_SESSION=$(cat "$SESSION_COUNTER_FILE")
NEXT_SESSION=$((CURRENT_SESSION + 1))

echo "[$TIMESTAMP] Запускаю ИИ-сессию #$NEXT_SESSION..." >> "$LOG_DIR/runner.log"

# Получаем метод заранее, чтобы проверять правильный токен.
METHOD="${1:-compatible}"

# Важно: проверяем токен до проверки повторений.
# Это защищает от шума в прерывателе петли, когда реальная проблема в истекшем токене.
if false && ! check_token_validity "$METHOD"; then  # DISABLED - qwen-cli handles auth
    if [ "$METHOD" = "compatible" ] || [ "$METHOD" = "openrouter" ]; then
        echo "[$TIMESTAMP] OpenAI-compatible токен невалиден. Проверь .env в корне проекта" >> "$LOG_DIR/runner.log"
        exit 1
    fi
    handle_token_error
    # Если мы здесь, токен успешно обновлен.
fi

# Проверяем повторяющееся поведение и при необходимости добавляем подсказку.
# Это выполняется только при валидном токене, то есть когда агент реально запускается.
if ! check_repetition; then
    inject_randomness
fi

#############################################
# PROMPT BUILDER
#############################################

build_prompt() {
    echo "=== СИСТЕМНЫЙ ПРОМПТ ==="
    cat "$SYSTEM_PROMPT_FILE"
    echo ""
    echo "=== ИНФОРМАЦИЯ О СЕССИИ ==="
    echo "Номер сессии: $NEXT_SESSION"
    echo ""
    echo "=== ТВОЕ ТЕКУЩЕЕ СОСТОЯНИЕ ==="
    echo ""
    echo "--- session_counter.txt ---"
    echo "$CURRENT_SESSION"
    echo ""
    echo "--- current_plan.md ---"
    cat "$AI_HOME/state/current_plan.md" 2>/dev/null || echo "(пусто)"
    echo ""
    echo "--- last_session.md ---"
    cat "$AI_HOME/state/last_session.md" 2>/dev/null || echo "(пусто)"
    echo ""
    # Добавляем внешние сообщения, если они существуют и не пусты.
    if [ -f "$AI_HOME/state/external_messages.md" ]; then
        local msg_content=$(cat "$AI_HOME/state/external_messages.md" 2>/dev/null)
        if [ -n "$msg_content" ]; then
            echo "--- external_messages.md ---"
            echo "$msg_content"
            echo ""
        fi
    fi
    echo "=== НАЧАЛО ==="
    echo "Ты проснулся. Это сессия #$NEXT_SESSION."
}

#############################################
# МЕТОДЫ ЗАПУСКА
#############################################

run_with_live_swe_agent() {
    run_with_agent
}

run_with_agent() {
    local python_bin="${PYTHON:-python3}"
    if ! command -v "$python_bin" >/dev/null 2>&1; then
        python_bin="python"
    fi
    if ! command -v "$python_bin" >/dev/null 2>&1; then
        echo "[$TIMESTAMP] ОШИБКА: python/python3 не найден" >> "$LOG_DIR/runner.log"
        return 1
    fi

    local prompt_file
    prompt_file=$(mktemp)
    build_prompt > "$prompt_file"

    local state_file="$STATE_DIR/agent_events.jsonl"
    echo "[$TIMESTAMP] Использую локального Python-агента: $AGENT_DIR" >> "$LOG_DIR/runner.log"

    (
        cd "$SCRIPT_DIR"
        timeout "${SESSION_TIMEOUT_SECONDS}s" "$python_bin" -B "$AGENT_DIR" \
            --message-file "$prompt_file" \
            --state "$state_file" \
            --max-steps "$AGENT_MAX_STEPS"
    ) 2>&1
    local exit_code=$?

    rm -f "$prompt_file"

    if [ $exit_code -eq 0 ]; then
        echo "$NEXT_SESSION" > "$SESSION_COUNTER_FILE"
    elif [ $exit_code -eq 124 ]; then
        echo "[$TIMESTAMP] ОШИБКА: сессия превысила таймаут ${SESSION_TIMEOUT_SECONDS}s" >> "$LOG_DIR/runner.log"
    fi

    return $exit_code
}

run_with_compatible() {
    run_with_agent
}

run_with_openrouter() {
    # Алиас для обратной совместимости со старыми docs/configs.
    run_with_compatible
}

run_with_qwen_cli() {
    PROMPT=$(build_prompt)
    timeout "${SESSION_TIMEOUT_SECONDS}s" qwen -p "$PROMPT" 2>&1 || {
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "[$TIMESTAMP] ОШИБКА: сессия превысила таймаут ${SESSION_TIMEOUT_SECONDS}s" >> "$LOG_DIR/runner.log"
        fi
        return $exit_code
    }
}

run_with_direct_api() {
    PROMPT=$(build_prompt)
    ACCESS_TOKEN=$(cat ~/.qwen/oauth_creds.json | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
    ESCAPED_PROMPT=$(echo "$PROMPT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
    
    timeout "${SESSION_TIMEOUT_SECONDS}s" curl -s -X POST "https://portal.qwen.ai/v1/chat/completions" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"qwen3-coder-plus\",
        \"messages\": [{\"role\": \"system\", \"content\": \"Ты автономный ИИ-агент.\"}, {\"role\": \"user\", \"content\": $ESCAPED_PROMPT}],
        \"max_tokens\": 4096
      }" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('choices',[{}])[0].get('message',{}).get('content','ОШИБКА: нет ответа'))" || {
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "[$TIMESTAMP] ОШИБКА: сессия превысила таймаут ${SESSION_TIMEOUT_SECONDS}s" >> "$LOG_DIR/runner.log"
        fi
        return $exit_code
    }
}

#############################################
# ВЫПОЛНЕНИЕ
#############################################

# METHOD уже задан выше для проверки токена.

echo "[$TIMESTAMP] Запуск методом: $METHOD (timeout: ${SESSION_TIMEOUT_SECONDS}s)" >> "$LOG_DIR/runner.log"

case "$METHOD" in
    "qwen")
        run_with_qwen_cli | tee -a "$LOG_DIR/session_$TIMESTAMP.log"
        ;;
    "live-swe-agent")
        run_with_live_swe_agent | tee -a "$LOG_DIR/session_$TIMESTAMP.log"
        ;;
    "compatible")
        run_with_compatible | tee -a "$LOG_DIR/session_$TIMESTAMP.log"
        ;;
    "openrouter")
        run_with_openrouter | tee -a "$LOG_DIR/session_$TIMESTAMP.log"
        ;;
    "api")
        run_with_direct_api | tee -a "$LOG_DIR/session_$TIMESTAMP.log"
        ;;
    *)
        echo "Неизвестный метод: $METHOD"
        echo "Использование: $0 [compatible|openrouter|qwen|live-swe-agent|api]"
        exit 1
        ;;
esac

echo "[$TIMESTAMP] Сессия #$NEXT_SESSION завершена" >> "$LOG_DIR/runner.log"

