# Architecture

Roxora images are built by Armbian's build framework with one extension added.
The result is a board that boots Armbian's kernel, device tree, U-Boot and
firmware, and runs a stock Ubuntu userspace that updates from the Ubuntu
archive.

## The build

- [`armbian.ref`](../armbian.ref) pins one commit of
  [armbian/build](https://github.com/armbian/build). Every image is built from
  that commit; moving to a newer Armbian is a one-line change that goes
  through CI like any other.
- [`build.sh`](../build.sh) fetches armbian/build at that commit into
  `cache/armbian-build`, refuses to run if the checkout is at another commit
  or has local changes, copies [`userpatches/`](../userpatches) into it and
  runs Armbian's `compile.sh` with the `roxora` extension enabled. It accepts
  only combinations listed in [`boards.conf`](../boards.conf) and always
  builds a minimal server image.
- [`userpatches/extensions/roxora.sh`](../userpatches/extensions/roxora.sh) is
  the extension. It uses Armbian's documented extension hooks; Roxora does not
  carry a fork or patches of armbian/build.
- [`verify/verify-image.sh`](../verify/verify-image.sh) checks every finished
  image without booting it (see [Verification](#verification)).

## Two layers

Armbian's images contain two different things, and Roxora keeps only one of
them.

The hardware layer is kept from Armbian. It is what the board needs to boot
and to drive its hardware:

- the kernel (`linux-image-*`) and its headers (`linux-headers-*`, installed
  only where a board needs DKMS),
- device trees (`linux-dtb-*`),
- U-Boot (`linux-u-boot-*`),
- firmware (`armbian-firmware*`),
- the hardware-related files of the board support package (BSP): the boot
  script and its environment, the hook that wraps each initramfs for U-Boot,
  udev rules and module options for Wi-Fi, Ethernet adapters, video decoders,
  audio device names and LEDs, and the device tree overlay tool.

The distro layer is removed, or replaced with what Ubuntu ships. It is
everything that changes how the system looks or behaves compared with stock
Ubuntu: the
first-login wizard and `armbian-firstrun`, `armbian-config`, Armbian's login
message, logs in RAM and zram swap, Armbian's apt settings, its replacement
`base-files`, branding, and edits Armbian's build makes to files of Ubuntu
packages.

The full list, file by file, with the reason for each decision, is in
[bsp-classification.md](bsp-classification.md). The build reads the same
lists as the check:
[`bsp-remove.list`](../userpatches/roxora/bsp-remove.list),
[`rootfs-remove.list`](../userpatches/roxora/rootfs-remove.list) and
[`keep-modified.list`](../userpatches/roxora/keep-modified.list).

What the extension does, in order:

1. Checks the board, branch and release against `boards.conf` and refuses
   desktop images.
2. Sets Armbian options so that some distro-layer parts are never installed:
   Ubuntu's own `base-files` and `/etc/os-release`, no console autologin,
   time zone `Etc/UTC`, no tuning profile, no boot splash, no kernel headers
   unless a board needs them.
3. Builds the BSP package with the distro-layer files left out, and with
   maintainer scripts that keep only the boot-related steps. The package keeps
   Armbian's name.
4. Keeps Armbian from adding the `armbian-config` repository and package.
5. Installs the apt pin described below, from the first stage of the root
   filesystem on.
6. Purges `fake-ubuntu-advantage-tools`, replaces any other Armbian-built
   package outside the hardware layer with Ubuntu's version, removes files
   Armbian created outside packages, and reinstalls every Ubuntu package whose
   files Armbian edited, until `dpkg --verify` reports nothing but the files
   in `keep-modified.list`.
7. Installs cloud-init and unattended-upgrades, seeds the first boot and
   creates the default account `roxora` with the password `roxora`, which
   must be changed at the first login (see
   [faq.md](faq.md#how-do-i-log-in-the-first-time)). Automatic security
   updates are on, as on Ubuntu's server images.
8. On UEFI images only: leaves out `linux-dtb`, replaces the GRUB settings
   of Armbian's GRUB support with Roxora's, removes its wallpaper and fonts,
   leaves out the packages it adds that Ubuntu's server image does not have
   (`efivar`, `busybox`, `cloud-initramfs-growroot`), and turns off firmware boot entry updates (see [UEFI images](#uefi-images)).

A few Armbian defaults stay because they belong to the boot path or protect
the hardware, and are listed as hardware layer in
[bsp-classification.md](bsp-classification.md): gzip initramfs compression
(the boot script loads a gzip `uInitrd`), `RESUME=none`, sleep states turned
off (suspend and resume are not validated on these boards), the serial console
on `ttyS0` at 1500000 baud, and the hostname set to the board name.

## Where packages come from

The image keeps both apt sources Armbian writes:

- `/etc/apt/sources.list.d/ubuntu.sources`: `ports.ubuntu.com`, with
  `noble`, `noble-updates`, `noble-security` and `noble-backports`.
- `/etc/apt/sources.list.d/armbian.sources`: `apt.armbian.com`. It stays,
  because kernel, device tree, U-Boot and firmware updates come from it.

The Armbian repository is pinned with
[`roxora-hardware.pref.in`](../userpatches/roxora/apt/roxora-hardware.pref.in),
installed as `/etc/apt/preferences.d/roxora-hardware.pref`:

    Package: linux-image-* linux-dtb-* linux-headers-* linux-u-boot-* armbian-firmware*
    Pin: release o=Armbian
    Pin-Priority: 500

    Package: charsiu
    Pin: release o=Armbian
    Pin-Priority: 500

    Package: *
    Pin: release o=Armbian
    Pin-Priority: -1

For each package apt uses the first record that matches it. The hardware
packages get priority 500, the normal priority, so apt installs and upgrades
them from Armbian. So does charsiu, an LLM runtime for the RK3576 NPU on the
mainline `rocket` driver that only Armbian's repository publishes; it is not
in the image, but `sudo apt install charsiu` finds it. Every other package in
the Armbian repository gets -1, so apt never installs or upgrades it from
there.

Which repository the hardware packages come from is set in one file,
[`hardware-repo.conf`](../userpatches/roxora/hardware-repo.conf): today
`apt.armbian.com`, with origin `Armbian`. The pin is rendered from that file,
and `verify-image.sh` checks the image against it. Moving the hardware
packages to another repository (for example one run by Roxora) is a change to
that file only: the extension then writes that repository's source list and
key in place of Armbian's.

Why the pin is needed: besides its own packages, the Armbian repository
publishes packages under the names of Ubuntu packages, with higher version
numbers. Its `noble-utils` component carries, for example, `base-files` (with
Armbian's `/etc/os-release`), `zfsutils-linux` and `gh`. Without the pin, the
next `apt upgrade` would replace those Ubuntu packages with Armbian's. With
it, they come from the Ubuntu archive.

The BSP package itself (`armbian-bsp-cli-*`) is not in the hardware patterns.
Roxora builds its own version of it, and an update from Armbian's repository
would bring back the removed files, so it is never upgraded from there.

## Boot

There are two kinds of image: board images, which carry U-Boot and boot the
way Armbian boots the board, and UEFI images, which carry no bootloader and
are started by UEFI firmware already on the board.

### Board images: Armbian's boot method, as is

Roxora does not change how the boards boot. For both supported boards
Armbian's method is a U-Boot boot script:

1. U-Boot loads `/boot/boot.scr`, compiled from `/boot/boot.cmd`.
2. The script reads `/boot/armbianEnv.txt` (device tree file name, overlays,
   kernel arguments).
3. It loads `/boot/Image`, `/boot/uInitrd` and `/boot/dtb/<fdtfile>`, applies
   overlays from `/boot/dtb/rockchip/overlay/` and `/boot/overlay-user/`, and
   starts the kernel.

`/boot/Image`, `/boot/uInitrd` and `/boot/dtb` are links to the files of the
installed kernel. The kernel and device tree packages update the links, and
the BSP's initramfs hook wraps each new initramfs as `uInitrd` with
`mkimage`. There is no boot menu: the board boots the one installed kernel.

Where U-Boot itself lives depends on the board. The image carries U-Boot at
32 KiB, and the CM5-IO starts it from the eMMC or SD card it boots from. The
ROCK 4D never boots from the SD card in the
first stage: it needs a mainline U-Boot in its SPI NOR flash, which then boots
the SD card. [hardware-test.md](hardware-test.md) has the details for both
boards.

### UEFI images

`generic-rk3576-uefi` is one image for every RK3576 board that runs UEFI firmware,
for example [edk2-rk3576](https://github.com/gahingwoo/edk2-rk3576) on the
ROCK 4D (in SPI NOR flash) or the CM5-IO (on eMMC or an SD card). It boots
like other arm64 Ubuntu systems:

1. The firmware starts `\EFI\BOOT\BOOTAA64.EFI` from the image's EFI system
   partition. That is GRUB, from Ubuntu's `grub-efi-arm64` package.
2. GRUB reads `/boot/grub/grub.cfg`, which `update-grub` writes from
   `/etc/default/grub` and `/etc/default/grub.d/`, shows its menu for three
   seconds and loads `/boot/vmlinuz-<version>` and
   `/boot/initrd.img-<version>`.
3. The kernel takes the device tree from the firmware (EFI configuration
   table). GRUB loads none, so the same image works on every board the
   firmware supports, and the device tree is the one the firmware was built
   and tested with.

The kernel is the same as on the board images: Armbian's
`linux-image-edge-rockchip64`, with the `rocket` NPU driver. Its device tree
files are in `/usr/lib/linux-image-<version>/rockchip/`; the `linux-dtb`
package is not installed, because Ubuntu's `10_linux` (as of GRUB 2.12)
writes a `devicetree` line for any `/boot/dtb-<version>` or `/boot/dtb` it
finds, and has no setting to turn that off.

The image also carries Armbian's device trees for the SoC on the EFI system
partition, as `\dtb\rockchip\<name>.dtb` (for example
`rk3576-rock-4d.dtb`). That is where edk2-rk3576's device tree override
looks: with "Support DTB override & overlays" on, the firmware loads the
file named after its board from the drive it boots from, applies its
fix-ups and passes that instead of its own (see
[install.md](install.md#using-armbians-device-tree-instead-of-the-firmwares)).
The kernel hook
[`zz-roxora-efi-dtb`](../userpatches/roxora/uefi/efi-dtb.in) in
`/etc/kernel/postinst.d` copies the device trees of every kernel that is
installed or updated, and removes those the kernel no longer has, so they
always match the kernel. No overlays are copied: the firmware applies every
overlay in its overlay directory.

Disk layout: GPT, an EFI system partition of 256 MiB (FAT, mounted at
`/boot/efi`) at 16 MiB, then the root file system. Nothing is written
before the first partition apart from the partition table.

Kernel updates from Armbian's repository run Ubuntu's `zz-update-grub`
hook, which writes a new `grub.cfg`. Armbian's kernel package has one name
per branch (`linux-image-edge-rockchip64`), so an update replaces the
kernel instead of adding one; the menu lists the kernels of the installed
branches, and going back to an older kernel is a package downgrade, as on
the board images. GRUB updates come from the Ubuntu archive; their `grub-install`
also refreshes `\EFI\BOOT\BOOTAA64.EFI`. The image sets
`grub2/update_nvram` to false: GRUB updates write no boot entry into the
firmware, which edk2-rk3576 does not keep from Linux, and its runtime
services fault when Linux tries. The firmware boots the removable-media path
instead.

Roxora's GRUB settings are in
[`grub.cfg.in`](../userpatches/roxora/uefi/grub.cfg.in), installed as
`/etc/default/grub.d/90-roxora.cfg`: kernel messages on the SoC's serial
port (`ttyS0` at 1500000 baud on RK3576) and the display, and the menu on
the firmware's console. Everything else is Ubuntu's `/etc/default/grub`.
There is no shim: secure boot is not set up on these boards, and shim's
fallback loader writes boot entries the firmware does not keep.

The image is built by Armbian's own GRUB support (the `grub` extension) on a
Roxora board file,
[`generic-rk3576-uefi.conf`](../userpatches/config/boards/generic-rk3576-uefi.conf), which
picks Armbian's `rk35xx` family for the kernel and sets no U-Boot
(`BOOTCONFIG=none`). What all UEFI images share is in
[`board.inc`](../userpatches/roxora/uefi/board.inc), so a UEFI image for
another SoC is a board file that names its family, SoC and serial console
(see [adding-a-board.md](adding-a-board.md#a-uefi-image-for-another-soc)).
The hostname is the image name, `generic-rk3576-uefi`.

## Verification

`verify/verify-image.sh` mounts an image read-only (changes go to a
throwaway overlay) and checks:

- every installed package is in Ubuntu's own server image, belongs to the
  hardware layer, or is on the
  [allowlist](../verify/reference/allowlist), against the reference
  manifests in [`verify/reference/`](../verify/reference);
- the pin file is installed unchanged, the Armbian source list is present,
  only hardware packages have an Armbian candidate, `base-files` comes from
  the Ubuntu archive, and a simulated `full-upgrade` takes nothing else from
  Armbian;
- none of the removed paths exist, `dpkg --verify` finds no changed Ubuntu
  files beyond `keep-modified.list`, and `/etc/os-release` is Ubuntu's;
- board images: the boot script, environment, kernel, `uInitrd`, device
  tree and the bootloader at 32 KiB are in place and match the installed
  packages;
- UEFI images (those with an EFI system partition): GPT, the EFI system
  partition is FAT and mounted at `/boot/efi`, `\EFI\BOOT\BOOTAA64.EFI` is the
  GRUB image `grub-install` made, `grub.cfg` is `update-grub`'s and starts
  the installed kernel and initrd with Roxora's arguments and no device tree,
  the SoC's device trees on the EFI system partition are the installed
  kernel's and the kernel hook that keeps them so is in place,
  there is no U-Boot (package, boot script, or data between 32 KiB and the
  first partition), GRUB comes from the Ubuntu archive and
  `grub2/update_nvram` is false;
- cloud-init is seeded, the `roxora` account exists with an expired
  password, root is locked, there is no autologin, and automatic updates
  are on.

CI runs it on every image, and its output is published with each release
(see [release-contract.md](release-contract.md)). It cannot tell whether a
board boots; that is what [hardware-test.md](hardware-test.md) is for. For
UEFI images CI also boots the image in QEMU (arm64 `virt` machine, Ubuntu's
edk2 build, device tree from the firmware) and checks that the firmware
starts GRUB and GRUB starts the kernel
([`qemu-boot.sh`](../verify/qemu-boot.sh)). QEMU is not a board, so this
says nothing about the board's hardware.

## What Roxora does not do

- No kernel or U-Boot patches of its own. Hardware support is whatever
  Armbian ships at the pinned commit; hardware fixes are made in Armbian.
- No changes to Armbian's boot method on board images. UEFI images use
  Armbian's own GRUB support; Roxora only replaces its settings.
- No UEFI firmware in any image. The firmware is installed on the board on
  its own, from its own project.
- No `armbian-config`, and no Roxora replacement for it. Configuration is
  done the Ubuntu way.
- No desktop images yet. Only minimal server images are built.
- No Debian images. Roxora is Ubuntu only, starting with 24.04 (noble).
- No packages of its own in the image, and no apt repository of its own.
  Userspace updates come from the Ubuntu archive, hardware updates from
  Armbian.
