#!/usr/bin/env python3
"""Fail the build when a setting exists but nothing acts on it.

This is the bug the previous app kept producing — five times a control
shipped that moved, saved its value, and changed nothing: the duck posted a
notification nobody observed; self monitor, noise suppression, auto pause and
auto rewind had sliders and no consumers; the visibility picker was bound to
two booleans an enum had already replaced.

Every one compiled. Every one looked right in review. The compiler cannot
catch it, because storing a value IS a use — so it has to be checked
structurally: a preference that appears in the UI must also appear somewhere
that is not the UI, or it does nothing.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
MODELS = SOURCES / "OpenComms" / "Models" / "Models.swift"

# Display-only text and identity, not behaviour to wire up.
EXEMPT = {"label", "detail", "id", "subtitle", "symbol", "displayName", "onboarded"}


def preference_names() -> list[str]:
    text = MODELS.read_text()
    match = re.search(r"struct Preferences[^{]*\{(.*?)\n\}", text, re.S)
    if not match:
        print("audit: could not find the Preferences struct", file=sys.stderr)
        return sys.exit(2)
    body = match.group(1)
    # `var x = ...` / `var x: T = ...` is stored; `var x: T { ... }` is computed.
    names = []
    for line in body.splitlines():
        m = re.match(r"\s*var ([a-zA-Z]+)\s*(?::[^={]+)?=", line)
        if m and m.group(1) not in EXEMPT:
            names.append(m.group(1))
    return names


def derived_from() -> dict[str, list[str]]:
    """Computed properties on Preferences, mapped to the stored ones they read.

    A stored setting can be perfectly well wired up through a computed
    property — `sensitivity` is consumed everywhere as `thresholdDB`. Counting
    only the raw name would flag that as dead and teach everyone to ignore
    this check, which is worse than not having it.
    """
    text = MODELS.read_text()
    match = re.search(r"struct Preferences[^{]*\{(.*?)\n\}", text, re.S)
    body = match.group(1) if match else ""
    stored = set(preference_names())
    out: dict[str, list[str]] = {}
    for name, expr in re.findall(r"var ([a-zA-Z]+):\s*[^={]+\{(.*?)\n    \}", body, re.S):
        out[name] = [s for s in stored if re.search(rf"\b{s}\b", expr)]
    return out


def main() -> int:
    prefs = preference_names()
    derived = derived_from()
    ui_hits, behaviour_hits = {}, {}

    for path in SOURCES.rglob("*.swift"):
        text = path.read_text()
        is_ui = "/UI/" in str(path)
        is_model = path.name in {"Models.swift", "Store.swift"}
        for name in prefs:
            aliases = [name] + [c for c, sources in derived.items() if name in sources]
            if not any(re.search(rf"\.{alias}\b", text) for alias in aliases):
                continue
            if is_ui:
                ui_hits.setdefault(name, []).append(path.name)
            elif not is_model:
                behaviour_hits.setdefault(name, []).append(path.name)

    dead = sorted(n for n in prefs if n in ui_hits and n not in behaviour_hits)
    unused = sorted(n for n in prefs if n not in ui_hits and n not in behaviour_hits)

    for name in dead:
        print(f"DEAD CONTROL: {name} — shown in {', '.join(sorted(set(ui_hits[name])))} "
              f"but nothing outside the UI reads it")
    for name in unused:
        print(f"UNUSED SETTING: {name} — stored but neither shown nor acted on")

    if dead:
        print(f"\n{len(dead)} control(s) move and do nothing. Wire it up or remove it.")
        return 1

    print(f"audit: {len(prefs)} settings checked, every one has something acting on it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
