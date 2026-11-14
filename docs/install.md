# Installing Roxora

Every Roxora image is built and checked in CI before it is released. Some
have also been tested on a board: the Download page and the release notes say
which. With an image that has not, keep a way back (another SD card, or the
board's vendor image).

## Which image

Each board has up to three images per Ubuntu release. They are the same
system underneath: the same kernel, the same updates, the same `roxora`
account.

- Command line (`roxora-<board>-<release>-edge-<version>.img.xz`): no
  desktop, close to Ubuntu's server image. For a board used over SSH or the
  serial console, and the smallest download. It fits a 4 GB card.
- GNOME minimal (`...-edge-gnome-minimal-<version>.img.xz`): Ubuntu's
  desktop with Firefox, the App Center, Files, Settings, a terminal and a
  text editor (`ubuntu-desktop-minimal`). Pick this for a desktop; more
  applications can be installed later.
- GNOME (`...-edge-gnome-<version>.img.xz`): the full Ubuntu desktop
  (`ubuntu-desktop`), which adds LibreOffice, Thunderbird and the other
  applications of a default Ubuntu installation.

A desktop image needs a card or drive of 16 GB or more, and a display on
HDMI with a keyboard and mouse. Desktop images are built with the `edge`
kernel only. You can also start from the command line image and add the
desktop later with `sudo apt install ubuntu-desktop-minimal`; the
[FAQ](faq.md#are-there-desktop-images) says what differs then.

## 1. Download

Pick the image for your board from the website's Download page
(https://roxora-os.github.io/download/) or from the
[releases](https://github.com/roxora-os/build/releases). Download the
`.img.xz` file and its `.sha256` file. For the Radxa ROCK 4D also download
the `-spi.img` file and its `.sha256` file; the three images of one board,
Ubuntu release and Roxora release come with the same bootloader, under each
image's name.

Roxora Imager downloads and checks the files itself; you can skip to step 3
if you use it.

Check the files (`<release>` is `noble` for Ubuntu 24.04 or `resolute` for
Ubuntu 26.04; a desktop image has `-gnome-minimal` or `-gnome` after
`edge`):

    sha256sum -c roxora-<board>-<release>-edge-<version>.img.xz.sha256
    sha256sum -c roxora-<board>-<release>-edge-<version>-spi.img.sha256   # ROCK 4D

Every line must end in `OK`.

From release 2026.11.3 on, each image also has a build provenance
attestation: a signed record of the GitHub Actions run, commit and repository
that built it. With the GitHub CLI:

    gh attestation verify roxora-<board>-<release>-edge-<version>.img.xz --repo roxora-os/build

## 2. Radxa ROCK 4D: bootloader into SPI NOR flash

The ROCK 4D starts from SPI NOR flash, UFS or USB, never directly from an SD
card. An SD card boots only through a U-Boot in the SPI NOR flash. If the
flash is blank, or holds an EDK2 (UEFI) firmware, write Roxora's `-spi.img`
to it first, with Roxora Imager over USB (Maskrom mode). Skip this step if
the flash already holds a mainline U-Boot. To keep an EDK2 firmware in the
flash, use the UEFI image instead (see
[RK3576 boards with UEFI firmware](#rk3576-boards-with-uefi-firmware)).

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

## RK3576 boards with UEFI firmware

The `generic-rk3576-uefi` image is for any RK3576 board that runs UEFI firmware, for
example [edk2-rk3576](https://github.com/gahingwoo/edk2-rk3576) on the
Radxa ROCK 4D or the ArmSoM CM5-IO. It has no bootloader of its own and no
`-spi.img` file: the firmware on the board starts GRUB from the image, and
gives the kernel the board's device tree.

1. Install the firmware first, as its project describes: for edk2-rk3576 see
   its [releases](https://github.com/gahingwoo/edk2-rk3576/releases) and
   [flashing guide](https://github.com/gahingwoo/edk2-rk3576/blob/main/docs/FLASHING.md).
   On the ROCK 4D it goes
   into the SPI NOR flash; on the CM5-IO onto the eMMC or an SD card. Check
   that the board shows the firmware's front page on HDMI or on the serial
   console (1500000 baud) before you go on.
2. Download and check
   `roxora-generic-rk3576-uefi-<release>-<branch>-<version>.img.xz` as in
   step 1 above. `<branch>` is the kernel:
   - `edge`: Armbian's kernel, close to mainline Linux. It works with the
     firmware's own device tree and with Armbian's (below).
   - `vendor`: Rockchip's BSP kernel (Linux 6.1), with the drivers of
     Rockchip's own SDK. It needs Armbian's device tree for that kernel, so
     turn on the firmware's DTB override first, as described in
     [Using Armbian's device tree](#using-armbians-device-tree-instead-of-the-firmwares);
     the firmware's own device tree is written for mainline Linux. Its serial
     console is `ttyFIQ0`.
3. Write the image to a USB drive, an NVMe drive or an SD card, the same way
   as in step 3 above (Roxora Imager, Raspberry Pi Imager, or `xz -dc ... |
   sudo dd ...`). An NVMe drive can be written in another computer with a
   USB adapter. Do not write it over the medium that holds the firmware:
   on the CM5-IO with the firmware on its SD card, put the image on NVMe or
   USB; with the firmware on the eMMC, the SD card is free.
4. Connect the drive and power the board on. The firmware starts
   `\EFI\BOOT\BOOTAA64.EFI` from the drives in its boot order; if it starts
   another system, choose the drive in its boot manager. GRUB shows its menu for
   three seconds, then starts the newest kernel. The first boot then goes on
   as in step 4 below; the host name is `generic-rk3576-uefi`.

### Using Armbian's device tree instead of the firmware's

By default the kernel gets the firmware's device tree. The `vendor` image
needs this override; for the `edge` image it is optional. The image also has
Armbian's device trees for RK3576, from the installed kernel, on its EFI
system partition (`/boot/efi/dtb/rockchip/`); every kernel update refreshes
them. To boot with those instead, on edk2-rk3576:

1. At power on, enter the firmware setup (Escape on edk2).
2. Go to Device Manager, RK3576 Platform Configuration, ACPI / Device Tree.
3. Set "Support DTB override & overlays" to Enabled. Leave "Firmware
   Fix-ups" enabled and both paths empty.
4. Save, and reset the board.

The firmware then loads `\dtb\rockchip\<board>.dtb` (for example
`rk3576-rock-4d.dtb` or `rk3576-armsom-cm5-io.dtb`) from the drive it boots
from. A debug build of the firmware prints `FdtPlatform: Loaded FDT
override` on the serial console when it does. To go back, set the option to Disabled again. If the board does not
boot with the override, the firmware setup is still reachable at power on.

Kernel updates through `apt` rewrite the GRUB menu for the new kernel.
Armbian's kernel package replaces the kernel it updates (one package per
kernel branch, not one per version), so the menu lists one kernel per
installed branch. GRUB itself is updated from the Ubuntu archive.

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

### First boot of a desktop image

A desktop image starts the login screen (GDM) on HDMI. Choose the user
`roxora` and enter the password `roxora`. The login screen then says the
password must be changed: enter `roxora` once more as the current password,
then a new password twice; Ubuntu's password rules apply. After that the
desktop starts.

The first boot takes a few minutes longer than later ones. Besides growing
the root file system, snapd installs the snaps that are in the image
(Firefox, the App Center and the snaps they need); until it has finished,
their icons are missing from the application list or do not start. No
network is needed for that.

SSH works as on the command line image, with the same account; changing the
password over SSH or on the console first also counts for the login screen.
The network is run by NetworkManager, as on any Ubuntu desktop: wired
Ethernet gets its address by DHCP, and Wi-Fi is set up from the system menu.

Hardware Tool (the GTK app of `hwtool`) is in the application list, and the
`hwtool` command works as on the command line image. The wallpaper is
Roxora's Facet; the other Roxora wallpapers and Ubuntu's are in Settings,
Appearance.

## 5. Updates

Ubuntu packages come from the Ubuntu archive, and the kernel, device tree,
U-Boot and firmware packages from Armbian's repository:

    sudo apt update && sudo apt full-upgrade

Security updates install automatically (unattended-upgrades), as on Ubuntu
server. On a desktop image the snaps update on their own from the snap
store, as on Ubuntu.

## Problems

Report problems at https://github.com/roxora-os/build/issues. See the
[FAQ](faq.md) for where kernel and hardware problems belong.
