#!/bin/bash
# dpkg-query formats are single-quoted on purpose.
# shellcheck disable=SC2016
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2026 Ga Hing Woo <gahing@gahingwoo.com>
#
# Try Ubuntu's release upgrade (do-release-upgrade, 24.04 to 26.04) on a
# Roxora image, in a chroot, and report what it leaves.
#
#   sudo verify/release-upgrade-test.sh [--allow-third-party] <image.img> <log directory>
#
# <image.img> is a 24.04 image with Roxora's repository, as
# verify/upgrade-test.sh leaves it; it is changed in place. Its root file
# system first grows by 8 GiB. do-release-upgrade runs with its
# non-interactive front end; --allow-third-party sets
# RELEASE_UPGRADER_ALLOW_THIRD_PARTY=1, with which the upgrader moves the
# sources it does not know (Armbian's, Roxora's) to the new release instead
# of turning them off. The upgrader's logs and a report of the result (apt
# sources, hardware and Roxora packages, boot files) go to <log directory>.
#
# This is an experiment, not a supported procedure: services do not run in
# the chroot, so it says nothing about a running system's reboot into 26.04.
# Exits with do-release-upgrade's status.

set -euo pipefail

allow=no
args=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--allow-third-party)
			allow=yes
			shift
			;;
		*)
			args+=("$1")
			shift
			;;
	esac
done
[[ ${#args[@]} -eq 2 ]] || {
	echo "usage: $0 [--allow-third-party] <image.img> <log directory>" >&2
	exit 2
}
img="${args[0]}" logs="${args[1]}"
mkdir -p "${logs}"
logs="$(cd "${logs}" && pwd)"

work="$(mktemp -d)"
loop=""
mnt="${work}/root"
cleanup() {
	set +e
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

truncate -s +8G "${img}"
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
mount --bind /dev "${mnt}/dev"
mount --bind /dev/pts "${mnt}/dev/pts"
mount -t tmpfs tmpfs "${mnt}/run"
cp -a "${mnt}/etc/resolv.conf" "${work}/resolv.conf.saved" 2> /dev/null || true
rm -f "${mnt}/etc/resolv.conf"
cp -L /etc/resolv.conf "${mnt}/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "${mnt}/usr/sbin/policy-rc.d"
chmod 0755 "${mnt}/usr/sbin/policy-rc.d"

in_chroot() {
	chroot "${mnt}" env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LC_ALL=C.UTF-8 TERM=dumb DEBIAN_FRONTEND=noninteractive "$@" < /dev/null
}

# What the system looks like, before and after.
report() {
	echo "--- os-release: $(in_chroot sh -c '. /etc/os-release && echo "${PRETTY_NAME}"')"
	echo "--- /etc/roxora-release:"
	in_chroot cat /etc/roxora-release 2> /dev/null || echo "(none)"
	for f in "${mnt}"/etc/apt/sources.list.d/*; do
		echo "--- ${f#"${mnt}"}"
		cat "${f}"
	done
	echo "--- packages (hardware layer, BSP, Roxora, release upgrader):"
	in_chroot dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Version}\n' 'linux-*' 'armbian-*' 'roxora-*' 'ubuntu-release-upgrader-core' 2> /dev/null | grep -v '^un' || true
	echo "--- dpkg --audit:"
	in_chroot dpkg --audit || true
	echo "--- dpkg --verify of Roxora's packages:"
	in_chroot dpkg --verify roxora-release 2>&1 || true
	echo "--- apt-get -s full-upgrade:"
	in_chroot apt-get -s full-upgrade 2>&1 | grep -E '^(Inst|Remv) |upgraded,' || true
	echo "--- /boot:"
	ls -l "${mnt}/boot" | head -30
}

declare -i status=0
{
	echo "== before"
	report
	if ! in_chroot dpkg-query -W -f '${db:Status-Abbrev}' ubuntu-release-upgrader-core 2> /dev/null | grep -q '^ii'; then
		echo "== ubuntu-release-upgrader-core is not installed; installing it"
		in_chroot apt-get install -y -q ubuntu-release-upgrader-core
	fi
	echo "== /etc/update-manager/release-upgrades: $(grep '^Prompt' "${mnt}/etc/update-manager/release-upgrades" || true)"
	declare -a env=(RELEASE_UPGRADER_NO_SCREEN=1)
	[[ "${allow}" == yes ]] && env+=(RELEASE_UPGRADER_ALLOW_THIRD_PARTY=1)
	echo "== ${env[*]} do-release-upgrade -f DistUpgradeViewNonInteractive"
	in_chroot env "${env[@]}" do-release-upgrade -f DistUpgradeViewNonInteractive || status=$?
	echo "== do-release-upgrade exited with ${status}"
	echo "== after"
	report
} 2>&1 | tee "${logs}/report.txt"
status=0
grep -q '^== do-release-upgrade exited with 0$' "${logs}/report.txt" || status=1
cp -a "${mnt}/var/log/dist-upgrade" "${logs}/" 2> /dev/null || true
cp -a "${mnt}/var/log/apt/term.log" "${logs}/apt-term.log" 2> /dev/null || true

rm -f "${mnt}/usr/sbin/policy-rc.d" "${mnt}/etc/resolv.conf"
if [[ -e "${work}/resolv.conf.saved" || -L "${work}/resolv.conf.saved" ]]; then
	cp -a "${work}/resolv.conf.saved" "${mnt}/etc/resolv.conf"
fi
exit "${status}"
