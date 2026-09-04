#!/usr/bin/env python3
"""Fail the build on code that can never run and permissions nothing uses.

The dead-control audit checks settings. This checks the two larger versions
of the same failure, both of which have already shipped here:

  1. The whole nearby feature. `people` was @Published, the radar and the
     list both read it, and nothing ever assigned it — there was no server
     function to ask, so "Nobody nearby right now" was true by construction.
  2. Contacts. The app requested the address book during onboarding, carried
     the usage string, and never called match_contacts or set a phone hash.
     Asking for data you do not use is a review risk and the wrong thing to
     do regardless of review.

Neither fails to compile. Both look complete in review.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
PROJECT = ROOT / "project.yml"

# Permission string -> the API you must actually touch to justify asking.
PERMISSIONS = {
    "NSMicrophoneUsageDescription":        r"requestRecordPermission|AVAudioApplication|setMicrophone",
    "NSLocationWhenInUseUsageDescription": r"CLLocationManager",
    "NSContactsUsageDescription":          r"CNContactStore",
    "NSAppleMusicUsageDescription":        r"MPMusicPlayerController|MPRemoteCommand",
    "NSBluetoothAlwaysUsageDescription":   r"CBCentralManager|allowBluetooth",
    # Camera is a special case: LiveKit links the camera APIs whether or not
    # this app opens one, and Apple scans the binary, so the string is
    # mandatory and its absence fails the upload. Never flag it.
}
EXEMPT_PERMISSIONS = {"NSCameraUsageDescription", "NSLocalNetworkUsageDescription"}


def swift() -> str:
    return "\n".join(p.read_text() for p in SOURCES.rglob("*.swift"))


def published_never_filled(all_src: str) -> list[str]:
    out = []
    for path in SOURCES.rglob("*.swift"):
        text = path.read_text()
        for match in re.finditer(r"@Published[^\n]*var (\w+)", text):
            name = match.group(1)
            # Assignment in any form: direct, optional-chained through self,
            # a SwiftUI binding ($object.name), or a mutating collection call.
            assigned = re.search(
                rf"(?:self\??\.)?{name}\s*(?:=[^=]|\+=)|\${name}\b|"
                rf"\.{name}\s*=[^=]|{name}\.(?:append|insert|remove|removeAll)",
                all_src.replace(match.group(0), "", 1),
            )
            if not assigned:
                out.append(f"{path.name}: @Published {name} is read but never filled")
    return out


def permissions_never_used(all_src: str) -> list[str]:
    if not PROJECT.exists():
        return []
    declared = set(re.findall(r"(NS\w+UsageDescription):", PROJECT.read_text()))
    out = []
    for key in sorted(declared - EXEMPT_PERMISSIONS):
        api = PERMISSIONS.get(key)
        if api and not re.search(api, all_src):
            out.append(f"{key} is declared but nothing in the app uses {api.split('|')[0]}")
    return out


def main() -> int:
    all_src = swift()
    problems = published_never_filled(all_src) + permissions_never_used(all_src)
    for line in problems:
        print(line)
    if problems:
        print(f"\n{len(problems)} thing(s) that can never do what they claim.")
        return 1
    print("audit: no orphaned state, no permission asked for and unused")
    return 0


if __name__ == "__main__":
    sys.exit(main())
