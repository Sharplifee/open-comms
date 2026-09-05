#!/usr/bin/env python3
"""Confirm a build reached App Store Connect.

altool reports success for an upload that App Store Connect later throws away,
so a green pipeline has meant "nothing to install" more than once. This polls
until the build shows up, and fails the run if it never does.
"""
import json, os, sys, time, urllib.request
import jwt

KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER = os.environ["ASC_ISSUER_ID"]
SECRET = os.environ["ASC_KEY_P8"]
WANT = sys.argv[1] if len(sys.argv) > 1 else None
APP_ID = "6808660412"


def token():
    return jwt.encode(
        {"iss": ISSUER, "iat": int(time.time()), "exp": int(time.time()) + 900,
         "aud": "appstoreconnect-v1"},
        SECRET, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})


def builds():
    url = f"https://api.appstoreconnect.apple.com/v1/builds?filter[app]={APP_ID}&limit=10"
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token()})
    with urllib.request.urlopen(request) as response:
        return json.load(response).get("data", [])


# Apple took 24 minutes to process build 25, well past the old 15-minute
# window, so the run reported a failure for a build that was fine. A green
# upload followed by a red verify is worse than either alone: it reads as
# "Apple rejected it" and sends somebody hunting through an inbox for an
# ITMS email that does not exist. Sixty polls at thirty seconds is half an
# hour, which covers every processing time seen so far with room to spare.
for attempt in range(60):
    for build in builds():
        attributes = build["attributes"]
        if attributes.get("version") == WANT:
            print(f"build {WANT} present, state {attributes.get('processingState')}")
            sys.exit(0)
    print(f"build {WANT} not visible yet, waiting… ({attempt + 1}/60)")
    time.sleep(30)

print(f"build {WANT} never appeared in App Store Connect")
sys.exit(1)
