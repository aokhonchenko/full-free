from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from agent import Tool


def describe() -> dict[str, str]:
    return {
        "name": "write",
        "description": (
            "Записывает текстовый файл. Payload: path, mode='write' для полной перезаписи, "
            "mode='append' для дописывания или mode='replace_regex' для замены по регулярке через pattern и replacement."
        ),
    }


def _write(path: Path, content: str, encoding: str) -> dict[str, Any]:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding=encoding)
    return {"path": str(path), "mode": "write", "bytes_written": len(content.encode(encoding))}


def _append(path: Path, content: str, encoding: str) -> dict[str, Any]:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding=encoding) as file:
        file.write(content)
    return {"path": str(path), "mode": "append", "bytes_written": len(content.encode(encoding))}


def _replace_regex(path: Path, payload: dict[str, Any], encoding: str) -> dict[str, Any]:
    pattern = payload.get("pattern")
    replacement = payload.get("replacement")
    if pattern is None:
        raise ValueError("replace_regex mode requires pattern")
    if replacement is None:
        raise ValueError("replace_regex mode requires replacement")

    flags = 0
    if payload.get("multiline", True):
        flags |= re.MULTILINE
    if payload.get("dotall", False):
        flags |= re.DOTALL
    if payload.get("ignore_case", False):
        flags |= re.IGNORECASE

    count = int(payload.get("count", 0))
    original = path.read_text(encoding=encoding)
    updated, replacements = re.subn(pattern, replacement, original, count=count, flags=flags)
    path.write_text(updated, encoding=encoding)

    return {
        "path": str(path),
        "mode": "replace_regex",
        "replacements": replacements,
        "bytes_written": len(updated.encode(encoding)),
    }


def run(payload: dict[str, Any]) -> dict[str, Any]:
    path_value = payload.get("path")
    if not path_value:
        raise ValueError("Missing required payload field: path")

    path = Path(path_value)
    mode = payload.get("mode", "write")
    encoding = payload.get("encoding", "utf-8")
    content = payload.get("content", "")

    if mode == "write":
        return _write(path, content, encoding)
    if mode == "append":
        return _append(path, content, encoding)
    if mode == "replace_regex":
        return _replace_regex(path, payload, encoding)

    raise ValueError(f"Unknown write mode: {mode}")


def create_tool() -> Tool:
    info = describe()
    return Tool(name=info["name"], description=info["description"], handler=run)




