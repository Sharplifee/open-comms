#!/usr/bin/env python3
"""Fail the build when the client calls an RPC with parameters the server
does not declare.

PostgREST rejects a call outright if it carries an unknown parameter, so a
wrong field name is not harmless — the whole call fails, at runtime, with the
Swift compiling cleanly and the function existing. That shipped once in the
previous app, on join_squad and create_squad, which are the two calls the
entire thing depends on.

The signatures live in EXPECTED rather than being queried live, so this runs
in CI without credentials. When a migration changes a signature, update it
here in the same commit — that coupling is the point.

Verified against live project tbgcinfhgskcjoevfkea on 2026-09-04.
"""

import re
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parent.parent / "Sources/OpenComms/Session/Backend.swift"

EXPECTED = {
    "block_device":     {"p_blocker", "p_blocked"},
    "blocked_devices":  {"p_blocker"},
    "claim_host":       {"p_squad_id", "p_device_id"},
    "create_squad":     {"p_code", "p_name", "p_device_id", "p_display_name"},
    "delete_device":    {"p_device_id"},
    "end_squad":        {"p_squad_id", "p_device_id"},
    "heartbeat":        {"p_squad_id", "p_device_id"},
    "join_squad":       {"p_code", "p_device_id", "p_display_name"},
    "leave_squad":      {"p_squad_id", "p_device_id"},
    "match_contacts":   {"p_hashes"},
    "nearby_devices":   {"p_device_id", "p_lat", "p_lon", "p_radius_m"},
    "register_device":  {"p_device_id", "p_display_name", "p_phone_hash",
                         "p_ghost", "p_identity"},
    "report_device":    {"p_reporter", "p_reported", "p_squad", "p_reason", "p_detail"},
    "set_ghost_mode":   {"p_device_id", "p_ghost"},
    "unblock_device":   {"p_blocker", "p_blocked"},
    "update_location":  {"p_device_id", "p_lat", "p_lon"},
}


def main() -> int:
    src = BACKEND.read_text()
    problems = []
    checked = 0

    # Calls look like: rpc("name", ["p_a": x, "p_b": y]) — possibly wrapped
    # across lines, so take everything up to the closing bracket of the dict.
    for match in re.finditer(r'rpc(?:Void)?\("([a-z_]+)",\s*\[(.*?)\]\)', src, re.S):
        name, body = match.group(1), match.group(2)
        checked += 1
        if name not in EXPECTED:
            problems.append(f"UNKNOWN RPC: {name} is called but not in the expected list")
            continue
        sent = set(re.findall(r'"(p_[a-z_]+)"\s*:', body))
        extra = sent - EXPECTED[name]
        missing = EXPECTED[name] - sent
        if extra:
            problems.append(
                f"BAD PARAM: {name} sends {sorted(extra)}, which the server does "
                f"not declare — PostgREST rejects the whole call"
            )
        if missing:
            problems.append(
                f"MISSING PARAM: {name} omits {sorted(missing)}, which the server "
                f"declares without a default"
            )

    for line in problems:
        print(line)

    if problems:
        print(f"\n{len(problems)} RPC mismatch(es). These fail at runtime, not compile time.")
        return 1

    print(f"audit: {checked} RPC call(s) checked against {len(EXPECTED)} signatures, "
          f"client and server agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
