#!/usr/bin/env python3
# frozen_string_literal: true
"""
Antigravity Agent runner executed inside an isolated Quest Agent Container (Phase 7).

Responsibilities:
1. Read the instruction payload from `/workspace/.omochi_instruction.json`.
2. Initialize google.antigravity.Agent with capabilities for workspace navigation/editing.
3. Stream thoughts, tool calls, and execution progress as structured JSONL events on stdout.
4. Emit the final result summary and completion event so omochi can update GitHub/Slack/Dashboard.
"""
import asyncio
import json
import logging
import os
import sys
from datetime import datetime, timezone

# Ensure stdout and stderr flush immediately for real-time streaming to Rails
sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

# Ensure HOME and app data directories point to a writable location
if not os.environ.get("HOME") or os.environ.get("HOME") == "/":
    os.environ["HOME"] = "/home/agent"

HOME_DIR = os.environ["HOME"]
APP_DATA_DIR = os.path.join(HOME_DIR, ".gemini", "antigravity")
try:
    os.makedirs(APP_DATA_DIR, exist_ok=True)
except Exception:
    pass

WORKSPACE_DIR = os.environ.get("OMOCHI_WORKSPACE", "/workspace")
INSTRUCTION_FILE = os.path.join(WORKSPACE_DIR, ".omochi_instruction.json")


def emit(event_type: str, message: str = "", **extra):
    payload = {
        "type": event_type,
        "message": message,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        **extra,
    }
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


class StepErrorHandler(logging.Handler):
    """Detects fatal step errors logged by google-antigravity so step_queue.get() does not hang."""

    def __init__(self):
        super().__init__()
        self.last_error: str | None = None
        self.error_event: asyncio.Event | None = None
        self._loop: asyncio.AbstractEventLoop | None = None

    def reset(self, loop: asyncio.AbstractEventLoop):
        self.last_error = None
        self.error_event = asyncio.Event()
        self._loop = loop

    def emit(self, record: logging.LogRecord):
        msg = self.format(record)
        if "Agent execution terminated due to error" in msg or "System step error" in msg:
            self.last_error = msg
            if self.error_event and self._loop:
                self._loop.call_soon_threadsafe(self.error_event.set)


async def heartbeat_worker(interval: float = 15.0):
    count = 1
    while True:
        await asyncio.sleep(interval)
        emit("progress", message=f"Antigravity Agent is reasoning and processing ({count * int(interval)}s elapsed)...")
        count += 1


async def resolve_response_text(response, step_error_handler: StepErrorHandler, timeout: float = 180.0) -> str:
    """Resolves the full text from ChatResponse while watching for silent step termination errors."""
    text_attr = getattr(response, "text", None)
    if callable(text_attr):
        coro = text_attr()
    else:
        async def _stream():
            chunks = []
            async for token in response:
                chunks.append(str(token))
            return "".join(chunks)
        coro = _stream()

    text_task = asyncio.create_task(coro)
    err_task = asyncio.create_task(step_error_handler.error_event.wait())
    try:
        done, pending = await asyncio.wait(
            [text_task, err_task],
            timeout=timeout,
            return_when=asyncio.FIRST_COMPLETED,
        )
        for task in pending:
            task.cancel()
            try:
                await task
            except BaseException:
                pass

        if err_task in done:
            raise RuntimeError(step_error_handler.last_error or "Agent step terminated due to error")
        if text_task in done:
            return str(text_task.result() or "").strip()

        raise TimeoutError(f"Timed out waiting for Antigravity response after {int(timeout)}s")
    finally:
        for task in (text_task, err_task):
            if not task.done():
                task.cancel()
                try:
                    await task
                except BaseException:
                    pass


async def main():
    if not os.path.exists(INSTRUCTION_FILE):
        emit("failed", message=f"Instruction file not found: {INSTRUCTION_FILE}")
        sys.exit(1)

    try:
        with open(INSTRUCTION_FILE, "r", encoding="utf-8") as f:
            instruction = json.load(f)
    except Exception as e:
        emit("failed", message=f"Failed to read instruction file: {e}")
        sys.exit(1)

    quest_id = instruction.get("quest_public_id", "unknown")
    sequence = instruction.get("instruction_sequence", 1)
    body = instruction.get("body", "")

    emit("started", message=f"Antigravity Agent starting for {quest_id} (instruction #{sequence})")

    # Check for Gemini API key
    if not os.environ.get("GEMINI_API_KEY"):
        emit("failed", message="GEMINI_API_KEY is not configured in agent environment.")
        sys.exit(2)

    try:
        from google.antigravity import Agent, CapabilitiesConfig, LocalAgentConfig

        system_instructions = (
            "You are omochi, an autonomous AI coding assistant running inside an isolated workspace. "
            "Your working directory is /workspace. You have access to tools for navigating, editing, "
            "and testing the codebase. Be concise, precise, and provide a clear summary of your findings or changes."
        )

        policies = []
        try:
            from google.antigravity.hooks.policy import allow
            policies.append(allow("*"))
        except Exception:
            pass

        config_candidates = [
            {"system_instructions": system_instructions, "capabilities": CapabilitiesConfig(), "app_data_dir": APP_DATA_DIR, "policies": policies},
            {"system_instructions": system_instructions, "capabilities": CapabilitiesConfig(), "app_data_dir": APP_DATA_DIR},
            {"system_instructions": system_instructions, "capabilities": CapabilitiesConfig()},
            {"system_instructions": system_instructions},
        ]
        config = None
        for kwargs in config_candidates:
            try:
                config = LocalAgentConfig(**kwargs)
                break
            except (TypeError, Exception):
                continue

        emit("progress", message="Antigravity Agent initialized with workspace capabilities.")

        step_error_handler = StepErrorHandler()
        logging.getLogger().addHandler(step_error_handler)
        loop = asyncio.get_running_loop()

        summary = ""
        max_retries = 3
        heartbeat_task = asyncio.create_task(heartbeat_worker(15.0))
        try:
            for attempt in range(1, max_retries + 1):
                step_error_handler.reset(loop)
                try:
                    async with Agent(config) as agent:
                        emit("progress", message=f"Analyzing instruction #{sequence} with Antigravity (attempt {attempt}/{max_retries})...")
                        response = await agent.chat(body)
                        summary = await resolve_response_text(response, step_error_handler, timeout=180.0)
                        break
                except Exception as e:
                    err_str = str(e)
                    is_retryable = any(
                        code in err_str
                        for code in ["503", "429", "UNAVAILABLE", "high demand", "retryable", "terminated due to error"]
                    )
                    if is_retryable and attempt < max_retries:
                        backoff = attempt * 5
                        emit(
                            "progress",
                            message=f"Model provider temporary error (HTTP 503/429). Retrying in {backoff}s (attempt {attempt}/{max_retries})...",
                        )
                        await asyncio.sleep(backoff)
                    else:
                        raise
        finally:
            heartbeat_task.cancel()
            try:
                await heartbeat_task
            except BaseException:
                pass
            logging.getLogger().removeHandler(step_error_handler)

        summary = summary.strip()
        if not summary:
            summary = f"Antigravity Agent completed instruction #{sequence}."

        emit("result", summary=summary, message=summary)
        emit("completed", message=summary, summary=summary)
        sys.exit(0)

    except ImportError:
        emit("failed", message="google-antigravity package is not installed in the container environment.")
        sys.exit(3)
    except Exception as e:
        emit("failed", message=f"Antigravity execution error: {e}")
        sys.exit(4)


if __name__ == "__main__":
    asyncio.run(main())
