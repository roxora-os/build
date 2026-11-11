# FAQ

## What is Roxora?

Images for Rockchip boards that pair Armbian's kernel, device tree, U-Boot and
firmware with a stock Ubuntu userspace. Only hardware packages come from
Armbian; everything else comes from the Ubuntu archive.
[architecture.md](architecture.md) explains how.

## Why not ubuntu-rockchip?

[ubuntu-rockchip](https://github.com/Joshua-Riek/ubuntu-rockchip) built
Ubuntu images for Rockchip boards. Its repository has been archived by its
owner (read only, last push September 2025), so its images get no more
updates or new boards. Roxora takes a different route: it does not maintain
kernels or board support itself, and uses Armbian's, which are maintained for
many boards.

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

Only as far as the mainline kernel and the Ubuntu archive support them.

The edge kernel uses the upstream graphics and video drivers. Their userspace
comes from the Ubuntu archive: mesa for the GPU, and V4L2 for the video
decoders. What works depends on the upstream kernel and on the versions in
Ubuntu 24.04.

Other Ubuntu images for Rockchip boards offered hardware video and NPU
acceleration with a vendor kernel and userspace packages from third-party
PPAs. ubuntu-rockchip, for example, added the `jjriek/rockchip` and
`jjriek/rockchip-multimedia` PPAs to its 24.04 images
([`config/suites/noble.sh`](https://github.com/Joshua-Riek/ubuntu-rockchip/blob/main/config/suites/noble.sh)).
Roxora does not provide those packages and adds no PPAs, and that does not
change if a vendor kernel is added later. Userspace stays what the Ubuntu
archive ships.

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
- Nothing else is installed or upgraded from Armbian's repository. It is
  pinned (see [architecture.md](architecture.md#where-packages-come-from)).
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

Not yet. Roxora builds minimal server images only.

## Is Roxora affiliated with Ubuntu, Armbian or Rockchip?

No. Roxora is based on Ubuntu and Armbian. It is not affiliated with or
endorsed by Canonical, the Armbian project or Rockchip.
