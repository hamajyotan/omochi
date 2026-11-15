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


async def resolve_response_text(response, step_error_handler: StepErrorHandler, timeout: float = 90.0) -> str:
    """Resolves the full text from ChatResponse while streaming tool call progress and watching for step errors."""
    async def _collect():
        chunks_attr = getattr(response, "chunks", None)
        if chunks_attr is not None:
            text_parts = []
            async for chunk in chunks_attr:
                cls_name = type(chunk).__name__
                if cls_name == "ToolCall":
                    tool_name = getattr(chunk, "name", "tool")
                    emit("progress", message=f"Executing tool: {tool_name}...")
                elif cls_name == "Text":
                    content = getattr(chunk, "text", None) or getattr(chunk, "content", None)
                    if content:
                        text_parts.append(str(content))
            return "".join(text_parts)

        text_attr = getattr(response, "text", None)
        if callable(text_attr):
            return await text_attr()

        tokens = []
        async for token in response:
            tokens.append(str(token))
        return "".join(tokens)

    text_task = asyncio.create_task(_collect())
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


def build_agent_config(model_name: str, system_instructions: str):
    from google.antigravity import CapabilitiesConfig, LocalAgentConfig

    policies = []
    try:
        from google.antigravity.hooks.policy import allow_all
        policies.append(allow_all())
    except Exception:
        try:
            from google.antigravity.hooks.policy import allow
            policies.append(allow("*"))
        except Exception:
            pass

    config_candidates = [
        {
            "model": model_name,
            "system_instructions": system_instructions,
            "capabilities": CapabilitiesConfig(),
            "workspaces": [WORKSPACE_DIR],
            "app_data_dir": APP_DATA_DIR,
            "policies": policies,
        },
        {
            "model": model_name,
            "system_instructions": system_instructions,
            "capabilities": CapabilitiesConfig(),
            "app_data_dir": APP_DATA_DIR,
            "policies": policies,
        },
        {
            "system_instructions": system_instructions,
            "capabilities": CapabilitiesConfig(),
            "app_data_dir": APP_DATA_DIR,
            "policies": policies,
        },
        {
            "system_instructions": system_instructions,
            "capabilities": CapabilitiesConfig(),
            "app_data_dir": APP_DATA_DIR,
        },
        {"system_instructions": system_instructions},
    ]
    for kwargs in config_candidates:
        try:
            return LocalAgentConfig(**kwargs)
        except (TypeError, Exception):
            continue
    return LocalAgentConfig()


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
    history = instruction.get("history") or []
    git_context = instruction.get("git_context") or {}

    prompt_parts = []
    if git_context:
        repo = git_context.get("repository", "")
        mode = git_context.get("mode", "")
        if mode == "pull_request":
            pr_num = git_context.get("pull_number")
            base_ref = git_context.get("base_ref", "")
            head_ref = git_context.get("head_ref", "")
            head_sha = git_context.get("head_sha", "")
            diff_file = os.path.join(WORKSPACE_DIR, git_context.get("diff_file", ".omochi_pr.diff"))
            diff_excerpt = ""
            if os.path.exists(diff_file):
                try:
                    with open(diff_file, "r", encoding="utf-8", errors="replace") as df:
                        raw_diff = df.read()
                    if len(raw_diff) > 40000:
                        diff_excerpt = raw_diff[:40000] + "\n... (diff truncated in prompt; full diff is in /workspace/.omochi_pr.diff)"
                    else:
                        diff_excerpt = raw_diff
                except Exception:
                    pass
            context_block = (
                f"Workspace Context:\n"
                f"- Repository `{repo}` is checked out in `/workspace` at PR #{pr_num} (`{base_ref}` <- `{head_ref}`, SHA `{head_sha}`).\n"
                f"- Full unified diff is saved at `/workspace/.omochi_pr.diff`."
            )
            if diff_excerpt:
                context_block += f"\n\nPull Request Unified Diff:\n```diff\n{diff_excerpt}\n```"
            prompt_parts.append(context_block)
        elif mode == "branch":
            branch = git_context.get("branch", "")
            prompt_parts.append(
                f"Workspace Context:\n- Repository `{repo}` is checked out in `/workspace` (branch: `{branch}`)."
            )

    if history:
        history_lines = ["Previous conversation history in this Quest:"]
        for entry in history:
            seq = entry.get("sequence")
            user_msg = (entry.get("body") or "").strip()
            agent_msg = (entry.get("result_summary") or "").strip()
            history_lines.append(f"[Instruction #{seq} (User)]:\n{user_msg}")
            if agent_msg:
                history_lines.append(f"[Response #{seq} (omochi)]:\n{agent_msg}")
        prompt_parts.append("\n\n".join(history_lines))

    if prompt_parts:
        prompt_parts.append(f"Current instruction (#{sequence}):\n{body}")
        prompt = "\n\n".join(prompt_parts)
    else:
        prompt = body

    emit("started", message=f"Antigravity Agent starting for {quest_id} (instruction #{sequence})")

    # Check for Gemini API key
    if not os.environ.get("GEMINI_API_KEY"):
        emit("failed", message="GEMINI_API_KEY is not configured in agent environment.")
        sys.exit(2)

    try:
        from google.antigravity import Agent

        system_instructions = (
            "You are omochi, an autonomous AI coding assistant running inside an isolated workspace (/workspace). "
            "You have access to tools for navigating, editing, and testing the codebase. "
            "When asked to implement a feature, fix a bug, or modify files for a Pull Request: "
            "1) Edit the necessary files in /workspace, 2) Run relevant checks/tests if applicable, and "
            "3) Stage and commit your changes locally with `git add <files>` and `git commit -m '<concise commit title>'` "
            "(do NOT run `git push`; the host will automatically push any new local commits and create or update the Pull Request after you finish). "
            "When only answering a question, investigating, or reviewing a Pull Request (/review), do NOT create any Git commits. "
            "Be concise, precise, and provide a clear summary of your findings or changes."
        )

        primary_model = os.environ.get("GEMINI_MODEL", "").strip() or "gemini-3.5-flash"
        fallback_models = []
        for candidate in [primary_model, "gemini-3.5-flash", "gemini-3.1-flash-lite", "gemini-3.8-flash"]:
            if candidate and candidate not in fallback_models:
                fallback_models.append(candidate)

        emit("progress", message=f"Antigravity Agent initialized with workspace capabilities (model: {fallback_models[0]}).")

        step_error_handler = StepErrorHandler()
        logging.getLogger().addHandler(step_error_handler)
        loop = asyncio.get_running_loop()

        summary = ""
        max_attempts = len(fallback_models)
        heartbeat_task = asyncio.create_task(heartbeat_worker(15.0))
        try:
            for idx, current_model in enumerate(fallback_models, start=1):
                step_error_handler.reset(loop)
                config = build_agent_config(current_model, system_instructions)
                try:
                    async with Agent(config) as agent:
                        emit(
                            "progress",
                            message=f"Analyzing instruction #{sequence} with Antigravity ({current_model}, attempt {idx}/{max_attempts})...",
                        )
                        response = await agent.chat(prompt)
                        summary = await resolve_response_text(response, step_error_handler, timeout=90.0)
                        break
                except Exception as e:
                    err_str = str(e)
                    is_retryable = any(
                        code in err_str
                        for code in [
                            "503",
                            "429",
                            "UNAVAILABLE",
                            "high demand",
                            "retryable",
                            "terminated due to error",
                            "Timed out waiting",
                        ]
                    )
                    if is_retryable and idx < max_attempts:
                        next_model = fallback_models[idx]
                        emit(
                            "progress",
                            message=f"Model {current_model} unavailable or timed out. Falling back to {next_model} (attempt {idx + 1}/{max_attempts})...",
                        )
                        await asyncio.sleep(2)
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
