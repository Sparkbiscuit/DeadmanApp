#!/usr/bin/env python3
"""Minimal stdio MCP bridge: Claude Code -> locally authenticated Codex CLI.

This server intentionally has no OpenAI API key path. `codex exec` authenticates
through the user's existing ChatGPT/Codex CLI login. It exposes exactly one tool
so the Claude coordinator retains control over every delegation.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

CODEX_BIN = os.environ.get("CODEX_BIN", "codex")
WORKSPACE = Path(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd())).resolve()
TIMEOUT_SECONDS = int(os.environ.get("CODEX_WORKER_TIMEOUT", "1200"))
FIXED_MODEL = os.environ.get("CODEX_FIXED_MODEL", "").strip()
REASONING_EFFORT = os.environ.get("CODEX_REASONING_EFFORT", "").strip()

ROLES = {
    "researcher": "Explore and report evidence only. Do not edit files.",
    "planner": "Produce an implementation plan with risks and verification steps. Do not edit files.",
    "implementer": "Make the smallest correct change, then run focused checks and report the diff.",
    "reviewer": "Inspect the specified work for correctness, regressions, security, and missing tests. Do not edit files.",
    "tester": "Analyze test coverage and run relevant safe tests. Do not edit files unless explicitly permitted.",
}

TOOL = {
    "name": "run_gpt_worker",
    "description": "Delegate one bounded task to the locally authenticated Codex CLI. Use read-only mode for research, planning, review, and testing. Only set write=true for one scoped implementation task at a time.",
    "inputSchema": {
        "type": "object",
        "required": ["role", "task"],
        "properties": {
            "role": {"type": "string", "enum": list(ROLES)},
            "task": {"type": "string", "description": "Precise objective, constraints, relevant paths, and expected outcome."},
            "write": {"type": "boolean", "default": False},
            "model": {"type": "string", "description": "Optional Codex model override. Omit to use the ChatGPT subscription's configured default."},
        },
        "additionalProperties": False,
    },
}


def send(message: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def tool_result(text: str, is_error: bool = False) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def run_worker(arguments: dict[str, Any]) -> dict[str, Any]:
    role = arguments.get("role")
    task = arguments.get("task", "").strip()
    write = arguments.get("write", False)
    requested_model = arguments.get("model", "").strip()

    if role not in ROLES or not task:
        return tool_result("role and a non-empty task are required.", True)
    if len(task) > 30000:
        return tool_result("Task is too long; pass a concise brief and file paths instead.", True)
    if FIXED_MODEL == "REPLACE_WITH_THE_EXACT_CODEX_MODEL_ID":
        return tool_result("Set CODEX_FIXED_MODEL in .mcp.json to a model ID supported by your Codex CLI before running workers.", True)
    if FIXED_MODEL and requested_model and requested_model != FIXED_MODEL:
        return tool_result(f"This executor is pinned to {FIXED_MODEL}; model override {requested_model} was rejected.", True)
    model = FIXED_MODEL or requested_model

    # A read-only worker cannot mutate the repository, even if its prompt is compromised.
    sandbox = "workspace-write" if write else "read-only"
    permission = "You may edit only files needed for the stated task." if write else "You must not edit files."
    prompt = f"""You are the {role} executor in a coordinator-executor loop.
{ROLES[role]}
{permission}

Workspace: {WORKSPACE}

Task:
{task}

Return a concise, evidence-based final report with:
- outcome;
- files inspected or changed;
- commands/tests run and results;
- remaining risks or blockers.
Do not perform network, credential, deployment, or external-account actions.
"""

    with tempfile.NamedTemporaryFile(prefix="codex-final-", suffix=".txt", delete=False) as output:
        output_path = Path(output.name)
    command = [CODEX_BIN, "exec", "--ephemeral", "--color", "never", "--sandbox", sandbox,
               "--cd", str(WORKSPACE), "--output-last-message", str(output_path)]
    if model:
        command.extend(["--model", model])
    if REASONING_EFFORT:
        command.extend(["--config", f'model_reasoning_effort="{REASONING_EFFORT}"'])
    command.append(prompt)

    try:
        completed = subprocess.run(
            command, stdin=subprocess.DEVNULL, text=True, capture_output=True,
            timeout=TIMEOUT_SECONDS, cwd=WORKSPACE,
        )
        final = output_path.read_text(errors="replace").strip() if output_path.exists() else ""
        if not final:
            final = completed.stdout.strip() or completed.stderr.strip() or "Codex returned no final report."
        if completed.returncode:
            return tool_result(f"Codex worker failed (exit {completed.returncode}).\n\n{final}", True)
        return tool_result(final)
    except FileNotFoundError:
        return tool_result(f"Codex executable not found: {CODEX_BIN}. Set CODEX_BIN or install/sign in to Codex CLI.", True)
    except subprocess.TimeoutExpired:
        return tool_result(f"Codex worker timed out after {TIMEOUT_SECONDS} seconds.", True)
    finally:
        output_path.unlink(missing_ok=True)


def handle(message: dict[str, Any]) -> None:
    method = message.get("method")
    request_id = message.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "codex-executor", "version": "1.0.0"}}})
    elif method == "notifications/initialized":
        return
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"tools": [TOOL]}})
    elif method == "tools/call":
        result = run_worker(message.get("params", {}).get("arguments", {}))
        send({"jsonrpc": "2.0", "id": request_id, "result": result})
    elif request_id is not None:
        send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": f"Unsupported method: {method}"}})


for raw_line in sys.stdin:
    try:
        handle(json.loads(raw_line))
    except Exception as error:  # Keep the MCP process alive and return a useful error.
        send({"jsonrpc": "2.0", "id": None, "error": {"code": -32603, "message": str(error)}})
