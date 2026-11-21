#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
"""
CIC agent event logger — lightweight PostToolUse/PostToolUseFailure/Stop observer.

Reads Claude Code hook JSON from stdin, appends one JSONL line to:
  $CIC_WORKDIR/jobs/$CIC_JOB_ID/output/events.jsonl

No-ops silently if CIC_JOB_ID or CIC_WORKDIR is unset, or if the
output directory does not exist. Always exits 0 — never blocks the agent.
"""

import json
import os
import sys
import argparse
from datetime import datetime, timezone


def ts() -> str:
    """The current UTC time as an ISO 8601 string with second precision."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def summarize(data: dict, event: str) -> dict:
    """Reduce one hook payload to the event record: time, event and tool, plus the
    truncated command or the file path and the success flag (PostToolUse), the truncated
    error and interrupt flag (PostToolUseFailure) or the session id (Stop). Returns {}
    for a Stop issued while a stop hook is already active, so it is not logged.
    """
    tool = data.get("tool_name", "")
    record: dict = {"ts": ts(), "event": event, "tool": tool}

    if event == "PostToolUse":
        inp = data.get("tool_input", {})
        if tool == "Bash":
            record["cmd"] = (inp.get("command", "") or "")[:100]
        elif tool in ("Write", "Edit", "Read"):
            record["file"] = inp.get("file_path", "")
        resp = data.get("tool_response", {})
        record["ok"] = not resp.get("is_error", False)

    elif event == "PostToolUseFailure":
        record["error"] = str(data.get("error", ""))[:120]
        record["interrupted"] = data.get("is_interrupt", False)

    elif event == "Stop":
        # stop_hook_active guard: skip to avoid infinite loop
        if data.get("stop_hook_active"):
            return {}
        record["session"] = data.get("session_id", "")

    return record


def main() -> None:
    """Append the summarized hook payload from stdin to the job's events.jsonl; exits 0
    without writing when the job environment, the output directory or a parsable payload
    is missing.
    """
    parser = argparse.ArgumentParser()
    parser.add_argument("--event", required=True,
                        choices=["PostToolUse", "PostToolUseFailure", "Stop"])
    args = parser.parse_args()

    job_id = os.environ.get("CIC_JOB_ID", "")
    workdir = os.environ.get("CIC_WORKDIR", "")
    if not job_id or not workdir:
        sys.exit(0)

    out_path = os.path.join(workdir, "jobs", job_id, "output", "events.jsonl")
    if not os.path.isdir(os.path.dirname(out_path)):
        sys.exit(0)

    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    record = summarize(data, args.event)
    if not record:
        sys.exit(0)

    try:
        with open(out_path, "a") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
