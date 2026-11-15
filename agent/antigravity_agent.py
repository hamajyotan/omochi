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

        config = LocalAgentConfig(
            system_instructions=system_instructions,
            capabilities=CapabilitiesConfig(),
        )

        emit("progress", message="Antigravity Agent initialized with workspace capabilities.")

        async with Agent(config) as agent:
            emit("progress", message=f"Analyzing instruction #{sequence}...")
            response = await agent.chat(body)

            # Stream thinking deltas in real time
            async for thought in response.thoughts:
                thought_str = str(thought).strip()
                if thought_str:
                    emit("progress", message=f"🤔 {thought_str}")

            # Stream tool calls
            async for call in response.tool_calls:
                call_name = getattr(call, "name", str(call))
                emit("progress", message=f"🔧 Executing tool: {call_name}")

            # Stream response tokens
            tokens = []
            async for token in response:
                tokens.append(token)

            summary = "".join(tokens).strip()
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
