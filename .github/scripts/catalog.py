#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2026 Ga Hing Woo <gahing@gahingwoo.com>
"""Write roxora-catalog.json and the release notes for a release.

    catalog.py make  --dir DIR --tag vYYYY.MM.N[-beta.N] --boards boards.conf --ref armbian.ref
    catalog.py mark  --catalog roxora-catalog.json --tested IMAGE[,IMAGE...] [--full-release]
    catalog.py notes --catalog roxora-catalog.json

"make" reads the files images.yml leaves next to each image in DIR
(<name>.img.xz, .img.xz.sha256, .verify.txt, .extract_size, .extract_sha256,
.kernel) and prints the catalog described in docs/release-contract.md.
"mark" sets the listed images (BOARD, BOARD:RELEASE, BOARD:RELEASE:BRANCH or
BOARD:RELEASE:BRANCH:FLAVOR) to hardware-tested and prints the new catalog.
A tag vYYYY.MM.N makes a release; vYYYY.MM.N-beta.N makes a beta, published
as a GitHub pre-release. "mark" leaves that as it is, unless --full-release
turns a beta into a release.
"notes" prints the release notes for a catalog.
"""

import argparse
import datetime
import json
import pathlib
import re
import sys

REPO = "roxora-os/build"
UBUNTU_VERSIONS = {"noble": "24.04", "resolute": "26.04"}
TAG_RE = re.compile(r"^v(\d{4}\.\d{2}\.\d+(-beta\.\d+)?)$")
# Image flavors (FLAVOR column of boards.conf) and what the notes call them.
FLAVORS = {"cli": "command line", "gnome-minimal": "minimal GNOME desktop", "gnome": "GNOME desktop"}


def read_boards(path):
    boards = []
    for line in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        board, branch, release, flavor, status, soc, vendor, *name = line.split()
        if flavor not in FLAVORS:
            sys.exit(f"boards.conf: unknown flavor {flavor!r} in {line!r}")
        boards.append({"board": board, "branch": branch, "release": release,
                       "flavor": flavor, "status": status, "soc": soc,
                       "vendor": vendor, "name": " ".join(name)})
    return boards


def needs_uefi(board):
    """True for a board file built on userpatches/roxora/uefi/board.inc: its
    image has no U-Boot and boots only on a board with UEFI firmware."""
    conf = pathlib.Path("userpatches/config/boards") / f"{board}.conf"
    return conf.is_file() and "roxora/uefi/board.inc" in conf.read_text(encoding="utf-8")


def first_field(path):
    return pathlib.Path(path).read_text(encoding="utf-8").split()[0]


def make(args):
    m = TAG_RE.match(args.tag)
    if not m:
        sys.exit(f"tag {args.tag!r} is not vYYYY.MM.N or vYYYY.MM.N-beta.N")
    version = m.group(1)
    beta = m.group(2) is not None
    base = f"https://github.com/{REPO}/releases/download/{args.tag}/"
    d = pathlib.Path(args.dir)
    images = []
    for b in read_boards(args.boards):
        # A command line image has no flavor in its name.
        suffix = "" if b["flavor"] == "cli" else f"-{b['flavor']}"
        stem = f"roxora-{b['board']}-{b['release']}-{b['branch']}{suffix}-{version}"
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
            "vendor": b["vendor"],
            "soc": b["soc"],
            "release": b["release"],
            "ubuntu_version": UBUNTU_VERSIONS[b["release"]],
            "branch": b["branch"],
            "flavor": b["flavor"],
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
        if needs_uefi(b["board"]):
            images[-1]["firmware"] = "uefi"
        spi = d / f"{stem}-spi.img"
        if spi.is_file():
            images[-1]["spi"] = {
                "file": spi.name,
                "url": base + spi.name,
                "size": spi.stat().st_size,
                "sha256": first_field(d / f"{stem}-spi.img.sha256"),
            }
    catalog = {
        "schema": 1,
        "release": {
            "tag": args.tag,
            "version": version,
            "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
            # A release once its images pass the checks in CI (and the QEMU
            # boot for UEFI images); a beta when the tag says so.
            "prerelease": beta,
            "url": f"https://github.com/{REPO}/releases/tag/{args.tag}",
            "armbian_ref": pathlib.Path(args.ref).read_text(encoding="utf-8").strip(),
        },
        "images": images,
    }
    print(json.dumps(catalog, indent=2))


def mark(args):
    """--tested takes comma-separated entries: BOARD for all of its images,
    BOARD:RELEASE for one Ubuntu release, BOARD:RELEASE:BRANCH for one kernel
    branch, BOARD:RELEASE:BRANCH:FLAVOR for one image (for example
    radxa-rock-4d:resolute:edge:cli). A shorter entry covers every flavor."""
    catalog = json.loads(pathlib.Path(args.catalog).read_text(encoding="utf-8"))
    entries = [e for e in args.tested.split(",") if e]
    for e in entries:
        parts = e.split(":")
        if len(parts) > 4:
            sys.exit(f"{e!r}: use BOARD, BOARD:RELEASE, BOARD:RELEASE:BRANCH or BOARD:RELEASE:BRANCH:FLAVOR")
        # Catalogs from before the desktop images have no flavor: all cli.
        hits = [i for i in catalog["images"]
                if [i["board"], i["release"], i["branch"], i.get("flavor", "cli")][:len(parts)] == parts]
        if not hits:
            sys.exit(f"not in this release: {e}")
        for i in hits:
            i["status"] = "hardware-tested"
    if args.full_release:
        catalog["release"]["prerelease"] = False
    print(json.dumps(catalog, indent=2))


def notes(args):
    c = json.loads(pathlib.Path(args.catalog).read_text(encoding="utf-8"))
    r = c["release"]
    out = [f"Roxora {r['version']}, built from armbian/build {r['armbian_ref'][:12]}.", ""]
    groups = {"hardware-tested": [], "ci-only": []}
    for i in c["images"]:
        groups[i["status"]].append(i)

    def entry(i, file=None):
        flavor = i.get("flavor", "cli")
        return f"- {i['board_name']} ({FLAVORS.get(flavor, flavor)}): {file or i['file']}"

    out.append("Hardware-tested (docs/hardware-test.md passed on the board):")
    out += [entry(i) for i in groups["hardware-tested"]] or ["- none yet"]
    out.append("")
    out.append("CI-verified only (built and checked by verify-image.sh, not booted yet):")
    out += [entry(i) for i in groups["ci-only"]] or ["- none"]
    out.append("")
    if any(i.get("flavor", "cli") != "cli" for i in c["images"]):
        out.append("Flavors: command line images have no flavor in their file name; "
                   "`gnome-minimal` is Ubuntu's minimal GNOME desktop (ubuntu-desktop-minimal), "
                   "`gnome` the full one (ubuntu-desktop).")
        out.append("")
    systems = dict.fromkeys(
        "Ubuntu {} ({}) with the Armbian {} kernel {}".format(
            i["ubuntu_version"], i["release"], i["branch"], i["kernel"])
        for i in c["images"])
    if systems:
        out.append("Systems: " + "; ".join(systems) + ".")
        out.append("")
    uefi = [i for i in c["images"] if i.get("firmware") == "uefi"]
    if uefi:
        out.append("UEFI images (no U-Boot inside; the board needs UEFI firmware such as edk2-rk3576 in its SPI flash first):")
        out += [entry(i) for i in uefi]
        out.append("")
    spi = [i for i in c["images"] if i.get("spi")]
    if spi:
        out.append("SPI bootloader (written to the board's SPI flash, not to the card):")
        out += [entry(i, i["spi"]["file"]) for i in spi]
    out.append("")
    out.append("Check a download with `sha256sum -c <file>.sha256`. The verify output of each image is attached as <file>.verify.txt.")
    if r["prerelease"]:
        out.append("")
        out.append("This is a beta. Use the newest release unless you want to try what comes next.")
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
                   help="publish a beta as a release")
    n = sub.add_parser("notes")
    n.add_argument("--catalog", required=True)
    args = p.parse_args()
    {"make": make, "mark": mark, "notes": notes}[args.cmd](args)


if __name__ == "__main__":
    main()
