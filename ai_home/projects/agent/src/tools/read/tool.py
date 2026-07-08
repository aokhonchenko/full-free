from __future__ import annotations

from pathlib import Path
from typing import Any

from agent import Tool


def describe() -> dict[str, str]:
    return {
        "name": "read",
        "description": (
            "Читает текстовый файл. Payload: path, опционально start_line и end_line "
            "как включительный диапазон строк с нумерацией от 1. По умолчанию читает файл целиком."
        ),
    }


def _line_window(lines: list[str], start_line: int | None, end_line: int | None) -> tuple[int, int]:
    total = len(lines)
    start = 1 if start_line is None else start_line
    end = total if end_line is None else end_line

    if start < 1:
        raise ValueError("start_line must be >= 1")
    if end < start:
        raise ValueError("end_line must be >= start_line")

    return start, min(end, total)


def run(payload: dict[str, Any]) -> dict[str, Any]:
    path_value = payload.get("path")
    if not path_value:
        raise ValueError("Missing required payload field: path")

    path = Path(path_value)
    encoding = payload.get("encoding", "utf-8")
    start_line = payload.get("start_line")
    end_line = payload.get("end_line")

    text = path.read_text(encoding=encoding)
    lines = text.splitlines(keepends=True)

    if start_line is None and end_line is None:
        content = text
        selected_start = 1
        selected_end = len(lines)
    else:
        selected_start, selected_end = _line_window(lines, start_line, end_line)
        content = "".join(lines[selected_start - 1 : selected_end])

    return {
        "path": str(path),
        "start_line": selected_start,
        "end_line": selected_end,
        "line_count": len(lines),
        "content": content,
    }


def create_tool() -> Tool:
    info = describe()
    return Tool(name=info["name"], description=info["description"], handler=run)




