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
  only combinations listed in [`boards.conf`](../boards.conf). Every image
  starts as Armbian's minimal image; a desktop flavor adds Ubuntu's desktop
  to it (see [Desktop flavors](#desktop-flavors)).
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

1. Checks the board, branch, release and flavor against `boards.conf` and
   refuses Armbian's own desktop builds (`BUILD_DESKTOP`).
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
8. On desktop flavors only: installs Ubuntu's desktop metapackage, hands the
   network to NetworkManager and seeds the snaps (see
   [Desktop flavors](#desktop-flavors)).
9. Adds Roxora's apt repository and installs Roxora's packages: the
   keyring, hwtool (with its GTK app on a desktop) and the wallpapers from
   the repository, and the release packages of the commit, which own
   Roxora's apt sources, pins and cloud-init settings from then on (see
   [Roxora's apt repository](#roxoras-apt-repository)).
10. On UEFI images only: leaves out `linux-dtb`, replaces the GRUB settings
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

The image keeps both apt sources Armbian writes, and adds Roxora's (see
[Roxora's apt repository](#roxoras-apt-repository)):

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

## Roxora's apt repository

[roxora-os/apt](https://github.com/roxora-os/apt) publishes Roxora's own
packages at https://roxora-os.github.io/apt, one suite per Ubuntu release
(`noble`, `resolute`) with one component, `main`. Its Release files are
signed with Roxora's key (Ed25519, fingerprint
`07353CCFAF21725418E3CE4798FC2BE6A9A8952D`). Every image has:

- `/etc/apt/sources.list.d/roxora.sources`
  ([`roxora.sources.in`](../userpatches/roxora/apt/roxora.sources.in)): the
  URL, the image's Ubuntu release as the suite, and
  `Signed-By: /usr/share/keyrings/roxora-archive-keyring.gpg`, the key from
  the `roxora-archive-keyring` package.
- `/etc/apt/preferences.d/roxora.pref`
  ([`roxora.pref.in`](../userpatches/roxora/apt/roxora.pref.in)):

      Package: roxora-*
      Pin: origin "roxora-os.github.io"
      Pin-Priority: 500

      Package: *
      Pin: origin "roxora-os.github.io"
      Pin-Priority: -1

  The records match the host the repository is served from, not a field of
  its Release file, so nothing but `roxora-*` packages can come from there,
  whatever its index lists. Armbian's -1 record keeps any `roxora-*` package
  of Armbian's repository out.

What the repository carries, and the versions an image installs from it
([`roxora-repo.conf`](../userpatches/roxora/roxora-repo.conf)):

| Package | What it is | Built by |
| --- | --- | --- |
| `roxora-archive-keyring` | the repository's key | roxora-os/apt |
| `roxora-hwtool`, `roxora-hwtool-gtk` | hwtool and its GTK app, from hwtool's GitHub releases | roxora-os/hwtool |
| `roxora-wallpapers` | the wallpapers, from roxora-os/design at a fixed commit | roxora-os/apt |
| `roxora-release` | what every flavor of a release shares | this repository, [`packages/`](../userpatches/roxora/packages) |
| `roxora-cli`, `roxora-desktop-gnome-minimal`, `roxora-desktop-gnome` | one per flavor | this repository |

A new hwtool or Roxora release reaches the repository within the hour (its
workflow looks every hour); a published version never changes.

### Release packages

The release packages bring an installed system what a release changed in its
image. Their version is the Roxora release, `+` and the Ubuntu version
(`2026.11.5+24.04`), so each suite has its own build and a later release is
always the newer package.

`roxora-release` owns, as configuration files: the source list and pin of
Roxora's repository, the source list of the hardware repository
(`armbian.sources`, as Armbian's build writes it,
[`armbian.sources.in`](../userpatches/roxora/apt/armbian.sources.in)) and its
pin (`roxora-hardware.pref`), and cloud-init's settings (`99-roxora.cfg`). It
also owns `/usr/share/fonts`, creates `/usr/local/share/fonts` (see
[Desktop flavors](#desktop-flavors) for why both must exist), and depends on
the keyring, hwtool and the wallpapers.

Each flavor package depends on `roxora-release` of its own version and on
what that flavor's image has in the release: `roxora-cli` on
NetworkManager (from 2026.11.5 on); the desktop packages on NetworkManager
and the GTK app of hwtool, they recommend Ubuntu's desktop metapackage, and
own `99-roxora-desktop.cfg`. One flavor package is installed at a time;
installing another replaces it. The flavor package writes
`/usr/lib/roxora-release`, linked from `/etc/roxora-release`:

    ROXORA_VERSION=2026.11.5
    ROXORA_FLAVOR=cli
    ROXORA_UBUNTU_CODENAME=noble
    ROXORA_PACKAGE=roxora-cli

Steps that apt cannot express run in the packages' maintainer scripts, once,
by the version a system comes from, and never against a setting the user
changed: on its first installation a desktop package disables
systemd-networkd's enablement as the desktop images have it (only where
Ubuntu's netplan file makes NetworkManager the renderer; nothing is stopped,
it counts from the next boot). Nothing reboots, and nothing repeats the first
boot or writes a bootloader.

Configuration files. Images up to 2026.11.4 have Roxora's files without a
package. dpkg takes over a file that is exactly as the package ships it;
for older versions of a file, the package's preinst moves it aside when its
SHA-256 is that of an earlier image
([`takeover.list`](../userpatches/roxora/packages/takeover.list)), and puts
it back if the installation fails. A file the user changed stays, and dpkg
asks about it, as about any configuration file. Removing `roxora-release`
leaves its files in place; purging it removes the sources and pins of both
repositories together, so the system then takes nothing more from either.

The image build runs [`packages/build.sh`](../userpatches/roxora/packages/build.sh)
and installs the release packages it writes, with the other packages from
the repository at the versions of `roxora-repo.conf`. roxora-os/apt runs the
same script at the release's tag to publish them. So a change to the
release packages is built and checked with the images before it reaches any
installed system, and a release's packages reach the repository with the
release, not before. A release tag must carry its version as
`ROXORA_RELEASE` (release.yml checks).

Images install packages without their recommended packages; apt installs
those on a running system. A release that adds a package to a flavor
package should check what that package recommends: `apt full-upgrade`
brings it on upgraded systems. The upgrade test (see
[Verification](#verification)) shows it.

### Ubuntu release upgrades

From 24.04 to 26.04 with Ubuntu's own release upgrader, as
[install.md](install.md#from-ubuntu-2404-to-2604) says: `apt full-upgrade`,
then `do-release-upgrade`, nothing by hand. Not supported yet: it passes in
CI, and has not been run on a board (B9 of
[hardware-test.md](hardware-test.md)). What makes it work:

- `roxora-release` depends on `ubuntu-release-upgrader-core`, which
  Ubuntu's server images have and Roxora's command line images lacked.
- The upgrader turns off every apt source it does not know. It reads
  `/etc/update-manager/release-upgrades.d/*.cfg`, and a
  `[ThirdPartyMirrors]` section there names archives it moves to the new
  release like Ubuntu's own (`isThirdPartyMirror` in its
  `DistUpgradeController.py`). `roxora-release` ships `roxora.cfg` there
  ([`release-upgrades.cfg.in`](../userpatches/roxora/apt/release-upgrades.cfg.in))
  with Roxora's repository and the hardware repository, and nothing else:
  other third-party sources are turned off as Ubuntu does.
- The upgrader moves only the suite: Armbian's components keep the names
  `noble-utils` and `noble-desktop`. The 26.04 `roxora-release`, which the
  upgrader installs from Roxora's repository during the upgrade, recognises
  that edit of the 24.04 package's `armbian.sources` (and of `roxora.sources`,
  and the `Enabled: no` the upgrader writes without the configuration) by
  SHA-256, writes back what the 24.04 package shipped, and dpkg replaces it
  with the 26.04 file (`resolute-utils`, `resolute-desktop`) without asking.
- 26.04 has chrony where 24.04 has systemd-timesyncd. `roxora-release`
  26.04 depends on `chrony | time-daemon`, as Ubuntu's `ubuntu-minimal`
  does: a new image has chrony, an upgraded system keeps timesyncd, as an
  upgraded Ubuntu server. A plain dependency on chrony made the upgrader and
  apt keep the release packages back.
- 26.04 requires the unified cgroup v2 hierarchy; the upgrader refuses a
  system without it. systemd mounts it unless the kernel command line turns
  it off, and nothing in Roxora's or Armbian's boot files does
  (`verify-image.sh` checks `boot.cmd`, `armbianEnv.txt` and GRUB's
  settings, and that the kernel has cgroups). On a board this is B2 of the
  hardware test.
- The hardware layer stays: the upgrader removes none of Armbian's packages
  or the BSP package as obsolete, and initramfs-tools stays, whose hook
  makes the `uInitrd` the boot script loads (26.04 otherwise uses dracut).

`.github/workflows/release-upgrade.yml`
([`release-upgrade-test.sh`](../verify/release-upgrade-test.sh)) runs the
commands of install.md as written on the previous release's 24.04 ROCK 4D
images (command line, GNOME minimal, GNOME) and RK3576 UEFI command line
image, each first updated as in "Updating to a new Roxora release", in a
chroot, with the upgrader's non-interactive front end. Release packages not
yet published come from a local repository that the test adds to the
upgrader's `[ThirdPartyMirrors]`. Each result passes
`verify-image.sh --upgraded` as a 26.04 system, a second
`apt full-upgrade` has nothing to do, and the UEFI image then boots in QEMU
to the kernel. What an upgraded system has that a new 26.04 image does not,
and why, is in
[`allowlist-upgraded`](../verify/reference/allowlist-upgraded) and
[`keep-modified-upgraded`](../verify/reference/keep-modified-upgraded).

What the chroot cannot show: services do not run, so the upgrader skips its
snap steps (on a running desktop it moves the snaps to their 26.04 channels
through snapd, as on Ubuntu; in a desktop image that has not booted the
24.04 seed stays and snapd installs it at the first boot), and nothing
reboots into 26.04 there.

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

## Kernel branches

Each board image exists with Armbian's `edge` kernel (mainline Linux) and
with its `vendor` kernel (Rockchip's Linux 6.1, the `rk35xx` family's
`vendor` branch); `boards.conf` has a row for each. Everything above holds
for both: the same extension, the same Ubuntu userspace, the same pin. What
differs comes from Armbian:

- The kernel packages are `linux-image-vendor-rk35xx` and
  `linux-dtb-vendor-rk35xx`, updated from Armbian's repository like the
  edge ones.
- U-Boot. The ROCK 4D uses mainline U-Boot with either kernel. The CM5-IO
  with the vendor kernel uses Rockchip's U-Boot, which the image carries as
  two files, `idbloader.img` at 32 KiB and `u-boot.itb` at 8 MiB, where the
  mainline build is one `u-boot-rockchip.bin`. `verify-image.sh` compares
  whichever the installed U-Boot package has with the image.
- The serial console of the vendor kernel is `ttyFIQ0`.
- The GPU. The vendor desktop images use Mesa and panfrost, not Rockchip's
  Mali driver or `libmali`: Armbian's vendor kernel is built with the
  `panfrost` driver and without Arm's kbase driver for this GPU (`CONFIG_DRM_PANFROST=m`, no
  `CONFIG_MALI_BIFROST`), so Mesa drives the Mali-G52 as it does on the edge
  kernel and the desktop flavors need nothing else. The check reads the
  kernel's configuration from the image and fails a desktop image whose
  kernel has no panfrost, or has Arm's driver, or that carries a `libmali`.

The UEFI image has both branches too, command line only for `vendor`.

## Desktop flavors

`boards.conf` gives every image a flavor. `cli` is the command line image
described so far. `gnome-minimal` and `gnome` are the same image with
Ubuntu's GNOME desktop on top, built in the same run:
`./build.sh ... FLAVOR=gnome-minimal`. Armbian's desktop support is not
used: it installs Armbian's own desktop package sets and settings, and
Roxora wants what Ubuntu ships.

Packages. After the Ubuntu files are restored, the extension installs one
metapackage with its recommended packages, as `apt install` does on a
running system: `ubuntu-desktop-minimal` for `gnome-minimal`,
`ubuntu-desktop` for `gnome`. That brings GDM, GNOME Shell and Ubuntu's
session, NetworkManager, the fonts (Noto CJK among them), the language
tools and, for `gnome`, LibreOffice and the other applications of a default
Ubuntu installation. Nothing is taken from Armbian's repository: the pin
keeps everything but the hardware layer out.

Snaps. Ubuntu delivers Firefox, the App Center and Thunderbird as snaps;
the `firefox` and `thunderbird` packages only install the snap, and skip
that where no snapd runs, as in an image build. The build seeds the snaps
the way Ubuntu's image builds do (livecd-rootfs, ubuntu-image):
`snap prepare-image --classic` with the store's `generic-classic` model
writes the snap files and their assertions to `/var/lib/snapd/seed`, and
snapd installs them from there at the first boot, without a network.
[`snaps.list`](../userpatches/roxora/desktop/snaps.list) names the snaps
and channels, taken from the manifests of Ubuntu's arm64 desktop images;
the build adds the base and content snaps those need today
([`snap-closure.py`](../userpatches/roxora/desktop/snap-closure.py)), since
a snap can move to a newer base after Ubuntu made its image. The snaps come
from the store on the day of the build, so two builds can carry different
revisions; after the first boot snapd updates them anyway. Ubuntu's builds
also run `snap-preseed`, which does part of the first-boot work at build
time; Roxora does not, so the first boot of a desktop image spends a few
minutes installing the seed.

Fonts in snaps. snapd gives a snap the host's fonts through the font
directories that exist when it sets the snap up. In a desktop image the
fonts are installed when the image is built and the snaps are set up at the
first boot, so Firefox sees them.

Network. A command line image runs wired Ethernet with systemd-networkd,
from the netplan file cloud-init writes from the image's seed, as Ubuntu's
server images do. It also has NetworkManager, installed without its
recommended packages, for `nmtui` and `nmcli`: Ubuntu's network-manager
package ships
`/usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf` with
`unmanaged-devices=*,except:type:wifi,except:type:gsm,except:type:cdma`, so
there it manages Wi-Fi and mobile broadband and nothing else. netplan lifts
that only when a netplan file makes NetworkManager the renderer, which no
file of a command line image does. Roxora adds no setting of its own; the
check fails if that default changes.

On a desktop NetworkManager runs every device: `ubuntu-settings`
ships `/usr/lib/netplan/00-network-manager-all.yaml`, which makes it
netplan's renderer, as on an installed Ubuntu desktop. So the desktop
flavors differ from `cli` in two ways. cloud-init writes no network
configuration
([`99-roxora-desktop.cfg`](../userpatches/roxora/desktop/99-roxora-desktop.cfg);
the `cli` seed's `network-config` is left out), and systemd-networkd, which
Armbian's build enables, is disabled again. Ubuntu's systemd package does
not enable it either: netplan starts it when a configuration asks for it.
Left enabled, `systemd-networkd-wait-online` would hold every boot for two
minutes, waiting for links it does not manage.

First login. Ubuntu's preinstalled desktop images create the first user on
the display (oem-config on 24.04, gnome-initial-setup on 26.04). Roxora
keeps the account of the `cli` image, `roxora` with an expired password, in
every flavor: a board can then be set up over SSH or the serial console
without a display, and the documentation is the same for all images. GDM
asks for the new password through PAM. cloud-init still does the rest of
the first boot (host keys, growing the root file system, the swap file).
On the desktop flavors `roxora` is also in the `lpadmin` and `users`
groups, as Ubuntu's first desktop user is.

Roxora's own parts are packages from
[Roxora's apt repository](#roxoras-apt-repository): `roxora-wallpapers`, in
every flavor, whose settings override makes Facet the default wallpaper,
`roxora-hwtool-gtk`, the GTK app of hwtool, and the flavor's release
package (`roxora-desktop-gnome-minimal` or `roxora-desktop-gnome`).

The boot is not changed: no boot splash is set up, so kernel messages show
until GDM starts.

## Verification

`verify/verify-image.sh` mounts an image read-only (changes go to a
throwaway overlay) and checks:

- every installed package is in Ubuntu's own image, belongs to the
  hardware layer, or is on the
  [allowlist](../verify/reference/allowlist), against the reference
  manifests in [`verify/reference/`](../verify/reference): the server image
  for `cli`, and with it Ubuntu's desktop images for the desktop flavors;
- the pin file is installed unchanged, the Armbian source list is present,
  only hardware packages have an Armbian candidate, `base-files` comes from
  the Ubuntu archive, and a simulated `full-upgrade` takes nothing else from
  Armbian;
- Roxora's repository: its source list, pin and key (fingerprint as in
  `roxora-repo.conf`) and the hardware repository's source list and pin
  are as `roxora-release` and `roxora-archive-keyring` ship them and owned
  by them; only `roxora-*` packages have their candidate in Roxora's
  repository, and a simulated `full-upgrade` takes nothing else from it;
- the release packages: `roxora-release` and the flavor's package at the
  release of `roxora-repo.conf` for the image's Ubuntu release, no other
  flavor package, and `/etc/roxora-release` with that release and flavor;
  the keyring, hwtool (and its GTK app on a desktop) and the wallpapers at
  the versions of `roxora-repo.conf`, from Roxora's repository;
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
  are on;
- desktop flavors: GDM is the display manager and the system boots to
  `graphical.target`, without automatic login; NetworkManager is enabled and
  netplan's renderer, cloud-init writes no network configuration and
  systemd-networkd is not enabled; the CJK fonts are installed; the default
  wallpaper in the compiled GNOME settings is Facet; every snap of `snaps.list` is in the seed in its channel,
  the model is `generic-classic`, and `snap debug validate-seed` accepts
  the seed. A `cli` image must have none of the desktop parts.

The flavor is read from the image (which desktop metapackage is installed);
CI also passes the flavor it built, and a mismatch fails.

CI runs it on every image, and its output is published with each release
(see [release-contract.md](release-contract.md)). It cannot tell whether a
board boots; that is what [hardware-test.md](hardware-test.md) is for. For
UEFI images CI also boots the image in QEMU (arm64 `virt` machine, Ubuntu's
edk2 build, device tree from the firmware) and checks that the firmware
starts GRUB and GRUB starts the kernel
([`qemu-boot.sh`](../verify/qemu-boot.sh)). QEMU is not a board, so this
says nothing about the board's hardware.

The upgrade test (`.github/workflows/upgrade.yml`,
[`upgrade-test.sh`](../verify/upgrade-test.sh)) takes published images of
the previous release (a command line board image, a command line UEFI image
and a desktop image), runs the commands of
[Updating to a new Roxora release](install.md#updating-to-a-new-roxora-release)
in a chroot as they are written, with the release packages of the commit
under test, and checks the result with `verify-image.sh --upgraded`: the
same checks as for a new image, except that the bootloader on the disk may
be older than an updated U-Boot package. A question from dpkg about a
configuration file fails it. The images have not booted, so it says
nothing about services of a running system.

## What Roxora does not do

- No kernel or U-Boot patches of its own. Hardware support is whatever
  Armbian ships at the pinned commit; hardware fixes are made in Armbian.
- No changes to Armbian's boot method on board images. UEFI images use
  Armbian's own GRUB support; Roxora only replaces its settings.
- No UEFI firmware in any image. The firmware is installed on the board on
  its own, from its own project.
- No `armbian-config`, and no Roxora replacement for it. Configuration is
  done the Ubuntu way.
- No desktop of its own. The desktop flavors are Ubuntu's GNOME desktop as
  Ubuntu packages it; there are no other desktops. With the vendor kernel
  the desktop is the same: Mesa on the kernel's panfrost driver, and no
  Mali userspace from Rockchip (see [faq.md](faq.md#does-the-desktop-on-the-vendor-kernel-use-rockchips-mali-driver)).
- No Debian images. Roxora is Ubuntu only, starting with 24.04 (noble).
- No packages of other projects in its apt repository. Userspace updates
  come from the Ubuntu archive, hardware updates from Armbian; Roxora's
  repository carries only Roxora's own packages, and the pin takes nothing
  else from it.
