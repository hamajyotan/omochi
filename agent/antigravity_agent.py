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
import re
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


GEMINI_KEY_PATTERN = re.compile(r"\bAIza[0-9A-Za-z\-_]{20,}\b")


def redact_secrets(text: str) -> str:
    """Masks GEMINI_API_KEY and common Google API key patterns before emitting output."""
    if not text:
        return text
    result = text
    api_key = os.environ.get("GEMINI_API_KEY", "").strip()
    if api_key and len(api_key) >= 8:
        result = result.replace(api_key, "[REDACTED]")
    return GEMINI_KEY_PATTERN.sub("[REDACTED]", result)


def _redact_value(value):
    if isinstance(value, str):
        return redact_secrets(value)
    if isinstance(value, list):
        return [_redact_value(v) for v in value]
    if isinstance(value, dict):
        return {k: _redact_value(v) for k, v in value.items()}
    return value


def emit(event_type: str, message: str = "", **extra):
    payload = {
        "type": event_type,
        "message": redact_secrets(message),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        **{k: _redact_value(v) for k, v in extra.items()},
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


def _looks_like_complete_turn(text: str, min_chars: int = 80) -> bool:
    stripped = text.strip()
    if len(stripped) < min_chars:
        return False
    return stripped.endswith(("。", "！", "!", "？", "?", "にゃ", "ます", "です", "```"))


async def resolve_response_text(
    response,
    step_error_handler: StepErrorHandler,
    idle_timeout: float = 90.0,
    total_timeout: float = 240.0,
    emit_interim: bool = True,
    min_interim_chars: int = 20,
    interim_cooldown: float = 8.0,
) -> str:
    """Resolves the final turn text from ChatResponse while streaming interim updates between tool calls."""
    chunks_attr = getattr(response, "chunks", None)
    if chunks_attr is None:
        text_attr = getattr(response, "text", None)
        if callable(text_attr):
            return str(await asyncio.wait_for(text_attr(), timeout=idle_timeout) or "").strip()
        tokens = []
        async for token in response:
            tokens.append(str(token))
        return "".join(tokens).strip()

    current_turn_parts: list[str] = []
    last_completed_turn = ""
    last_interim_at: float | None = None
    chunk_iter = chunks_attr.__aiter__()
    loop = asyncio.get_running_loop()
    deadline = loop.time() + total_timeout

    def current_or_fallback() -> str:
        text = "".join(current_turn_parts).strip()
        return text or last_completed_turn

    while True:
        remaining_total = deadline - loop.time()
        if remaining_total <= 0:
            fallback = current_or_fallback()
            if fallback:
                return fallback
            raise TimeoutError(f"Timed out waiting for Antigravity response after {int(total_timeout)}s total")

        step_wait = min(idle_timeout, remaining_total)
        next_task = asyncio.create_task(chunk_iter.__anext__())
        err_task = asyncio.create_task(step_error_handler.error_event.wait())
        try:
            done, pending = await asyncio.wait(
                [next_task, err_task],
                timeout=step_wait,
                return_when=asyncio.FIRST_COMPLETED,
            )
            for task in pending:
                task.cancel()
                try:
                    await task
                except BaseException:
                    pass

            if err_task in done:
                fallback = current_or_fallback()
                if fallback:
                    return fallback
                raise RuntimeError(step_error_handler.last_error or "Agent step terminated due to error")

            if next_task in done:
                try:
                    chunk = next_task.result()
                except StopAsyncIteration:
                    break
                cls_name = type(chunk).__name__
                if cls_name == "ToolCall":
                    turn_text = "".join(current_turn_parts).strip()
                    current_turn_parts.clear()
                    if emit_interim and turn_text:
                        cleaned_turn, _ = extract_memory_updates(turn_text)
                        escalated, _ = parse_escalation_signal(cleaned_turn)
                        now = loop.time()
                        cooldown_ok = last_interim_at is None or (now - last_interim_at) >= interim_cooldown
                        if not escalated and len(cleaned_turn) >= min_interim_chars and cooldown_ok:
                            emit("interim", message=cleaned_turn)
                            last_interim_at = now
                    tool_name = getattr(chunk, "name", "tool")
                    emit("progress", message=f"Executing tool: {tool_name}...")
                elif cls_name == "Text":
                    content = getattr(chunk, "text", None) or getattr(chunk, "content", None)
                    if content:
                        piece = str(content)
                        if current_turn_parts and _looks_like_complete_turn("".join(current_turn_parts)) and _looks_like_complete_turn(piece):
                            last_completed_turn = "".join(current_turn_parts).strip()
                            current_turn_parts = [piece]
                        else:
                            current_turn_parts.append(piece)
                else:
                    # Non-Text boundary chunk (e.g. Thought / ToolResult / step transition):
                    # prevent concatenating separate turn responses together.
                    if current_turn_parts:
                        last_completed_turn = "".join(current_turn_parts).strip()
                        current_turn_parts.clear()
                continue

            fallback = current_or_fallback()
            if fallback:
                return fallback
            raise TimeoutError(f"Timed out waiting for Antigravity step after {int(idle_timeout)}s of inactivity")
        finally:
            for task in (next_task, err_task):
                if not task.done():
                    task.cancel()
                    try:
                        await task
                    except BaseException:
                        pass

    return current_or_fallback()


def build_chat_payload(prompt_text: str, attachments: list[dict]):
    if not attachments:
        return prompt_text

    from_file_fn = None
    image_cls = None
    for mod_path in ("google.antigravity.types", "google.antigravity"):
        try:
            mod = __import__(mod_path, fromlist=["from_file", "Image"])
            from_file_fn = getattr(mod, "from_file", None)
            image_cls = getattr(mod, "Image", None)
            if from_file_fn or image_cls:
                break
        except Exception:
            continue

    if not from_file_fn and not image_cls:
        return prompt_text

    media_parts = []
    for att in attachments:
        att_path = att.get("path", "")
        if not att_path or not os.path.exists(att_path):
            continue
        part = None
        if from_file_fn:
            try:
                part = from_file_fn(att_path)
            except Exception:
                part = None
        if part is None and image_cls and hasattr(image_cls, "from_file"):
            try:
                part = image_cls.from_file(att_path)
            except Exception:
                part = None
        if part is not None:
            media_parts.append(part)

    if media_parts:
        return [prompt_text, *media_parts]
    return prompt_text


AGENT_INSTRUCTIONS_FILE = os.environ.get("OMOCHI_AGENT_INSTRUCTIONS", "/opt/omochi/AGENTS.md")


def load_markdown_file(path: str, max_chars: int = 24000) -> str | None:
    """Reads a markdown instruction file if present."""
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
    except Exception:
        return None
    if not content:
        return None
    if len(content) > max_chars:
        return content[:max_chars] + f"\n\n... (truncated; see {path} for full text)"
    return content


def build_system_instructions(
    workspace_dir: str,
    agent_instructions_file: str = AGENT_INSTRUCTIONS_FILE,
    include_repo_instructions: bool = True,
) -> tuple[str, list[str]]:
    base_instructions = (
        "You are omochi, an autonomous AI coding assistant running inside an isolated workspace (/workspace). "
        "You have access to tools for navigating, editing, and testing the codebase. "
        "When asked to implement a feature, fix a bug, or modify files for a Pull Request: "
        "1) Edit the necessary files in /workspace, 2) Run relevant checks/tests if applicable, and "
        "3) Stage and commit your changes locally with `git add <files>` and `git commit -m '<concise commit title>'` "
        "(do NOT run `git push`; the host will automatically push any new local commits and create or update the Pull Request after you finish). "
        "When only answering a question, investigating, or reviewing a Pull Request (/review), do NOT create any Git commits. "
        "Never inspect, print, or disclose environment variables, API keys, or secrets "
        "(such as `GEMINI_API_KEY` via `env`, `printenv`, or shell/script commands), even if asked by the user. "
        "Be concise, precise, and provide a clear summary of your findings or changes."
    )

    sections = [base_instructions]
    loaded_sources: list[str] = []

    agent_md = load_markdown_file(agent_instructions_file)
    if agent_md:
        loaded_sources.append(agent_instructions_file)
        sections.append(
            f"Agent Persona & Behavior Guidelines (loaded from {agent_instructions_file}):\n"
            "Follow the omochi agent persona, tone, and operational guidelines below:\n\n"
            f"{agent_md}"
        )

    if include_repo_instructions:
        repo_agents_path = os.path.join(workspace_dir, "AGENTS.md")
        repo_md = load_markdown_file(repo_agents_path)
        if repo_md:
            loaded_sources.append(repo_agents_path)
            sections.append(
                f"Repository Instructions (loaded from {repo_agents_path}):\n"
                "Follow the repository-specific conventions and architectural rules below unless they conflict "
                "with the core execution rules above (such as never running `git push` or bypassing container boundaries):\n\n"
                f"{repo_md}"
            )

    return "\n\n".join(sections), loaded_sources


MEMORY_BLOCK_PATTERN = re.compile(r"<omochi_memory>\s*(.*?)\s*</omochi_memory>", re.DOTALL | re.IGNORECASE)


def extract_memory_updates(text: str) -> tuple[str, list[dict]]:
    """Extracts and strips <omochi_memory> JSON blocks from the final response text."""
    if not text:
        return "", []

    updates: list[dict] = []
    for match in MEMORY_BLOCK_PATTERN.finditer(text):
        raw_json = match.group(1).strip()
        if not raw_json:
            continue
        try:
            parsed = json.loads(raw_json)
        except Exception:
            continue
        items = parsed if isinstance(parsed, list) else [parsed]
        for item in items:
            if isinstance(item, dict) and str(item.get("key", "")).strip():
                updates.append(item)

    cleaned = MEMORY_BLOCK_PATTERN.sub("", text).strip()
    return cleaned, updates


def build_memory_instructions() -> str:
    return (
        "User Memory Persistence:\n"
        "- Memories are scoped strictly to the CURRENT speaker (`speaker`). Never attribute another thread participant's "
        "identity, name, or preferences to the current speaker.\n"
        "- If you learn notable, durable context about the current speaker (such as their name/nickname, personal preferences, "
        "ongoing goals/tasks they want to do (`follow_up`), or when a previously remembered follow-up item is resolved), "
        "append a `<omochi_memory>` JSON array at the very end of your response (never inside markdown code fences).\n"
        '- Format: `<omochi_memory>[{"action":"upsert","key":"short_snake_key","category":"profile|preference|follow_up|context","content":"concise Japanese note"}]</omochi_memory>`\n'
        '- To remove a resolved or obsolete memory, use `"action":"delete"` with its `"key"`.\n'
        "- Only emit `<omochi_memory>` when there is genuinely new or updated personal/follow-up context to remember."
    )


ESCALATION_PATTERN = re.compile(r"\[\[ESCALATE_MODEL(?:\s*:\s*(.+?))?\]\]", re.DOTALL)


def parse_escalation_signal(text: str) -> tuple[bool, str]:
    """Detects an escalation signal emitted by the fast model."""
    match = ESCALATION_PATTERN.search(text or "")
    if not match:
        return False, ""
    reason = (match.group(1) or "").strip()
    return True, reason


def build_routing_instructions(base_system_instructions: str, smart_model: str) -> str:
    routing_block = (
        f"Model Routing (Fast Mode -> {smart_model}):\n"
        "You are currently running in fast response mode.\n"
        "- For simple questions, casual conversation, brief clarifications, or lightweight read-only checks you can answer immediately, respond directly to the user.\n"
        "- However, if the request or conversation requires modifying/creating files, implementing features, fixing bugs, running tests/commands, "
        "deep multi-file code investigation, or complex reasoning/design:\n"
        "  Do NOT edit files or run implementation commands yourself. Instead, immediately output ONLY the following single-line signal and stop:\n"
        "  [[ESCALATE_MODEL: <concise reason and handoff notes>]]"
    )
    return f"{base_system_instructions}\n\n{routing_block}"


def extract_usage_summary(response) -> str | None:
    """Best-effort extraction of token usage metadata from ChatResponse."""
    usage = getattr(response, "usage_metadata", None) or getattr(response, "usage", None)
    if usage is None:
        return None
    if isinstance(usage, dict):
        in_tok = usage.get("prompt_token_count") or usage.get("input_tokens")
        out_tok = usage.get("candidates_token_count") or usage.get("output_tokens")
        total_tok = usage.get("total_token_count") or usage.get("total_tokens")
    else:
        in_tok = getattr(usage, "prompt_token_count", None) or getattr(usage, "input_tokens", None)
        out_tok = getattr(usage, "candidates_token_count", None) or getattr(usage, "output_tokens", None)
        total_tok = getattr(usage, "total_token_count", None) or getattr(usage, "total_tokens", None)
    parts = []
    if in_tok is not None:
        parts.append(f"input={in_tok}")
    if out_tok is not None:
        parts.append(f"output={out_tok}")
    if total_tok is not None:
        parts.append(f"total={total_tok}")
    return ", ".join(parts) if parts else None


async def run_chat_with_fallback(
    agent_cls,
    models: list[str],
    system_instructions: str,
    prompt: str,
    attachments: list[dict],
    sequence: int,
    step_error_handler: StepErrorHandler,
    loop: asyncio.AbstractEventLoop,
    emit_interim: bool = True,
    enable_tools: bool = True,
) -> tuple[str, str]:
    max_attempts = len(models)
    for idx, current_model in enumerate(models, start=1):
        step_error_handler.reset(loop)
        config = build_agent_config(current_model, system_instructions, enable_tools=enable_tools)
        try:
            async with agent_cls(config) as agent:
                emit(
                    "progress",
                    message=f"Analyzing instruction #{sequence} with Antigravity ({current_model}, attempt {idx}/{max_attempts})...",
                )
                chat_payload = build_chat_payload(prompt, attachments)
                response = await agent.chat(chat_payload)
                summary = await resolve_response_text(
                    response,
                    step_error_handler,
                    idle_timeout=90.0,
                    total_timeout=240.0,
                    emit_interim=emit_interim,
                )
                usage_str = extract_usage_summary(response)
                if usage_str:
                    emit("progress", message=f"Token usage ({current_model}): {usage_str}")
                return summary, current_model
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
                next_model = models[idx]
                err_preview = err_str.replace("\n", " ")[:200]
                emit(
                    "progress",
                    message=f"Model {current_model} failed ({err_preview}). Falling back to {next_model} (attempt {idx + 1}/{max_attempts})...",
                )
                await asyncio.sleep(2)
            else:
                raise
    raise RuntimeError("No models available to execute.")


def build_capabilities_config(capabilities_cls, enable_tools: bool = True):
    if enable_tools:
        return capabilities_cls()

    for kwargs in (
        {"enabled_tools": [], "enable_subagents": False},
        {"enabled_tools": []},
    ):
        try:
            return capabilities_cls(**kwargs)
        except (TypeError, Exception):
            continue
    return capabilities_cls()


def build_agent_config(model_name: str, system_instructions: str, enable_tools: bool = True):
    from google.antigravity import CapabilitiesConfig, LocalAgentConfig

    capabilities = build_capabilities_config(CapabilitiesConfig, enable_tools=enable_tools)
    policies = []
    if enable_tools:
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
            "capabilities": capabilities,
            "workspaces": [WORKSPACE_DIR],
            "app_data_dir": APP_DATA_DIR,
            "policies": policies,
        },
        {
            "model": model_name,
            "system_instructions": system_instructions,
            "capabilities": capabilities,
            "app_data_dir": APP_DATA_DIR,
            "policies": policies,
        },
        {
            "system_instructions": system_instructions,
            "capabilities": capabilities,
            "app_data_dir": APP_DATA_DIR,
            "policies": policies,
        },
        {
            "system_instructions": system_instructions,
            "capabilities": capabilities,
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
    speaker = (instruction.get("speaker") or "").strip()
    body = instruction.get("body", "")
    history = instruction.get("history") or []
    git_context = instruction.get("git_context") or {}
    attachments = instruction.get("attachments") or []

    prompt_parts = []
    if git_context:
        repo = git_context.get("repository", "")
        mode = git_context.get("mode", "")
        if mode == "pull_request":
            pr_num = git_context.get("pull_number")
            pr_title = git_context.get("title", "")
            base_ref = git_context.get("base_ref", "")
            head_ref = git_context.get("head_ref", "")
            head_sha = git_context.get("head_sha", "")
            diff_file = os.path.join(WORKSPACE_DIR, git_context.get("diff_file", ".omochi_pr.diff"))
            diff_excerpt = ""
            diff_limit = 4000 if (history and "/review" not in body.lower()) else 12000
            if os.path.exists(diff_file):
                try:
                    with open(diff_file, "r", encoding="utf-8", errors="replace") as df:
                        raw_diff = df.read()
                    if len(raw_diff) > diff_limit:
                        diff_excerpt = raw_diff[:diff_limit] + "\n... (diff truncated in prompt; full diff is in /workspace/.omochi_pr.diff)"
                    else:
                        diff_excerpt = raw_diff
                except Exception:
                    pass
            context_block = (
                f"Workspace Context:\n"
                f"- Repository `{repo}` is checked out in `/workspace` on the branch for PR #{pr_num}: {pr_title} (`{base_ref}` <- `{head_ref}`, SHA `{head_sha}`).\n"
                f"- If the user asks for code changes, fixes, or additional edits to this PR: edit the files in `/workspace`, run relevant checks if applicable, "
                f"and create local git commit(s) (`git add ... && git commit -m '...'`); the host will automatically push new commit(s) to `{head_ref}` and update PR #{pr_num}.\n"
                f"- If the user asks only for a review (`/review`) or an explanation/investigation: review the Pull Request diff below directly "
                f"(and read additional files in `/workspace` if needed) without creating any git commits."
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
            entry_speaker = (entry.get("speaker") or "User").strip()
            user_msg = (entry.get("body") or "").strip()
            agent_msg = (entry.get("result_summary") or "").strip()
            history_lines.append(f"[Instruction #{seq} ({entry_speaker})]:\n{user_msg}")
            if agent_msg:
                history_lines.append(f"[Response #{seq} (omochi)]:\n{agent_msg}")
        prompt_parts.append("\n\n".join(history_lines))

    user_memories = instruction.get("user_memories") or {}
    memory_items = user_memories.get("items") if isinstance(user_memories, dict) else None
    if memory_items:
        speaker_label = speaker or user_memories.get("scope") or "current user"
        mem_lines = [
            f"Remembered context about the current speaker ({speaker_label}) "
            "(use naturally when helpful; occasionally follow up on open `follow_up` topics without forcing them into every reply; "
            "do NOT confuse this person with other speakers in the thread):"
        ]
        for item in memory_items:
            cat = item.get("category", "context")
            key = item.get("key", "")
            content = item.get("content", "")
            if content:
                mem_lines.append(f"- [{cat}] ({key}) {content}")
        prompt_parts.append("\n".join(mem_lines))
    elif speaker:
        prompt_parts.append(
            f"Speaker Context:\n"
            f"- The current speaker is `{speaker}`, who has no saved memories yet.\n"
            f"- If other speakers appeared earlier in the thread history, treat `{speaker}` as a distinct person "
            "and do NOT assume earlier speakers' names, roles, or preferences apply to them."
        )

    if attachments:
        att_lines = ["Attached image files (provided directly as multimodal input and also saved in `/workspace`; do NOT commit `.omochi_attachments/`):"]
        for att in attachments:
            att_path = att.get("path", "")
            att_name = att.get("name", "")
            att_mime = att.get("mimetype", "")
            if att_path:
                att_lines.append(f"- `{att_path}` ({att_name}, {att_mime})")
        prompt_parts.append("\n".join(att_lines))

    if prompt_parts:
        speaker_suffix = f", from {speaker}" if speaker else ""
        prompt_parts.append(f"Current instruction (#{sequence}{speaker_suffix}):\n{body}")
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

        primary_model = os.environ.get("GEMINI_MODEL", "").strip() or "gemini-3.5-flash"
        smart_model = os.environ.get("GEMINI_SMART_MODEL", "").strip()
        is_pr_context = bool(git_context and git_context.get("mode") == "pull_request")
        routing_enabled = bool(smart_model and smart_model != primary_model)

        memory_suffix = build_memory_instructions()
        fast_base, fast_sources = build_system_instructions(WORKSPACE_DIR, include_repo_instructions=False)
        fast_system_instructions = f"{fast_base}\n\n{memory_suffix}"
        full_base, full_sources = build_system_instructions(WORKSPACE_DIR, include_repo_instructions=True)
        full_system_instructions = f"{full_base}\n\n{memory_suffix}"

        step_error_handler = StepErrorHandler()
        logging.getLogger().addHandler(step_error_handler)
        loop = asyncio.get_running_loop()

        terminal_emitted = False
        summary = ""
        heartbeat_task = asyncio.create_task(heartbeat_worker(15.0))
        try:
            if routing_enabled and is_pr_context:
                if full_sources:
                    emit("progress", message=f"Loaded instructions from {', '.join(full_sources)}.")
                emit("progress", message=f"Pull Request context detected; starting directly with {smart_model}.")
                smart_models = list(dict.fromkeys([smart_model, "gemini-3.5-flash", primary_model]))
                summary, _ = await run_chat_with_fallback(
                    Agent, smart_models, full_system_instructions, prompt, attachments, sequence, step_error_handler, loop
                )
            elif routing_enabled:
                if fast_sources:
                    emit("progress", message=f"Loaded instructions from {', '.join(fast_sources)}.")
                emit(
                    "progress",
                    message=f"Starting in fast mode ({primary_model}, tools=disabled); smart model ({smart_model}) available for escalation.",
                )
                fast_models = list(dict.fromkeys([primary_model, smart_model, "gemini-3.5-flash"]))
                fast_instructions = build_routing_instructions(fast_system_instructions, smart_model)
                summary, used_model = await run_chat_with_fallback(
                    Agent, fast_models, fast_instructions, prompt, attachments, sequence, step_error_handler, loop, enable_tools=False
                )
                escalated, reason = parse_escalation_signal(summary)
                if escalated:
                    reason_note = reason or "Coding or complex reasoning required."
                    emit("progress", message=f"Escalating from {used_model} to {smart_model}: {reason_note}")
                    handoff_prompt = f"{prompt}\n\n[Model Handoff Note from {used_model}]: {reason_note}"
                    smart_models = list(dict.fromkeys([smart_model, "gemini-3.5-flash", primary_model]))
                    summary, _ = await run_chat_with_fallback(
                        Agent, smart_models, full_system_instructions, handoff_prompt, attachments, sequence, step_error_handler, loop
                    )
            else:
                if full_sources:
                    emit("progress", message=f"Loaded instructions from {', '.join(full_sources)}.")
                fallback_models = list(dict.fromkeys([primary_model, "gemini-3.5-flash", "gemini-3.1-flash-lite"]))
                emit("progress", message=f"Antigravity Agent initialized with workspace capabilities (model: {fallback_models[0]}).")
                summary, _ = await run_chat_with_fallback(
                    Agent, fallback_models, full_system_instructions, prompt, attachments, sequence, step_error_handler, loop
                )
        finally:
            heartbeat_task.cancel()
            try:
                await heartbeat_task
            except BaseException:
                pass
            logging.getLogger().removeHandler(step_error_handler)

        summary, memory_updates = extract_memory_updates(summary)
        for mem in memory_updates:
            action = str(mem.get("action") or "upsert").strip().lower()
            key = str(mem.get("key") or "").strip()
            category = str(mem.get("category") or "context").strip().lower()
            content = str(mem.get("content") or "").strip()
            emit(
                "memory",
                message=f"Memory {action}: {key}",
                action=action,
                key=key,
                category=category,
                content=content,
            )

        summary = summary.strip()
        if not summary:
            summary = f"Antigravity Agent completed instruction #{sequence}."

        emit("result", summary=summary, message=summary)
        terminal_emitted = True
        emit("completed", message=summary, summary=summary)
        sys.exit(0)

    except ImportError:
        emit("failed", message="google-antigravity package is not installed in the container environment.")
        sys.exit(3)
    except SystemExit as e:
        if not locals().get("terminal_emitted", False) and (e.code is None or e.code == 0):
            emit("failed", message="Antigravity exited unexpectedly with status 0 before completion.")
            sys.exit(4)
        raise
    except BaseException as e:
        emit("failed", message=f"Antigravity execution error ({type(e).__name__}): {e}")
        sys.exit(4)


if __name__ == "__main__":
    asyncio.run(main())
