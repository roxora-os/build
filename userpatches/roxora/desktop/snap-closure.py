#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2026 Ga Hing Woo <gahing@gahingwoo.com>
"""Complete a list of snaps to seed with the snaps they need.

    snap-closure.py ARCH NAME=CHANNEL [NAME=CHANNEL...]

Asks the snap store what each snap is today in its channel, and adds the
base and the default content providers it names when the list does not have
them, from their stable channel. Prints one NAME=CHANNEL per line, the given
snaps first. snapd warns about a missing content provider but still writes
the seed, and the application then starts without its libraries, so the
build resolves them here and verify-image.sh validates the seed.
"""

import json
import re
import sys
import urllib.request

API = "https://api.snapcraft.io/v2/snaps/refresh"


def info(name, channel, arch):
    body = {"context": [],
            "actions": [{"action": "install", "instance-key": name, "name": name, "channel": channel}],
            "fields": ["base", "type", "snap-yaml"]}
    req = urllib.request.Request(API, data=json.dumps(body).encode(), headers={
        "Content-Type": "application/json",
        "Snap-Device-Series": "16",
        "Snap-Device-Architecture": arch,
    })
    last = None
    for _ in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                res = json.load(r)["results"][0]
            break
        except OSError as e:
            last = e
    else:
        sys.exit(f"snap-closure.py: store query for {name} failed: {last}")
    if res.get("result") == "error":
        sys.exit(f"snap-closure.py: {name} in {channel} for {arch}: {res['error'].get('message')}")
    return res["snap"]


def needs(snap):
    """Base and default content providers of a snap."""
    out = []
    if snap.get("type") == "app":
        # A snap without a base runs on the core snap.
        out.append(snap.get("base") or "core")
    for provider in re.findall(r"^\s*default-provider:\s*([A-Za-z0-9-]+)", snap.get("snap-yaml") or "", re.M):
        out.append(provider)
    return out


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    arch = sys.argv[1]
    channels = {}
    for arg in sys.argv[2:]:
        name, sep, channel = arg.partition("=")
        if not sep or not re.match(r"^[a-z0-9-]+$", name) or not re.match(r"^[a-z0-9./-]+$", channel):
            sys.exit(f"snap-closure.py: bad argument {arg!r}")
        channels[name] = channel
    todo = list(channels)
    while todo:
        name = todo.pop(0)
        for dep in needs(info(name, channels[name], arch)):
            if dep not in channels:
                print(f"snap-closure.py: {name} needs {dep}, adding it from stable", file=sys.stderr)
                channels[dep] = "stable"
                todo.append(dep)
    for name, channel in channels.items():
        print(f"{name}={channel}")


if __name__ == "__main__":
    main()
