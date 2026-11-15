#!/bin/bash
# dpkg-query formats are single-quoted on purpose.
# shellcheck disable=SC2016
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2026 Ga Hing Woo <gahing@gahingwoo.com>
#
# Upgrade a Roxora image of an earlier release to this commit's release, the
# way docs/install.md tells a user to, in a chroot.
#
#   sudo verify/upgrade-test.sh [--flavor FLAVOR] [--release-debs DIR] <old image.img.xz | .img> <new image.img>
#
# Writes the old image, decompressed, to <new image.img> and changes that
# copy: it runs the commands of "Updating to a new Roxora release" in
# docs/install.md (between the roxora-join markers) as they are written, then
# the flavor's "apt install" line and "apt full-upgrade" from the same
# section, and checks that a second update and full-upgrade have nothing
# left to do. Then run verify-image.sh on <new image.img>.
#
# Nothing answers for the user: apt says yes to its own questions, but a
# question from dpkg (about a changed configuration file) gets no answer and
# fails the run. Services are not started (policy-rc.d), so this upgrades an
# image that has not booted yet, not a running system.
#
# --release-debs DIR: release packages built from this commit
# (userpatches/roxora/packages/build.sh), for a release Roxora's repository
# does not publish yet. They are offered to apt from a local repository in
# the chroot while the commands run, and removed again afterwards.
#
# Needs root and an arm64 host (the chroot runs natively).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "${HERE}")"
DOC="${REPO}/docs/install.md"

flavor=cli
release_debs=""
args=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--flavor)
			flavor="$2"
			shift 2
			;;
		--release-debs)
			release_debs="$(cd "$2" && pwd)"
			shift 2
			;;
		*)
			args+=("$1")
			shift
			;;
	esac
done
[[ ${#args[@]} -eq 2 ]] || {
	echo "usage: $0 [--flavor FLAVOR] [--release-debs DIR] <old image> <new image.img>" >&2
	exit 2
}
old="${args[0]}" new="${args[1]}"
[[ "$(id -u)" == 0 ]] || {
	echo "upgrade-test.sh: needs root" >&2
	exit 2
}
flavor_pkg=roxora-cli
[[ "${flavor}" == cli ]] || flavor_pkg="roxora-desktop-${flavor}"

# The commands, from the documentation.
join="$(awk '/<!-- roxora-join:begin -->/ { on = 1; next } /<!-- roxora-join:end -->/ { on = 0 } on && /^    / { print substr($0, 5) }' "${DOC}")"
[[ -n "${join}" ]] || {
	echo "upgrade-test.sh: no roxora-join block in ${DOC}" >&2
	exit 1
}
install_line="sudo apt install --no-install-recommends ${flavor_pkg}"
grep -qF "\`${install_line}\`" "${DOC}" || {
	echo "upgrade-test.sh: ${DOC} does not give '${install_line}'" >&2
	exit 1
}
upgrade_line="sudo apt update && sudo apt full-upgrade"
grep -qF "    ${upgrade_line}" "${DOC}" || {
	echo "upgrade-test.sh: ${DOC} does not give '${upgrade_line}'" >&2
	exit 1
}

work="$(mktemp -d)"
loop=""
mnt="${work}/root"
cleanup() {
	set +e
	# Processes left in the chroot (gpg-agent, dirmngr) keep it busy.
	for p in /proc/[0-9]*; do
		[[ "$(readlink "${p}/root" 2> /dev/null)" == "${mnt}" ]] && kill "${p##*/}" 2> /dev/null
	done
	sleep 1
	for m in run dev/pts dev sys proc boot/efi ""; do
		mountpoint -q "${mnt}/${m}" && umount -l "${mnt}/${m}"
	done
	[[ -n "${loop}" ]] && losetup -d "${loop}"
	rm -rf "${work}"
}
trap cleanup EXIT

echo "Writing ${new} from ${old}"
if [[ "${old}" == *.xz ]]; then
	xz -dc "${old}" > "${new}"
else
	cp --sparse=always "${old}" "${new}"
fi
loop="$(losetup -f --show -P "${new}")"
udevadm settle 2> /dev/null || true
rootpart="$(find /dev -maxdepth 1 -name "$(basename "${loop}")p*" | sort -V | tail -1)"
mkdir -p "${mnt}"
mount "${rootpart}" "${mnt}"
esp_num="$(sfdisk -d "${new}" 2> /dev/null | awk 'tolower($0) ~ /type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b/ { sub(/ :.*/, ""); sub(/.*[^0-9]/, ""); print; exit }')"
if [[ -n "${esp_num}" ]]; then
	mount "${loop}p${esp_num}" "${mnt}/boot/efi"
fi
mount -t proc proc "${mnt}/proc"
mount -t sysfs sysfs "${mnt}/sys"
mount --bind /dev "${mnt}/dev"
mount --bind /dev/pts "${mnt}/dev/pts"
mount -t tmpfs tmpfs "${mnt}/run"
# shellcheck source=/dev/null
echo "Image: $(. "${mnt}/etc/os-release" && echo "${PRETTY_NAME}"), $(cat "${mnt}/etc/hostname"), $(grep -s VERSION "${mnt}/etc/roxora-release" || echo 'no /etc/roxora-release')"

# What a running system has and a chroot lacks: name resolution, and no
# services started by package scripts.
cp -a "${mnt}/etc/resolv.conf" "${work}/resolv.conf.saved" 2> /dev/null || true
rm -f "${mnt}/etc/resolv.conf"
cp -L /etc/resolv.conf "${mnt}/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "${mnt}/usr/sbin/policy-rc.d"
chmod 0755 "${mnt}/usr/sbin/policy-rc.d"
# apt says yes, as a user typing "y" would; dpkg's own questions are left
# unanswered (stdin is /dev/null), so one fails the run.
printf '%s\n' 'APT::Get::Assume-Yes "true";' 'Dpkg::Use-Pty "0";' > "${mnt}/etc/apt/apt.conf.d/00roxora-upgrade-test"

if [[ -n "${release_debs}" ]]; then
	echo "Release packages of this commit, from a local repository: $(cd "${release_debs}" && echo ./*.deb)"
	mkdir -p "${mnt}/tmp/roxora-upgrade-test"
	cp "${release_debs}"/*.deb "${mnt}/tmp/roxora-upgrade-test/"
	(cd "${mnt}/tmp/roxora-upgrade-test" && apt-ftparchive packages . > Packages && apt-ftparchive release . > Release)
	echo 'deb [trusted=yes] file:/tmp/roxora-upgrade-test ./' > "${mnt}/etc/apt/sources.list.d/zz-roxora-upgrade-test.list"
fi

in_chroot() {
	chroot "${mnt}" env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LC_ALL=C.UTF-8 TERM=dumb "$@" < /dev/null
}

declare -i status=0
echo
echo "== the commands of docs/install.md"
printf '%s\n' "${join}" "${install_line}" "${upgrade_line}"
echo
in_chroot bash -euxo pipefail -c "$(printf '%s\n' "${join}" "${install_line}" "${upgrade_line}")" || status=$?
if ((status == 0)); then
	echo
	echo "== a second update and full-upgrade: nothing left to do"
	in_chroot bash -euo pipefail -c 'apt-get update -qq && apt-get -s full-upgrade' > "${work}/second.txt" 2>&1 || status=$?
	cat "${work}/second.txt"
	grep -q '^0 upgraded, 0 newly installed, 0 to remove' "${work}/second.txt" || {
		echo "upgrade-test.sh: a second full-upgrade still has work"
		status=1
	}
	echo
	echo "== installed: $(in_chroot dpkg-query -W -f '${Package} ${Version}\n' 'roxora-*' | tr '\n' ' ')"
	in_chroot cat /etc/roxora-release
fi
in_chroot dpkg --audit || status=1
grep -h ' conffile \| status half' "${mnt}/var/log/dpkg.log" | tail -20 || true

# Leave the image as a system would be after the commands: without the test's
# own files, and with the apt lists of its own sources only.
rm -f "${mnt}/usr/sbin/policy-rc.d" "${mnt}/etc/apt/apt.conf.d/00roxora-upgrade-test"
if [[ -n "${release_debs}" ]]; then
	rm -rf "${mnt}/tmp/roxora-upgrade-test" "${mnt}/etc/apt/sources.list.d/zz-roxora-upgrade-test.list"
	rm -f "${mnt}"/var/lib/apt/lists/_tmp_roxora-upgrade-test_*
fi
in_chroot apt-get clean
rm -f "${mnt}/etc/resolv.conf"
if [[ -e "${work}/resolv.conf.saved" || -L "${work}/resolv.conf.saved" ]]; then
	cp -a "${work}/resolv.conf.saved" "${mnt}/etc/resolv.conf"
fi
if ((status != 0)); then
	echo "upgrade-test.sh: the upgrade failed"
	exit 1
fi
echo "upgrade-test.sh: upgraded; now run verify-image.sh on ${new}"
