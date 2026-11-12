# Installing Roxora

Roxora images are pre-releases: they are built and checked in CI, and have
not been booted on hardware yet. Keep a way back (another SD card, or the
board's vendor image) until a release is marked as tested.

## 1. Download

Pick the image for your board from the website's Download page
(https://roxora-os.github.io/download/) or from the
[releases](https://github.com/roxora-os/build/releases). Download the
`.img.xz` file and its `.sha256` file. For the Radxa ROCK 4D also download
the `-spi.img` file and its `.sha256` file.

Roxora Imager downloads and checks the files itself; you can skip to step 3
if you use it.

Check the files (`<release>` is `noble` for Ubuntu 24.04 or `resolute` for
Ubuntu 26.04):

    sha256sum -c roxora-<board>-<release>-edge-<version>.img.xz.sha256
    sha256sum -c roxora-<board>-<release>-edge-<version>-spi.img.sha256   # ROCK 4D

Every line must end in `OK`.

## 2. Radxa ROCK 4D: bootloader into SPI NOR flash

The ROCK 4D starts from SPI NOR flash, UFS or USB, never directly from an SD
card. An SD card boots only through a U-Boot in the SPI NOR flash. If the
flash is blank, or holds an EDK2 (UEFI) firmware, write Roxora's `-spi.img`
to it first, with Roxora Imager over USB (Maskrom mode). Skip this step if
the flash already holds a mainline U-Boot.

The ArmSoM CM5-IO needs no bootloader step: its U-Boot is on the SD card or
eMMC with the image. It prefers eMMC over SD, so if the eMMC holds a bootable
system, the SD card is not used.

## 3. Write the image

Any of these works:

- Roxora Imager: choose the board, the image and the SD card. It checks the
  download, writes the card and reads it back.
- Raspberry Pi Imager: "Use custom", then the `.img.xz` file.
- On Linux, where `/dev/sdX` is the SD card (check with `lsblk`; everything
  on it is erased):

      xz -dc roxora-<board>-<release>-edge-<version>.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress

To install to the CM5-IO's eMMC instead, write the image there with Roxora
Imager over USB (Maskrom mode).

## 4. First boot

Insert the card, connect Ethernet and power the board on. The first boot
takes a minute longer than later ones: the root file system grows to fill the
card, and cloud-init creates the SSH host keys.

Log in on the console or over SSH:

- user `roxora`, password `roxora`;
- the password must be changed at the first login;
- the host name is the board name, for example `radxa-rock-4d`, and the
  wired interface gets its address by DHCP.

The root account is locked; use `sudo`. Change the password before you
connect the board to a network you do not trust.

The image includes `hwtool` for the board's hardware settings: `hwtool info`
shows what it found, and `hwtool --help` lists what it can change.

## 5. Updates

Ubuntu packages come from the Ubuntu archive, and the kernel, device tree,
U-Boot and firmware packages from Armbian's repository:

    sudo apt update && sudo apt full-upgrade

Security updates install automatically (unattended-upgrades), as on Ubuntu
server.

## Problems

Report problems at https://github.com/roxora-os/build/issues. See the
[FAQ](faq.md) for where kernel and hardware problems belong.
