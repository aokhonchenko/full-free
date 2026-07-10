# Python Agent

Локальная программа агента с auto-discovered tools. Проект упаковывается и устанавливается именно из этой директории:

```bash
cd ai_home/projects/agent
python -m pip install --upgrade pip build
python -m build
pip install --force-reinstall dist/full_free_agent-*.whl
```

Если на `python -m build` появляется ошибка `No module named build`, значит в текущем Python не установлен пакет сборщика. Установите его командой:

```bash
python -m pip install --upgrade build
```

## Установка на Windows для `run_ai.bat`

`run_ai.bat` по умолчанию ищет установленный агент здесь:

```text
ai_home\projects\agent\.venv\Scripts\full-free-agent.exe
```

Полный цикл сборки и установки в ожидаемое окружение:

```powershell
cd C:\_dev\own\ai\full-free\ai_home\projects\agent

python -m pip install --upgrade pip build
python -m build

python -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip

$wheel = Get-ChildItem .\dist\full_free_agent-*.whl | Sort-Object LastWriteTime -Descending | Select-Object -First 1
.\.venv\Scripts\python.exe -m pip install --force-reinstall $wheel.FullName

.\.venv\Scripts\full-free-agent.exe --passport
```

После установки запускайте стабильную копию из Python-окружения:

```bash
full-free-agent --message "wake up"
```

Основной запуск сессий из корня репозитория должен идти через `run_ai`:

```bash
run_ai.bat compatible
```

или в shell:

```bash
./run_ai.sh compatible
```

`run_ai` использует установленный entrypoint `full-free-agent` из `ai_home/projects/agent/.venv`, если он есть, и не запускает агент напрямую из исходной директории.

Так агент использует установленный wheel из `site-packages`, а не текущие исходники в рабочей директории. Если ИИ позже изменит файлы в `ai_home/projects/agent` и временно сломает их, уже установленный `full-free-agent` продолжит работать до следующей явной переустановки.

Не устанавливайте агент через editable-режим:

```bash
pip install -e .
```

Editable-установка ссылается на рабочую директорию и снова делает запуск зависимым от текущих правок.

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

Из установленного окружения:

```bash
full-free-agent --passport
full-free-agent --message "wake up"
```

Локальный запуск из корня репозитория по-прежнему возможен:

```bash
python ai_home/projects/agent --passport
python ai_home/projects/agent --message "wake up"
```

Вызвать инструмент напрямую:

```bash
full-free-agent --tool read --payload '{"path":"README.md","start_line":1,"end_line":5}'
full-free-agent --tool write --payload '{"path":"tmp/agent.txt","mode":"write","content":"hello\n"}'
full-free-agent --tool terminal --payload '{"command":["python","--version"]}'
```

Полный журнал событий пишется в JSONL state-файл только если передать `--state`. По умолчанию запись state отключена, а stdout показывает компактный итог шагов.

## Build Notes

Рабочая директория для сборки - `ai_home/projects/agent`.

Рекомендуемый цикл обновления стабильного агента:

```bash
cd ai_home/projects/agent
uv venv .venv
uv pip install --python .venv\Scripts\python.exe .
.venv\Scripts\full-free-agent.exe --passport
```

Для Unix-like shell:

```bash
cd ai_home/projects/agent
uv venv .venv
uv pip install --python .venv/bin/python .
.venv/bin/full-free-agent --passport
```

Папки `logs/` и `state/` не нужны для установки агента и не должны заполняться сборочным процессом. Установка может создать только локальную инфраструктуру вроде `.venv/`, `.uv-cache/`, `build/` и `*.egg-info`; эти пути игнорируются Git.

