#!/bin/bash
#
# setup-compatible.sh - настройка любого OpenAI-compatible API endpoint.
#
# Использование:
#   ./setup-compatible.sh API_KEY BASE_URL MODEL
#   ./setup-compatible.sh API_KEY https://api.openai.com/v1 gpt-4o-mini
#
# Если аргументы не переданы, скрипт спросит их интерактивно.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPATIBLE_ENV="${COMPATIBLE_ENV:-$SCRIPT_DIR/.env}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}OK${NC} $1"; }
log_warn() { echo -e "${YELLOW}WARN${NC} $1"; }
log_error() { echo -e "${RED}ERR${NC} $1"; }
log_step() { echo -e "${BLUE}--${NC} $1"; }

echo ""
echo "=========================================="
echo "  Настройка OpenAI-compatible для ИИ-агента"
echo "=========================================="
echo ""

API_KEY="${1:-}"
BASE_URL="${2:-}"
MODEL="${3:-}"

if [ -z "$API_KEY" ]; then
    read -p "Введите API key: " -s API_KEY
    echo ""
fi

if [ -z "$BASE_URL" ]; then
    read -p "Введите base URL [https://api.openai.com/v1]: " BASE_URL
    BASE_URL="${BASE_URL:-https://api.openai.com/v1}"
fi

if [ -z "$MODEL" ]; then
    read -p "Введите модель [gpt-4o-mini]: " MODEL
    MODEL="${MODEL:-gpt-4o-mini}"
fi

if [ -z "$API_KEY" ]; then
    log_error "API key не указан"
    exit 1
fi

BASE_URL="${BASE_URL%/}"

log_step "Проверяю endpoint..."

RESPONSE=$(curl -s -w "\n%{http_code}" -m 30 -X POST "${BASE_URL}/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"$MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"Ответь одним словом: привет.\"}], \"max_tokens\": 10}" 2>/dev/null)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "200" ]; then
    log_info "Endpoint доступен, ключ работает"
else
    log_warn "Проверка вернула HTTP $HTTP_CODE"
    echo "Ответ: $BODY"
    read -p "Сохранить эту конфигурацию все равно? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

mkdir -p "$(dirname "$COMPATIBLE_ENV")"

log_step "Записываю конфигурацию в $COMPATIBLE_ENV"

{
    echo "# OpenAI-compatible конфигурация для ИИ-агента"
    echo "# Сгенерировано setup-compatible.sh: $(date)"
    echo ""
    echo "OPENAI_API_KEY=$API_KEY"
    echo "OPENAI_BASE_URL=$BASE_URL"
    echo "COMPATIBLE_MODEL=$MODEL"
    echo "MSWEA_MODEL_NAME=openai/$MODEL"
    echo "MSWEA_CONFIGURED=true"
    echo "MSWEA_COST_TRACKING=ignore_errors"
} > "$COMPATIBLE_ENV"

echo ""
log_info "Конфигурация сохранена"
echo ""
echo "Запусти одну сессию так:"
echo ""
echo "./run_ai.sh compatible"
echo ""
