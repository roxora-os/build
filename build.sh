#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2026 Ga Hing Woo <gahing@gahingwoo.com>
#
# Build a Roxora image.
#
#   ./build.sh BOARD=radxa-rock-4d BRANCH=edge RELEASE=noble [VERSION=2026.11.0] [ARGS...]
#
# Clones armbian/build at the commit in armbian.ref into cache/armbian-build
# (once), copies userpatches/ into it, and runs its compile.sh with the roxora
# extension enabled. Any other KEY=VALUE arguments are passed to compile.sh.
#
# The finished image is written to
# output/roxora-<board>-<release>-<branch>-<version>.img.xz with a .sha256 file.
#
# Armbian's build needs root (it uses sudo) or Docker.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARMBIAN_URL="https://github.com/armbian/build.git"
CHECKOUT="${ROOT}/cache/armbian-build"
OUTPUT="${ROOT}/output"

die() {
	echo "build.sh: $*" >&2
	exit 1
}

usage() {
	sed -n '5,17s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

BOARD="${BOARD:-}"
BRANCH="${BRANCH:-}"
RELEASE="${RELEASE:-}"
VERSION="${VERSION:-dev}"
extensions="roxora"
passthrough=()

for arg in "$@"; do
	case "${arg}" in
		-h | --help) usage 0 ;;
		BOARD=*) BOARD="${arg#*=}" ;;
		BRANCH=*) BRANCH="${arg#*=}" ;;
		RELEASE=*) RELEASE="${arg#*=}" ;;
		VERSION=*) VERSION="${arg#*=}" ;;
		ENABLE_EXTENSIONS=* | EXT=*) extensions="${extensions},${arg#*=}" ;;
		BUILD_MINIMAL=* | BUILD_DESKTOP=*) die "${arg%%=*} is fixed by Roxora (minimal images only)" ;;
		*=*) passthrough+=("${arg}") ;;
		*) die "unknown argument '${arg}' (try --help)" ;;
	esac
done

[[ -n "${BOARD}" && -n "${BRANCH}" && -n "${RELEASE}" ]] || usage 1
[[ "${VERSION}" =~ ^[0-9A-Za-z.+~-]+$ ]] || die "VERSION '${VERSION}' has characters that do not belong in a file name"

# The combination must be listed in boards.conf.
if ! awk -v b="${BOARD}" -v br="${BRANCH}" -v r="${RELEASE}" \
	'!/^[[:space:]]*(#|$)/ && $1 == b && $2 == br && $3 == r { found = 1 } END { exit !found }' \
	"${ROOT}/boards.conf"; then
	die "${BOARD} ${BRANCH} ${RELEASE} is not listed in boards.conf"
fi

ref="$(tr -d '[:space:]' < "${ROOT}/armbian.ref")"
[[ "${ref}" =~ ^[0-9a-f]{40}$ ]] || die "armbian.ref does not hold a full commit SHA"

# Get armbian/build at the pinned commit, or check the one we already have.
if [[ ! -d "${CHECKOUT}/.git" ]]; then
	echo "build.sh: fetching armbian/build ${ref}"
	mkdir -p "${CHECKOUT}"
	git -C "${CHECKOUT}" init -q
	git -C "${CHECKOUT}" fetch -q --depth 1 "${ARMBIAN_URL}" "${ref}"
	git -C "${CHECKOUT}" -c advice.detachedHead=false checkout -q FETCH_HEAD
fi
head="$(git -C "${CHECKOUT}" rev-parse HEAD)"
if [[ "${head}" != "${ref}" ]]; then
	die "cache/armbian-build is at ${head}, armbian.ref wants ${ref}; remove cache/armbian-build and run again"
fi
if [[ -n "$(git -C "${CHECKOUT}" status --porcelain --untracked-files=normal)" ]]; then
	die "cache/armbian-build has local changes; remove cache/armbian-build and run again"
fi

# Roxora's userpatches replace whatever is in the checkout. Armbian ignores
# userpatches/ in git, so this does not make the checkout dirty.
rm -rf "${CHECKOUT}/userpatches"
cp -a "${ROOT}/userpatches" "${CHECKOUT}/userpatches"
cp "${ROOT}/boards.conf" "${CHECKOUT}/userpatches/roxora/boards.conf"

stamp="$(mktemp)"
trap 'rm -f "${stamp}"' EXIT

(
	cd "${CHECKOUT}"
	./compile.sh build \
		BOARD="${BOARD}" BRANCH="${BRANCH}" RELEASE="${RELEASE}" \
		BUILD_MINIMAL=yes BUILD_DESKTOP=no KERNEL_CONFIGURE=no \
		ENABLE_EXTENSIONS="${extensions}" ROXORA_VERSION="${VERSION}" \
		COMPRESS_OUTPUTIMAGE=sha,xz EXPERT=yes \
		"${passthrough[@]}"
)

# Pick up the image this run produced and give it Roxora's name.
built="$(find "${CHECKOUT}/output/images" -maxdepth 1 -name '*.img.xz' -newer "${stamp}" -printf '%T@ %p\n' 2> /dev/null |
	sort -n | awk 'END { print $2 }')"
[[ -n "${built}" ]] || die "compile.sh finished but no new image is in cache/armbian-build/output/images"

name="roxora-${BOARD}-${RELEASE}-${BRANCH}-${VERSION}.img.xz"
mkdir -p "${OUTPUT}"
cp -f "${built}" "${OUTPUT}/${name}"
(cd "${OUTPUT}" && sha256sum "${name}" > "${name}.sha256")

echo "build.sh: ${OUTPUT}/${name}"
