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

**Hardware layer: kept, from Armbian.** What the board needs to boot and to
drive its hardware:

- the kernel (`linux-image-*`) and its headers (`linux-headers-*`, installed
  only where a board needs DKMS),
- device trees (`linux-dtb-*`),
- U-Boot (`linux-u-boot-*`),
- firmware (`armbian-firmware*`),
- the hardware-related files of the board support package (BSP): the boot
  script and its environment, the hook that wraps each initramfs for U-Boot,
  udev rules and module options for Wi-Fi, Ethernet adapters, video decoders,
  audio device names and LEDs, and the device tree overlay tool.

**Distro layer: removed, or replaced with what Ubuntu ships.** Everything that
changes how the system looks or behaves compared with stock Ubuntu: the
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
7. Installs cloud-init and unattended-upgrades and seeds the first boot (see
   [faq.md](faq.md#how-do-i-log-in-the-first-time)). Automatic security
   updates are on, as on Ubuntu's server images.

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
[`roxora-armbian.pref`](../userpatches/roxora/apt/roxora-armbian.pref),
installed as `/etc/apt/preferences.d/roxora-armbian.pref`:

    Package: linux-image-* linux-dtb-* linux-headers-* linux-u-boot-* armbian-firmware*
    Pin: release o=Armbian
    Pin-Priority: 500

    Package: *
    Pin: release o=Armbian
    Pin-Priority: -1

For each package apt uses the first record that matches it. The hardware
packages get priority 500, the normal priority, so apt installs and upgrades
them from Armbian. Every other package in the Armbian repository gets -1, so
apt never installs or upgrades it from there.

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

### Phase 1: Armbian's boot method, as is

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

### Phase 2: UEFI (planned, not done)

The plan is U-Boot's UEFI support with `grub-efi-arm64` from the Ubuntu
archive, so the boards boot like other arm64 Ubuntu systems, with a boot menu
and kernel selection. Nothing of this is implemented. Until it is, an EFI
firmware in SPI flash does not boot a Roxora image.

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
- the boot script, environment, kernel, `uInitrd`, device tree and the
  bootloader at 32 KiB are in place and match the installed packages;
- cloud-init is seeded, root is locked, there is no autologin, and automatic
  updates are on.

CI runs it on every image, and its output is published with each release
(see [release-contract.md](release-contract.md)). It cannot tell whether a
board boots; that is what [hardware-test.md](hardware-test.md) is for.

## What Roxora does not do

- No kernel or U-Boot patches of its own. Hardware support is whatever
  Armbian ships at the pinned commit; hardware fixes are made in Armbian.
- No changes to Armbian's boot method (phase 1 above).
- No `armbian-config`, and no Roxora replacement for it. Configuration is
  done the Ubuntu way.
- No desktop images yet. Only minimal server images are built.
- No Debian images. Roxora is Ubuntu only, starting with 24.04 (noble).
- No packages of its own in the image, and no apt repository of its own.
  Userspace updates come from the Ubuntu archive, hardware updates from
  Armbian.
