# Быстрый запуск проекта из статьи

Проект уже развернут в этой папке из репозитория `mikhailsal/ai_lives_on_computer`.

Статья описывает эксперимент, где агент просыпается по cron, читает файлы памяти в `ai_home/state`, запускается через `mini-swe-agent`, пишет заметку для следующей сессии и снова "засыпает". В этой локальной версии основной способ запуска - любой OpenAI-compatible endpoint: свой `base_url`, `api_key` и имя модели.

## Что где лежит

```text
.
├── run_ai.sh / run_ai.bat     # запуск одной сессии агента
├── setup-compatible.sh / .bat # запись OpenAI-compatible API key/base_url/model
├── setup-openrouter.sh        # старый OpenRouter setup, оставлен для совместимости
├── deploy.sh                  # деплой на Linux-сервер по SSH alias debian
├── SYSTEM_PROMPT.md           # исходный системный промпт
├── config/
│   ├── ai_agent.yaml
│   └── ai_agent_openrouter.yaml
└── ai_home/
    ├── config.sh              # длительность и частота сессий
    ├── state/
    │   ├── current_plan.md
    │   ├── external_messages.md
    │   ├── last_session.md
    │   └── session_counter.txt
    └── logs/
        ├── consolidated_history.md
        └── history.md
```

## Запуск на Linux/VPS

1. Установить зависимости:

```bash
sudo apt update
sudo apt install -y python3 python3-pip python3-venv git curl jq cron
mkdir -p ~/live-swe-agent/config
python3 -m venv ~/live-swe-agent/venv
source ~/live-swe-agent/venv/bin/activate
pip install mini-swe-agent
```

2. Скопировать проект на сервер или выполнить `deploy.sh`, если настроен SSH alias `debian`.

3. Настроить OpenAI-compatible endpoint одним из двух способов.

Через интерактивный скрипт:

```bash
./setup-compatible.sh YOUR_API_KEY https://your-provider.example/v1 your-model-name
```

Или вручную через локальный `.env` в корне проекта:

```bash
OPENAI_API_KEY=your-api-key
OPENAI_BASE_URL=https://your-provider.example/v1
COMPATIBLE_MODEL=your-model-name
MSWEA_MODEL_NAME=openai/your-model-name
MSWEA_CONFIGURED=true
MSWEA_COST_TRACKING=ignore_errors
```

4. Проверить одну ручную сессию:

```bash
./run_ai.sh compatible
```

5. Включить автозапуск через cron, например каждые 10 минут:

```bash
crontab -e
```

```cron
*/10 * * * * /home/YOUR_USER/run_ai.sh compatible
```

## Запуск на Windows

Для запуска из этой папки можно использовать `.bat`-дубли:

```bat
setup-compatible.bat YOUR_API_KEY https://your-provider.example/v1 your-model-name
run_ai.bat compatible
```

Если `.env` уже заполнен вручную, достаточно:

```bat
run_ai.bat compatible
```

Нужны установленные `python`, `mini-swe-agent`, `curl`/PowerShell и доступная команда `mini` в текущем окружении или в `.venv`.

## Настройка поведения

- Частота и таймаут: `ai_home/config.sh`
- Модель: переменная `COMPATIBLE_MODEL` в локальном `.env`.
- Endpoint и ключ: `OPENAI_BASE_URL` и `OPENAI_API_KEY` в локальном `.env`.
- Сообщение агенту извне: `ai_home/state/external_messages.md`
- Память последней сессии: `ai_home/state/last_session.md`
- Долгая история: `ai_home/logs/history.md`

## Важно

Для постоянного автозапуска на сервере проще использовать Linux/VPS и cron. Для ручных локальных запусков из Windows добавлены `.bat`-скрипты.
