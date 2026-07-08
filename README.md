# Автономный агент

Минимальный эксперимент: агент периодически запускается, читает файловую память,
делает один шаг, записывает состояние для следующей сессии и завершает работу до
следующего запуска.

Идея вдохновлена статьей на Хабре:
[«Я дал ИИ собственный компьютер и 483 сессии свободы. Вот что произошло»](https://habr.com/ru/articles/1007574/).

## Как это работает

- `run_ai.sh` / `run_ai.bat` собирает промпт и запускает одну сессию локального Python-агента.
- `ai_home/projects/agent/` содержит программу агента и его инструменты; `ai_home` не является Python-пакетом.
- `SYSTEM_PROMPT.md` задает базовые правила поведения агента.
- `ai_home/state/last_session.md` хранит сообщение для следующей сессии.
- `ai_home/state/current_plan.md` хранит текущие намерения.
- `ai_home/state/external_messages.md` позволяет передать агенту сообщение извне.
- `ai_home/state/agent_events.jsonl` хранит события запусков Python-агента.
- `ai_home/logs/` хранит журналы запусков.

## Настройка

Создай `.env` в корне проекта по примеру `.env.example`. Сейчас локальный агент не
использует модель напрямую, но OpenAI-compatible переменные оставлены для следующего
шага интеграции модели:

```env
OPENAI_API_KEY=your-api-key
OPENAI_BASE_URL=https://your-provider.example/v1
COMPATIBLE_MODEL=your-model-name
RANDOM_CRON_MIN_DELAY_SECONDS=300
RANDOM_CRON_MAX_DELAY_SECONDS=900
```

## Запуск

Linux / macOS / WSL:

```bash
./run_ai.sh
```

Windows:

```bat
run_ai.bat
```

По умолчанию используется метод `compatible`; он запускает локального Python-агента.

## Автозапуск

Windows random cron:

```bat
random_cron.bat
```

Он запускает сессии, ждет случайную задержку из `.env` и после каждой сессии
коммитит изменения рабочей директории.

Пример cron-задачи для Linux:

```cron
*/15 * * * * /path/to/project/run_ai.sh >> /path/to/project/ai_home/logs/cron.log 2>&1
```

## Зависимости

Нужен Python. Внешний агент для основного запуска больше не требуется.

## Важные файлы

```text
.
├── run_ai.sh / run_ai.bat
├── random_cron.bat
├── SYSTEM_PROMPT.md
└── ai_home/
    ├── config.sh
    ├── logs/
    ├── state/
    ├── knowledge/
    ├── projects/
    │   └── agent/
    └── tools/
```

`.env` не коммитится.



