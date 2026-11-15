#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2026 Ga Hing Woo <gahing@gahingwoo.com>
#
# Build Roxora's release packages for one Ubuntu release.
#
#   userpatches/roxora/packages/build.sh --suite <codename> --out <directory> [--flavor <flavor>]...
#
# roxora-release: what every Roxora system of this release shares (the apt
# sources and pins of Roxora's repository and of the hardware repository,
# cloud-init's settings, the system font directories) and its dependencies
# on Roxora's keyring, hwtool and wallpapers. One package per flavor
# (roxora-cli, roxora-desktop-gnome-minimal, roxora-desktop-gnome), which
# depends on roxora-release of the same version, on what that flavor needs,
# and writes /etc/roxora-release. Without --flavor, all three.
#
# The version is ROXORA_RELEASE of roxora-repo.conf, "+" and the Ubuntu
# version: 2026.11.5+24.04. The image build runs this script and installs
# the packages it writes; roxora-os/apt runs it at each release's tag and
# publishes them. Every file gets the same time stamp, so a rebuild gives the
# same packages. A suite that boards.conf has no image for is skipped.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROXORA_DIR="$(dirname "${HERE}")"

suite="" out=""
declare -a flavors=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--suite) suite="${2:-}" && shift 2 ;;
		--out) out="${2:-}" && shift 2 ;;
		--flavor) flavors+=("${2:-}") && shift 2 ;;
		*)
			echo "usage: $0 --suite <codename> --out <directory> [--flavor <flavor>]..." >&2
			exit 2
			;;
	esac
done
[[ -n "${suite}" && -n "${out}" ]] || {
	echo "usage: $0 --suite <codename> --out <directory> [--flavor <flavor>]..." >&2
	exit 2
}
[[ ${#flavors[@]} -gt 0 ]] || flavors=(cli gnome-minimal gnome)

declare ROXORA_REPO_URI ROXORA_REPO_HOST ROXORA_RELEASE HWTOOL_VERSION WALLPAPERS_VERSION KEYRING_VERSION
declare HW_REPO HW_REPO_ORIGIN
# shellcheck source=userpatches/roxora/roxora-repo.conf
source "${ROXORA_DIR}/roxora-repo.conf"
# shellcheck source=userpatches/roxora/hardware-repo.conf
source "${ROXORA_DIR}/hardware-repo.conf"

die() {
	echo "packages/build.sh: $1" >&2
	exit 1
}

# boards.conf is at the top of the repository, and build.sh copies it next to
# this directory in the Armbian checkout.
boards="${ROXORA_DIR}/boards.conf"
[[ -f "${boards}" ]] || boards="${ROXORA_DIR}/../../boards.conf"
[[ -f "${boards}" ]] || die "no boards.conf"
if ! awk -v r="${suite}" '!/^[[:space:]]*(#|$)/ && $3 == r { found = 1 } END { exit !found }' "${boards}"; then
	echo "packages/build.sh: boards.conf has no image for ${suite}, nothing to build"
	exit 0
fi
# The Ubuntu version, and the release a release upgrade comes from.
previous=""
case "${suite}" in
	noble) ubuntu=24.04 ;;
	resolute) ubuntu=26.04 previous=noble ;;
	*) die "no Ubuntu version known for ${suite}" ;;
esac
[[ "${ROXORA_RELEASE}" =~ ^([0-9]{4})\.([0-9]{2})\.[0-9]+(~beta\.[0-9]+)?$ ]] ||
	die "ROXORA_RELEASE '${ROXORA_RELEASE}' is not YYYY.MM.N or YYYY.MM.N~beta.N"
epoch="$(date -u -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-01" +%s)"
version="${ROXORA_RELEASE}+${ubuntu}"
# The release packages carry the source list of the hardware repository as
# Armbian's build writes it (apt/armbian.sources.in). Another hardware
# repository (hardware-repo.conf) would need a source list and key in the
# package, and the removal of armbian.sources on installed systems.
[[ "${HW_REPO}" == armbian ]] || die "HW_REPO=${HW_REPO}: the release packages carry only Armbian's source list so far"

mkdir -p "${out}"
out="$(cd "${out}" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# Takeover lines for preinst, and the paths for postinst and postrm.
takeover="$(awk '!/^[[:space:]]*(#|$)/ { s[$1] = s[$1] " " $2; if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 } }
	END { for (i = 1; i <= n; i++) printf "\ttake_over %s%s\n", order[i], s[order[i]] }' "${HERE}/takeover.list")"
takeover_paths="$(awk '!/^[[:space:]]*(#|$)/ { print $1 }' "${HERE}/takeover.list" | sort -u | tr '\n' ' ' | sed 's/ $//')"

# After a release upgrade from ${previous}: the source lists as that suite's
# roxora-release shipped them, and their SHA-256 after the release
# upgrader's known edits (see roxora-release.preinst).
rewrites=""
if [[ -n "${previous}" ]]; then
	declare src shipped variants v
	for src in roxora armbian; do
		if [[ "${src}" == roxora ]]; then
			shipped="$(sed -e "s|@URI@|${ROXORA_REPO_URI}|g" -e "s/@SUITE@/${previous}/g" "${ROXORA_DIR}/apt/roxora.sources.in")"
		else
			shipped="$(sed -e "s/@SUITE@/${previous}/g" "${ROXORA_DIR}/apt/armbian.sources.in")"
		fi
		variants=""
		for v in "${shipped}"$'\nEnabled: no' "${shipped//Suites: ${previous}/Suites: ${suite}}" \
			"${shipped//Suites: ${previous}/Suites: ${suite}}"$'\nEnabled: no'; do
			variants+=" $(printf '%s\n' "${v}" | sha256sum | cut -d ' ' -f 1)"
		done
		[[ "${shipped}" != *"'"* ]] || die "apt/${src}.sources.in has a quote"
		rewrites+="$(printf "\trestore_rewrite /etc/apt/sources.list.d/%s.sources '%s\n'%s" "${src}" "${shipped}" "${variants}")"$'\n'
	done
fi
# Packages Ubuntu's server image has for this release that the image build
# installs again (ubuntu-defaults.list): a release upgrade brings them too.
ubuntu_defaults="$(awk -v r="${suite}" '!/^[[:space:]]*(#|$)/ && $1 == r { for (i = 2; i <= NF; i++) printf ", %s", $i }' "${ROXORA_DIR}/ubuntu-defaults.list")"

# write_copyright <package root> <name>
write_copyright() {
	install -d "$1/usr/share/doc/$2"
	cat > "$1/usr/share/doc/$2/copyright" <<- COPYRIGHT
		Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
		Upstream-Name: $2
		Source: https://github.com/roxora-os/build

		Files: *
		Copyright: 2026 Ga Hing Woo
		License: GPL-2
		 On Debian and Ubuntu systems, the complete text of the GNU General Public
		 License version 2 can be found in /usr/share/common-licenses/GPL-2.
	COPYRIGHT
}

# finish <package root> <file name>: modes, time stamps, conffiles, the deb.
finish() {
	declare root="$1"
	chmod -R u=rwX,go=rX "${root}"
	find "${root}/DEBIAN" -name 'p*' -type f -exec chmod 0755 {} +
	(cd "${root}" && find etc -type f 2> /dev/null | sort | sed 's|^|/|') > "${root}/DEBIAN/conffiles"
	[[ -s "${root}/DEBIAN/conffiles" ]] || rm -f "${root}/DEBIAN/conffiles"
	find "${root}" -exec touch --no-dereference --date="@${epoch}" {} +
	SOURCE_DATE_EPOCH="${epoch}" dpkg-deb --root-owner-group --build "${root}" "${out}/$2" > /dev/null
	echo "${out}/$2"
}

# --- roxora-release -----------------------------------------------------------

pkg="${work}/roxora-release"
install -d "${pkg}/DEBIAN" "${pkg}/etc/apt/preferences.d" "${pkg}/etc/apt/sources.list.d" \
	"${pkg}/etc/cloud/cloud.cfg.d" "${pkg}/usr/share/fonts"
sed -e "s/@ORIGIN@/${HW_REPO_ORIGIN}/g" "${ROXORA_DIR}/apt/roxora-hardware.pref.in" > "${pkg}/etc/apt/preferences.d/roxora-hardware.pref"
sed -e "s/@HOST@/${ROXORA_REPO_HOST}/g" "${ROXORA_DIR}/apt/roxora.pref.in" > "${pkg}/etc/apt/preferences.d/roxora.pref"
sed -e "s|@URI@|${ROXORA_REPO_URI}|g" -e "s/@SUITE@/${suite}/g" "${ROXORA_DIR}/apt/roxora.sources.in" > "${pkg}/etc/apt/sources.list.d/roxora.sources"
sed -e "s/@SUITE@/${suite}/g" "${ROXORA_DIR}/apt/armbian.sources.in" > "${pkg}/etc/apt/sources.list.d/armbian.sources"
install -m 0644 "${ROXORA_DIR}/cloud-init/99-roxora.cfg" "${pkg}/etc/cloud/cloud.cfg.d/99-roxora.cfg"
write_copyright "${pkg}" roxora-release
awk -v t="${takeover}" -v r="${rewrites:-$'\t:\n'}" '$0 == "@TAKEOVER@" { print t; next } $0 == "@REWRITES@" { printf "%s", r; next } { print }' "${HERE}/roxora-release.preinst" > "${pkg}/DEBIAN/preinst"
for script in postinst postrm; do
	sed -e "s|@TAKEOVER_PATHS@|${takeover_paths}|" "${HERE}/roxora-release.${script}" > "${pkg}/DEBIAN/${script}"
done
cat > "${pkg}/DEBIAN/control" <<- CONTROL
	Package: roxora-release
	Version: ${version}
	Architecture: all
	Maintainer: Roxora Project <oss@gahingwoo.com>
	Section: admin
	Priority: optional
	Depends: roxora-archive-keyring (>= ${KEYRING_VERSION}), roxora-hwtool (>= ${HWTOOL_VERSION}), roxora-wallpapers (>= ${WALLPAPERS_VERSION})${ubuntu_defaults}
	Homepage: https://roxora-os.github.io
	Description: Roxora ${ROXORA_RELEASE}: what every Roxora system shares
	 The part of Roxora release ${ROXORA_RELEASE} for Ubuntu ${ubuntu} (${suite}) that
	 every flavor has: the apt sources of Roxora's repository and of the
	 hardware repository (Armbian's kernel, device tree, U-Boot and firmware),
	 the apt pins that take only those packages from them, cloud-init's
	 settings and the system font directories, and Roxora's keyring, hwtool
	 and wallpapers. It is installed with one of the flavor packages
	 roxora-cli, roxora-desktop-gnome-minimal and roxora-desktop-gnome, which
	 take a system to the state of a new release on "apt full-upgrade".
CONTROL
finish "${pkg}" "roxora-release_${version}_all.deb"

# --- the flavor packages ------------------------------------------------------

declare flavor name depends recommends summary others
for flavor in "${flavors[@]}"; do
	pkg="${work}/flavor-${flavor}"
	recommends=""
	case "${flavor}" in
		cli)
			name=roxora-cli
			summary="command line image"
			# Wi-Fi with nmtui and nmcli, from 2026.11.5 on.
			depends="network-manager"
			;;
		gnome-minimal)
			name=roxora-desktop-gnome-minimal
			summary="GNOME desktop, ubuntu-desktop-minimal"
			depends="roxora-hwtool-gtk (>= ${HWTOOL_VERSION}), network-manager"
			recommends="ubuntu-desktop-minimal"
			;;
		gnome)
			name=roxora-desktop-gnome
			summary="GNOME desktop, ubuntu-desktop"
			depends="roxora-hwtool-gtk (>= ${HWTOOL_VERSION}), network-manager"
			recommends="ubuntu-desktop"
			;;
		*) die "unknown flavor '${flavor}' (cli, gnome-minimal, gnome)" ;;
	esac
	install -d "${pkg}/DEBIAN" "${pkg}/usr/lib" "${pkg}/etc"
	cat > "${pkg}/usr/lib/roxora-release" <<- RELEASE
		# The Roxora release and flavor of this system, from ${name}.
		# /etc/roxora-release points here. Shell variable assignments.
		ROXORA_VERSION=${ROXORA_RELEASE}
		ROXORA_FLAVOR=${flavor}
		ROXORA_UBUNTU_CODENAME=${suite}
		ROXORA_PACKAGE=${name}
	RELEASE
	ln -s ../usr/lib/roxora-release "${pkg}/etc/roxora-release"
	if [[ "${flavor}" != cli ]]; then
		install -D -m 0644 "${ROXORA_DIR}/desktop/99-roxora-desktop.cfg" "${pkg}/etc/cloud/cloud.cfg.d/99-roxora-desktop.cfg"
		install -m 0755 "${HERE}/roxora-desktop.postinst" "${pkg}/DEBIAN/postinst"
	fi
	write_copyright "${pkg}" "${name}"
	{
		echo "Package: ${name}"
		echo "Version: ${version}"
		echo "Architecture: all"
		echo "Maintainer: Roxora Project <oss@gahingwoo.com>"
		echo "Section: admin"
		echo "Priority: optional"
		echo "Depends: roxora-release (= ${version}), ${depends}"
		[[ -z "${recommends}" ]] || echo "Recommends: ${recommends}"
		# One flavor at a time: installing another replaces this one.
		others="$(printf '%s\n' roxora-cli roxora-desktop-gnome-minimal roxora-desktop-gnome | grep -vx "${name}" | paste -sd, | sed 's/,/, /g')"
		echo "Provides: roxora-flavor"
		echo "Conflicts: ${others}"
		echo "Replaces: ${others}"
		echo "Homepage: https://roxora-os.github.io"
		echo "Description: Roxora ${ROXORA_RELEASE}, ${summary}"
		echo " The ${flavor} flavor of Roxora release ${ROXORA_RELEASE} for Ubuntu ${ubuntu}"
		echo " (${suite}): it depends on roxora-release of the same version and on"
		echo " what this flavor's image has in this release, and writes"
		echo " /etc/roxora-release with the release and the flavor. Installing a"
		echo " newer version, which \"apt full-upgrade\" does, takes the system to"
		echo " that release."
	} > "${pkg}/DEBIAN/control"
	finish "${pkg}" "${name}_${version}_all.deb"
done
