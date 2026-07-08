from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any

from agent import Tool


def describe() -> dict[str, str]:
    return {
        "name": "terminal",
        "description": (
            "Выполняет команду терминала. Payload: command как list[str] или строка, "
            "опционально cwd, timeout в секундах и shell как boolean."
        ),
    }


def run(payload: dict[str, Any]) -> dict[str, Any]:
    command = payload.get("command")
    if not command:
        raise ValueError("Missing required payload field: command")

    shell = bool(payload.get("shell", isinstance(command, str)))
    cwd_value = payload.get("cwd")
    cwd = Path(cwd_value) if cwd_value else None
    timeout = float(payload.get("timeout", 30))

    completed = subprocess.run(
        command,
        cwd=cwd,
        shell=shell,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )

    return {
        "command": command,
        "cwd": str(cwd) if cwd else None,
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }


def create_tool() -> Tool:
    info = describe()
    return Tool(name=info["name"], description=info["description"], handler=run)




