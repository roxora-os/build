# FAQ

## What is Roxora?

Images for Rockchip boards that pair Armbian's kernel, device tree, U-Boot and
firmware with a stock Ubuntu userspace. Only hardware packages come from
Armbian; everything else comes from the Ubuntu archive.
[architecture.md](architecture.md) explains how.

## Is Roxora the only way to run Ubuntu on these boards?

No. Board makers and other projects publish their own images too. Roxora is
stock Ubuntu userspace with Armbian's kernels and bootloaders.

## Why not Armbian's own images?

Armbian's images come with Armbian's own setup: a first-boot wizard, a
configuration tool and its own defaults. Roxora is for people who want the
system Ubuntu ships instead. Both use the same kernels and bootloaders. If you
want Armbian's tools, use Armbian's images.

## Which kernel do the images use?

Armbian's `edge` kernel branch, built from mainline Linux (7.3.y at the
armbian/build commit in [`armbian.ref`](../armbian.ref)). Armbian's `vendor`
branch, based on Rockchip's kernel, may be added once the edge images work.

## Are hardware video decoding and the NPU supported?

Roxora images use Armbian's `edge` kernel branch, built from mainline Linux.
The GPU and the video decoders use the upstream kernel drivers, with their
userspace from the Ubuntu archive: mesa for the GPU, and V4L2 for the video
decoders. What works depends on the upstream kernel and on the versions in
the Ubuntu release (24.04 or 26.04).

On the ROCK 4D the edge kernel has a driver for the NPU: the image ships the
mainline Rocket driver (`rocket.ko`), and the board's device tree enables
both NPU cores.

[charsiu](https://github.com/gahingwoo/charsiu), an LLM runtime for the
RK3576 NPU, drives that driver directly. It is not in the image; install it
from Armbian's repository, which the apt pin allows for this one package, and
fetch a model:

    sudo apt install charsiu
    charsiu pull

Other programs reach the Rocket driver through Mesa's Teflon delegate, and
the Mesa in Ubuntu 24.04 is older than the Mesa releases with Rocket support.
Rockchip's own RKNN runtime needs Armbian's `vendor` kernel branch, based on
Rockchip's kernel; [hwtool](https://github.com/roxora-os/hwtool) can switch an
installed system to that branch and back (`hwtool kernel switch vendor`, then
`hwtool kernel revert`).

The NPU has not been tested on Roxora yet; the hardware test includes it.

## How do I log in the first time?

Connect a serial console (1500000 baud, 8N1) or wired Ethernet with DHCP,
and log in as `roxora` with the password `roxora`. You must choose a new
password at once, on the console and over SSH alike. The root account is
locked; use `sudo`.

At the first boot cloud-init also creates new SSH host keys, grows the root
partition to the size of the card or eMMC, and brings up wired Ethernet with
DHCP. The hostname is the board name, for example `radxa-rock-4d`.

To set your own user, SSH keys, hostname or network at the first boot, plug
a USB stick with a filesystem labelled `CIDATA` into the board before it
starts for the first time. Put files named `user-data` and `meta-data` on it
in cloud-init's NoCloud format. cloud-init reads the image's own seed first,
then the `CIDATA` filesystem: a `user-data` file there replaces the image's,
and `meta-data` is merged with it. The `roxora` account exists either way;
it is part of the image, not of the cloud-init seed. See cloud-init's
[NoCloud documentation](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html).

## Where do updates come from?

- Ubuntu packages come from the Ubuntu archive (`ports.ubuntu.com`).
  unattended-upgrades is installed and installs security updates
  automatically, with Ubuntu's default settings.
- Hardware packages (`linux-image-*`, `linux-dtb-*`, `linux-headers-*`,
  `linux-u-boot-*`, `armbian-firmware*`) come from Armbian's repository
  (`apt.armbian.com`). Ubuntu's default unattended-upgrades settings do not
  include that repository, so these arrive with `sudo apt update && sudo apt
  full-upgrade`.
- Nothing else is installed or upgraded from Armbian's repository, except
  charsiu if you install it (see the NPU answer above). It is pinned (see [architecture.md](architecture.md#where-packages-come-from)).
- A hardware package that Armbian's repository does not carry for a board
  stays at the version in the image.
- The ROCK 4D Wi-Fi driver (AIC8800) is downloaded from Radxa's GitHub
  releases when the image is built and installed with DKMS. DKMS rebuilds it
  for each new kernel, but apt does not update the driver itself.

There is no Roxora apt repository. New Roxora images are published as
[GitHub releases](https://github.com/roxora-os/build/releases) of this
repository; an installed system does not need them to stay up to date.

## Can I update the kernel and go back?

Yes, with apt. The board boots the one installed kernel; there is no boot menu
yet. To go back, install an older version of the kernel and dtb packages
with `apt install --allow-downgrades`.
Step B7 of [hardware-test.md](hardware-test.md#b7-roll-back-the-kernel)
shows the commands.

## Why does the ROCK 4D not boot from the SD card?

The ROCK 4D's boot ROM starts from SPI NOR flash, UFS or USB, never from the
SD card. The SPI flash must hold a mainline U-Boot, which then boots the SD
card. The CM5-IO prefers its eMMC over the SD card. See step 2 of
[install.md](install.md#2-radxa-rock-4d-bootloader-into-spi-nor-flash).

## Are there desktop images?

Not yet. Roxora builds minimal server images only. You can install a
desktop on one with `sudo apt install ubuntu-desktop-minimal`.

## Firefox shows boxes instead of Chinese, Japanese or Korean text

This can happen after installing a desktop on a server image. A server image
has no `/usr/share/fonts`. If apt installs the Firefox snap before the font
packages, snapd sets up Firefox without the system fonts, and Firefox does
not see fonts installed later. Reconnecting the snap's desktop interface
makes snapd set it up again, with the fonts:

    sudo snap disconnect firefox:desktop
    sudo snap connect firefox:desktop

Then restart Firefox.

## Is Roxora affiliated with Ubuntu, Armbian or Rockchip?

No. Roxora is based on Ubuntu and Armbian. It is not affiliated with or
endorsed by Canonical, the Armbian project or Rockchip.
