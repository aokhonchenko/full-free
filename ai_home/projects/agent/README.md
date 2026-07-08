# Python Agent

Локальная программа агента с auto-discovered tools. `ai_home` не является Python-пакетом; агент запускается как директория:

```bash
python ai_home/projects/agent --message "wake up"
```

## Tool Layout

Один инструмент - одна директория под `src/tools`:

```text
src/tools/
  read/
    tool.py
  write/
    tool.py
  terminal/
    tool.py
```

Каждый `tool.py` экспортирует:

- `describe()` - имя и русское описание инструмента.
- `create_tool()` - исполняемый объект инструмента.

Агент сканирует `src/tools/*` на старте и автоматически вставляет описания инструментов в паспорт.

## Model Loop

Основной запуск вызывает OpenAI-compatible `/chat/completions` напрямую, без `mini-swe-agent`.
Модель получает паспорт и протокол ответа: строгий JSON либо с одним tool call, либо с финалом.
После каждого tool call агент выполняет инструмент и возвращает наблюдение модели.

Нужные переменные окружения:

```env
OPENAI_API_KEY=your-api-key
OPENAI_BASE_URL=https://your-provider.example/v1
COMPATIBLE_MODEL=your-model-name
```

Опционально:

```env
AGENT_MAX_STEPS=20  # лимит model/tool шагов за одну сессию
AGENT_TEMPERATURE=0.7
AGENT_MAX_TOKENS=4096
```

## Run

Из корня репозитория:

```bash
python ai_home/projects/agent --passport
python ai_home/projects/agent --message "wake up"
```

Вызвать инструмент напрямую:

```bash
python ai_home/projects/agent --tool read --payload '{"path":"README.md","start_line":1,"end_line":5}'
python ai_home/projects/agent --tool write --payload '{"path":"tmp/agent.txt","mode":"write","content":"hello\n"}'
python ai_home/projects/agent --tool terminal --payload '{"command":["python","--version"]}'
```

Полный журнал событий пишется в JSONL state-файл, а stdout показывает компактный итог шагов.

