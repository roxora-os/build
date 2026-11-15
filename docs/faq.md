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

There are two, and the image's name says which: `edge` or `vendor`.

- `edge` is Armbian's kernel built from mainline Linux (7.3.y at the
  armbian/build commit in [`armbian.ref`](../armbian.ref)). Pick it unless
  you need something below. Its drivers are the upstream ones, it follows
  new kernel releases, and it is the kernel the hardware test has been run
  with.
- `vendor` is Armbian's build of Rockchip's own kernel (Linux 6.1). Pick it
  for what only Rockchip's kernel has. Its configuration, at the pinned
  commit, builds in:
  - Rockchip's NPU driver (`CONFIG_ROCKCHIP_RKNPU`), the one Rockchip's
    RKNN runtime (`librknnrt`) talks to;
  - Rockchip's MPP video service (`CONFIG_ROCKCHIP_MPP_SERVICE`) with its
    hardware decoder, encoder, JPEG and AV1 units (`_MPP_RKVDEC2`,
    `_MPP_RKVENC2`, `_MPP_JPGDEC`, `_MPP_AV1DEC` and others), which
    Rockchip's MPP library and the programs built on it use;
  - Rockchip's camera, ISP, RGA and HDMI input drivers
    (`CONFIG_VIDEO_ROCKCHIP_*`).

  These are kernel drivers only. Roxora installs none of Rockchip's
  userspace for them (no RKNN runtime, no MPP library): Ubuntu does not
  package it, and you add it from where you trust. Whether each driver
  comes up on a given board also depends on the board's device tree in
  Rockchip's kernel, and none of it has been tested by Roxora yet. The
  price is an old kernel that gets Rockchip's fixes and not mainline's, no
  mainline `rocket` NPU driver (so no charsiu), and less testing: no
  vendor image has been booted on a board by Roxora yet.

The desktop is the same on both kernels: Ubuntu's Mesa on the kernel's
panfrost driver. See the next question.

## Does the desktop on the vendor kernel use Rockchip's Mali driver?

No. The vendor desktop images use Mesa with the panfrost driver, exactly
as the edge images do. There is no Rockchip Mali driver in the kernel and
no `libmali` in the image.

The reason is how Armbian builds the vendor kernel. Rockchip's kernel tree
has two drivers for the RK3576's Mali-G52: Arm's own (kbase,
`CONFIG_MALI_BIFROST`), which only works with Arm's closed `libmali`
userspace, and the open `panfrost` driver that Mesa uses. Armbian builds
its vendor kernel with panfrost (`CONFIG_DRM_PANFROST=m`) and without Arm's
driver, so on a Roxora vendor image the GPU is panfrost's and the userspace
is the Mesa of the Ubuntu release. `verify-image.sh` checks
both in the kernel's configuration. That the desktop then runs accelerated
on the boards has not been tested on hardware yet; on the edge kernel it
has (ROCK 4D).

`libmali` is therefore not in any image, and installing it would not work:
it has no kernel driver to talk to. It would also replace Mesa's EGL and
GBM libraries with its own, and Armbian's own notes for another RK3576
board say GNOME's Wayland session crashes on it. Software that needs
Arm's driver (Rockchip's OpenCL, for one) needs another kernel build than
Armbian's.

## Are hardware video decoding and the NPU supported?

This is about the images with Armbian's `edge` kernel, built from mainline
Linux; for the `vendor` kernel see
[Which kernel do the images use?](#which-kernel-do-the-images-use).
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
    sudo charsiu-get llama3.2-1b-q8      # the model directory belongs to root
    charsiu "What is a single-board computer?"

Other programs reach the Rocket driver through Mesa's Teflon delegate, and
the Mesa in Ubuntu 24.04 is older than the Mesa releases with Rocket support.
Rockchip's own RKNN runtime needs Armbian's `vendor` kernel branch, based on
Rockchip's kernel: start from a `vendor` image, or let
[hwtool](https://github.com/roxora-os/hwtool) switch an
installed system to that branch and back (`hwtool kernel switch vendor`, then
`hwtool kernel revert`).

Tested on a ROCK 4D with Roxora 2026.11.3 (Ubuntu 26.04, edge kernel 7.3.3):
`/dev/accel/accel0` and the Rocket driver are there, apt installs charsiu
and nothing else from Armbian, and Llama 3.2 1B (Q8) answers at about
12 tokens per second (prompt about 41). The CM5-IO has not been tested yet.

## How do I log in the first time?

Connect a serial console (1500000 baud, 8N1) or wired Ethernet with DHCP,
and log in as `roxora` with the password `roxora`. You must choose a new
password at once, on the console and over SSH alike. The root account is
locked; use `sudo`. A desktop image asks for the same on its login screen
(see [First boot of a desktop image](install.md#first-boot-of-a-desktop-image)).

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

- Roxora's own packages (hwtool, the wallpapers and the release packages)
  come from Roxora's repository (`roxora-os.github.io/apt`), signed with
  Roxora's key. The pin takes only `roxora-*` packages from there. These
  too arrive with `sudo apt update && sudo apt full-upgrade`, not
  automatically.

New Roxora images are published as
[GitHub releases](https://github.com/roxora-os/build/releases) of this
repository. An installed system does not need them: the next question says
how it gets to a new release.

## How do I get to a new Roxora release without writing a new image?

With `sudo apt update && sudo apt full-upgrade`, from 2026.11.5 on: each
release publishes release packages that bring an installed system what the
release changed in its image. An image up to 2026.11.4 needs Roxora's
repository added once first. Both are in
[Updating to a new Roxora release](install.md#updating-to-a-new-roxora-release).
A new bootloader is not part of it.

## Can I upgrade from Ubuntu 24.04 to 26.04?

Not yet: `do-release-upgrade` is not supported on Roxora. Write the 26.04
image of your board instead, and copy your data over.

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

## How do I connect to Wi-Fi?

On a desktop image, from the system menu. On a command line image (after
2026.11.4), with `sudo nmtui`, or
`sudo nmcli device wifi connect "<network name>" password "<password>"`.
NetworkManager only runs Wi-Fi there; wired Ethernet stays with
systemd-networkd, so nothing changes for a board on a cable. On an older
command line image, install it first: `sudo apt install network-manager`
gives the same setup.

## Are there desktop images?

Yes. Besides the command line image, each board has two images with
Ubuntu's GNOME desktop for the `edge` kernel: `gnome-minimal`
(`ubuntu-desktop-minimal`) and `gnome` (`ubuntu-desktop`). See
[Which image](install.md#which-image). The desktop is Ubuntu's own packages
and snaps, with nothing from Armbian's desktop builds; Roxora adds its
wallpapers and the Hardware Tool app.

You can also install the desktop on a command line image with
`sudo apt install ubuntu-desktop-minimal`. The result differs from the
desktop image in three ways: apt then downloads the Firefox snap from the
snap store instead of taking it from the image, cloud-init keeps writing
the wired network's configuration (NetworkManager still runs it), and
systemd-networkd stays enabled, which the next question is about.

## Why is the default user not created by a setup wizard on the desktop?

Ubuntu's desktop images create the first user in a setup wizard on the
display. Roxora's desktop images keep the account of the command line
image, `roxora` with a password that must be changed at the first login, so
that a board can be set up without a display, over SSH or the serial
console, the same way for every image. The login screen asks for the new
password.

## The board takes two minutes longer to boot after installing a desktop

This is about a desktop installed on a command line image; the desktop
images do not have it. The desktop brings NetworkManager, which then runs the wired network instead
of systemd-networkd. `systemd-networkd-wait-online` still waits for
systemd-networkd to bring a link up, and gives up after two minutes. With the
desktop installed it is not needed:

    sudo systemctl disable systemd-networkd-wait-online.service

## Firefox shows boxes instead of Chinese, Japanese or Korean text

This can happen after installing a desktop on a command line image from before
2026.11.4, which had no `/usr/share/fonts`. The desktop images do not have
this problem: their fonts are in place before snapd sets Firefox up at the
first boot. If apt installs the Firefox snap
before the font packages, snapd sets up Firefox without the system fonts,
and Firefox does not see fonts installed later. Reconnecting the snap's desktop interface
makes snapd set it up again, with the fonts:

    sudo snap disconnect firefox:desktop
    sudo snap connect firefox:desktop

Then restart Firefox.

## Is Roxora affiliated with Ubuntu, Armbian or Rockchip?

No. Roxora is based on Ubuntu and Armbian. It is not affiliated with or
endorsed by Canonical, the Armbian project or Rockchip.
