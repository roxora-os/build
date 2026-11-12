# shellcheck shell=bash disable=SC2034
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2026 Ga Hing Woo <gahing@gahingwoo.com>
#
# Shared part of Roxora's UEFI board files (userpatches/config/boards/uefi-*.conf).
# A board file sets BOARD_NAME, BOARDFAMILY (the Armbian family whose kernel
# the image uses), BOOT_SOC and ROXORA_UEFI_SERIAL, then sources this file.
#
# Such an image has no U-Boot and no boot script. The UEFI firmware on the
# board starts GRUB (Ubuntu's grub-efi-arm64) from the EFI system partition,
# GRUB starts the kernel, and the firmware passes its own device tree to the
# kernel through the EFI configuration table. GRUB loads no device tree, so
# one image serves every board of the SoC. See docs/architecture.md.

declare -g BOARD_VENDOR="generic"
declare -g BOARD_MAINTAINER=""
declare -g INTRODUCED="2026"
declare -g KERNEL_TARGET="edge"
declare -g KERNEL_TEST_TARGET="edge"
declare -g ROXORA_UEFI="yes"

# No U-Boot: Armbian builds none, writes none to the image, installs no
# U-Boot package.
declare -g BOOTCONFIG="none"
declare -g IMAGE_PARTITION_TABLE="gpt"
# EFI system partition in MiB, mounted at /boot/efi. GRUB needs a few MiB;
# the rest leaves room for files the firmware reads (device tree overrides).
declare -g UEFISIZE=256
# GRUB on the firmware's console, which edk2 sends to the display and the
# serial port.
declare -g UEFI_GRUB_TERMINAL="console"

# Armbian's GRUB support: GPT, EFI partition, grub-install, update-grub.
# userpatches/extensions/roxora.sh replaces its GRUB settings with Roxora's.
enable_extension "grub"

# The family file sets a U-Boot boot script and its environment file; with
# them the board support package would ship boot.cmd and armbianEnv.txt.
function post_family_config__roxora_uefi_no_boot_script() {
	display_alert "Roxora" "UEFI image: no U-Boot boot script" "info"
	unset BOOTSCRIPT BOOTENV_FILE BOOT_FDT_FILE
}
