# Hardware test

Run this on each board before an image is marked `hardware-tested` (see
[release-contract.md](release-contract.md)). It covers the image itself and
the two tools that write and change boards, Roxora Imager and hwtool. Every
step says what passes. Keep the serial log of the whole session; it goes into
the report.

Do the parts in this order. Parts A and B are needed to mark a release
tested; parts C and D test the tools and can follow later.

| Part | What | Changes storage |
| --- | --- | --- |
| A | Install the image | SPI NOR (ROCK 4D), SD card, eMMC (CM5-IO, optional) |
| B | Test the image | no |
| C | Roxora Imager | SD card, eMMC, SPI NOR |
| D | hwtool | overlays, kernel packages, bootloader, eMMC, NVMe |

## What you need

For each board: power supply, wired Ethernet with DHCP and internet access,
a USB to 3.3 V serial adapter on the board's debug UART (pins are in the
[Radxa ROCK 4D](https://docs.radxa.com/en/rock4/rock4d) and
[ArmSoM CM5-IO](https://docs.armsom.org/armsom-cm5-io) documentation),
a microSD card of 8 GB or more and a card reader, and a USB-C data cable for
Maskrom mode.

Use the newest release on the
[releases page](https://github.com/roxora-os/build/releases), at least
2026.11.1 (the first with the ROCK 4D SPI bootloader file). In the commands
below, `<image>` is the board's `.img.xz`, for example
`roxora-radxa-rock-4d-noble-edge-2026.11.1.img.xz`.

Tools, until they have releases of their own:

- Roxora Imager desktop app: the per-system packages from the newest
  successful run of the
  [imager Release workflow](https://github.com/roxora-os/imager/actions/workflows/release.yml)
  (artifacts `linux-x86_64`, `linux-arm64`, `macos-arm64`, `macos-x86_64`,
  `windows-x64`). The web version is at https://roxora-os.github.io/imager/
  (Chrome or Edge).
- hwtool: the `debs` artifact of the newest successful run of the
  [hwtool CI workflow](https://github.com/roxora-os/hwtool/actions/workflows/ci.yml).

Maskrom mode: power off the board, hold its Maskrom button, connect its
USB-C port to the computer, release the button after two seconds. On Linux
`lsusb` then shows a device `2207:...`.

## Part A: install

### A1. Check the download

    sha256sum -c <image>.sha256
    sha256sum -c <image without .img.xz>-spi.img.sha256      # ROCK 4D only

Pass: every line ends in `OK`.

### A2. ROCK 4D: bootloader into SPI NOR

The ROCK 4D's boot ROM starts from SPI NOR, UFS or USB and never from SD, so
the SD card boots only through a U-Boot in SPI NOR. A blank SPI NOR drops the
board into Maskrom; an EDK2 firmware there does not start Roxora, which has no
EFI loader yet.

Write the release's `-spi.img` with Roxora Imager (C7, or C10 in the
browser). Pass: "Written and verified". Skip this step if the SPI NOR already
holds a mainline U-Boot; note its version from the serial log in B1.

### A3. Write the SD card

With Roxora Imager (C3), with Raspberry Pi Imager (Use custom, the
`.img.xz`), or on Linux:

    xz -dc <image> | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress

Pass: the tool reports success (the imager also reads the card back and
compares it with the release).

### A4. CM5-IO: eMMC instead of SD (optional)

The CM5-IO's boot ROM prefers eMMC over SD: with a bootable eMMC the SD card
is not used. To test from the eMMC, write the image there with Roxora Imager
over Maskrom (C6). This erases whatever is on the eMMC.

## Part B: the image

### B1. Serial console

Debug UART at 1500000 baud, 8N1 (`ttyS0` on the edge kernel):

    picocom -b 1500000 /dev/ttyUSB0 --logfile roxora-<board>-serial.log

Pass: U-Boot prints its banner (on the ROCK 4D, the SPI U-Boot's version) and
`Boot script loaded from mmc ...`, the kernel boots, and a `login:` prompt
appears on the serial console.

### B2. First boot (cold boot)

Power the board on from off. Wait for the login prompt, then log in as
`roxora` with password `roxora`.

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

### B3. Network

    ip -br addr
    resolvectl status | head -20
    ping -c 3 ports.ubuntu.com
    ssh roxora@<board-ip>               # from the host, with the new password

Pass: the wired interface has an IPv4 address from DHCP, the name resolves,
three ping replies, the SSH login works.

On the ROCK 4D also check the on-board Wi-Fi driver:

    dkms status                         # aic8800-usb ... installed for the running kernel
    ip -br link | grep wl               # a wlan interface exists

### B4. Warm boot

    sudo reboot

Pass: the board comes back to `login:` on the serial console and over SSH,
`systemctl --failed` lists 0 units, and `cloud-init status` says `done`
without running the first boot again (the password set in B2 still works).

### B5. Update from the archives

unattended-upgrades may run during the first minutes after boot. If apt
reports the dpkg lock is held, wait for it (`systemctl status
unattended-upgrades apt-daily-upgrade`) and run the command again.

    sudo apt update
    apt list --upgradable
    apt-cache policy base-files linux-image-edge-rockchip64
    sudo apt full-upgrade

Pass:

- `base-files` has its installed and candidate version from
  `ports.ubuntu.com`, never from `apt.armbian.com`;
- every package that `full-upgrade` takes from `apt.armbian.com` is one of
  `linux-image-*`, `linux-dtb-*`, `linux-headers-*`, `linux-u-boot-*`,
  `armbian-firmware*` (or `charsiu`); everything else comes from `ports.ubuntu.com`;
- the upgrade finishes without errors.

Images carry kernel packages with a version such as `26.11.0-trunk`, lower
than the versions Armbian publishes, so this step normally installs Armbian's
current kernel. Note the old and new versions:

    dpkg -l 'linux-image-*' 'linux-dtb-*' 'linux-u-boot-*' | grep ^ii

### B6. Reboot into the new kernel

    sudo reboot
    uname -r
    ls -l /boot/Image /boot/uInitrd /boot/dtb

Pass: the board boots, `uname -r` shows the kernel from B5, and the three
links in `/boot` point at that version. On the ROCK 4D, `dkms status` shows
the Wi-Fi driver built for the new kernel and the wlan interface exists.

If B5 did not upgrade the kernel, install an explicit newer version from the
list in `apt-cache policy linux-image-edge-rockchip64`:

    sudo apt install linux-image-edge-rockchip64=<version> linux-dtb-edge-rockchip64=<version>
    # ROCK 4D also: linux-headers-edge-rockchip64=<version>

### B7. Roll back the kernel

The boot script loads one kernel; there is no boot menu, so rolling back means
installing an older package version. The version the image shipped
(`...-trunk`) is in no repository, so pick an older version from
`apt-cache policy linux-image-edge-rockchip64` than the one now running:

    sudo apt install --allow-downgrades \
        linux-image-edge-rockchip64=<older> linux-dtb-edge-rockchip64=<older>
    # ROCK 4D also: linux-headers-edge-rockchip64=<older>
    sudo reboot
    uname -r

Pass: the board boots the older kernel and B3 and B4 pass again. Then
`sudo apt full-upgrade` and one more reboot return it to the current kernel.

If a kernel does not boot: put the card in another Linux machine, mount its
root partition, and check that `/boot/Image`, `/boot/uInitrd` and `/boot/dtb`
point at files of one and the same kernel version.

### B8. NPU (charsiu)

On the edge kernel, before or after B7:

    ls -l /dev/accel/                   # accel0 exists
    lsmod | grep rocket
    sudo apt install charsiu            # from apt.armbian.com
    apt-cache policy charsiu            # installed from apt.armbian.com
    charsiu pull                        # fetch a model, as it offers
    # then ask the model something, as charsiu pull describes

Pass: `/dev/accel/accel0` exists, apt installs charsiu without installing or
upgrading anything else from `apt.armbian.com`, and the model answers. Note
the tokens per second charsiu prints. On the CM5-IO also record whether
`/dev/accel/accel0` exists at all.

## Part C: Roxora Imager

Record for each test the app version (Settings), the computer's system, and
the result. When something fails, open "rkdeveloptool output" on the result
page and keep its text.

### C1. The app starts and lists the releases

Pass: the Board page lists the ROCK 4D and the CM5-IO with the newest release,
the same as the releases page; the search finds "rock4d" and "cm5".

### C2. System disks are not offered

Choose a board and image, then Destination, SD card or USB drive, and open
"N drives are not offered". Pass: the computer's own disks are listed there
with a reason, not in the table. Repeat on each system.

### C3. Write an SD card and verify (Linux, macOS, Windows)

Choose the board, the newest image, SD card or USB drive, the card, Review.
Review shows the card's name, device and size under "Will be erased". Erase
and write, confirm, give the administrator password.

Pass: "Written and verified", with the SHA-256 equal to `extract_sha256` in
the release's `roxora-catalog.json`; the card boots (B1).

### C4. Cancel and refusal

Start a write and cancel it during Write; start another and refuse the
password prompt. Pass: the first says the drive may be partly written; the
second says administrator rights were not granted and nothing was written.

### C5. Linux udev rule

Install the `.deb` or `.rpm` and do not run the app as root. With the board in
Maskrom mode, `getfacl` on its `/dev/bus/usb/...` node shows an entry for your
user. Pass: C6 works without sudo.

### C6. CM5-IO: image to eMMC over Maskrom

Choose ArmSoM CM5-IO, the newest image, Board storage over USB (Maskrom),
Storage eMMC, the image chosen in the previous step. Review, Erase and write,
confirm, do not touch the cable.

Pass: no second device prompt after the loader is sent; "Written and
verified" with the SHA-256 equal to `extract_sha256`; with "Restart the board
after a Maskrom write" on, the board boots Roxora from eMMC. If the result
says "Could not verify: from N bytes on, the loader returns filler", note N
and whether the board boots: writes past 32 MiB through this loader have not
been checked on hardware before.

### C7. ROCK 4D: SPI bootloader over Maskrom

Choose Radxa ROCK 4D, the newest image, Board storage over USB (Maskrom). What
to write defaults to "This release's SPI bootloader". Review, Erase and write,
confirm.

Pass: "Written and verified"; after a restart the serial log shows U-Boot from
SPI NOR, and with an SD card from A3 inserted the board boots Roxora.

### C8. SD card in the board (untested on RK3576)

The loader is asked to switch to the board's SD card slot (rkdeveloptool
`cs 2`). Put a card in the board, enter Maskrom mode, choose "SD card in the
board" and the image.

Pass: either "Written and verified" and the board boots Roxora from the card,
or "The board did not switch to SD card in the board. Nothing was written."
Record which; with the second, check the eMMC or SPI NOR was not changed.

### C9. Windows and macOS

On a Windows PC that never had a Rockchip driver, run C6: the app does not
find the board; install WinUSB with Zadig as the imager's install notes say,
run C6 again. On macOS (Apple silicon, and Intel if available) run C6 and C7
with no driver installed. Pass: C6 and C7 pass on both.

### C10. Web version

At https://roxora-os.github.io/imager/ in Chrome or Edge:

1. In the browser console, `crossOriginIsolated` is `true` (after one
   automatic reload).
2. CM5-IO eMMC: as C6. When the page asks for the image, use "Download from
   the release" if offered, otherwise download the `.img.xz` from the
   releases page and choose it. After the loader is sent, the page says
   "Choose the board again": pick the board once more.
3. ROCK 4D SPI: as C7.

Pass: the file is accepted ("matches the release") and both writes end with
"Written and verified". Note how long the eMMC write took.

## Part D: hwtool

hwtool changes the boot configuration, the kernel packages, the bootloader
and the eMMC or NVMe drive. Have a second SD card with the same image ready to
recover, and nothing on the eMMC or NVMe you want to keep.

Install it on the board from the `debs` artifact (see What you need):

    sudo apt install ./roxora-hwtool_<version>_arm64.deb

### D1. Information (no changes)

    hwtool info

Pass: the board name and SoC are right, the kernel branch is `edge`, the SD
card is listed as `sd` and "running system", the eMMC as `emmc`, an NVMe drive
as `nvme`. On the ROCK 4D, `/dev/mtd0` is listed as SPI flash.

### D2. Overlays

On the edge kernel the device tree package has no RK3576 overlays, so this
uses a user overlay that only adds a property to `/chosen`:

    sudo apt install device-tree-compiler
    cat > roxora-test.dtso << 'EOF'
    /dts-v1/;
    /plugin/;
    / {
        fragment@0 {
            target-path = "/chosen";
            __overlay__ {
                roxora-hwtool-test = "ok";
            };
        };
    };
    EOF
    sudo armbian-add-overlay roxora-test.dtso
    sudo hwtool overlays disable roxora-test --dry-run
    hwtool overlays list

Reboot; the serial log shows `Applying user provided DT overlay
roxora-test.dtbo`. Then:

    cat /proc/device-tree/chosen/roxora-hwtool-test        # prints ok
    sudo hwtool overlays disable roxora-test               # type yes
    ls /var/backups/hwtool/*/boot/armbianEnv.txt            # a backup exists

Reboot. Pass: `/proc/device-tree/chosen/roxora-hwtool-test` no longer exists
and the board booted normally both times.

### D3. Kernel branch switch and back

The `vendor` branch is not a supported Roxora image yet; this only tests that
hwtool can switch and return.

    sudo hwtool kernel switch vendor --dry-run
    sudo hwtool kernel switch vendor                       # type yes
    hwtool kernel status
    ls -l /var/lib/hwtool/packages/*/

Reboot. `uname -r` ends in `-vendor-rk35xx`. Then:

    sudo hwtool kernel revert                              # type yes

Reboot. Pass: the dry run lists a "Save ..." step for each edge package,
`/var/lib/hwtool/packages/<time>/` holds one `.deb` per saved package, the
board boots both times with Ethernet working, `uname -r` ends in
`-edge-rockchip64` after the revert, and on the ROCK 4D the Wi-Fi driver is
built again (`dkms status`).

On the CM5-IO the Armbian repository has no `linux-u-boot-armsom-cm5-io-edge`,
so the revert dry run says it installs the saved copy from
`/var/lib/hwtool/packages/...`; after the revert `dpkg -s
linux-u-boot-armsom-cm5-io-edge` shows the version the image shipped.

### D4. Rewrite the bootloader on the SD card

Use the device `hwtool info` shows for the SD card (usually `/dev/mmcblk1`):

    sudo hwtool boot write-bootloader --target /dev/mmcblk1                    # must refuse
    sudo hwtool boot write-bootloader --target /dev/mmcblk1 --allow-booted-device --dry-run
    sudo hwtool boot write-bootloader --target /dev/mmcblk1 --allow-booted-device

Reboot. Pass: the first command refuses and names `--allow-booted-device`, the
dry run shows one `dd` line writing `u-boot-rockchip.bin` at 32 KiB, and the
board boots from the SD card afterwards.

### D5. SPI flash (ROCK 4D)

    sudo hwtool boot write-bootloader --target spi --dry-run
    sudo hwtool boot write-bootloader --target spi

Reboot with the SD card inserted. Pass: the dry run shows `flashcp -v -p
.../u-boot-rockchip-spi.bin /dev/mtd0`, `flashcp` reports verifying, and the
board starts from SPI U-Boot and then the card. On the CM5-IO the same command
must refuse: its U-Boot package has no SPI writer.

### D6. Move the system to eMMC

    sudo hwtool boot migrate --target /dev/mmcblk0 --dry-run
    sudo hwtool boot migrate --target /dev/mmcblk0          # type yes

Power off, remove the SD card, power on. Then:

    findmnt /                     # /dev/mmcblk0p1
    cat /etc/fstab                # UUID of mmcblk0p1
    cat /boot/armbianEnv.txt      # rootdev=UUID of mmcblk0p1
    hwtool info                   # eMMC is the running system

Pass: the board boots from the eMMC without the SD card, and the SD card
still boots the old system when inserted again (on the ROCK 4D U-Boot boots
the SD card first; on the CM5-IO the boot ROM prefers the eMMC, so remove it
or blank it to boot the card).

### D7. Move the system to NVMe

ROCK 4D (U-Boot in SPI flash):

    sudo hwtool boot migrate --target /dev/nvme0n1 --write-spi --dry-run
    sudo hwtool boot migrate --target /dev/nvme0n1 --write-spi             # type yes

Power off, remove the SD card (and anything bootable on the eMMC), power on.
Pass: `findmnt /` shows `/dev/nvme0n1p1`.

CM5-IO (no SPI writer): run the same without `--write-spi`. The board then
needs a U-Boot on eMMC or SD that looks for `/boot` on NVMe. Record which
device boots with the SD card removed and with it inserted; the result decides
whether hwtool offers NVMe on this board.

## Report and marking

Send the maintainer, per board: the release and image file name, board
revision and RAM, the storage used, pass or fail for each step run, the kernel
versions from B5 to B7, the serial log, the output of `journalctl -b -p err`
from B2, B4 and B6, and for parts C and D the app or hwtool version and the
output the steps ask for.

When parts A and B pass for a board, the maintainer runs the "Mark
hardware-tested" workflow in roxora-os/build (Actions, Mark hardware-tested,
Run workflow) with the release tag and the board. The release becomes a full
release when every image in it is hardware-tested and `full_release` is
ticked. The board's `STATUS` in `boards.conf` is set to `hardware-tested` at
the same time.
