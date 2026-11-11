# Hardware test

Run this on each board before an image is marked `hardware-tested` (see
[release-contract.md](release-contract.md)). Every step says what passes. Keep
the serial log of the whole session; it goes into the test report.

You need: the board, a power supply, a USB to 3.3 V serial adapter on the
debug UART, Ethernet with DHCP and internet access, and an SD card (ROCK 4D,
CM5-IO) or Maskrom access to eMMC (CM5-IO).

Replace `<image>` with the release file, for example
`roxora-radxa-rock-4d-noble-edge-2026.11.0.img.xz`.

## 1. Check and flash the image

On the host:

    sha256sum -c <image>.sha256
    xz -dc <image> | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress

Raspberry Pi Imager with "Use custom" works as well. For CM5-IO eMMC, write
the decompressed image over Maskrom.

Pass: `sha256sum -c` prints `OK`; `dd` finishes without errors.

Boot order matters:

- **ROCK 4D**: the BootROM starts from SPI NOR, UFS or USB, never from SD.
  The SPI NOR must hold a mainline U-Boot (which then boots the SD card
  first). A blank SPI drops the board into Maskrom; an EDK2 firmware in SPI
  does not boot Roxora, which has no EFI loader yet. Note which U-Boot the
  SPI holds; the U-Boot inside the image at 32 KiB is not used on this board.
- **CM5-IO**: the BootROM prefers eMMC over SD. To boot the SD card, the eMMC
  must be blank or hold a U-Boot that tries SD first (mainline U-Boot does).
  Writing the image to the eMMC replaces whatever was there.

## 2. Serial console

Debug UART at 1500000 baud, 8N1 (`ttyS0` on the edge kernel):

    picocom -b 1500000 /dev/ttyUSB0 --logfile roxora-<board>-serial.log

Pass: U-Boot prints its banner (on the ROCK 4D this is the SPI U-Boot's
version) and `Boot script loaded from mmc ...`, the kernel boots, and a
`login:` prompt appears on the serial console.

## 3. First boot (cold boot)

Power the board on from off with the flashed card or eMMC. Wait for the login
prompt, then log in as `roxora` with password `roxora`.

Pass:

- the login asks for a new password at once, and accepts the new one;
- on the board:

      cloud-init status --wait          # status: done
      id                                # uid=1000(roxora), groups include sudo
      hostnamectl hostname              # the board name, e.g. radxa-rock-4d
      cat /etc/os-release               # NAME="Ubuntu", VERSION_ID="24.04"
      df -h /                           # size close to the card or eMMC size
      ls -l --time-style=+%F /etc/ssh/ssh_host_*_key.pub   # dated today, not the image build date
      sudo passwd -S root               # "root L ..." (locked)
      systemctl --failed                # 0 loaded units listed
      journalctl -b -p err --no-pager   # note every line in the report

## 4. Network

    ip -br addr
    resolvectl status | head -20
    ping -c 3 ports.ubuntu.com
    ssh roxora@<board-ip>               # from the host, with the new password

Pass: the wired interface has an IPv4 address from DHCP, the name resolves,
three ping replies, the SSH login works.

On the ROCK 4D also check the on-board Wi-Fi driver:

    dkms status                         # aic8800-usb ... installed for the running kernel
    ip -br link | grep wl               # a wlan interface exists

## 5. Warm boot

    sudo reboot

Pass: the board comes back to `login:` on the serial console and over SSH,
`systemctl --failed` lists 0 units, and `cloud-init status` says `done`
without running the first boot again (the password set in step 3 still
works).

## 6. Update from the archives

    sudo apt update
    apt list --upgradable
    apt-cache policy base-files linux-image-edge-rockchip64
    sudo apt full-upgrade

Pass:

- `base-files` has its installed and candidate version from
  `ports.ubuntu.com`, never from `apt.armbian.com`;
- every package that `full-upgrade` takes from `apt.armbian.com` is one of
  `linux-image-*`, `linux-dtb-*`, `linux-headers-*`, `linux-u-boot-*`,
  `armbian-firmware*`; everything else comes from `ports.ubuntu.com`;
- the upgrade finishes without errors.

Images are built with a kernel package version such as `26.11.0-trunk`, which
is lower than the versions Armbian publishes, so this step normally also
installs Armbian's current kernel. Note the old and new version:

    dpkg -l 'linux-image-*' 'linux-dtb-*' 'linux-u-boot-*' | grep ^ii

## 7. Reboot into the new kernel

    sudo reboot
    uname -r
    ls -l /boot/Image /boot/uInitrd /boot/dtb

Pass: the board boots, `uname -r` shows the kernel from step 6, and the three
links in `/boot` point at that version. On the ROCK 4D, `dkms status` shows the
Wi-Fi driver built for the new kernel and the wlan interface exists.

If step 6 did not upgrade the kernel, install an explicit newer version from
the list in `apt-cache policy linux-image-edge-rockchip64`:

    sudo apt install linux-image-edge-rockchip64=<version> linux-dtb-edge-rockchip64=<version>
    # ROCK 4D also: linux-headers-edge-rockchip64=<version>

## 8. Roll back the kernel

The boot script loads one kernel; there is no boot menu, so rolling back means
installing an older package version. Pick an older version from
`apt-cache policy linux-image-edge-rockchip64` than the one now running:

    sudo apt install --allow-downgrades \
        linux-image-edge-rockchip64=<older> linux-dtb-edge-rockchip64=<older>
    # ROCK 4D also: linux-headers-edge-rockchip64=<older>
    sudo reboot
    uname -r

Pass: the board boots the older kernel and steps 4 and 5 pass again. Then
`sudo apt full-upgrade` and one more reboot return it to the current kernel.

If a kernel does not boot: put the card in another Linux machine, mount its
root partition, and check `/boot/Image`, `/boot/uInitrd` and `/boot/dtb`
point at files of one and the same kernel version.

## Report

For each board: image file name, board revision and RAM, storage used,
pass or fail for steps 1 to 8, the kernel versions from steps 6 to 8, the
serial log, and the output of `journalctl -b -p err` from steps 3, 5 and 7.
