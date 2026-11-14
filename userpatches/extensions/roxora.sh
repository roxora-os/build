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

# Where the hardware-layer packages come from (HW_REPO, HW_REPO_ORIGIN, ...).
# shellcheck source=userpatches/roxora/hardware-repo.conf
source "${ROXORA_DIR}/hardware-repo.conf"

# The apt pin for the hardware repository, from its template.
function roxora_render_pin() {
	sed -e "s/@ORIGIN@/${HW_REPO_ORIGIN}/g" "${ROXORA_DIR}/apt/roxora-hardware.pref.in"
}

# Print a list file without comments and blank lines.
function roxora_list() {
	sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "${ROXORA_DIR}/${1}"
}

# A path list whose entries are removed: every entry must be an absolute path
# below the root, with no "..", no whitespace and no characters beyond those
# of file names and glob patterns. A bad entry stops the build instead of
# reaching rm.
function roxora_path_list() {
	declare line
	while read -r line; do
		if [[ ! "${line}" =~ ^/[A-Za-z0-9._+@:/*?-]+$ || "${line}" =~ (^|/)\.\.(/|$) || "${line}" =~ ^/+\**$ ]]; then
			exit_with_error "Roxora: bad path '${line}' in ${1}"
		fi
		echo "${line}"
	done < <(roxora_list "${1}")
}

# Armbian versions the BSP package by hashing the source of the
# post_family_tweaks_bsp hooks. The BSP filter reads bsp-remove.list at run
# time, so fold the list's hash into the name of an empty hook: a change to the
# list then changes the package version, and a stale cached BSP is not reused.
eval "function post_family_tweaks_bsp__roxora_zz_list_$(sha256sum "${ROXORA_DIR}/bsp-remove.list" | cut -c1-16)() { :; }"

function extension_prepare_config__roxora() {
	display_alert "Roxora" "${BOARD} ${BRANCH} ${RELEASE} ${ROXORA_VERSION:-dev}" "info"

	if [[ ${#roxora_missing_overrides[@]} -gt 0 ]]; then
		exit_with_error "Roxora: armbian/build no longer defines ${roxora_missing_overrides[*]}; review the armbian-config override"
	fi

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
	# images: it regenerates the SSH host keys and grows the root partition.
	# The default user is created when the image is built. unattended-upgrades installs security updates
	# automatically, as on Ubuntu's server images.
	declare pkg
	for pkg in cloud-init cloud-guest-utils unattended-upgrades; do
		EXTRA_PACKAGES_IMAGE+=("${pkg}")
		EXTRA_PACKAGES_IMAGE_REFS+=("extension_prepare_config__roxora:${BASH_SOURCE[0]}:${LINENO}")
	done

	# Armbian leaves /home out when it copies the root file system into the
	# image; the default user's home directory is made at build time.
	declare -g INCLUDE_HOME_DIR=yes

	if [[ "${ROXORA_UEFI:-no}" == yes ]]; then
		[[ "${BOOTCONFIG}" == none && "${IMAGE_PARTITION_TABLE}" == gpt ]] ||
			exit_with_error "Roxora: UEFI board ${BOARD} must have BOOTCONFIG=none and a GPT partition table"
		[[ -n "${ROXORA_UEFI_SERIAL:-}" ]] ||
			exit_with_error "Roxora: UEFI board ${BOARD} does not set ROXORA_UEFI_SERIAL"
		display_alert "Roxora" "UEFI image: GRUB from Ubuntu, no U-Boot, device tree from the firmware" "info"
		# Armbian's GRUB support adds these; Ubuntu's server image has none of
		# them. cloud-init grows the root partition at the first boot.
		remove_packages cloud-initramfs-growroot busybox efivar
	fi
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
	done < <(roxora_path_list bsp-remove.list)
	# Leave no empty directories behind.
	find "${destination}" -mindepth 1 -depth -type d -not -path "${destination}/DEBIAN*" -empty -delete

	# The BSP maintainer scripts mix boot-related steps with distro defaults.
	# Replace them with the boot-related steps only. These functions are
	# rendered into the package after this hook returns.
	declare fn
	for fn in board_side_bsp_cli_preinst board_side_bsp_cli_postinst_base board_side_bsp_cli_postinst_finish board_side_bsp_cli_postrm; do
		declare -F "${fn}" > /dev/null ||
			exit_with_error "Roxora: armbian/build no longer defines ${fn}; review the BSP override"
	done
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
# replace its two hooks and nothing is added or installed. If armbian/build
# renames them, these definitions would replace nothing, so record now whether
# the originals exist; extension_prepare_config__roxora stops the build if not.
roxora_missing_overrides=()
for roxora_fn in custom_apt_repo__add_armbian-github-repo post_armbian_repo_customize_image__install_armbian-config; do
	declare -F "${roxora_fn}" > /dev/null || roxora_missing_overrides+=("${roxora_fn}")
done
unset roxora_fn
function custom_apt_repo__add_armbian-github-repo() {
	display_alert "Roxora" "not adding the armbian-config repository" "info"
}
function post_armbian_repo_customize_image__install_armbian-config() {
	display_alert "Roxora" "not installing armbian-config" "info"
}

# Pin the hardware repository. Its source list stays, because kernel, DTB,
# U-Boot and firmware updates come from it; everything else it publishes is
# never installed or upgraded from there. The pin is in place from the rootfs
# stage on: Armbian's noble-utils component publishes newer versions of Ubuntu
# packages (base-files among them) that the rootfs upgrade would otherwise
# take. The rootfs cache id includes this hook, so a rootfs built this way is
# never mixed up with Armbian's own. hardware-repo.conf says which repository
# that is; with HW_REPO other than "armbian" its source list replaces
# Armbian's in the image.
function custom_apt_repo__roxora_pin_armbian() {
	display_alert "Roxora" "pinning the hardware repository ${HW_REPO_ORIGIN} (${CUSTOM_REPO_WHEN})" "info"
	mkdir -p "${SDCARD}/etc/apt/preferences.d"
	roxora_render_pin > "${SDCARD}/etc/apt/preferences.d/roxora-hardware.pref"

	[[ "${HW_REPO}" == armbian ]] && return 0
	[[ "${CUSTOM_REPO_WHEN}" == image* ]] || return 0
	[[ -n "${HW_REPO_URI}" && -n "${HW_REPO_KEY}" ]] ||
		exit_with_error "Roxora: HW_REPO=${HW_REPO} needs HW_REPO_URI and HW_REPO_KEY in hardware-repo.conf"
	install -D -m 0644 "${ROXORA_DIR}/apt/${HW_REPO_KEY}" "${SDCARD}/usr/share/keyrings/${HW_REPO_KEY}"
	cat > "${SDCARD}/etc/apt/sources.list.d/roxora-hardware.sources" <<- SOURCES
		Types: deb
		URIs: ${HW_REPO_URI}
		Suites: ${HW_REPO_SUITES:-${RELEASE}}
		Components: ${HW_REPO_COMPONENTS}
		Signed-By: /usr/share/keyrings/${HW_REPO_KEY}
	SOURCES
	rm -f "${SDCARD}"/etc/apt/sources.list.d/armbian.sources*
}

# Seed cloud-init for the first boot and create the default account.
function post_customize_image__roxora_cloud_init() {
	display_alert "Roxora" "seeding cloud-init" "info"
	install -D -m 0644 "${ROXORA_DIR}/cloud-init/99-roxora.cfg" "${SDCARD}/etc/cloud/cloud.cfg.d/99-roxora.cfg"
	install -d -m 0755 "${SDCARD}/var/lib/cloud/seed/nocloud"
	install -m 0644 "${ROXORA_DIR}/cloud-init/user-data" "${SDCARD}/var/lib/cloud/seed/nocloud/user-data"
	install -m 0644 "${ROXORA_DIR}/cloud-init/network-config" "${SDCARD}/var/lib/cloud/seed/nocloud/network-config"
	sed -e "s/@HOSTNAME@/${HOST}/g" "${ROXORA_DIR}/cloud-init/meta-data" > "${SDCARD}/var/lib/cloud/seed/nocloud/meta-data"

	# Default account: user "roxora", password "roxora", which must be changed
	# at the first login (console and SSH). Groups are those Ubuntu gives its
	# default user, plus video and render for the GPU and the NPU
	# (/dev/accel/accel0 belongs to render), where they exist. cloud-init is
	# told not to add another user (users: [] in user-data).
	declare -a groups=()
	declare group
	for group in adm cdrom dip plugdev sudo video render; do
		chroot_sdcard_with_stdout getent group "${group}" > /dev/null && groups+=("${group}")
	done
	chroot_sdcard useradd --create-home --shell /bin/bash --groups "$(
		IFS=,
		echo "${groups[*]}"
	)" roxora
	chroot_sdcard "echo roxora:roxora | chpasswd"
	chroot_sdcard chage --lastday 0 roxora

	# Like Ubuntu: root has no password; the default user uses sudo.
	chroot_sdcard usermod -p "'*'" root

	# The system font directories, empty until a font package is installed.
	# snapd gives a snap the host's fonts only through directories that exist
	# when it sets the snap up; installing a desktop on this image put the
	# Firefox snap in before the first font package, and Firefox then had no
	# system fonts (no CJK text) until firefox:desktop was reconnected.
	install -d -m 0755 "${SDCARD}/usr/share/fonts" "${SDCARD}/usr/local/share/fonts"
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
	roxora_remove_listed "${SDCARD}" rootfs-remove.list

	# Stock Ubuntu ships apt's archive cache directories; Armbian's cleanup
	# removes them.
	roxora_apt_cache_dirs

	# Package files Armbian edited or deleted. dpkg --verify reports them; the
	# packages they belong to are reinstalled with --force-confmiss so that
	# deleted conffiles come back as shipped.
	declare -a changed=() packages=()
	declare path
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

	# Files Armbian edits that dpkg --verify does not cover: configuration
	# generated from a template at install time, and file modes.
	# sshd_config: "PermitRootLogin yes" and "PubkeyAuthentication yes";
	# the template is what ucf recorded when openssh-server was installed.
	install -m 0644 "${SDCARD}/usr/share/openssh/sshd_config" "${SDCARD}/etc/ssh/sshd_config"
	# nsswitch.conf: Armbian rewrites the hosts line.
	install -m 0644 "${SDCARD}/usr/share/libc-bin/nsswitch.conf" "${SDCARD}/etc/nsswitch.conf"
	# Armbian removes the execute bit from every motd script to hide the
	# message until its first-login wizard has run; that wizard is not in
	# Roxora, and Ubuntu ships the scripts executable.
	chmod +x "${SDCARD}"/etc/update-motd.d/*

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

	# Ubuntu defaults Armbian's package lists replace. From 26.04 Ubuntu keeps
	# time with chrony; Armbian installs systemd-timesyncd, which chrony
	# replaces. (Armbian also installs initramfs-tools where Ubuntu 26.04 uses
	# dracut; that one stays: the boot path's uInitrd is made by an
	# initramfs-tools hook.)
	declare -a ubuntu_defaults=()
	mapfile -t ubuntu_defaults < <(roxora_list ubuntu-defaults.list | awk -v r="${RELEASE}" '$1 == r { $1 = ""; print substr($0, 2) }' | tr ' ' '\n' | sed '/^$/d')
	if [[ ${#ubuntu_defaults[@]} -gt 0 ]]; then
		display_alert "Roxora" "installing Ubuntu ${RELEASE} defaults: ${ubuntu_defaults[*]}" "info"
		chroot_sdcard_apt_get install "${ubuntu_defaults[@]}"
	fi

	# File capabilities (ping's cap_net_raw) do not survive Armbian's rootfs
	# cache, and dpkg --verify does not see them. Run again the part of each
	# package's postinst that sets them, the way dpkg runs it.
	declare postinst pkg version arch
	for postinst in "${SDCARD}"/var/lib/dpkg/info/*.postinst; do
		grep -q setcap "${postinst}" || continue
		pkg="$(basename "${postinst}" .postinst)"
		version="$(chroot_sdcard_with_stdout dpkg-query -W -f '${Version}' "${pkg}")"
		arch="$(chroot_sdcard_with_stdout dpkg-query -W -f '${Architecture}' "${pkg}")"
		display_alert "Roxora" "setting file capabilities again: ${pkg}" "info"
		# The environment dpkg gives maintainer scripts; dpkg-maintscript-helper
		# (called by some postinsts, iproute2's on 26.04) needs it.
		chroot_sdcard DEBIAN_FRONTEND=noninteractive DPKG_MAINTSCRIPT_PACKAGE="${pkg%%:*}" \
			DPKG_MAINTSCRIPT_PACKAGE_REFCOUNT=1 DPKG_MAINTSCRIPT_ARCH="${arch}" DPKG_MAINTSCRIPT_NAME=postinst \
			DPKG_ADMINDIR=/var/lib/dpkg DPKG_ROOT= "/var/lib/dpkg/info/${pkg}.postinst" configure "${version}"
	done
}

# Remove the paths of a list file (roxora_path_list) below a root directory.
function roxora_remove_listed() {
	declare root="${1}" pattern path
	while read -r pattern; do
		# shellcheck disable=SC2086 # the pattern is a glob on purpose
		for path in "${root}"${pattern}; do
			[[ -e "${path}" || -L "${path}" ]] || continue
			display_alert "Roxora" "removing ${path#"${root}"}" "info"
			rm -rf -- "${path}"
		done
	done < <(roxora_path_list "${2}")
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
	# Early, Armbian's build-time stand-ins are still in place: the fake
	# start-stop-daemon and initctl it puts in /sbin while the image is built
	# (on Ubuntu 26.04 they overwrite dpkg's own /usr/sbin/start-stop-daemon
	# through the /sbin symlink, which dpkg needs to run). Armbian removes them
	# at the end; the late check restores and checks them.
	[[ "${1:-}" == early ]] && keep+=("/var/lib/apt/lists" "/var/lib/apt/lists/*"
		"/sbin/start-stop-daemon" "/usr/sbin/start-stop-daemon" "/sbin/initctl" "/usr/sbin/initctl")
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
declare -g -a ROXORA_LATE_PACKAGES=("dpkg" "libc-bin")
declare -g ROXORA_LATE_DEBS=""

# Preinstall the hwtool command line package (userpatches/roxora/hwtool.conf).
# Runs after the Ubuntu files are restored, so dpkg --verify sees it as
# installed, and before the late packages are fetched.
function post_repo_customize_image__roxora_tools_hwtool() {
	declare HWTOOL_VERSION HWTOOL_DEB_URL HWTOOL_DEB_SHA256
	# shellcheck source=userpatches/roxora/hwtool.conf
	source "${ROXORA_DIR}/hwtool.conf"
	declare deb="${SDCARD}/tmp/roxora-hwtool.deb"
	display_alert "Roxora" "installing hwtool ${HWTOOL_VERSION}" "info"
	run_host_command_logged curl --fail --silent --show-error --location --retry 3 -o "${deb}" "${HWTOOL_DEB_URL}"
	echo "${HWTOOL_DEB_SHA256}  ${deb}" | sha256sum --check --status ||
		exit_with_error "Roxora: ${HWTOOL_DEB_URL} does not match HWTOOL_DEB_SHA256 in hwtool.conf"
	chroot_sdcard_apt_get install /tmp/roxora-hwtool.deb
	rm -f "${deb}"
	[[ "$(chroot_sdcard_with_stdout dpkg-query -W -f '${Version}' roxora-hwtool)" == "${HWTOOL_VERSION}" ]] ||
		exit_with_error "Roxora: roxora-hwtool ${HWTOOL_VERSION} is not installed"
}

# Preinstall roxora-wallpapers, built here from roxora-os/design at a fixed
# commit (userpatches/roxora/wallpapers/). Nothing shows on a server image;
# with a GNOME desktop the wallpapers are in Settings and Facet is the default.
function post_repo_customize_image__roxora_tools_wallpapers() {
	declare WALLPAPERS_VERSION WALLPAPERS_DESIGN_COMMIT
	declare -a WALLPAPERS_FILES=()
	# shellcheck source=userpatches/roxora/wallpapers/wallpapers.conf
	source "${ROXORA_DIR}/wallpapers/wallpapers.conf"
	declare version="${WALLPAPERS_VERSION}+git${WALLPAPERS_DESIGN_COMMIT:0:7}"
	display_alert "Roxora" "building roxora-wallpapers ${version}" "info"
	declare work pkg entry file sum
	work="$(mktemp -d)"
	pkg="${work}/pkg"
	mkdir -p "${pkg}/DEBIAN" "${pkg}/usr/share/backgrounds/roxora" "${pkg}/usr/share/doc/roxora-wallpapers" \
		"${pkg}/usr/share/gnome-background-properties" "${pkg}/usr/share/glib-2.0/schemas"
	for entry in "${WALLPAPERS_FILES[@]}"; do
		read -r file sum <<< "${entry}"
		run_host_command_logged curl --fail --silent --show-error --location --retry 3 -o "${work}/${file}" \
			"https://raw.githubusercontent.com/roxora-os/design/${WALLPAPERS_DESIGN_COMMIT}/wallpapers/${file}"
		echo "${sum}  ${work}/${file}" | sha256sum --check --status ||
			exit_with_error "Roxora: design ${WALLPAPERS_DESIGN_COMMIT} wallpapers/${file} does not match wallpapers.conf"
		[[ "${file}" == *.png ]] && install -m 0644 "${work}/${file}" "${pkg}/usr/share/backgrounds/roxora/${file}"
	done
	install -m 0644 "${ROXORA_DIR}/wallpapers/roxora-wallpapers.xml" "${pkg}/usr/share/gnome-background-properties/roxora-wallpapers.xml"
	install -m 0644 "${ROXORA_DIR}/wallpapers/90_roxora-wallpapers.gschema.override" \
		"${pkg}/usr/share/glib-2.0/schemas/90_roxora-wallpapers.gschema.override"
	{
		printf '%s\n' "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/" \
			"Upstream-Name: Roxora wallpapers" \
			"Source: https://github.com/roxora-os/design/tree/${WALLPAPERS_DESIGN_COMMIT}/wallpapers" "" \
			"Files: *" "Copyright: 2026 DavidQyn" "           2026 Ga Hing Woo" "License: CC-BY-SA-4.0" "" \
			"License: CC-BY-SA-4.0"
		sed -e 's/^$/./' -e 's/^/ /' "${work}/LICENSE"
	} > "${pkg}/usr/share/doc/roxora-wallpapers/copyright"
	cat > "${pkg}/DEBIAN/control" <<- CONTROL
		Package: roxora-wallpapers
		Version: ${version}
		Architecture: all
		Maintainer: Roxora Project <oss@gahingwoo.com>
		Section: graphics
		Priority: optional
		Homepage: https://github.com/roxora-os/design
		Description: Roxora desktop wallpapers
		 Four wallpapers in light and dark versions for the GNOME background list,
		 with Roxora Facet as the default wallpaper. By DavidQyn and Ga Hing Woo,
		 CC BY-SA 4.0.
	CONTROL
	chmod -R u=rwX,go=rX "${pkg}"
	dpkg-deb --root-owner-group --build "${pkg}" "${SDCARD}/tmp/roxora-wallpapers.deb" > /dev/null
	rm -rf "${work}"
	chroot_sdcard_apt_get install /tmp/roxora-wallpapers.deb
	rm -f "${SDCARD}/tmp/roxora-wallpapers.deb"
	[[ "$(chroot_sdcard_with_stdout dpkg-query -W -f '${Version}' roxora-wallpapers)" == "${version}" ]] ||
		exit_with_error "Roxora: roxora-wallpapers ${version} is not installed"
}

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

	# No SSH host keys in the image: every board would share them, and anyone
	# could read the private keys from the download. cloud-init creates them
	# at the first boot, as on Ubuntu's cloud images.
	rm -f "${SDCARD}"/etc/ssh/ssh_host_*
}

# --- UEFI images (ROXORA_UEFI=yes, userpatches/roxora/uefi/board.inc) --------
#
# The firmware passes the device tree, so the linux-dtb package is not
# installed: it puts a directory at /boot/dtb-<version>, and Ubuntu's
# /etc/grub.d/10_linux would then write a "devicetree" line for it into
# grub.cfg at the next kernel update. The kernel package carries the same
# device trees in /usr/lib/linux-image-<version>/. The list of packages to
# build or download is already made when these hooks run.
function pre_install_kernel_debs__roxora_uefi_no_dtb_package() {
	[[ "${ROXORA_UEFI:-no}" == yes ]] || return 0
	display_alert "Roxora" "UEFI image: not installing linux-dtb" "info"
	declare -g ROXORA_SAVED_KERNEL_BUILD_DTBS="${KERNEL_BUILD_DTBS:-yes}"
	declare -g KERNEL_BUILD_DTBS=no
}

function post_install_kernel_debs__roxora_uefi_no_dtb_package() {
	[[ "${ROXORA_UEFI:-no}" == yes ]] || return 0
	declare -g KERNEL_BUILD_DTBS="${ROXORA_SAVED_KERNEL_BUILD_DTBS}"
}

# GRUB updates come from the Ubuntu archive. On upgrade, grub-efi-arm64 runs
# grub-install again: it also refreshes EFI/BOOT/BOOTAA64.EFI (Ubuntu's
# default), and with update_nvram false it writes no firmware boot entry.
# Boot entries written from Linux do not reach edk2-rk3576, and its runtime
# services fault when Linux tries.
function post_customize_image__roxora_uefi_grub_debconf() {
	[[ "${ROXORA_UEFI:-no}" == yes ]] || return 0
	display_alert "Roxora" "UEFI image: GRUB updates without NVRAM writes" "info"
	chroot_sdcard "printf '%s\n' 'grub-efi-arm64 grub2/update_nvram boolean false' 'grub-efi-arm64 grub2/no_efi_extra_removable boolean false' | debconf-set-selections"
}

# Armbian's GRUB support (extensions/grub.sh) has just written its settings
# to /etc/default/grub.d/98-armbian.cfg (Armbian's name in the menu and the
# EFI directory, its wallpaper and fonts, console arguments without a baud
# rate). Replace them with Roxora's; the rest is /etc/default/grub as Ubuntu
# ships it. update-grub runs after this, and again on every kernel update.
function grub_early_config__roxora_settings() {
	: "${MOUNT:?MOUNT is not set}"
	# Rockchip's BSP kernel puts the debug UART behind its FIQ debugger
	# (CONFIG_FIQ_DEBUGGER=y in linux-rk35xx-vendor.config) as ttyFIQ0; with
	# a mainline device tree it is ttyS0. The kernel uses the consoles that
	# exist.
	declare consoles="console=${ROXORA_UEFI_SERIAL}"
	[[ "${BRANCH}" == vendor* ]] && consoles="console=ttyFIQ0 ${consoles}"
	display_alert "Roxora" "GRUB settings: ${consoles}" "info"
	rm -f "${MOUNT}/etc/default/grub.d/98-armbian.cfg"
	sed -e "s/@CONSOLES@/${consoles}/g" "${ROXORA_DIR}/uefi/grub.cfg.in" > "${MOUNT}/etc/default/grub.d/90-roxora.cfg"
}

# grub.sh copies its wallpaper and font after the hook above; nothing reads
# them now. rootfs-remove.list lists them, so verify-image.sh checks they are
# gone.
function grub_pre_install__roxora_no_artwork() {
	: "${MOUNT:?MOUNT is not set}"
	roxora_remove_listed "${MOUNT}" rootfs-remove.list
	# Armbian's partitioning writes a U-Boot environment with the root file
	# system type whenever the root is not the first partition, boot script
	# or not (lib/functions/image/partitioning.sh). Nothing reads it here.
	rm -f "${MOUNT}/boot/armbianEnv.txt"

	# The device tree hook (below) is installed after the kernel; run it once
	# for the kernel in the image, with the EFI system partition mounted.
	display_alert "Roxora" "UEFI image: copying the kernel's ${BOOT_SOC} device trees to the EFI system partition" "info"
	chroot_custom "${MOUNT}" 'for d in /usr/lib/linux-image-*/; do v="${d%/}"; /etc/kernel/postinst.d/zz-roxora-efi-dtb "${v##*/linux-image-}"; done'
	compgen -G "${MOUNT}/boot/efi/dtb/rockchip/${BOOT_SOC}-*.dtb" > /dev/null ||
		exit_with_error "Roxora: no ${BOOT_SOC} device trees on the EFI system partition"
}

# Keep Armbian's device trees for the SoC on the EFI system partition, for the
# firmware's device tree override (userpatches/roxora/uefi/efi-dtb.in). Every
# kernel installation and update runs /etc/kernel/postinst.d.
function post_customize_image__roxora_uefi_efi_dtb_hook() {
	[[ "${ROXORA_UEFI:-no}" == yes ]] || return 0
	[[ -n "${BOOT_SOC:-}" ]] || exit_with_error "Roxora: UEFI board ${BOARD} does not set BOOT_SOC"
	display_alert "Roxora" "UEFI image: kernel hook for ${BOOT_SOC} device trees on the EFI system partition" "info"
	mkdir -p "${SDCARD}/etc/kernel/postinst.d"
	sed -e "s/@SOC@/${BOOT_SOC}/g" "${ROXORA_DIR}/uefi/efi-dtb.in" > "${SDCARD}/etc/kernel/postinst.d/zz-roxora-efi-dtb"
	chmod 0755 "${SDCARD}/etc/kernel/postinst.d/zz-roxora-efi-dtb"
}

# Armbian writes /etc/fstab while it partitions the image, after every other
# hook, and puts /tmp on a tmpfs. Ubuntu keeps /tmp on the root filesystem.
function pre_umount_final_image__roxora_tmp_on_disk() {
	: "${MOUNT:?MOUNT is not set}"
	display_alert "Roxora" "keeping /tmp on the root filesystem" "info"
	sed -i '\|^tmpfs[[:space:]]\+/tmp[[:space:]]|d' "${MOUNT}/etc/fstab"
}
