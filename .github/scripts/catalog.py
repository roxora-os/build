#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2026 Ga Hing Woo <gahing@gahingwoo.com>
"""Write roxora-catalog.json and the release notes for a release.

    catalog.py make  --dir DIR --tag vYYYY.MM.N --boards boards.conf --ref armbian.ref
    catalog.py mark  --catalog roxora-catalog.json --tested BOARD[,BOARD...] [--full-release]
    catalog.py notes --catalog roxora-catalog.json

"make" reads the files images.yml leaves next to each image in DIR
(<name>.img.xz, .img.xz.sha256, .verify.txt, .extract_size, .extract_sha256,
.kernel) and prints the catalog described in docs/release-contract.md.
"mark" sets the listed boards to hardware-tested and prints the new catalog.
The release stays a pre-release unless every image is hardware-tested and
--full-release is given.
"notes" prints the release notes for a catalog.
"""

import argparse
import datetime
import json
import pathlib
import re
import sys

REPO = "roxora-os/build"
UBUNTU_VERSIONS = {"noble": "24.04"}
TAG_RE = re.compile(r"^v(\d{4}\.\d{2}\.\d+)$")


def read_boards(path):
    boards = []
    for line in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        board, branch, release, status, soc, *name = line.split()
        boards.append({"board": board, "branch": branch, "release": release,
                       "status": status, "soc": soc, "name": " ".join(name)})
    return boards


def first_field(path):
    return pathlib.Path(path).read_text(encoding="utf-8").split()[0]


def make(args):
    m = TAG_RE.match(args.tag)
    if not m:
        sys.exit(f"tag {args.tag!r} is not vYYYY.MM.N")
    version = m.group(1)
    base = f"https://github.com/{REPO}/releases/download/{args.tag}/"
    d = pathlib.Path(args.dir)
    images = []
    for b in read_boards(args.boards):
        stem = f"roxora-{b['board']}-{b['release']}-{b['branch']}-{version}"
        img = d / f"{stem}.img.xz"
        if not img.is_file():
            sys.exit(f"missing {img}")
        sha = first_field(d / f"{stem}.img.xz.sha256")
        kernel = first_field(d / f"{stem}.kernel").split("-", 1)[0]
        if not re.match(r"^\d+\.\d+(\.\d+)?$", kernel):
            sys.exit(f"{stem}: kernel version {kernel!r} does not look like a version")
        images.append({
            "board": b["board"],
            "board_name": b["name"],
            "soc": b["soc"],
            "release": b["release"],
            "ubuntu_version": UBUNTU_VERSIONS[b["release"]],
            "branch": b["branch"],
            "kernel": kernel,
            "file": img.name,
            "url": base + img.name,
            "size": img.stat().st_size,
            "sha256": sha,
            "extract_size": int(first_field(d / f"{stem}.extract_size")),
            "extract_sha256": first_field(d / f"{stem}.extract_sha256"),
            # A new release has not been booted by anyone yet.
            "status": "ci-only",
            "verify_url": base + f"{stem}.verify.txt",
        })
    catalog = {
        "schema": 1,
        "release": {
            "tag": args.tag,
            "version": version,
            "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
            "prerelease": True,
            "url": f"https://github.com/{REPO}/releases/tag/{args.tag}",
            "armbian_ref": pathlib.Path(args.ref).read_text(encoding="utf-8").strip(),
        },
        "images": images,
    }
    print(json.dumps(catalog, indent=2))


def mark(args):
    catalog = json.loads(pathlib.Path(args.catalog).read_text(encoding="utf-8"))
    tested = {b for b in args.tested.split(",") if b}
    known = {i["board"] for i in catalog["images"]}
    if tested - known:
        sys.exit(f"not in this release: {', '.join(sorted(tested - known))}")
    for i in catalog["images"]:
        if i["board"] in tested:
            i["status"] = "hardware-tested"
    all_tested = all(i["status"] == "hardware-tested" for i in catalog["images"])
    # A full release also needs the maintainer's explicit go-ahead.
    catalog["release"]["prerelease"] = not (all_tested and args.full_release)
    print(json.dumps(catalog, indent=2))


def notes(args):
    c = json.loads(pathlib.Path(args.catalog).read_text(encoding="utf-8"))
    r = c["release"]
    out = [f"Roxora {r['version']}, built from armbian/build {r['armbian_ref'][:12]}.", ""]
    groups = {"hardware-tested": [], "ci-only": []}
    for i in c["images"]:
        groups[i["status"]].append(i)
    out.append("Hardware-tested (docs/hardware-test.md passed on the board):")
    out += [f"- {i['board_name']}: {i['file']}" for i in groups["hardware-tested"]] or ["- none yet"]
    out.append("")
    out.append("CI-verified only (built and checked by verify-image.sh, not booted yet):")
    out += [f"- {i['board_name']}: {i['file']}" for i in groups["ci-only"]] or ["- none"]
    out.append("")
    out.append("Each image: Ubuntu {} ({}), Armbian {} kernel {}.".format(
        c["images"][0]["ubuntu_version"], c["images"][0]["release"],
        c["images"][0]["branch"], c["images"][0]["kernel"]) if c["images"] else "")
    out.append("")
    out.append("Check a download with `sha256sum -c <file>.sha256`. The verify output of each image is attached as <file>.verify.txt.")
    if r["prerelease"]:
        out.append("")
        out.append("This is a pre-release: not every image has been tested on hardware.")
    print("\n".join(out))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("make")
    m.add_argument("--dir", required=True)
    m.add_argument("--tag", required=True)
    m.add_argument("--boards", required=True)
    m.add_argument("--ref", required=True)
    k = sub.add_parser("mark")
    k.add_argument("--catalog", required=True)
    k.add_argument("--tested", required=True)
    k.add_argument("--full-release", action="store_true",
                   help="allow a full release once every image is hardware-tested")
    n = sub.add_parser("notes")
    n.add_argument("--catalog", required=True)
    args = p.parse_args()
    {"make": make, "mark": mark, "notes": notes}[args.cmd](args)


if __name__ == "__main__":
    main()
