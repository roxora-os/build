#!/bin/bash
# dpkg-query and awk programs are single-quoted on purpose.
# shellcheck disable=SC2016
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2026 Ga Hing Woo <gahing@gahingwoo.com>
#
# Check a Roxora image without booting it.
#
#   sudo verify/verify-image.sh [--offline] [--flavor FLAVOR] <image.img | image.img.xz>
#
# The image is attached read-only. Its root filesystem is mounted under an
# overlay with a throwaway upper layer, so apt can run in a chroot without
# changing the image. Needs root and an arm64 host (the chroot runs natively).
#
# --offline  skip "apt-get update" in the chroot and use the package lists the
#            image shipped with.
# --flavor   the flavor the image must be: cli, gnome-minimal or gnome. The
#            check always reads the flavor from the image's packages; with
#            this option it fails when the image is another one.
#
# A desktop image also needs the snap command on the host (package snapd),
# to validate the seeded snaps.
#
# Exits 0 when every check passes, 1 otherwise.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "${HERE}")"
LISTS="${REPO}/userpatches/roxora"
REF="${HERE}/reference"

offline=no
want_flavor=""
image=""
while [[ $# -gt 0 ]]; do
	arg="$1"
	shift
	case "${arg}" in
		--offline) offline=yes ;;
		--flavor)
			want_flavor="${1:-}"
			shift || true
			;;
		--flavor=*) want_flavor="${arg#*=}" ;;
		-h | --help)
			sed -n '5,24s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
			exit 0
			;;
		*) image="${arg}" ;;
	esac
done
[[ -n "${image}" && -f "${image}" ]] || {
	echo "usage: $0 [--offline] [--flavor FLAVOR] <image.img | image.img.xz>" >&2
	exit 2
}
[[ -z "${want_flavor}" || "${want_flavor}" =~ ^(cli|gnome-minimal|gnome)$ ]] || {
	echo "verify-image.sh: --flavor is cli, gnome-minimal or gnome" >&2
	exit 2
}
image_arg="${image}"
[[ "$(id -u)" == 0 ]] || {
	echo "verify-image.sh: needs root (loop devices, mounts, chroot)" >&2
	exit 2
}

work="$(mktemp -d)"
loop=""
cleanup() {
	set +e
	for m in "${work}/root/proc" "${work}/root/tmp" "${work}/root" "${work}/lower" "${work}/upper" "${work}/esp"; do
		mountpoint -q "${m}" && umount -l "${m}"
	done
	[[ -n "${loop}" ]] && losetup -d "${loop}"
	rm -rf "${work}"
}
trap cleanup EXIT

declare -i failures=0
declare -a summary=()
pass() {
	summary+=("PASS  $1")
	echo "PASS  $1"
}
fail() {
	summary+=("FAIL  $1")
	echo "FAIL  $1"
	failures+=1
}
detail() { sed 's/^/      /'; }
# A check could not run at all: stop, the image counts as failed.
die() {
	echo "verify-image.sh: $1" >&2
	exit 1
}

# List file without comments and blank lines.
list() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"; }

# Where the hardware-layer packages come from (HW_REPO, HW_REPO_ORIGIN, ...).
# shellcheck source=userpatches/roxora/hardware-repo.conf
source "${LISTS}/hardware-repo.conf"
expected_pin="$(sed -e "s/@ORIGIN@/${HW_REPO_ORIGIN}/g" "${LISTS}/apt/roxora-hardware.pref.in")"

# Packages the hardware repository may provide: those of every record in the
# pin file with priority 500 (the hardware layer, and charsiu).
mapfile -t hw_patterns < <(awk '
	/^Package:/ { pk = ""; for (i = 2; i <= NF; i++) pk = pk " " $i }
	/^Pin-Priority:/ && $2 == 500 { n = split(pk, a, " "); for (i = 1; i <= n; i++) print a[i] }
' <<< "${expected_pin}")
[[ ${#hw_patterns[@]} -gt 0 ]] || die "no priority 500 record in the pin file"
is_hw() {
	local p
	for p in "${hw_patterns[@]}"; do
		# shellcheck disable=SC2053 # glob match on purpose
		[[ "$1" == ${p} ]] && return 0
	done
	return 1
}

# --- attach -----------------------------------------------------------------

if [[ "${image}" == *.xz ]]; then
	echo "Decompressing ${image}"
	xz -dc "${image}" > "${work}/image.img"
	image="${work}/image.img"
fi
# A UEFI image (userpatches/roxora/uefi/board.inc) has a GPT with an EFI
# system partition and boots GRUB; the others boot a U-Boot boot script.
ptdump="$(sfdisk -d "${image}" 2> /dev/null || true)"
ptable="$(awk '/^label:/ { print $2 }' <<< "${ptdump}")"
esp_num="$(awk 'tolower($0) ~ /type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b/ { sub(/ :.*/, ""); sub(/.*[^0-9]/, ""); print; exit }' <<< "${ptdump}")"
# Start of the first partition, in bytes.
first_start="$(awk -F'start= *' 'NF > 1 { split($2, a, ","); print a[1] * 512; exit }' <<< "${ptdump}")"
uefi=no
[[ -n "${esp_num}" ]] && uefi=yes

loop="$(losetup -f --show -r -P "${image}")"
udevadm settle 2> /dev/null || true
rootpart="$(find /dev -maxdepth 1 -name "$(basename "${loop}")p*" | sort -V | tail -1)"
[[ -b "${rootpart}" ]] || {
	echo "verify-image.sh: no partition found on ${loop}" >&2
	exit 2
}
mkdir -p "${work}/lower" "${work}/upper" "${work}/root"
mount -o ro "${rootpart}" "${work}/lower"
mount -t tmpfs tmpfs "${work}/upper"
mkdir -p "${work}/upper/data" "${work}/upper/work"
mount -t overlay overlay -o "lowerdir=${work}/lower,upperdir=${work}/upper/data,workdir=${work}/upper/work" "${work}/root"
mount -t proc proc "${work}/root/proc"
mount -t tmpfs tmpfs "${work}/root/tmp"
R="${work}/root"
in_root() { chroot "${R}" env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C "$@"; }

# shellcheck source=/dev/null
# shellcheck disable=SC2153 # BOARD comes from the sourced file
board="$(. "${R}/etc/armbian-release" && echo "${BOARD}")"
# The installed kernel package (not a name it Provides, such as linux-image-armbian).
kpkg="$(in_root dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 'linux-image-*' | awk '$1 ~ /^ii/ && $2 ~ /^linux-image-[^-]+-[^-]+$/ && $2 != "linux-image-armbian" { print $2; exit }')"
[[ -n "${kpkg}" ]] || die "no installed linux-image-<branch>-<family> package in the image"
branch="$(sed -E 's/^linux-image-([^-]+)-.*/\1/' <<< "${kpkg}")"
echo "Image: board ${board}, kernel package ${kpkg} (branch ${branch})"
echo

# --- 1. packages against the Ubuntu reference ---------------------------------

in_root dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' > "${work}/dpkg-query.txt" ||
	die "dpkg-query failed in the image"
cp "${work}/dpkg-query.txt" /tmp/roxora-dpkg.txt
mapfile -t installed < <(awk '$1 ~ /^ii/ { print $2 }' "${work}/dpkg-query.txt" | sort -u)
[[ ${#installed[@]} -gt 0 ]] || die "dpkg-query lists no installed packages in the image"
declare -A ref=() allow=()
is_installed() { grep -qx "ii  $1" "${work}/dpkg-query.txt"; }
# The flavor is what the image has: Ubuntu's desktop metapackages.
flavor=cli
is_installed ubuntu-desktop-minimal && flavor=gnome-minimal
is_installed ubuntu-desktop && flavor=gnome
# shellcheck source=/dev/null
codename="$(. "${R}/etc/os-release" && echo "${VERSION_CODENAME}")"
# The server cloud image is the reference for every flavor. A desktop image
# adds Ubuntu's preinstalled desktop image, and the full desktop Ubuntu's
# live desktop image too (see reference/README.md).
manifests=("${REF}/${codename}-server-cloudimg-arm64.manifest")
ref_name="Ubuntu server image"
if [[ "${flavor}" != cli ]]; then
	manifests+=("${REF}/${codename}-preinstalled-desktop-arm64+raspi.manifest")
	ref_name="Ubuntu server and preinstalled desktop images"
fi
if [[ "${flavor}" == gnome ]]; then
	manifests+=("${REF}/${codename}-desktop-arm64.manifest")
	ref_name="Ubuntu server, preinstalled desktop and live desktop images"
fi
for manifest in "${manifests[@]}"; do
	[[ -f "${manifest}" ]] || die "no reference manifest for Ubuntu ${codename} (${manifest})"
	while read -r p _; do
		[[ "${p}" == snap:* ]] || ref["${p%%:*}"]=1
	done < "${manifest}"
done
if [[ -z "${want_flavor}" || "${want_flavor}" == "${flavor}" ]]; then
	pass "flavor: ${flavor} (Ubuntu ${codename})"
else
	fail "flavor: the image is ${flavor}, expected ${want_flavor}"
fi
while read -r p reason; do allow["${p}"]="${reason}"; done < <(list "${REF}/allowlist")
unexplained=()
for p in "${installed[@]}"; do
	[[ -n "${ref[${p}]:-}" ]] && continue
	is_hw "${p}" && continue
	[[ -n "${allow[${p}]:-}" ]] && continue
	unexplained+=("${p}")
done
if [[ ${#unexplained[@]} -eq 0 ]]; then
	pass "packages: ${#installed[@]} installed; every package not in the ${ref_name} is hardware-layer or allowlisted"
else
	fail "packages: ${#unexplained[@]} not in the Ubuntu reference, not hardware-layer, not allowlisted"
	printf '%s\n' "${unexplained[@]}" | detail
fi

# --- 2. apt pinning and upgrade origin --------------------------------------

if cmp -s <(printf '%s\n' "${expected_pin}") "${R}/etc/apt/preferences.d/roxora-hardware.pref"; then
	pass "apt: pin for the hardware repository (origin ${HW_REPO_ORIGIN}) is installed as rendered from userpatches/roxora/apt"
else
	fail "apt: /etc/apt/preferences.d/roxora-hardware.pref is missing or differs from userpatches/roxora/apt/roxora-hardware.pref.in"
fi
if [[ "${HW_REPO}" == armbian ]]; then
	hw_source=/etc/apt/sources.list.d/armbian.sources
else
	hw_source=/etc/apt/sources.list.d/roxora-hardware.sources
	[[ ! -e "${R}/etc/apt/sources.list.d/armbian.sources" ]] ||
		fail "apt: armbian.sources is present although HW_REPO=${HW_REPO}"
fi
if grep -q "${HW_REPO_HOST}" "${R}${hw_source}" 2> /dev/null; then
	pass "apt: hardware repository source ${hw_source} (${HW_REPO_HOST}) is present (needed for kernel updates)"
else
	fail "apt: ${hw_source} with ${HW_REPO_HOST} is missing"
fi

if [[ "${offline}" == no ]]; then
	cp -L /etc/resolv.conf "${R}/tmp/resolv.conf"
	rm -f "${R}/etc/resolv.conf"
	ln -s /tmp/resolv.conf "${R}/etc/resolv.conf"
	if ! in_root apt-get -qq update > "${work}/apt-update.log" 2>&1; then
		fail "apt: apt-get update failed in the chroot"
		detail < "${work}/apt-update.log"
	fi
fi

# Every package the hardware repository offers: is its candidate from there?
mapfile -t armbian_pkgs < <(cat "${R}"/var/lib/apt/lists/"${HW_REPO_HOST}"_*_Packages 2> /dev/null | awk '/^Package:/ { print $2 }' | sort -u)
if [[ ${#armbian_pkgs[@]} -eq 0 ]]; then
	fail "apt: no package lists from ${HW_REPO_HOST} in the image"
else
	policy_ok=yes
	in_root apt-cache policy "${armbian_pkgs[@]}" > "${work}/policy.txt" 2> "${work}/policy.err" || policy_ok=no
	# For each package, print "<name> <origin>" for its candidate version:
	# "ubuntu" when an Ubuntu archive offers it (apt then downloads it from
	# there: Armbian mirrors some Ubuntu packages at the same version),
	# "armbian" when only the hardware repository does, "none" when there is
	# no candidate.
	awk -v hw="${HW_REPO_HOST}" '
		function flush() {
			if (pkg == "") return
			if (cand == "(none)" || cand == "") o = "none"
			else if (ub) o = "ubuntu"
			else if (ar) o = "armbian"
			else o = "other"
			print pkg, o
		}
		/^[^ ].*:$/ { flush(); pkg = substr($0, 1, length($0) - 1); cand = ""; invers = 0; ub = 0; ar = 0; next }
		/^  Candidate:/ { cand = $2; next }
		/^ \*\*\* / { invers = ($2 == cand); next }
		/^     [^ ]/ { invers = ($1 == cand); next }
		/^        / && invers && /ubuntu\.com/ { ub = 1; next }
		/^        / && invers && index($0, hw) { ar = 1; next }
		END { flush() }
	' "${work}/policy.txt" > "${work}/candidates.txt"
	bad=()
	while read -r p org; do
		[[ "${org}" == armbian ]] || continue
		is_hw "${p}" || bad+=("${p}")
	done < "${work}/candidates.txt"
	hw_from_armbian="$(awk '$2 == "armbian"' "${work}/candidates.txt" | wc -l)"
	n_cand="$(wc -l < "${work}/candidates.txt")"
	if [[ "${policy_ok}" != yes ]]; then
		fail "apt: apt-cache policy failed in the chroot"
		detail < "${work}/policy.err"
	elif [[ "${n_cand}" -ne ${#armbian_pkgs[@]} ]]; then
		fail "apt: apt-cache policy described ${n_cand} of ${#armbian_pkgs[@]} packages from ${HW_REPO_HOST}"
	elif [[ ${#bad[@]} -eq 0 ]]; then
		pass "apt: of ${#armbian_pkgs[@]} packages in ${HW_REPO_HOST}, only the ${hw_from_armbian} hardware-layer ones have their candidate there"
	else
		fail "apt: ${HW_REPO_HOST} is the candidate for packages outside the hardware layer"
		printf '%s\n' "${bad[@]}" | detail
	fi
fi

# Is the installed version of a package Ubuntu's (maintainer), and offered by
# an Ubuntu archive? apt-cache policy output in $2.
from_ubuntu() {
	local inst
	inst="$(awk '/Installed:/ { print $2 }' <<< "$2")"
	in_root dpkg-query -W -f '${Maintainer}\n' "$1" | grep -qi ubuntu &&
		awk -v v="${inst}" '$1 == v || ($1 == "***" && $2 == v) { f = 1; next } f && /^ +[0-9-]+ / { if ($0 ~ /ubuntu/) ok = 1; next } f { f = 0 } END { exit !ok }' <<< "$2"
}

bf="$(in_root apt-cache policy base-files)"
bf_inst="$(awk '/Installed:/ { print $2 }' <<< "${bf}")"
if from_ubuntu base-files "${bf}"; then
	pass "apt: base-files ${bf_inst} is Ubuntu's, from the Ubuntu archive"
else
	fail "apt: base-files is not the Ubuntu archive's"
	detail <<< "${bf}"
fi

upgrade_ok=yes
in_root apt-get -s -o Debug::NoLocking=1 full-upgrade > "${work}/upgrade.txt" 2>&1 || upgrade_ok=no
bad=()
while read -r p origin; do
	is_hw "${p}" || bad+=("${p} (${origin})")
done < <(awk -v org="${HW_REPO_ORIGIN}:" '/^Inst / && index($0, "(") && index(substr($0, index($0, "(")), org) { o = $0; sub(/^[^(]*\(/, "", o); print $2, o }' "${work}/upgrade.txt")
if [[ "${upgrade_ok}" != yes ]]; then
	fail "apt: apt-get -s full-upgrade failed in the chroot"
	detail < "${work}/upgrade.txt"
elif [[ ${#bad[@]} -eq 0 ]]; then
	pass "apt: full-upgrade would take $(grep -c '^Inst ' "${work}/upgrade.txt" || true) packages and none outside the hardware layer from ${HW_REPO_ORIGIN}"
else
	fail "apt: full-upgrade would install or upgrade distro-layer packages from ${HW_REPO_ORIGIN}"
	printf '%s\n' "${bad[@]}" | detail
fi

# --- 3. removed files are gone, Ubuntu files are as shipped -------------------

present=()
while read -r pattern; do
	for path in "${R}"${pattern}; do
		[[ -e "${path}" || -L "${path}" ]] && present+=("${path#"${R}"}")
	done
done < <(
	list "${LISTS}/bsp-remove.list"
	list "${LISTS}/rootfs-remove.list"
)
if [[ ${#present[@]} -eq 0 ]]; then
	pass "files: none of the removed BSP and rootfs paths exist"
else
	fail "files: ${#present[@]} removed paths exist"
	printf '%s\n' "${present[@]}" | detail
fi

mapfile -t keep < <(list "${LISTS}/keep-modified.list")
# dpkg --verify exits non-zero when it finds changed files, so judge it by
# its error output: anything on stderr means it could not check.
in_root dpkg --verify > "${work}/dpkg-verify.txt" 2> "${work}/dpkg-verify.err" || true
changed=()
while read -r path; do
	owner="$(in_root dpkg-query -S "${path}" 2> /dev/null | head -1 | sed 's/: .*//')"
	[[ "${owner}" =~ ^(linux-image|linux-dtb|linux-headers|linux-u-boot|armbian-firmware|armbian-bsp-cli) ]] && continue
	skip=no
	for k in "${keep[@]}"; do
		# shellcheck disable=SC2053 # glob match on purpose
		[[ "${path}" == ${k} ]] && skip=yes && break
	done
	[[ "${skip}" == yes ]] || changed+=("${path} (${owner})")
done < <(awk '{ print $NF }' "${work}/dpkg-verify.txt" | sort -u)
if [[ -s "${work}/dpkg-verify.err" ]]; then
	fail "files: dpkg --verify reported errors"
	detail < "${work}/dpkg-verify.err"
elif [[ ${#changed[@]} -eq 0 ]]; then
	pass "files: dpkg --verify finds no changed Ubuntu package files beyond keep-modified.list"
else
	fail "files: Ubuntu package files differ from the packages"
	printf '%s\n' "${changed[@]}" | detail
fi

# Configuration generated from package templates and file modes, which dpkg
# --verify does not check.
tpl_errors=()
cmp -s "${R}/usr/share/openssh/sshd_config" "${R}/etc/ssh/sshd_config" ||
	tpl_errors+=("/etc/ssh/sshd_config differs from openssh-server's template")
cmp -s "${R}/usr/share/libc-bin/nsswitch.conf" "${R}/etc/nsswitch.conf" ||
	tpl_errors+=("/etc/nsswitch.conf differs from libc-bin's template")
grep -Eq '^tmpfs[[:space:]]+/tmp[[:space:]]' "${R}/etc/fstab" &&
	tpl_errors+=("/etc/fstab mounts /tmp as tmpfs")
for f in "${R}"/etc/update-motd.d/*; do
	[[ -x "${f}" ]] || tpl_errors+=("${f#"${R}"} is not executable")
done
if [[ ${#tpl_errors[@]} -eq 0 ]]; then
	pass "files: sshd_config and nsswitch.conf as Ubuntu generates them, motd scripts executable, /tmp on disk"
else
	fail "files: ${#tpl_errors[@]} differences from Ubuntu outside dpkg's checks"
	printf '%s\n' "${tpl_errors[@]}" | detail
fi

if grep -q '^ID=ubuntu$' "${R}/etc/os-release" && ! grep -qi armbian "${R}/etc/os-release"; then
	# shellcheck disable=SC1091
	pass "files: /etc/os-release is Ubuntu's ($(. "${R}/etc/os-release" && echo "${PRETTY_NAME}"))"
else
	fail "files: /etc/os-release is not Ubuntu's"
fi

# --- 4. boot files -----------------------------------------------------------

if [[ "${uefi}" == yes ]]; then
	# UEFI firmware on the board starts GRUB from the EFI system partition; it
	# passes its own device tree, so GRUB loads none and there is no U-Boot.
	boot_errors=()
	[[ "${ptable}" == gpt ]] || boot_errors+=("partition table is '${ptable}', not gpt")
	esppart="${loop}p${esp_num}"
	esp_fs="$(blkid -p -s TYPE -o value "${esppart}" 2> /dev/null || true)"
	esp_uuid="$(blkid -p -s UUID -o value "${esppart}" 2> /dev/null || true)"
	[[ "${esp_fs}" == vfat ]] || boot_errors+=("EFI system partition ${esp_num} is '${esp_fs}', not vfat")
	grep -Eq "^UUID=${esp_uuid}[[:space:]]+/boot/efi[[:space:]]+vfat[[:space:]]" "${R}/etc/fstab" ||
		boot_errors+=("/etc/fstab does not mount the EFI system partition (UUID ${esp_uuid}) at /boot/efi")
	mkdir -p "${work}/esp"
	loader=""
	if [[ "${esp_fs}" == vfat ]] && mount -o ro "${esppart}" "${work}/esp"; then
		# FAT is case-insensitive; firmware looks for \EFI\BOOT\BOOTAA64.EFI.
		loader="$(find "${work}/esp" -ipath "${work}/esp/efi/boot/bootaa64.efi" -type f | head -1)"
	fi
	core="${R}/boot/grub/arm64-efi/core.efi"
	if [[ -z "${loader}" ]]; then
		boot_errors+=("no EFI/BOOT/BOOTAA64.EFI on the EFI system partition")
	elif [[ "$(head -c 2 "${loader}")" != MZ ]]; then
		boot_errors+=("EFI/BOOT/BOOTAA64.EFI is not an EFI executable")
	elif ! cmp -s "${loader}" "${core}"; then
		boot_errors+=("EFI/BOOT/BOOTAA64.EFI is not the GRUB image grub-install made (${core#"${R}"})")
	fi
	# The kernel the installed kernel package carries, and its initrd.
	kver="$(in_root dpkg-query -L "${kpkg}" | sed -n 's|^/boot/vmlinuz-||p')"
	kver="${kver%%$'\n'*}"
	[[ -n "${kver}" && -f "${R}/boot/vmlinuz-${kver}" ]] || boot_errors+=("no /boot/vmlinuz-<version> from ${kpkg}")
	[[ -f "${R}/boot/initrd.img-${kver}" ]] || boot_errors+=("/boot/initrd.img-${kver} missing")
	[[ -n "${kver}" && -d "${R}/lib/modules/${kver}" ]] || boot_errors+=("no /lib/modules for kernel '${kver}'")
	# The kernel's device trees for the SoC on the EFI system partition, for
	# the firmware's device tree override, and the hook that keeps them there.
	soc="$(awk -v b="${board}" '!/^[[:space:]]*(#|$)/ && $1 == b { print $6; exit }' "${REPO}/boards.conf")"
	[[ -x "${R}/etc/kernel/postinst.d/zz-roxora-efi-dtb" ]] ||
		boot_errors+=("/etc/kernel/postinst.d/zz-roxora-efi-dtb missing or not executable")
	dtb_src="${R}/usr/lib/linux-image-${kver}/rockchip"
	dtb_dst="${work}/esp/dtb/rockchip"
	declare -i n_dtb=0
	if [[ -z "${soc}" ]]; then
		boot_errors+=("${board} is not in boards.conf, cannot tell its SoC")
	elif [[ ! -d "${dtb_dst}" ]]; then
		boot_errors+=("no dtb/rockchip directory on the EFI system partition")
	else
		for f in "${dtb_src}/${soc}"-*.dtb; do
			[[ -f "${f}" ]] || continue
			if cmp -s "${f}" "${dtb_dst}/${f##*/}"; then
				n_dtb+=1
			else
				boot_errors+=("dtb/rockchip/${f##*/} on the EFI system partition is missing or differs from kernel ${kver}'s")
			fi
		done
		for f in "${dtb_dst}/${soc}"-*.dtb; do
			[[ -f "${f}" && ! -f "${dtb_src}/${f##*/}" ]] && boot_errors+=("dtb/rockchip/${f##*/} on the EFI system partition is not in kernel ${kver}")
		done
		((n_dtb > 0)) || boot_errors+=("no ${soc} device trees in ${dtb_src#"${R}"} or on the EFI system partition")
	fi
	# grub.cfg is update-grub's, for that kernel, with Roxora's arguments.
	cfg="${R}/boot/grub/grub.cfg"
	root_uuid="$(blkid -p -s UUID -o value "${rootpart}" 2> /dev/null || true)"
	cmdline="$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "${R}/etc/default/grub.d/90-roxora.cfg" 2> /dev/null)"
	if [[ ! -f "${cfg}" ]]; then
		boot_errors+=("/boot/grub/grub.cfg missing")
	else
		grep -q '^### BEGIN /etc/grub.d/10_linux ###' "${cfg}" || boot_errors+=("grub.cfg was not made by update-grub (no 10_linux section)")
		grep -Eq "^[[:space:]]*linux[[:space:]]+/boot/vmlinuz-${kver}[[:space:]]+root=UUID=${root_uuid}[[:space:]]" "${cfg}" ||
			boot_errors+=("grub.cfg has no 'linux /boot/vmlinuz-${kver} root=UUID=${root_uuid}' line")
		grep -Eq "^[[:space:]]*initrd[[:space:]]+/boot/initrd.img-${kver}$" "${cfg}" ||
			boot_errors+=("grub.cfg has no 'initrd /boot/initrd.img-${kver}' line")
		if [[ -z "${cmdline}" ]]; then
			boot_errors+=("/etc/default/grub.d/90-roxora.cfg missing or without GRUB_CMDLINE_LINUX_DEFAULT")
		else
			grep -Fq -- "${cmdline}" "${cfg}" || boot_errors+=("grub.cfg does not pass '${cmdline}' to the kernel")
		fi
		grep -Eq '^[[:space:]]*devicetree[[:space:]]' "${cfg}" && boot_errors+=("grub.cfg loads a device tree (the firmware's must be used)")
	fi
	in_root dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 'linux-dtb-*' 2> /dev/null | grep -q '^ii' &&
		boot_errors+=("a linux-dtb package is installed (Ubuntu's 10_linux would load its directory as device tree)")
	# No U-Boot: no package, no boot script, nothing written before the first
	# partition (the GPT ends at 17 KiB).
	in_root dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 'linux-u-boot-*' 2> /dev/null | grep -q '^ii' &&
		boot_errors+=("a linux-u-boot package is installed")
	for f in boot.scr boot.cmd armbianEnv.txt uInitrd; do
		[[ ! -e "${R}/boot/${f}" ]] || boot_errors+=("/boot/${f} exists (U-Boot boot script files)")
	done
	gap=$((${first_start:-0} - 32768))
	if ((gap <= 0)); then
		boot_errors+=("first partition starts at ${first_start:-?} bytes, no room checked before it")
	elif ! cmp -s -n "${gap}" <(dd if="${loop}" bs=32k skip=1 count=$(((gap + 32767) / 32768)) status=none) /dev/zero; then
		boot_errors+=("data between 32 KiB and the first partition (a bootloader was written)")
	fi
	# GRUB comes from the Ubuntu archive, and its updates write no NVRAM entry.
	# Every installed grub package is checked. 26.04 images have no
	# grub-common, like Ubuntu's 26.04 server image.
	grub_pkgs=()
	mapfile -t grub_installed < <(awk '$1 ~ /^ii/ && $2 ~ /^grub/ { print $2 }' "${work}/dpkg-query.txt")
	for p in grub2-common grub-efi-arm64 grub-efi-arm64-bin; do
		[[ " ${grub_installed[*]} " == *" ${p} "* ]] || boot_errors+=("${p} is not installed")
	done
	for p in "${grub_installed[@]}"; do
		p="${p%%:*}"
		if from_ubuntu "${p}" "$(in_root apt-cache policy "${p}")"; then
			grub_pkgs+=("${p} $(in_root dpkg-query -W -f '${Version}' "${p}")")
		else
			boot_errors+=("${p} is not the Ubuntu archive's")
		fi
	done
	in_root debconf-show grub-efi-arm64 2> /dev/null | grep -q 'grub2/update_nvram: false' ||
		boot_errors+=("debconf grub2/update_nvram is not false (GRUB updates would write firmware boot entries)")
	if [[ ${#boot_errors[@]} -eq 0 ]]; then
		pass "boot: UEFI: GPT, EFI system partition ${esp_num} at /boot/efi with EFI/BOOT/BOOTAA64.EFI = GRUB's core.efi, grub.cfg from update-grub with vmlinuz and initrd.img in place for kernel ${kver}; no device tree in GRUB, ${n_dtb} ${soc} device trees on the EFI system partition match the kernel's, no U-Boot; $(
			IFS=,
			echo "${grub_pkgs[*]}"
		) from the Ubuntu archive, update_nvram false"
	else
		fail "boot: UEFI: ${#boot_errors[@]} problems"
		printf '%s\n' "${boot_errors[@]}" | detail
	fi
else
	boot_errors=()
	for f in boot.scr boot.cmd armbianEnv.txt; do
		[[ -f "${R}/boot/${f}" ]] || boot_errors+=("/boot/${f} missing")
	done
	for l in Image uInitrd dtb; do
		if [[ ! -L "${R}/boot/${l}" ]]; then
			boot_errors+=("/boot/${l} is not a symlink")
		elif [[ ! -e "${R}/boot/$(readlink "${R}/boot/${l}")" ]]; then
			boot_errors+=("/boot/${l} points at $(readlink "${R}/boot/${l}"), which is missing")
		fi
	done
	# The device tree comes from armbianEnv.txt, or, when it sets none, from the
	# default environment of the U-Boot the image carries (mainline U-Boot on the
	# ROCK 4D has DEFAULT_FDT_FILE set, and Armbian leaves fdtfile out).
	ubin="$(find "${R}"/usr/lib/linux-u-boot-* -name 'u-boot-rockchip.bin' 2> /dev/null | head -1)"
	fdtfile="$(sed -n 's/^fdtfile=//p' "${R}/boot/armbianEnv.txt" 2> /dev/null | tail -1)"
	fdtsource="armbianEnv.txt"
	if [[ -z "${fdtfile}" && -n "${ubin}" ]]; then
		fdtfile="$(grep -a -o 'fdtfile=[[:alnum:]/._-]*\.dtb' "${ubin}" | head -1 | sed 's/^fdtfile=//')"
		fdtsource="U-Boot default environment"
	fi
	if [[ -z "${fdtfile}" ]]; then
		boot_errors+=("neither armbianEnv.txt nor U-Boot sets fdtfile")
	elif [[ ! -f "${R}/boot/dtb/${fdtfile}" ]]; then
		boot_errors+=("/boot/dtb/${fdtfile} (fdtfile) missing")
	fi
	kver="$(readlink "${R}/boot/Image" 2> /dev/null | sed 's/^vmlinuz-//')"
	[[ -n "${kver}" && -d "${R}/lib/modules/${kver}" ]] || boot_errors+=("no /lib/modules for kernel '${kver}'")
	if command -v dumpimage > /dev/null && [[ -f "${R}/boot/uInitrd" ]]; then
		dumpimage -l "${R}/boot/uInitrd" 2> /dev/null | grep -q 'RAMDisk Image' || boot_errors+=("/boot/uInitrd is not a U-Boot ramdisk image")
	fi
	# The bootloader at 32 KiB must be the one the installed U-Boot package carries.
	if [[ -n "${ubin}" ]]; then
		size="$(stat -c %s "${ubin}")"
		if ! cmp -s -n "${size}" "${ubin}" <(dd if="${loop}" bs=32k skip=1 count=$(((size + 32767) / 32768)) status=none); then
			boot_errors+=("bootloader at 32 KiB differs from ${ubin#"${R}"}")
		fi
	else
		boot_errors+=("no u-boot-rockchip.bin in /usr/lib/linux-u-boot-*")
	fi
	if [[ ${#boot_errors[@]} -eq 0 ]]; then
		pass "boot: boot.scr, armbianEnv.txt, fdtfile=${fdtfile} (from ${fdtsource}), Image, uInitrd and dtb in place for kernel ${kver}; bootloader matches ${ubin#"${R}"}"
	else
		fail "boot: ${#boot_errors[@]} problems"
		printf '%s\n' "${boot_errors[@]}" | detail
	fi
fi

# --- 5. first boot ---------------------------------------------------------

fb_errors=()
for f in /var/lib/cloud/seed/nocloud/user-data /var/lib/cloud/seed/nocloud/meta-data /etc/cloud/cloud.cfg.d/99-roxora.cfg; do
	[[ -f "${R}${f}" ]] || fb_errors+=("${f} missing")
done
in_root dpkg-query -W cloud-init > /dev/null 2>&1 || fb_errors+=("cloud-init is not installed")
grep -q '^  filename: /swap.img' "${R}/etc/cloud/cloud.cfg.d/99-roxora.cfg" 2> /dev/null || fb_errors+=("no swap file configured for the first boot")
[[ ! -e "${R}/swap.img" ]] || fb_errors+=("/swap.img is in the image (it is made at the first boot)")
[[ -d "${R}/usr/share/fonts" && -d "${R}/usr/local/share/fonts" ]] || fb_errors+=("/usr/share/fonts or /usr/local/share/fonts is missing (snaps installed later would get no system fonts)")
[[ "$(awk -F: '$1 == "root" { print $2 }' "${R}/etc/shadow")" == "*" ]] || fb_errors+=("root has a password")
# Default account: roxora, password set, expired (lastchg 0), in sudo.
roxora_shadow="$(awk -F: '$1 == "roxora"' "${R}/etc/shadow")"
if [[ -z "${roxora_shadow}" ]]; then
	fb_errors+=("user roxora does not exist")
else
	[[ "$(cut -d: -f2 <<< "${roxora_shadow}")" == '$'* ]] || fb_errors+=("roxora has no password")
	[[ "$(cut -d: -f3 <<< "${roxora_shadow}")" == 0 ]] || fb_errors+=("roxora's password is not expired")
	in_root id -nG roxora | grep -qw sudo || fb_errors+=("roxora is not in the sudo group")
	in_root getent group render > /dev/null && { in_root id -nG roxora | grep -qw render || fb_errors+=("roxora is not in the render group (needed for the NPU)"); }
	# Compare numeric ids: the host's user names are not the image's.
	[[ -d "${R}/home/roxora" && "$(stat -c %u "${R}/home/roxora")" == "$(awk -F: '$1 == "roxora" { print $3 }' "${R}/etc/passwd")" ]] ||
		fb_errors+=("/home/roxora is missing or not owned by roxora")
fi
grep -q '^ubuntu:' "${R}/etc/passwd" && fb_errors+=("a user named ubuntu exists")
[[ ! -e "${R}/root/.not_logged_in_yet" ]] || fb_errors+=("/root/.not_logged_in_yet exists (Armbian first-login wizard)")
in_root getcap /usr/bin/ping | grep -q cap_net_raw || fb_errors+=("/usr/bin/ping has lost its cap_net_raw file capability")
compgen -G "${R}/etc/ssh/ssh_host_*" > /dev/null && fb_errors+=("SSH host keys are in the image (they must be created at the first boot)")
grep -rqs -- '--autologin' "${R}/etc/systemd/system" && fb_errors+=("a getty autologin override exists")
[[ "$(cat "${R}/etc/hostname")" == "${board}" ]] || fb_errors+=("hostname is '$(cat "${R}/etc/hostname")', expected '${board}'")
if [[ ${#fb_errors[@]} -eq 0 ]]; then
	pass "first boot: cloud-init seeded with a swap file, font directories for snaps, no SSH host keys, ping capability set, user roxora with a home directory and an expired password, root locked, no autologin, hostname ${board}"
else
	fail "first boot: ${#fb_errors[@]} problems"
	printf '%s\n' "${fb_errors[@]}" | detail
fi

# --- 6. automatic updates ------------------------------------------------------

au="${R}/etc/apt/apt.conf.d/20auto-upgrades"
if in_root dpkg-query -W unattended-upgrades > /dev/null 2>&1 &&
	grep -q 'APT::Periodic::Update-Package-Lists "1"' "${au}" 2> /dev/null &&
	grep -q 'APT::Periodic::Unattended-Upgrade "1"' "${au}" 2> /dev/null; then
	pass "updates: unattended-upgrades installed and enabled, as on Ubuntu server"
else
	fail "updates: unattended-upgrades missing or automatic updates off"
	[[ -f "${au}" ]] && detail < "${au}"
fi

# --- 6b. apt and sudo configuration --------------------------------------------

# Every file in these directories must belong to a package or be listed in
# reference/config-unowned.list, so nothing adds an apt source, a signing key,
# an apt setting or a sudo rule unnoticed. No local dpkg diversions either.
declare -A unowned_ok=()
while read -r p _; do unowned_ok["${p}"]=1; done < <(list "${REF}/config-unowned.list")
cfg_errors=()
while read -r f; do
	f="${f#"${R}"}"
	[[ -n "${unowned_ok[${f}]:-}" ]] && continue
	in_root dpkg-query -S "${f}" > /dev/null 2>&1 || cfg_errors+=("${f} belongs to no package and is not in config-unowned.list")
done < <(find "${R}/etc/apt/sources.list.d" "${R}/etc/apt/trusted.gpg.d" "${R}/etc/apt/keyrings" \
	"${R}/usr/share/keyrings" "${R}/etc/apt/apt.conf.d" "${R}/etc/apt/preferences.d" "${R}/etc/sudoers.d" \
	-mindepth 1 \( -type f -o -type l \) 2> /dev/null | sort)
[[ -e "${R}/etc/apt/trusted.gpg" ]] && cfg_errors+=("/etc/apt/trusted.gpg exists (keys belong in a keyring file per source)")
grep -Eq '^[[:space:]]*deb' "${R}/etc/apt/sources.list" 2> /dev/null && cfg_errors+=("/etc/apt/sources.list has sources (Ubuntu uses sources.list.d/ubuntu.sources)")
while read -r d; do
	cfg_errors+=("local dpkg diversion: ${d}")
done < <(in_root dpkg-divert --list 2> /dev/null | grep '^local diversion' || true)
if [[ ${#cfg_errors[@]} -eq 0 ]]; then
	pass "config: apt sources, keys, apt settings and sudo rules all from packages or listed; no local diversions"
else
	fail "config: unexpected apt or sudo configuration"
	printf '%s\n' "${cfg_errors[@]}" | detail
fi

# --- 7. Roxora's tools ---------------------------------------------------------

# shellcheck source=userpatches/roxora/hwtool.conf
source "${LISTS}/hwtool.conf"
hw_inst="$(in_root dpkg-query -W -f '${db:Status-Abbrev} ${Version}' roxora-hwtool 2> /dev/null || true)"
if [[ "${hw_inst}" == "ii  ${HWTOOL_VERSION}" ]] && in_root hwtool --version > /dev/null 2>&1; then
	pass "tools: hwtool ${HWTOOL_VERSION} installed and runs"
else
	fail "tools: hwtool ${HWTOOL_VERSION} not installed or does not run (dpkg: '${hw_inst}')"
fi
# The GTK app: in the desktop images, with its entry for the app grid, and
# not in the command line image.
gtk_inst="$(in_root dpkg-query -W -f '${db:Status-Abbrev} ${Version}' roxora-hwtool-gtk 2> /dev/null || true)"
if [[ "${flavor}" == cli ]]; then
	[[ -z "${gtk_inst}" ]] || fail "tools: roxora-hwtool-gtk is in a command line image (dpkg: '${gtk_inst}')"
elif [[ "${gtk_inst}" == "ii  ${HWTOOL_VERSION}" && -x "${R}/usr/bin/hwtool-gtk" ]] &&
	grep -qs '^Exec=hwtool-gtk' "${R}/usr/share/applications/io.github.roxora_os.HwTool.desktop"; then
	pass "tools: hwtool GTK app ${HWTOOL_VERSION} installed, with its desktop entry"
else
	fail "tools: hwtool GTK app ${HWTOOL_VERSION} not installed or without its desktop entry (dpkg: '${gtk_inst}')"
fi

# shellcheck source=userpatches/roxora/wallpapers/wallpapers.conf
source "${LISTS}/wallpapers/wallpapers.conf"
wp_version="${WALLPAPERS_VERSION}+git${WALLPAPERS_DESIGN_COMMIT:0:7}"
wp_inst="$(in_root dpkg-query -W -f '${db:Status-Abbrev} ${Version}' roxora-wallpapers 2> /dev/null || true)"
wp_errors=()
[[ "${wp_inst}" == "ii  ${wp_version}" ]] || wp_errors+=("roxora-wallpapers ${wp_version} not installed (dpkg: '${wp_inst}')")
for f in roxora-facet-light.png roxora-facet-dark.png; do
	[[ -s "${R}/usr/share/backgrounds/roxora/${f}" ]] || wp_errors+=("/usr/share/backgrounds/roxora/${f} missing")
done
cmp -s "${LISTS}/wallpapers/90_roxora-wallpapers.gschema.override" "${R}/usr/share/glib-2.0/schemas/90_roxora-wallpapers.gschema.override" ||
	wp_errors+=("the GNOME default wallpaper override is missing or differs from userpatches/roxora/wallpapers")
if ((${#wp_errors[@]} == 0)); then
	pass "tools: roxora-wallpapers ${wp_version} installed, Facet the default for GNOME"
else
	fail "tools: wallpapers"
	printf '%s\n' "${wp_errors[@]}" | detail
fi

# --- 8. desktop ------------------------------------------------------------------

if [[ "${flavor}" == cli ]]; then
	# A command line image has no desktop parts.
	cli_errors=()
	for p in gdm3 gnome-shell network-manager; do
		is_installed "${p}" && cli_errors+=("${p} is installed")
	done
	[[ ! -e "${R}/var/lib/snapd/seed/seed.yaml" ]] || cli_errors+=("snaps are seeded (/var/lib/snapd/seed/seed.yaml)")
	[[ -f "${R}/var/lib/cloud/seed/nocloud/network-config" ]] || cli_errors+=("/var/lib/cloud/seed/nocloud/network-config missing")
	if [[ ${#cli_errors[@]} -eq 0 ]]; then
		pass "desktop: none (command line image): no display manager, no NetworkManager, no seeded snaps; cloud-init configures the wired network"
	else
		fail "desktop: ${#cli_errors[@]} desktop parts in a command line image"
		printf '%s\n' "${cli_errors[@]}" | detail
	fi
else
	# The session: GDM starts at boot, into GNOME.
	dt_errors=()
	for p in gdm3 gnome-shell ubuntu-session; do
		is_installed "${p}" || dt_errors+=("${p} is not installed")
	done
	[[ "$(readlink "${R}/etc/systemd/system/display-manager.service" 2> /dev/null)" == */gdm*.service ]] ||
		dt_errors+=("/etc/systemd/system/display-manager.service does not point at GDM")
	[[ "$(cat "${R}/etc/X11/default-display-manager" 2> /dev/null)" == /usr/sbin/gdm3 ]] ||
		dt_errors+=("/etc/X11/default-display-manager is not /usr/sbin/gdm3")
	default_target="${R}/etc/systemd/system/default.target"
	[[ -L "${default_target}" ]] || default_target="${R}/usr/lib/systemd/system/default.target"
	[[ "$(basename "$(readlink "${default_target}" 2> /dev/null)")" == graphical.target ]] ||
		dt_errors+=("the default systemd target is '$(readlink "${default_target}" 2> /dev/null)', not graphical.target")
	grep -Eqs '^[[:space:]]*AutomaticLoginEnable[[:space:]]*=[[:space:]]*[Tt]rue' "${R}/etc/gdm3/custom.conf" &&
		dt_errors+=("GDM logs a user in automatically")
	# The fonts are in the image before snapd sets the seeded snaps up at the
	# first boot, so the snaps get them (CJK text in Firefox).
	is_installed fonts-noto-cjk || dt_errors+=("fonts-noto-cjk is not installed")
	compgen -G "${R}/usr/share/fonts/opentype/noto/NotoSansCJK*" > /dev/null ||
		dt_errors+=("no Noto Sans CJK font files in /usr/share/fonts/opentype/noto")
	if [[ ${#dt_errors[@]} -eq 0 ]]; then
		pass "desktop: GDM is the display manager and starts at boot (graphical.target), GNOME Shell and Ubuntu's session installed, no automatic login, CJK fonts in /usr/share/fonts"
	else
		fail "desktop: ${#dt_errors[@]} problems with the session"
		printf '%s\n' "${dt_errors[@]}" | detail
	fi

	# The network: NetworkManager for every device, as on an Ubuntu desktop,
	# and nothing that waits for systemd-networkd at boot.
	nm_errors=()
	is_installed network-manager || nm_errors+=("network-manager is not installed")
	[[ -L "${R}/etc/systemd/system/multi-user.target.wants/NetworkManager.service" ]] ||
		nm_errors+=("NetworkManager.service is not enabled")
	cmp -s "${LISTS}/desktop/99-roxora-desktop.cfg" "${R}/etc/cloud/cloud.cfg.d/99-roxora-desktop.cfg" ||
		nm_errors+=("/etc/cloud/cloud.cfg.d/99-roxora-desktop.cfg (cloud-init writes no network configuration) is missing or differs from userpatches/roxora/desktop")
	[[ ! -e "${R}/var/lib/cloud/seed/nocloud/network-config" ]] ||
		nm_errors+=("/var/lib/cloud/seed/nocloud/network-config exists (cloud-init would configure the network)")
	renderer_file=""
	for f in "${R}"/usr/lib/netplan/*.yaml "${R}"/etc/netplan/*.yaml; do
		[[ -f "${f}" ]] || continue
		grep -q '^[[:space:]]*renderer:[[:space:]]*NetworkManager' "${f}" && renderer_file="${f#"${R}"}"
		grep -Eq '^[[:space:]]*renderer:[[:space:]]*networkd|^[[:space:]]*(ethernets|wifis|bridges|bonds|vlans):' "${f}" &&
			nm_errors+=("${f#"${R}"} configures devices or names systemd-networkd")
	done
	[[ -n "${renderer_file}" ]] || nm_errors+=("no netplan file makes NetworkManager the renderer")
	while read -r f; do
		nm_errors+=("${f#"${R}"}: systemd-networkd is enabled in the image (wait-online would hold the boot for two minutes)")
	done < <(find "${R}/etc/systemd/system" \( -name 'systemd-networkd.service' -o -name 'systemd-networkd-wait-online.service' \) 2> /dev/null)
	if [[ ${#nm_errors[@]} -eq 0 ]]; then
		pass "desktop: NetworkManager enabled and the netplan renderer (${renderer_file}), cloud-init writes no network configuration, systemd-networkd and its wait-online service not enabled"
	else
		fail "desktop: ${#nm_errors[@]} problems with the network setup"
		printf '%s\n' "${nm_errors[@]}" | detail
	fi

	# The default wallpaper, as GNOME reads it from the compiled schemas: the
	# memory backend has no stored settings, so the answer is the default.
	wp_default="$(in_root env GSETTINGS_BACKEND=memory XDG_CURRENT_DESKTOP=ubuntu:GNOME gsettings get org.gnome.desktop.background picture-uri 2>&1 || true)"
	if [[ "${wp_default}" == "'file:///usr/share/backgrounds/roxora/roxora-facet-light.png'" ]]; then
		pass "desktop: the default wallpaper in the compiled GNOME settings is Roxora Facet"
	else
		fail "desktop: the default wallpaper is not Roxora Facet"
		detail <<< "${wp_default}"
	fi

	# Seeded snaps: every snap of snaps.list for this release and flavor, in
	# its channel, with its file; the model is generic-classic; snapd has not
	# run yet; and snapd's own check of the seed (assertions, bases).
	seed="${R}/var/lib/snapd/seed"
	sn_errors=()
	n_seeded=0
	if [[ ! -s "${seed}/seed.yaml" ]]; then
		sn_errors+=("/var/lib/snapd/seed/seed.yaml missing")
	else
		# "<name> <channel> <file>" per seeded snap.
		awk '
			function flush() { if (name != "") print name, channel, file }
			/^- name:/ { flush(); name = $3; channel = ""; file = "" }
			/^[[:space:]]+channel:/ { channel = $2 }
			/^[[:space:]]+file:/ { file = $2 }
			END { flush() }
		' "${seed}/seed.yaml" > "${work}/seeded.txt"
		n_seeded="$(wc -l < "${work}/seeded.txt")"
		while read -r name _ file; do
			[[ -n "${file}" && -s "${seed}/snaps/${file}" ]] || sn_errors+=("${name}: snap file '${file}' missing from the seed")
			[[ -n "${file}" && "$(stat -c %u:%g "${seed}/snaps/${file}" 2> /dev/null)" == 0:0 ]] || sn_errors+=("${name}: snap file not owned by root")
		done < "${work}/seeded.txt"
		while read -r name channel; do
			grep -q "^${name} ${channel} " "${work}/seeded.txt" ||
				sn_errors+=("${name} from ${channel} (userpatches/roxora/desktop/snaps.list) is not seeded: '$(grep "^${name} " "${work}/seeded.txt" || true)'")
		done < <(list "${LISTS}/desktop/snaps.list" | awk -v r="${codename}" -v f="${flavor}" '$1 == r && ($2 == "gnome-minimal" || $2 == f) { print $3, $4 }')
		for name in snapd firefox; do
			grep -q "^${name} " "${work}/seeded.txt" || sn_errors+=("${name} is not seeded")
		done
		cmp -s "${LISTS}/desktop/generic-classic.model" "${seed}/assertions/model" ||
			sn_errors+=("the seed's model assertion is not generic-classic (userpatches/roxora/desktop/generic-classic.model)")
		[[ ! -e "${R}/var/lib/snapd/state.json" ]] || sn_errors+=("/var/lib/snapd/state.json exists (snapd already ran; the seed would not be installed)")
		if ! command -v snap > /dev/null; then
			sn_errors+=("the snap command is missing on this host, the seed cannot be validated (install snapd)")
		elif ! snap debug validate-seed "${seed}/seed.yaml" > "${work}/validate-seed.txt" 2>&1; then
			sn_errors+=("snap debug validate-seed: $(tr '\n' ' ' < "${work}/validate-seed.txt")")
		fi
	fi
	[[ -L "${R}/etc/systemd/system/multi-user.target.wants/snapd.seeded.service" ]] || sn_errors+=("snapd.seeded.service is not enabled")
	[[ -L "${R}/etc/systemd/system/sockets.target.wants/snapd.socket" ]] || sn_errors+=("snapd.socket is not enabled")
	if [[ ${#sn_errors[@]} -eq 0 ]]; then
		pass "desktop: ${n_seeded} snaps seeded for the first boot ($(awk '{ printf "%s%s", (NR > 1 ? " " : ""), $1 }' "${work}/seeded.txt")), every snap of snaps.list in its channel, model generic-classic, seed valid (snap debug validate-seed)"
	else
		fail "desktop: ${#sn_errors[@]} problems with the seeded snaps"
		printf '%s\n' "${sn_errors[@]}" | detail
	fi
fi

# --- summary -------------------------------------------------------------------

echo
echo "Summary for $(basename "${image_arg}")"
printf '  %s\n' "${summary[@]}"
if ((failures > 0)); then
	echo "${failures} check(s) failed"
	exit 1
fi
echo "All checks passed"
