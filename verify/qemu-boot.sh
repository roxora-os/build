#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2026 Ga Hing Woo <gahing@gahingwoo.com>
#
# Boot a Roxora UEFI image on QEMU's arm64 "virt" machine with Ubuntu's edk2
# build (AAVMF, package qemu-efi-aarch64) and report how far it gets.
#
#   verify/qemu-boot.sh [--timeout SECONDS] [--stub-only] <image.img | image.img.xz> <log>
#
# QEMU (default qemu-system-aarch64) and AAVMF_DIR (default /usr/share/AAVMF)
# in the environment pick another QEMU binary or firmware directory.
#
# As on the boards, the firmware passes the device tree (QEMU's, with ACPI
# off) and starts EFI/BOOT/BOOTAA64.EFI from the EFI system partition. The
# image is not changed: QEMU writes to a throwaway copy. The serial console
# is written to <log>.
#
# QEMU is not a board: the kernel's console arguments name the boards' UART,
# so the kernel log stops once the early console hands over. The check is that
# the firmware starts GRUB and GRUB starts the kernel.
#
# Exits 0 when GRUB ran and the kernel started with grub.cfg's command line,
# 1 otherwise. With --stub-only the command line is not checked: for a kernel
# built only for Rockchip SoCs (the vendor branch has no PL011 UART driver
# and no generic PCI host), nothing it prints after its EFI stub reaches
# QEMU's console.

set -euo pipefail

timeout=300
stub_only=no
args=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--timeout)
			timeout="$2"
			shift 2
			;;
		--stub-only)
			stub_only=yes
			shift
			;;
		-h | --help)
			sed -n '5,27s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
			exit 0
			;;
		*)
			args+=("$1")
			shift
			;;
	esac
done
[[ ${#args[@]} -eq 2 && -f "${args[0]}" ]] || {
	echo "usage: $0 [--timeout SECONDS] <image.img | image.img.xz> <log>" >&2
	exit 2
}
image="${args[0]}"
log="${args[1]}"
[[ "${timeout}" =~ ^[0-9]+$ ]] || {
	echo "qemu-boot.sh: --timeout needs a number of seconds" >&2
	exit 2
}

# QEMU and AAVMF_DIR can point elsewhere than the installed packages.
qemu="${QEMU:-qemu-system-aarch64}"
code="${AAVMF_DIR:-/usr/share/AAVMF}/AAVMF_CODE.fd"
vars="${AAVMF_DIR:-/usr/share/AAVMF}/AAVMF_VARS.fd"
for f in "${code}" "${vars}"; do
	[[ -f "${f}" ]] || {
		echo "qemu-boot.sh: ${f} missing (install qemu-efi-aarch64)" >&2
		exit 2
	}
done
command -v "${qemu}" > /dev/null || {
	echo "qemu-boot.sh: ${qemu} missing (install qemu-system-arm)" >&2
	exit 2
}

work="$(mktemp -d)"
pid=""
cleanup() {
	[[ -n "${pid}" ]] && kill "${pid}" 2> /dev/null
	rm -rf "${work}"
}
trap cleanup EXIT

if [[ "${image}" == *.xz ]]; then
	xz -dc "${image}" > "${work}/disk.img"
else
	cp "${image}" "${work}/disk.img"
fi
cp "${vars}" "${work}/vars.fd"
: > "${log}"

"${qemu}" \
	-machine virt,acpi=off -cpu cortex-a72 -smp 2 -m 2048 \
	-drive if=pflash,format=raw,readonly=on,file="${code}" \
	-drive if=pflash,format=raw,file="${work}/vars.fd" \
	-drive if=none,id=disk0,format=raw,file="${work}/disk.img" \
	-device virtio-blk-pci,drive=disk0 \
	-nic none -display none -monitor none -serial file:"${log}" &
pid=$!

# The serial log without terminal control sequences.
text() { sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r/\n/g' "${log}" | tr -cd '\11\12\40-\176'; }

# Wait for the kernel to start (and a little longer, for its first messages),
# for QEMU to exit, or for the timeout.
started=""
for ((t = 0; t < timeout; t++)); do
	kill -0 "${pid}" 2> /dev/null || break
	if [[ -z "${started}" ]] && text | grep -q 'EFI stub: Booting Linux Kernel'; then
		started="${t}"
	fi
	[[ -n "${started}" ]] && ((t - started >= 60)) && break
	sleep 1
done
kill "${pid}" 2> /dev/null || true
wait "${pid}" 2> /dev/null || true
pid=""

declare -i ok=0
check() {
	if text | grep -q -- "$2"; then
		echo "seen      $1"
	else
		echo "not seen  $1"
		return 1
	fi
}
echo "QEMU virt, cortex-a72, AAVMF, device tree from the firmware (acpi=off), ${t} s"
check "GRUB menu (GNU GRUB)" 'GNU GRUB' || ok+=1
# The kernel started: its EFI stub, or its first message on the early
# console (QEMU's device tree names the PL011 UART as stdout-path).
if ! check "kernel EFI stub (EFI stub: Booting Linux Kernel)" 'EFI stub: Booting Linux Kernel' &&
	! check "kernel log on the early console (Booting Linux on physical CPU)" 'Booting Linux on physical CPU'; then
	ok+=1
fi
# The command line comes from grub.cfg: the root file system by UUID.
if [[ "${stub_only}" == yes ]]; then
	echo "skipped   kernel command line (--stub-only: the kernel has no driver for QEMU's UART)"
else
	check "kernel command line from grub.cfg (root=UUID=)" 'Kernel command line:.*root=UUID=' || ok+=1
fi
echo
echo "Matching lines:"
text | grep -E 'GNU GRUB|Loading|EFI stub|Booting Linux|Kernel command line|Machine model|OF: fdt|ACPI' | sed -e 's/^[[:space:]]*//' -e 's/^/  /' | head -n 20 || true
echo
echo "Last lines of the serial console:"
text | grep -v '^[[:space:]]*$' | tail -n 25 | sed 's/^/  /' || true
((ok == 0))
