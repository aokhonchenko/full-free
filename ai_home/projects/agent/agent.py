from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


AGENT_DIR = Path(__file__).resolve().parent
DEFAULT_THOUGHT_PATH = Path.cwd() / ".sessions" / "thought.md"
DEFAULT_TOOLS_PATH = AGENT_DIR / "src" / "tools"
DEFAULT_MAX_STEPS = 20
MAX_OBSERVATION_CHARS = 12000


@dataclass(frozen=True)
class AgentPassport:
    """Устойчивое описание агента и автоматически найденных инструментов."""

    name: str = "черновой-агент"
    role: str = "автономный Python-агент"
    goals: tuple[str, ...] = ("выполнять промпт через модель", "использовать инструменты осознанно")
    constraints: tuple[str, ...] = (
        "загружать инструменты из src/tools",
        "выполнять по одному инструменту за шаг",
        "завершать сессию финальным сообщением",
    )
    tools: tuple[dict[str, str], ...] = ()
    metadata: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class Tool:
    name: str
    description: str
    handler: Callable[[dict[str, Any]], Any]


@dataclass(frozen=True)
class ModelConfig:
    api_key: str
    base_url: str
    model: str
    temperature: float = 0.7
    max_tokens: int | None = None


class ToolRegistry:
    def __init__(self) -> None:
        self._tools: dict[str, Tool] = {}

    def register(self, tool: Tool) -> None:
        if tool.name in self._tools:
            raise ValueError(f"Tool already registered: {tool.name}")
        self._tools[tool.name] = tool

    def names(self) -> list[str]:
        return sorted(self._tools)

    def describe(self) -> list[dict[str, str]]:
        return [
            {"name": tool.name, "description": tool.description}
            for tool in sorted(self._tools.values(), key=lambda item: item.name)
        ]

    def call(self, name: str, payload: dict[str, Any] | None = None) -> Any:
        if name not in self._tools:
            raise KeyError(f"Unknown tool: {name}")
        return self._tools[name].handler(payload or {})


def load_env_file(path: Path) -> None:
    if not path.exists():
        return

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :]
        if "=" not in line:
            continue

        name, value = line.split("=", 1)
        name = name.strip()
        value = value.strip().strip('"').strip("'")
        if name and name not in os.environ:
            os.environ[name] = value


def load_tools(tools_path: Path = DEFAULT_TOOLS_PATH) -> ToolRegistry:
    registry = ToolRegistry()
    if not tools_path.exists():
        return registry

    for tool_dir in sorted(path for path in tools_path.iterdir() if path.is_dir()):
        if tool_dir.name.startswith("_"):
            continue

        module_path = tool_dir / "tool.py"
        if not module_path.exists():
            continue

        module_name = f"_agent_tool_{tool_dir.name}"
        spec = importlib.util.spec_from_file_location(module_name, module_path)
        if spec is None or spec.loader is None:
            raise ImportError(f"Cannot load tool module: {module_path}")

        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        spec.loader.exec_module(module)

        if not hasattr(module, "create_tool"):
            raise AttributeError(f"Tool module has no create_tool(): {module_path}")
        registry.register(module.create_tool())

    return registry


def model_config_from_env() -> ModelConfig:
    load_env_file(Path.cwd() / ".env")

    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    base_url = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1").strip()
    model = (
        os.environ.get("COMPATIBLE_MODEL")
        or os.environ.get("OPENROUTER_MODEL")
        or os.environ.get("MODEL")
        or ""
    ).strip()

    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is required for the local agent model call")
    if not model:
        raise RuntimeError("COMPATIBLE_MODEL is required for the local agent model call")

    temperature = float(os.environ.get("AGENT_TEMPERATURE", "0.7"))
    max_tokens_value = os.environ.get("AGENT_MAX_TOKENS", "").strip()
    max_tokens = int(max_tokens_value) if max_tokens_value else None

    return ModelConfig(
        api_key=api_key,
        base_url=base_url.rstrip("/"),
        model=model,
        temperature=temperature,
        max_tokens=max_tokens,
    )


class OpenAICompatibleClient:
    def __init__(self, config: ModelConfig) -> None:
        self.config = config

    def chat(self, messages: list[dict[str, str]]) -> str:
        payload: dict[str, Any] = {
            "model": self.config.model,
            "messages": messages,
            "temperature": self.config.temperature,
        }
        if self.config.max_tokens is not None:
            payload["max_tokens"] = self.config.max_tokens

        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(
            f"{self.config.base_url}/chat/completions",
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {self.config.api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
        )

        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                response_body = response.read().decode("utf-8")
        except urllib.error.HTTPError as error:
            details = error.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Model API HTTP {error.code}: {details}") from error
        except urllib.error.URLError as error:
            raise RuntimeError(f"Model API request failed: {error.reason}") from error

        data = json.loads(response_body)
        choices = data.get("choices") or []
        if not choices:
            raise RuntimeError(f"Model API returned no choices: {response_body}")

        message = choices[0].get("message") or {}
        content = message.get("content")
        if not isinstance(content, str) or not content.strip():
            raise RuntimeError(f"Model API returned empty content: {response_body}")
        return content


class Agent:
    def __init__(
        self,
        passport: AgentPassport | None = None,
        tools: ToolRegistry | None = None,
        state_path: Path | None = None,
        tools_path: Path = DEFAULT_TOOLS_PATH,
        client: OpenAICompatibleClient | None = None,
        max_steps: int = DEFAULT_MAX_STEPS,
        live_output: bool = True,
        thought_path: Path | None = None,
    ) -> None:
        self.tools = tools or load_tools(tools_path)
        self.passport = passport or self.build_passport(self.tools)
        self.state_path = state_path
        self.client = client or OpenAICompatibleClient(model_config_from_env())
        self.max_steps = max_steps
        self.live_output = live_output
        self.thought_path = thought_path or DEFAULT_THOUGHT_PATH

    @staticmethod
    def build_passport(tools: ToolRegistry) -> AgentPassport:
        return AgentPassport(tools=tuple(tools.describe()))

    def run(self, prompt: str) -> dict[str, Any]:
        messages = self.initial_messages(prompt)
        steps: list[dict[str, Any]] = []
        summary: str | None = None

        self.reset_thoughts()
        self.emit(f"start max_steps={self.max_steps} tools={', '.join(self.tools.names())}")
        for step_number in range(1, self.max_steps + 1):
            self.emit(f"step {step_number}: model request")
            raw_response = self.client.chat(messages)
            parsed = parse_model_action(raw_response)

            step: dict[str, Any] = {
                "step": step_number,
                "model_response": raw_response,
                "parsed": parsed,
            }

            self.emit_step_thought(step_number, parsed)

            if parsed.get("response_type") == "complete":
                summary = str(parsed.get("message", ""))
                self.emit(f"step {step_number}: complete {truncate_one_line(summary, 1200)}")
                step["type"] = "complete"
                steps.append(step)
                messages.append({"role": "assistant", "content": raw_response})
                break

            tool_name = parsed.get("tool")
            payload = parsed.get("payload") or {}
            if not isinstance(tool_name, str):
                observation = {
                    "ok": False,
                    "error": parsed.get("parse_error")
                    or "Ответ модели должен содержать response_type=complete или строковое поле tool.",
                }
                if "raw" in parsed:
                    observation["raw"] = parsed["raw"]
            elif not isinstance(payload, dict):
                observation = {"ok": False, "error": "Поле payload должно быть JSON-объектом."}
            else:
                self.emit(f"step {step_number}: tool {tool_name} payload={compact_json(payload, 1200)}")
                observation = self.call_tool(tool_name, payload)

            step["type"] = "tool"
            step["tool"] = tool_name
            step["payload"] = payload
            step["observation"] = observation
            steps.append(step)
            self.emit_observation(step_number, observation)

            messages.append({"role": "assistant", "content": raw_response})
            messages.append(
                {
                    "role": "user",
                    "content": "Результат инструмента:\n"
                    + truncate(json.dumps(observation, ensure_ascii=False, indent=2)),
                }
            )

        if summary is None:
            summary = f"Сессия остановлена: достигнут лимит шагов ({self.max_steps})."
            self.emit(summary)

        event = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "passport": asdict(self.passport),
            "prompt": prompt,
            "steps": steps,
            "summary": summary,
        }
        self.record(event)
        return event

    def reset_thoughts(self) -> None:
        self.thought_path.parent.mkdir(parents=True, exist_ok=True)
        self.thought_path.write_text("", encoding="utf-8")

    def append_thought(self, thought: str) -> None:
        value = thought.strip()
        if not value:
            return
        with self.thought_path.open("a", encoding="utf-8") as file:
            file.write(value + "\n\n")

    def emit(self, message: str) -> None:
        if self.live_output:
            print(f"[agent] {message}", flush=True)

    def emit_step_thought(self, step_number: int, parsed: dict[str, Any]) -> None:
        thought = parsed.get("thought")
        if thought:
            value = str(thought)
            self.append_thought(value)
            self.emit(f"step {step_number}: thought {truncate_one_line(value, 1200)}")

    def emit_observation(self, step_number: int, observation: dict[str, Any]) -> None:
        ok = observation.get("ok")
        if ok is False:
            self.emit(f"step {step_number}: observation error={observation.get('error')}")
            return
        self.emit(f"step {step_number}: observation ok payload={compact_json(observation.get('result'), 1600)}")

    def initial_messages(self, prompt: str) -> list[dict[str, str]]:
        return [
            {"role": "system", "content": self.agent_protocol()},
            {"role": "user", "content": prompt},
        ]

    def agent_protocol(self) -> str:
        return (
            "Ты управляешь автономным Python-агентом. Тебе дан промпт с контекстом сессии. "
            "Выполняй его через доступные инструменты.\n\n"
            "Паспорт агента:\n"
            f"{json.dumps(asdict(self.passport), ensure_ascii=False, indent=2)}\n\n"
            "Формат каждого ответа строго JSON без markdown и без текста вокруг.\n"
            "Чтобы вызвать инструмент, верни:\n"
            '{"thought":"почему это действие нужно","response_type":"tool","tool":"имя_инструмента","payload":{...}}\n'
            "Чтобы завершить сессию без вызова инструмента, верни:\n"
            '{"thought":"почему пора завершить","response_type":"complete","message":"краткий итог сессии"}\n\n'
            "Поле tool можно использовать только при response_type=tool. После результата инструмента ты получишь наблюдение "
            "и сможешь выбрать следующий шаг. Если нужно записать память для будущей сессии, используй write. "
            "Если нужно посмотреть файлы, используй read. Если нужна команда ОС, используй terminal."
        )

    def call_tool(self, name: str, payload: dict[str, Any]) -> dict[str, Any]:
        try:
            result = self.tools.call(name, payload)
            return {"ok": True, "result": result}
        except Exception as error:  # The error is returned to the model as observation.
            return {"ok": False, "error": f"{type(error).__name__}: {error}"}

    def record(self, event: dict[str, Any]) -> None:
        if self.state_path is None:
            return
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        with self.state_path.open("a", encoding="utf-8") as file:
            file.write(json.dumps(event, ensure_ascii=False) + "\n")


def truncate(text: str, limit: int = MAX_OBSERVATION_CHARS) -> str:
    if len(text) <= limit:
        return text
    head = text[: limit // 2]
    tail = text[-limit // 2 :]
    return f"{head}\n...<truncated {len(text) - limit} chars>...\n{tail}"


def truncate_one_line(text: str, limit: int) -> str:
    compact = re.sub(r"\s+", " ", text).strip()
    if len(compact) <= limit:
        return compact
    return compact[:limit] + f"...<truncated {len(compact) - limit} chars>"


def compact_json(value: Any, limit: int) -> str:
    try:
        text = json.dumps(value, ensure_ascii=False, sort_keys=True)
    except TypeError:
        text = repr(value)
    return truncate_one_line(text, limit)


def public_event(event: dict[str, Any]) -> dict[str, Any]:
    public_steps: list[dict[str, Any]] = []
    for step in event.get("steps", []):
        item: dict[str, Any] = {
            "step": step.get("step"),
            "type": step.get("type"),
            "thought": step.get("parsed", {}).get("thought"),
        }
        if step.get("type") == "tool":
            observation = step.get("observation", {})
            item.update(
                {
                    "tool": step.get("tool"),
                    "payload": step.get("payload"),
                    "ok": observation.get("ok"),
                }
            )
            if observation.get("ok") is False:
                item["error"] = observation.get("error")
        if step.get("type") == "complete":
            item["message"] = step.get("parsed", {}).get("message")
        public_steps.append(item)

    return {
        "timestamp": event.get("timestamp"),
        "summary": event.get("summary"),
        "steps": public_steps,
    }


def parse_model_action(content: str) -> dict[str, Any]:
    cleaned = content.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned, flags=re.IGNORECASE)
        cleaned = re.sub(r"\s*```$", "", cleaned)

    try:
        parsed = json.loads(cleaned)
    except json.JSONDecodeError as error:
        match = re.search(r"\{.*\}", cleaned, flags=re.DOTALL)
        if not match:
            return parse_error_action("JSON object not found", content)
        try:
            parsed = json.loads(match.group(0))
        except json.JSONDecodeError as nested_error:
            return parse_error_action(str(nested_error), content)

    if not isinstance(parsed, dict):
        return parse_error_action("Model response must be a JSON object", content)
    return parsed


def parse_error_action(error: str, raw: str) -> dict[str, Any]:
    return {
        "response_type": "tool",
        "tool": None,
        "payload": {},
        "parse_error": error,
        "raw": truncate_one_line(raw, 2000),
    }

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the local Python agent.")
    parser.add_argument(
        "--message",
        default="wake up",
        help="Input message for one agent session.",
    )
    parser.add_argument(
        "--message-file",
        type=Path,
        help="Read the input message for one agent session from a UTF-8 text file.",
    )
    parser.add_argument(
        "--state",
        type=Path,
        help="Optional path to the JSONL event journal. Disabled by default.",
    )
    parser.add_argument(
        "--tools-dir",
        type=Path,
        default=DEFAULT_TOOLS_PATH,
        help="Directory with one tool per subdirectory.",
    )
    parser.add_argument(
        "--thought-file",
        type=Path,
        help="Path to collect model thought values for this session.",
    )
    parser.add_argument(
        "--max-steps",
        type=int,
        default=int(os.environ.get("AGENT_MAX_STEPS", DEFAULT_MAX_STEPS)),
        help="Maximum model/tool loop steps for one session.",
    )
    parser.add_argument(
        "--passport",
        action="store_true",
        help="Print the auto-built passport and exit.",
    )
    parser.add_argument(
        "--tool",
        help="Call a tool by name instead of running an agent session.",
    )
    parser.add_argument(
        "--payload",
        default="{}",
        help="JSON payload for --tool.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    tools = load_tools(args.tools_dir)
    passport = Agent.build_passport(tools)

    if args.passport:
        print(json.dumps(asdict(passport), ensure_ascii=False, indent=2))
        return 0

    if args.tool:
        payload = json.loads(args.payload)
        if not isinstance(payload, dict):
            raise ValueError("--payload must be a JSON object")
        result = tools.call(args.tool, payload)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0

    message = args.message
    if args.message_file:
        message = args.message_file.read_text(encoding="utf-8")

    try:
        agent = Agent(
            passport=passport,
            tools=tools,
            state_path=args.state,
            max_steps=args.max_steps,
            thought_path=args.thought_file,
        )
        event = agent.run(message)
    except Exception as error:
        print(
            json.dumps(
                {"ok": False, "error": f"{type(error).__name__}: {error}"},
                ensure_ascii=False,
                indent=2,
            ),
        )
        return 1

    print(json.dumps(public_event(event), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
