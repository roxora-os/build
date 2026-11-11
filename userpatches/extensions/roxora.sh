# shellcheck shell=bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2026 Ga Hing Woo <gahing@gahingwoo.com>
#
# Roxora: keep Armbian's hardware layer (kernel, device tree, U-Boot, firmware
# and the hardware parts of the board support package) and give the image a
# stock Ubuntu userspace.
#
# What is kept and what is removed is listed in userpatches/roxora/*.list and
# explained in docs/bsp-classification.md. verify/verify-image.sh reads the same
# lists, so the build and the check cannot drift apart.
#
# Enabled by build.sh through ENABLE_EXTENSIONS=roxora.

# Variables set here are read by armbian/build (SC2034), hook and maintainer
# script functions are called indirectly (SC2317), and dpkg-query format
# strings are single-quoted on purpose (SC2016).
# shellcheck disable=SC2034,SC2317,SC2016

declare -g ROXORA_DIR="${USERPATCHES_PATH}/roxora"

# Print a list file without comments and blank lines.
function roxora_list() {
	sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "${ROXORA_DIR}/${1}"
}

# Armbian versions the BSP package by hashing the source of the
# post_family_tweaks_bsp hooks. The BSP filter reads bsp-remove.list at run
# time, so fold the list's hash into the name of an empty hook: a change to the
# list then changes the package version, and a stale cached BSP is not reused.
eval "function post_family_tweaks_bsp__roxora_zz_list_$(sha256sum "${ROXORA_DIR}/bsp-remove.list" | cut -c1-16)() { :; }"

function extension_prepare_config__roxora() {
	display_alert "Roxora" "${BOARD} ${BRANCH} ${RELEASE} ${ROXORA_VERSION:-dev}" "info"

	if ! awk -v b="${BOARD}" -v br="${BRANCH}" -v r="${RELEASE}" \
		'!/^[[:space:]]*(#|$)/ && $1 == b && $2 == br && $3 == r { found = 1 } END { exit !found }' \
		"${ROXORA_DIR}/boards.conf"; then
		exit_with_error "Roxora: ${BOARD} ${BRANCH} ${RELEASE} is not in boards.conf"
	fi
	[[ "${BUILD_MINIMAL}" == "yes" && "${BUILD_DESKTOP}" == "no" ]] ||
		exit_with_error "Roxora builds minimal server images only (BUILD_MINIMAL=yes BUILD_DESKTOP=no)"

	# Ubuntu's own base-files and /etc/os-release, not armbian-base-files.
	declare -g KEEP_ORIGINAL_OS_RELEASE="yes"
	# No root autologin on the consoles; stock Ubuntu has none.
	declare -g CONSOLE_AUTOLOGIN="no"
	# Stock Ubuntu images are UTC; Armbian copies the build host's zone.
	declare -g TZDATA="Etc/UTC"
	# armbian-config is not in the image, so there is no tuning profile to apply.
	declare -g TUNING_PROFILE="none"
	declare -g PLYMOUTH="no"
	# Headers only where a board needs them for DKMS (the ROCK 4D Wi-Fi
	# extension turns them back on); they are updated with the kernel.
	declare -g INSTALL_HEADERS="no"
	# Hostname is the board name (Armbian's default, kept on purpose).
	declare -g HOST="${BOARD}"

	# First boot is handled by cloud-init, as on Ubuntu's preinstalled server
	# images: it creates the default user, regenerates the SSH host keys and
	# grows the root partition. unattended-upgrades installs security updates
	# automatically, as on Ubuntu's server images.
	declare pkg
	for pkg in cloud-init cloud-guest-utils unattended-upgrades; do
		EXTRA_PACKAGES_IMAGE+=("${pkg}")
		EXTRA_PACKAGES_IMAGE_REFS+=("extension_prepare_config__roxora:${BASH_SOURCE[0]}:${LINENO}")
	done
}

# Drop the distro-layer parts of the board support package before it is built,
# so they are never installed. Runs with ${destination} as the package root.
function post_family_tweaks_bsp__roxora_hardware_only() {
	: "${destination:?destination is not set}"
	display_alert "Roxora" "removing distro-layer files from the BSP package" "info"

	declare pattern path
	while read -r pattern; do
		# shellcheck disable=SC2086 # the pattern is a glob on purpose
		for path in "${destination}"${pattern}; do
			[[ -e "${path}" || -L "${path}" ]] || continue
			rm -rf "${path}"
		done
	done < <(roxora_list bsp-remove.list)
	# Leave no empty directories behind.
	find "${destination}" -mindepth 1 -depth -type d -not -path "${destination}/DEBIAN*" -empty -delete

	# The BSP maintainer scripts mix boot-related steps with distro defaults.
	# Replace them with the boot-related steps only. These functions are
	# rendered into the package after this hook returns.
	function board_side_bsp_cli_preinst() {
		# Keep Armbian's initramfs compression: it is part of the boot path
		# (uInitrd is made by /etc/initramfs/post-update.d/99-uboot).
		sed -i "s/^COMPRESS=.*/COMPRESS=gzip/" /etc/initramfs-tools/initramfs.conf
	}
	function board_side_bsp_cli_postinst_base() {
		# Avoid the "waiting for suspend/resume device" boot delay.
		if [[ -f "/etc/initramfs-tools/initramfs.conf" ]]; then
			if ! grep --quiet "RESUME=none" /etc/initramfs-tools/initramfs.conf; then
				echo "RESUME=none" >> /etc/initramfs-tools/initramfs.conf
			fi
		fi
	}
	function board_side_bsp_cli_postinst_finish() {
		# Groups the BSP udev rules refer to.
		for group in i2c gpio spi; do
			getent group "${group}" > /dev/null || groupadd --system "${group}" || true
		done
		[[ -f /lib/systemd/system/armbian-led-state.service ]] &&
			systemctl --no-reload enable armbian-led-state.service > /dev/null 2>&1
		return 0
	}
	function board_side_bsp_cli_postrm() {
		if [[ remove == "$1" ]] || [[ abort-install == "$1" ]]; then
			systemctl disable armbian-led-state.service > /dev/null 2>&1
		fi
		return 0
	}
}

# armbian/build enables its armbian-config extension for every build
# (lib/functions/configuration/main-config.sh). It adds a second apt source,
# github.armbian.com/configng, whose origin is not "Armbian" and so escapes the
# pin, and installs armbian-config from it. armbian-config is distro layer.
# ENABLE_EXTENSIONS are sourced after that extension, so these definitions
# replace its two hooks and nothing is added or installed.
function custom_apt_repo__add_armbian-github-repo() {
	display_alert "Roxora" "not adding the armbian-config repository" "info"
}
function post_armbian_repo_customize_image__install_armbian-config() {
	display_alert "Roxora" "not installing armbian-config" "info"
}

# Pin the Armbian repository. Its source list stays, because kernel, DTB,
# U-Boot and firmware updates come from it; everything else it publishes is
# never installed or upgraded from there. The pin is in place from the rootfs
# stage on: Armbian's noble-utils component publishes newer versions of Ubuntu
# packages (base-files among them) that the rootfs upgrade would otherwise
# take. The rootfs cache id includes this hook, so a rootfs built this way is
# never mixed up with Armbian's own.
function custom_apt_repo__roxora_pin_armbian() {
	display_alert "Roxora" "pinning the Armbian repository (${CUSTOM_REPO_WHEN})" "info"
	install -D -m 0644 "${ROXORA_DIR}/apt/roxora-armbian.pref" "${SDCARD}/etc/apt/preferences.d/roxora-armbian.pref"
}

# Seed cloud-init for the first boot.
function post_customize_image__roxora_cloud_init() {
	display_alert "Roxora" "seeding cloud-init" "info"
	install -D -m 0644 "${ROXORA_DIR}/cloud-init/99-roxora.cfg" "${SDCARD}/etc/cloud/cloud.cfg.d/99-roxora.cfg"
	install -d -m 0755 "${SDCARD}/var/lib/cloud/seed/nocloud"
	install -m 0644 "${ROXORA_DIR}/cloud-init/user-data" "${SDCARD}/var/lib/cloud/seed/nocloud/user-data"
	install -m 0644 "${ROXORA_DIR}/cloud-init/network-config" "${SDCARD}/var/lib/cloud/seed/nocloud/network-config"
	sed -e "s/@HOSTNAME@/${HOST}/g" "${ROXORA_DIR}/cloud-init/meta-data" > "${SDCARD}/var/lib/cloud/seed/nocloud/meta-data"
	# Like Ubuntu: root has no password; the cloud-init user uses sudo.
	chroot_sdcard usermod -p "'*'" root
}

# Undo what Armbian changed in Ubuntu's own packages and remove the files it
# added outside any package. Runs with all repositories enabled, so the
# original package files can be fetched.
function post_repo_customize_image__roxora_restore_ubuntu() {
	display_alert "Roxora" "restoring stock Ubuntu files" "info"

	# Installed by Armbian on every Ubuntu image to hide Ubuntu Pro messages.
	if chroot_sdcard_with_stdout dpkg-query -W -f='${Status}' fake-ubuntu-advantage-tools 2> /dev/null | grep -q 'ok installed'; then
		chroot_sdcard_apt_get purge fake-ubuntu-advantage-tools
	fi

	# Should not be installed at all (see the overrides below); remove it if a
	# future armbian/build installs it some other way.
	if chroot_sdcard_with_stdout dpkg-query -W -f='${Status}' armbian-config 2> /dev/null | grep -q 'ok installed'; then
		chroot_sdcard_apt_get purge armbian-config
	fi

	# Any other Armbian-built package outside the hardware layer is replaced by
	# Ubuntu's version, which the pin makes the candidate. A rootfs from a cache
	# built without the pin carries Armbian's base-files, for example.
	# apt picks the candidate by priority before version: Ubuntu's version
	# (500) wins over the installed Armbian one (100 from dpkg status, -1
	# from the pinned repository), so installing the package name downgrades.
	declare -a armbian_pkgs=()
	mapfile -t armbian_pkgs < <(roxora_armbian_distro_packages)
	if [[ ${#armbian_pkgs[@]} -gt 0 ]]; then
		display_alert "Roxora" "replacing Armbian builds of ${armbian_pkgs[*]} with Ubuntu's" "info"
		chroot_sdcard_apt_get install --allow-downgrades "${armbian_pkgs[@]}"
		mapfile -t armbian_pkgs < <(roxora_armbian_distro_packages)
		[[ ${#armbian_pkgs[@]} -eq 0 ]] ||
			exit_with_error "Roxora: no Ubuntu version replaces these Armbian packages" "${armbian_pkgs[*]}"
	fi

	# root's dotfiles as base-files installs them.
	install -m 0644 "${SDCARD}/usr/share/base-files/dot.bashrc" "${SDCARD}/root/.bashrc"
	install -m 0644 "${SDCARD}/usr/share/base-files/dot.profile" "${SDCARD}/root/.profile"

	# Files Armbian created outside any package.
	declare path
	while read -r path; do
		# shellcheck disable=SC2086 # the path may be a glob
		run_host_command_logged rm -rfv "${SDCARD}"${path}
	done < <(roxora_list rootfs-remove.list)

	# Stock Ubuntu ships apt's archive cache directories; Armbian's cleanup
	# removes them.
	roxora_apt_cache_dirs

	# Package files Armbian edited or deleted. dpkg --verify reports them; the
	# packages they belong to are reinstalled with --force-confmiss so that
	# deleted conffiles come back as shipped.
	declare -a changed=() packages=()
	mapfile -t changed < <(roxora_dpkg_changed_files early)
	if [[ ${#changed[@]} -gt 0 ]]; then
		display_alert "Roxora" "restoring ${#changed[@]} changed package files" "info"
		for path in "${changed[@]}"; do
			# Conffiles have to be absent for --force-confmiss to restore them.
			rm -f "${SDCARD}${path}"
		done
		mapfile -t packages < <(chroot_sdcard_with_stdout dpkg-query -S "${changed[@]}" 2> /dev/null | sed 's/: .*//; s/, /\n/g' | sort -u)
		chroot_sdcard_apt_get -o Dpkg::Options::=--force-confmiss -o Dpkg::Options::=--force-confnew \
			install --reinstall "${packages[@]}"
	fi
	mapfile -t changed < <(roxora_dpkg_changed_files early)
	[[ ${#changed[@]} -eq 0 ]] || exit_with_error "Roxora: package files still differ from Ubuntu" "${changed[*]}"

	# Armbian seeds debconf so that unattended-upgrades does not turn on
	# automatic updates. Ubuntu's default is on.
	if [[ -f "${SDCARD}/usr/share/unattended-upgrades/20auto-upgrades" ]]; then
		chroot_sdcard 'echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections'
		chroot_sdcard DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive unattended-upgrades
	fi

	# Armbian disables Ubuntu's motd news timer; reinstalling base-files puts
	# the files back but not the enablement.
	if [[ -f "${SDCARD}/usr/lib/systemd/system/motd-news.timer" ]]; then
		chroot_sdcard systemctl --no-reload enable motd-news.timer
	fi
}

# Installed packages built by Armbian that are not hardware layer.
function roxora_armbian_distro_packages() {
	chroot_sdcard_with_stdout dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Maintainer}\n' |
		awk 'tolower($0) ~ /armbian/ && $1 ~ /^ii/ { print $2 }' | while read -r pkg; do
		[[ "${pkg}" =~ ^(linux-image|linux-dtb|linux-headers|linux-u-boot|armbian-firmware|armbian-bsp-cli)- ]] ||
			[[ "${pkg}" == armbian-firmware ]] || echo "${pkg}"
	done
}

function roxora_apt_cache_dirs() {
	install -d -m 0755 "${SDCARD}/var/cache/apt/archives"
	install -d -m 0700 "${SDCARD}/var/cache/apt/archives/partial"
	chroot "${SDCARD}" chown _apt:root /var/cache/apt/archives/partial
}

# The image's apt list directory as apt ships it (Armbian copies the lists in
# from the host cache).
function roxora_apt_lists_dir() {
	install -d -m 0755 "${SDCARD}/var/lib/apt/lists"
	install -d -m 0700 "${SDCARD}/var/lib/apt/lists/partial"
	chroot "${SDCARD}" chown _apt:root /var/lib/apt/lists/partial
}

# Package files that differ from what the package shipped, minus hardware-layer
# packages and the files Roxora changes on purpose (keep-modified.list).
# With "early", also skip /var/lib/apt/lists: during the build Armbian mounts
# the host's apt list cache there, and the image gets its own copy later.
function roxora_dpkg_changed_files() {
	declare -a keep=()
	mapfile -t keep < <(roxora_list keep-modified.list)
	[[ "${1:-}" == early ]] && keep+=("/var/lib/apt/lists" "/var/lib/apt/lists/*")
	chroot_sdcard_with_stdout dpkg --verify 2> /dev/null |
		awk '{ print $NF }' | sort -u | while read -r path; do
		declare owner
		owner="$(chroot_sdcard_with_stdout dpkg-query -S "${path}" 2> /dev/null | head -1 | sed 's/: .*//')"
		[[ "${owner}" =~ ^(linux-image|linux-dtb|linux-headers|linux-u-boot|armbian-firmware|armbian-bsp-cli) ]] && continue
		declare k skip=no
		for k in "${keep[@]}"; do
			# shellcheck disable=SC2053 # glob match on purpose
			[[ "${path}" == ${k} ]] && skip=yes && break
		done
		[[ "${skip}" == yes ]] || echo "${path}"
	done
}

# Armbian's post_debootstrap_tweaks runs after the step above: it edits
# /usr/bin/tzselect, removes the start-stop-daemon diversion (leaving a binary
# that differs from dpkg's) and the apt archive cache directories are gone by
# then. Fetch the packages those files come from while the repositories are
# still reachable, and put the shipped files back at the very end.
declare -g -a ROXORA_LATE_PACKAGES=("dpkg" "tzdata")
declare -g ROXORA_LATE_DEBS=""

function post_repo_customize_image__roxora_zz_fetch_late_packages() {
	ROXORA_LATE_DEBS="$(mktemp -d)"
	add_cleanup_handler roxora_cleanup_late_debs
	# Through Armbian's apt wrapper: it mounts the package lists the chroot
	# otherwise does not have.
	mkdir -p "${SDCARD}/tmp/roxora-late/partial"
	chroot_sdcard_apt_get --download-only -o Dir::Cache::archives=/tmp/roxora-late \
		install --reinstall "${ROXORA_LATE_PACKAGES[@]}"
	mv "${SDCARD}"/tmp/roxora-late/*.deb "${ROXORA_LATE_DEBS}/"
	rm -rf "${SDCARD}/tmp/roxora-late"
}

function roxora_cleanup_late_debs() {
	[[ -n "${ROXORA_LATE_DEBS}" ]] && rm -rf "${ROXORA_LATE_DEBS}"
	return 0
}

function post_post_debootstrap_tweaks__roxora_restore_late() {
	display_alert "Roxora" "restoring files changed after customization" "info"

	roxora_apt_cache_dirs
	roxora_apt_lists_dir

	declare -a changed=()
	mapfile -t changed < <(roxora_dpkg_changed_files)
	declare path deb owner unpacked
	unpacked="$(mktemp -d)"
	for deb in "${ROXORA_LATE_DEBS}"/*.deb; do
		dpkg-deb -x "${deb}" "${unpacked}"
	done
	for path in "${changed[@]}"; do
		owner="$(chroot "${SDCARD}" dpkg-query -S "${path}" 2> /dev/null | head -1 | sed 's/: .*//')"
		if [[ " ${ROXORA_LATE_PACKAGES[*]} " == *" ${owner%%:*} "* && -f "${unpacked}${path}" ]]; then
			display_alert "Roxora" "restoring ${path} from ${owner}" "info"
			cp -a "${unpacked}${path}" "${SDCARD}${path}"
		fi
	done
	rm -rf "${unpacked}"

	mapfile -t changed < <(roxora_dpkg_changed_files)
	[[ ${#changed[@]} -eq 0 ]] || exit_with_error "Roxora: package files still differ from Ubuntu" "${changed[*]}"
}
