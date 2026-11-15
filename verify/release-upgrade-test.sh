#!/bin/bash
# dpkg-query formats are single-quoted on purpose; cleanup runs from the trap.
# shellcheck disable=SC2016,SC2317
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2026 Ga Hing Woo <gahing@gahingwoo.com>
#
# Upgrade a Roxora image from Ubuntu 24.04 to 26.04 with Ubuntu's release
# upgrader, as docs/install.md says, in a chroot.
#
#   sudo verify/release-upgrade-test.sh [--release-debs DIR] <image.img> <log directory>
#
# <image.img> is a 24.04 image with Roxora's repository and release
# packages, as verify/upgrade-test.sh leaves it; it is changed in place, its
# root file system first grown by 12 GiB. The commands of "From Ubuntu 24.04
# to 26.04" in docs/install.md (between the roxora-release-upgrade markers)
# run as they are written, do-release-upgrade with its non-interactive front
# end, and nothing is changed by hand before or after. Then a second
# "apt update" and "apt full-upgrade" must have nothing to do, and the
# system must have the 26.04 release packages.
#
# --release-debs DIR: release packages of this commit for both Ubuntu
# releases (DIR/noble/, DIR/resolute/), for a release that Roxora's
# repository does not publish yet. They are offered from a local repository
# with one suite per release, served over HTTP on 127.0.0.1 (the upgrader
# does not accept a file: source as downloadable), which the upgrader is
# told to move like Roxora's own (a second [ThirdPartyMirrors] entry), and
# removed again afterwards.
#
# Services do not run in the chroot and snapd is not running, so the
# upgrader's snap steps are skipped; this says nothing about a running
# system's reboot into 26.04. The SSH host keys the upgrade creates in a
# never-booted image are removed at the end. The upgrader's logs and a
# report go to <log directory>. Exits 0 when the upgrade and the checks
# above passed.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="$(dirname "${HERE}")/docs/install.md"

release_debs=""
args=()
while [[ $# -gt 0 ]]; do
	case "$1" in
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
	echo "usage: $0 [--release-debs DIR] <image.img> <log directory>" >&2
	exit 2
}
img="${args[0]}" logs="${args[1]}"
mkdir -p "${logs}"
logs="$(cd "${logs}" && pwd)"

steps="$(awk '/<!-- roxora-release-upgrade:begin -->/ { on = 1; next } /<!-- roxora-release-upgrade:end -->/ { on = 0 } on && /^    / { print substr($0, 5) }' "${DOC}")"
[[ -n "${steps}" ]] || {
	echo "release-upgrade-test.sh: no roxora-release-upgrade block in ${DOC}" >&2
	exit 1
}
grep -qx 'sudo do-release-upgrade' <<< "${steps}" || {
	echo "release-upgrade-test.sh: the roxora-release-upgrade block has no 'sudo do-release-upgrade'" >&2
	exit 1
}
# The upgrader's non-interactive front end answers its questions as a user
# accepting the defaults would, without screen (no terminal here).
steps="${steps//sudo do-release-upgrade/sudo RELEASE_UPGRADER_NO_SCREEN=1 do-release-upgrade -f DistUpgradeViewNonInteractive}"

work="$(mktemp -d)"
loop=""
mnt="${work}/root"
cleanup() {
	set +e
	for p in /proc/[0-9]*; do
		[[ "$(readlink "${p}/root" 2> /dev/null)" == "${mnt}" ]] && kill "${p##*/}" 2> /dev/null
	done
	sleep 1
	[[ -n "${server:-}" ]] && kill "${server}" 2> /dev/null
	for m in run dev/pts dev sys/fs/cgroup sys proc boot/efi ""; do
		mountpoint -q "${mnt}/${m}" && umount -l "${mnt}/${m}"
	done
	[[ -n "${loop}" ]] && losetup -d "${loop}"
	rm -rf "${work}"
}
trap cleanup EXIT

truncate -s +12G "${img}"
ptdump="$(sfdisk -d "${img}")"
[[ "$(awk '/^label:/ { print $2 }' <<< "${ptdump}")" == gpt ]] && sfdisk -q --relocate gpt-bak-std "${img}"
rootnum="$(awk '/ : start=/ { sub(/ :.*/, ""); sub(/.*[^0-9]/, ""); n = $0 } END { print n }' <<< "${ptdump}")"
echo ", +" | sfdisk -q --no-reread -N "${rootnum}" "${img}"
loop="$(losetup -f --show -P "${img}")"
udevadm settle 2> /dev/null || true
e2fsck -fp "${loop}p${rootnum}" > /dev/null
resize2fs "${loop}p${rootnum}" 2>&1 | tail -1
mkdir -p "${mnt}"
mount "${loop}p${rootnum}" "${mnt}"
esp_num="$(awk 'tolower($0) ~ /type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b/ { sub(/ :.*/, ""); sub(/.*[^0-9]/, ""); print; exit }' <<< "${ptdump}")"
[[ -z "${esp_num}" ]] || mount "${loop}p${esp_num}" "${mnt}/boot/efi"
mount -t proc proc "${mnt}/proc"
mount -t sysfs sysfs "${mnt}/sys"
# The upgrader refuses a system without the unified cgroup v2 hierarchy,
# which it reads from /sys/fs/cgroup: here the host's (GitHub's runners boot
# with it, as Ubuntu does and as the boards do, see verify-image.sh).
mount -t cgroup2 cgroup2 "${mnt}/sys/fs/cgroup"
mount --bind /dev "${mnt}/dev"
mount --bind /dev/pts "${mnt}/dev/pts"
mount -t tmpfs tmpfs "${mnt}/run"
cp -a "${mnt}/etc/resolv.conf" "${work}/resolv.conf.saved" 2> /dev/null || true
rm -f "${mnt}/etc/resolv.conf"
cp -L /etc/resolv.conf "${mnt}/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "${mnt}/usr/sbin/policy-rc.d"
chmod 0755 "${mnt}/usr/sbin/policy-rc.d"
# apt and the upgrader say yes; dpkg's own questions get no answer.
printf '%s\n' 'APT::Get::Assume-Yes "true";' 'Dpkg::Use-Pty "0";' > "${mnt}/etc/apt/apt.conf.d/00roxora-upgrade-test"

in_chroot() {
	chroot "${mnt}" env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LC_ALL=C.UTF-8 TERM=dumb "$@" < /dev/null
}

test_repo="${work}/test-repo"
test_uri=http://127.0.0.1:8765
server=""
if [[ -n "${release_debs}" ]]; then
	declare suite
	for suite in noble resolute; do
		d="${test_repo}/dists/${suite}/main/binary-arm64"
		mkdir -p "${d}" "${test_repo}/pool/${suite}"
		cp "${release_debs}/${suite}"/*.deb "${test_repo}/pool/${suite}/"
		(cd "${test_repo}" && apt-ftparchive packages "pool/${suite}" > "dists/${suite}/main/binary-arm64/Packages")
		(cd "${test_repo}/dists/${suite}" && apt-ftparchive -o "APT::FTPArchive::Release::Suite=${suite}" \
			-o "APT::FTPArchive::Release::Codename=${suite}" -o APT::FTPArchive::Release::Components=main \
			-o APT::FTPArchive::Release::Architectures=arm64 release . > "${work}/Release" && mv "${work}/Release" Release)
	done
	python3 -m http.server --bind 127.0.0.1 --directory "${test_repo}" 8765 > "${work}/http.log" 2>&1 &
	server=$!
	sleep 2
	curl -fsS "${test_uri}/dists/resolute/Release" > /dev/null
	printf '%s\n' 'Types: deb' "URIs: ${test_uri}" 'Suites: noble' 'Components: main' 'Trusted: yes' \
		> "${mnt}/etc/apt/sources.list.d/zz-roxora-release-test.sources"
	printf '%s\n' '[ThirdPartyMirrors]' "roxora-release-test = ${test_uri}" \
		> "${mnt}/etc/update-manager/release-upgrades.d/zz-roxora-release-test.cfg"
fi

report() {
	echo "--- os-release: $(in_chroot sh -c '. /etc/os-release && echo "${PRETTY_NAME}"')"
	echo "--- /etc/roxora-release: $(grep -h '^ROXORA_' "${mnt}/usr/lib/roxora-release" 2> /dev/null | tr '\n' ' ')"
	for f in "${mnt}"/etc/apt/sources.list.d/*; do
		echo "--- ${f#"${mnt}"} (sha256 $(sha256sum < "${f}" | cut -c1-16))"
		cat "${f}"
	done
	echo "--- packages (hardware layer, BSP, Roxora, time, release upgrader):"
	in_chroot dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Version}\n' 'linux-image-*' 'linux-dtb-*' 'linux-u-boot-*' \
		'armbian-*' 'roxora-*' chrony systemd-timesyncd ubuntu-release-upgrader-core snapd initramfs-tools dracut 2> /dev/null | grep -v '^un' || true
	echo "--- dpkg --audit:"
	in_chroot dpkg --audit || true
	echo "--- dpkg --verify of Roxora's packages:"
	in_chroot dpkg --verify roxora-release roxora-cli roxora-desktop-gnome-minimal roxora-desktop-gnome 2>&1 | grep -v 'not installed' || true
	echo "--- apt-get -s autoremove:"
	in_chroot apt-get -s autoremove 2>&1 | grep -E '^Remv |upgraded,' || true
}

declare -i status=0
{
	echo "== before"
	report
	echo "== the commands of docs/install.md"
	printf '%s\n' "${steps}"
	in_chroot bash -euxo pipefail -c "${steps}" && echo "== the commands exited with 0" || echo "== the commands failed"
	echo "== after"
	report
	echo "== a second update and full-upgrade"
	in_chroot sh -c 'apt-get update -qq && apt-get -s -o Debug::pkgProblemResolver=1 full-upgrade' 2>&1 | grep -v '^Inst\|^Conf' | tail -30
	# The configuration files the upgrade left changed, against the packages.
	echo "== dpkg --verify (changed configuration files):"
	in_chroot dpkg --verify 2>&1 | grep ' c /' || true
	if in_chroot test -f /etc/cloud/cloud.cfg; then
		echo "== /etc/cloud/cloud.cfg against cloud-init-base's"
		in_chroot sh -c 'cd /tmp && apt-get download -qq cloud-init-base && dpkg-deb --fsys-tarfile cloud-init-base_*.deb | tar -xO ./etc/cloud/cloud.cfg > /tmp/cloud.cfg.dist && diff -u /tmp/cloud.cfg.dist /etc/cloud/cloud.cfg; rm -f /tmp/cloud-init-base_*.deb /tmp/cloud.cfg.dist' || true
	fi
} 2>&1 | tee "${logs}/report.txt"

grep -q '^== the commands exited with 0$' "${logs}/report.txt" || status=1
in_chroot sh -c '. /etc/os-release && test "${VERSION_CODENAME}" = resolute' || {
	echo "release-upgrade-test.sh: the system is not 26.04"
	status=1
}
in_chroot apt-get -s full-upgrade > "${work}/second.txt" 2>&1 || status=1
grep -q '^0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded' "${work}/second.txt" || {
	echo "release-upgrade-test.sh: apt full-upgrade still has work after the release upgrade"
	status=1
}
[[ "$(in_chroot dpkg-query -W -f '${Version}' roxora-release 2> /dev/null)" == *+26.04 ]] || {
	echo "release-upgrade-test.sh: roxora-release is not the 26.04 package"
	status=1
}
cp -a "${mnt}/var/log/dist-upgrade" "${logs}/" 2> /dev/null || true

rm -f "${mnt}/etc/apt/sources.list.d/zz-roxora-release-test.sources" \
	"${mnt}/etc/update-manager/release-upgrades.d/zz-roxora-release-test.cfg" "${mnt}"/var/lib/apt/lists/127.0.0.1:8765_*
rm -f "${mnt}/usr/sbin/policy-rc.d" "${mnt}/etc/apt/apt.conf.d/00roxora-upgrade-test" "${mnt}/etc/resolv.conf" "${mnt}"/etc/ssh/ssh_host_*
in_chroot apt-get clean || true
if [[ -e "${work}/resolv.conf.saved" || -L "${work}/resolv.conf.saved" ]]; then
	cp -a "${work}/resolv.conf.saved" "${mnt}/etc/resolv.conf"
fi
((status == 0)) && echo "release-upgrade-test.sh: upgraded to 26.04; now run verify-image.sh --upgraded"
exit "${status}"
