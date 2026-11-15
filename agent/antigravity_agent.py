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


async def heartbeat_worker(interval: float = 15.0):
    count = 1
    while True:
        await asyncio.sleep(interval)
        emit("progress", message=f"Antigravity Agent is reasoning and processing ({count * int(interval)}s elapsed)...")
        count += 1


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

        async with Agent(config) as agent:
            emit("progress", message=f"Analyzing instruction #{sequence} with Antigravity...")
            heartbeat_task = asyncio.create_task(heartbeat_worker(15.0))
            try:
                response = await agent.chat(body)
            finally:
                heartbeat_task.cancel()
                try:
                    await heartbeat_task
                except asyncio.CancelledError:
                    pass

            emit("progress", message="Received response from Antigravity, formatting summary...")

            # Inspect response object for debugging
            response_attrs = [m for m in dir(response) if not m.startswith("_")]
            emit("log", message=f"Antigravity response type: {type(response).__name__}, attributes: {response_attrs}")

            summary = ""
            tokens = []
            try:
                # Primary official pattern from Antigravity SDK: async for token in response
                async def stream_tokens():
                    async for token in response:
                        tokens.append(str(token))

                await asyncio.wait_for(stream_tokens(), timeout=90.0)
                summary = "".join(tokens).strip()
            except TypeError:
                # If response is not an async iterable, check text or content properties
                emit("log", message="Response is not an async iterable, checking text/content properties...")
                if hasattr(response, "text"):
                    text_val = getattr(response, "text")
                    if callable(text_val):
                        res = text_val()
                        if asyncio.iscoroutine(res):
                            res = await asyncio.wait_for(res, timeout=30.0)
                        summary = str(res)
                    else:
                        summary = str(text_val)
                elif hasattr(response, "content"):
                    summary = str(response.content)
                else:
                    summary = str(response)
            except asyncio.TimeoutError:
                emit("log", message="Token stream collection timed out after 90s, using collected tokens.")
                summary = "".join(tokens).strip()
            except Exception as e:
                emit("log", message=f"Error reading response tokens: {e}")
                summary = "".join(tokens).strip()

            summary = summary.strip()
            if not summary:
                summary = f"Antigravity Agent completed instruction #{sequence}."

            emit("result", summary=summary)
            emit("completed", message="Antigravity Agent execution completed successfully.")
            sys.exit(0)

    except ImportError:
        emit("failed", message="google-antigravity package is not installed in the container environment.")
        sys.exit(3)
    except Exception as e:
        emit("failed", message=f"Antigravity execution error: {e}")
        sys.exit(4)


if __name__ == "__main__":
    asyncio.run(main())
