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
| E | UEFI image (`generic-rk3576-uefi`), on a board with UEFI firmware | firmware storage (SPI NOR or eMMC/SD), USB drive or NVMe |

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
`roxora-radxa-rock-4d-noble-edge-2026.11.3.img.xz`.

Tools:

- Roxora Imager: the package for your system from the newest release on
  https://github.com/roxora-os/imager/releases (see
  https://roxora-os.github.io/roxora-imager/). The web version is at
  https://roxora-os.github.io/imager/ (Chrome or Edge).
- hwtool: preinstalled in the images. Newer versions are on
  https://github.com/roxora-os/hwtool/releases; the desktop app is the
  separate package `roxora-hwtool-gtk`.

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
board into Maskrom; an EDK2 firmware there does not start the board image
(the UEFI image is for that, see Part E).

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
      sudo journalctl -b | grep -A1 'SSH HOST KEY FINGERPRINTS'   # keys made on this boot
      sudo passwd -S root               # "root L ..." (locked)
      systemctl --failed                # 0 loaded units listed
      journalctl -b -p err --no-pager   # note every line in the report

  Without a battery on the board's clock, the time starts from the image
  build time until it is synced over the network. Host keys made
  on the first boot can therefore carry the build date; what counts is that
  cloud-init printed their fingerprints on this boot.

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
  the Ubuntu archive (`ports.ubuntu.com` on 24.04, `archive.ubuntu.com` on
  26.04), never from `apt.armbian.com`;
- every package that `full-upgrade` takes from `apt.armbian.com` is one of
  `linux-image-*`, `linux-dtb-*`, `linux-headers-*`, `linux-u-boot-*`,
  `armbian-firmware*` (or `charsiu`); everything else comes from the Ubuntu archive;
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
and the eMMC or NVMe drive. Before you start:

- Have a second SD card with the same image ready, to start the board if
  the first one stops booting.
- Have nothing on the eMMC or NVMe you want to keep.
- Run every command that changes something on the serial console, or over
  SSH inside `tmux` (`sudo apt install tmux`, then `tmux`; after a dropped
  connection, `tmux attach`). hwtool finishes a change even if the terminal
  goes away, but you would lose what it prints.
- Every change writes a log to `/var/log/hwtool/<time>.log`. Keep the logs
  of every step; they go into the report.

Install hwtool on the board from the `debs` artifact (see What you need):

    sudo apt install ./roxora-hwtool_<version>_arm64.deb

Recovery used below:

- Second SD card: Power off, swap the cards, power on. On the ROCK 4D the
  SPI U-Boot starts the card; on the CM5-IO the boot ROM starts the eMMC first
  when it holds a bootloader, so recovering the CM5-IO from SD needs an eMMC
  without one (see the first step of D7).
- Maskrom: Power off, hold the board's Maskrom button, connect its USB-C
  port to the computer, release the button after two seconds (`lsusb` shows
  `2207:...`). Then use Roxora Imager, Board storage over USB (Maskrom): C7
  writes the release's SPI bootloader to the ROCK 4D, C6 writes the image to
  the CM5-IO eMMC.

Device names differ between boards and with what is fitted: on a ROCK 4D
without eMMC the SD card is `/dev/mmcblk0`. Below, `<sd>` and `<emmc>` stand
for the devices `hwtool info` lists as `sd` and `emmc`. Check them before
every command that writes, above all the `dd` and `wipefs` lines, which
hwtool does not guard.

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
    sudo hwtool overlays disable --dry-run -- roxora-test
    hwtool overlays list

Reboot; the serial log shows `Applying user provided DT overlay
roxora-test.dtbo`. Then:

    cat /proc/device-tree/chosen/roxora-hwtool-test        # prints ok
    sudo hwtool overlays disable -- roxora-test             # type yes
    ls /var/backups/hwtool/*/boot/armbianEnv.txt            # a backup exists
    ls /var/log/hwtool/                                     # a log exists

Reboot. Pass: `/proc/device-tree/chosen/roxora-hwtool-test` no longer exists
and the board booted normally both times.

### D3. Kernel branch switch and back

The `vendor` branch is not a supported Roxora image yet; this only tests that
hwtool can switch and return. The first switch keeps the edge kernel
installed, so a vendor kernel that does not boot can be undone from the
second SD card.

    sudo hwtool kernel switch vendor --keep-old --dry-run
    sudo hwtool kernel switch vendor --keep-old              # type yes
    hwtool kernel status

Check the dry run: an "apt resolves" block under the install step lists
what apt installs and removes (only the edge U-Boot package may be removed),
and a "Save ..." step for the edge U-Boot package. Reboot.

If the board does not come back: start it from the second SD card, then
mount the first card and point it back at the edge kernel (its packages are
still installed):

    sudo mount <first card>p1 /mnt          # the first card, in a USB reader or the slot
    cd /mnt/boot
    sudo ln -sfn vmlinuz-<edge version> Image
    sudo ln -sfn dtb-<edge version> dtb
    sudo ln -sfn uInitrd-<edge version> uInitrd
    sudo cp /mnt/var/backups/hwtool/<time>/boot/armbianEnv.txt armbianEnv.txt
    cd / && sudo umount /mnt

(`<edge version>` is in the names of the files in `/mnt/boot`, for example
`7.3.4-edge-rockchip64`; `<time>` is the newest directory in
`/mnt/var/backups/hwtool`.) Record what happened and stop D3 there.

If it boots, `uname -r` ends in `-vendor-rk35xx`. Then go back, this time
removing the vendor packages:

    sudo hwtool kernel revert --dry-run
    sudo hwtool kernel revert                              # type yes

Reboot. Then the full switch without `--keep-old`, which saves and removes
the edge packages, and back:

    sudo hwtool kernel switch vendor --dry-run
    sudo hwtool kernel switch vendor                       # type yes
    ls -l /var/lib/hwtool/packages/*/

Reboot, check `uname -r`, then:

    sudo hwtool kernel revert                              # type yes

Reboot. Pass: the board boots after every switch with Ethernet working;
`uname -r` ends in `-vendor-rk35xx` after a switch and in `-edge-rockchip64`
after a revert; `/var/lib/hwtool/packages/<time>/` holds one `.deb` per saved
package; on the ROCK 4D the Wi-Fi driver is built again (`dkms status`).

On the CM5-IO the Armbian repository has no `linux-u-boot-armsom-cm5-io-edge`,
so the revert dry run says "apt no longer offers this version; installing
linux-u-boot-armsom-cm5-io-edge ... from /var/lib/hwtool/packages/..."; after
the revert `dpkg -s linux-u-boot-armsom-cm5-io-edge` shows the version the
image shipped.

### D4. Rewrite the bootloader on the boot device

Use the device `hwtool info` shows for the SD card as `<sd>`.
First keep a copy of what is there now:

    sudo dd if=<sd> of=sd-head.bin bs=1M count=16

Then:

    sudo hwtool boot write-bootloader --target <sd>                    # must refuse
    sudo hwtool boot write-bootloader --target <sd> --allow-booted-device --dry-run
    sudo hwtool boot write-bootloader --target <sd> --allow-booted-device

Reboot. Pass: the first command refuses and names `--allow-booted-device`, the
dry run shows one `dd` line writing `u-boot-rockchip.bin` at 32 KiB, and the
board boots afterwards.

On the ROCK 4D the boot ROM never starts U-Boot from the SD card (it uses the
one in SPI flash), so this only checks the write itself. On the CM5-IO it is
the U-Boot that starts. If the CM5-IO does not boot, start it from the second
SD card (with no bootable eMMC) and put the copy back on the first card:

    sudo dd if=sd-head.bin of=/dev/<first card> bs=1M seek=0 count=16 conv=notrunc,fsync

### D5. SPI flash (ROCK 4D)

First keep a copy of the SPI flash, and store it off the board as well:

    sudo dd if=/dev/mtd0 of=spi-backup.bin
    sha256sum spi-backup.bin

Then:

    sudo hwtool boot write-bootloader --target spi --dry-run
    sudo hwtool boot write-bootloader --target spi

Reboot with the SD card inserted. Pass: the dry run's title and command name
`/dev/mtd0` (`flashcp -v -p .../u-boot-rockchip-spi.bin /dev/mtd0`), `flashcp`
reports verifying, and the board starts from SPI U-Boot and then the card.

If it does not start: Maskrom, then Roxora Imager C7 writes the release's SPI
bootloader. Or, if the board still boots Linux from some medium:
`sudo flashcp -v spi-backup.bin /dev/mtd0`.

On the CM5-IO the same command must refuse: its U-Boot package has no SPI
writer.

### D6. Move the system to eMMC

Keep a copy of the start of the eMMC (where a bootloader would be):

    sudo dd if=<emmc> of=emmc-head.bin bs=1M count=16

Then:

    sudo hwtool boot migrate --target <emmc> --dry-run
    sudo hwtool boot migrate --target <emmc>          # type yes

Check in the dry run that "Check the copy can boot" comes before the U-Boot
write. Power off, remove the SD card, power on. Then:

    findmnt /                     # <emmc>p1
    cat /etc/fstab                # UUID of <emmc>p1
    cat /boot/armbianEnv.txt      # rootdev=UUID of <emmc>p1
    hwtool info                   # eMMC is the running system

Pass: the board boots from the eMMC without the SD card, and the SD card
still holds the old system. On the ROCK 4D U-Boot (in SPI flash) starts the SD
card before the eMMC, so the card boots again when inserted. On the CM5-IO the
boot ROM prefers the eMMC; to boot the card again, blank the eMMC boot area as
in D7.

### D7. Move the system to NVMe

Blank the eMMC first, so the board does not start the D6 copy. On the
system that is running now (the eMMC copy from D6), zero only the U-Boot
area, 32 KiB to 16 MiB; the partition after it is left alone:

    sudo dd if=/dev/zero of=<emmc> bs=512 seek=64 count=32704 conv=fsync

Power off, insert the SD card, power on: with no U-Boot on the eMMC the
CM5-IO's boot ROM goes on to the SD card, and the ROCK 4D starts the card as
before. Check with `hwtool info` that the SD card is the running system, then
remove the eMMC's partition table so U-Boot does not find the old copy there:

    sudo wipefs -a <emmc>

ROCK 4D (U-Boot in SPI flash):

    sudo hwtool boot migrate --target /dev/nvme0n1 --write-spi --dry-run
    sudo hwtool boot migrate --target /dev/nvme0n1 --write-spi             # type yes

Power off, remove the SD card, power on. Pass: `findmnt /` shows
`/dev/nvme0n1p1`.

CM5-IO (no SPI writer): run the same without `--write-spi`. The board then
needs a U-Boot on eMMC or SD that looks for `/boot` on NVMe. Record which
device boots with the SD card removed and with it inserted; the result decides
whether hwtool offers NVMe on this board.

### D8. NPU and charsiu via hwtool

Run this on the ROCK 4D after D3, on the edge kernel. It checks what hwtool
reports about the NPU on both kernel branches and that it installs and
removes charsiu. It does not download a model (B8 covers running charsiu).
If charsiu is installed from B8, remove it first: `sudo apt remove charsiu`.

    hwtool npu status                                       # record
    hwtool --json npu status > npu-edge.json

Pass: the verdict is "NPU ready for charsiu (sudo hwtool npu
install-charsiu)"; `rocket` is listed with its module file and "loaded";
two NPU nodes, `/soc/npu@27700000` and `/soc/npu@27708000`,
`rockchip,rk3576-rknn-core`, status `okay`; `/dev/accel/accel0` with its
mode and group; charsiu "not installed, 0.1.0 available from
http://apt.armbian.com noble/noble-utils ...".

    sudo hwtool npu install-charsiu --dry-run                # record
    sudo hwtool npu install-charsiu                          # type yes
    hwtool npu status

Pass: the dry run shows one `Inst charsiu` line under "apt resolves" and
nothing else installed or removed, and a note to use `charsiu pull`; after
the install the status says "NPU ready; charsiu 0.1.0 is installed".

Then the vendor branch, as in D3 (with `--keep-old`):

    sudo hwtool kernel switch vendor --keep-old --dry-run   # record

Pass: the dry run notes "charsiu 0.1.0 is installed. It needs the edge
kernel's rocket driver and will not work on the vendor branch until you go
back". Switch, reboot, then:

    hwtool npu status                                       # record

Pass: the verdict starts with "vendor kernel: charsiu needs the edge
kernel's rocket driver"; `rknpu` is listed (built in or as a module) and
`rocket` is not in this kernel; `sudo hwtool npu install-charsiu --dry-run`
refuses with the same reason. Go back:

    sudo hwtool kernel revert                               # type yes

Reboot. `hwtool npu status` shows the edge verdict again. Finally:

    sudo hwtool npu remove-charsiu --dry-run                 # record
    sudo hwtool npu remove-charsiu                           # type yes

Pass: the dry run shows one `Remv charsiu` line and notes that downloaded
models stay in /opt/charsiu/models; afterwards `dpkg -s charsiu` says it is
not installed.

On the CM5-IO run only the first command and record its output: whether
its device tree has enabled NPU nodes has not been checked.

### D9. Kernel headers

On the ROCK 4D (headers and the aic8800 DKMS module are in the image):

    hwtool kernel status                                    # record: DKMS modules
    sudo hwtool kernel headers remove --dry-run             # record

Pass: the dry run shows one `Remv linux-headers-...` line and warns that
the DKMS modules (aic8800) cannot be rebuilt on the next kernel update. Do
not remove them on the ROCK 4D. On the CM5-IO (no headers in the image):

    sudo hwtool kernel headers install --dry-run            # record
    sudo hwtool kernel headers install                      # type yes
    sudo hwtool kernel headers remove                       # type yes

Pass: install shows `Inst linux-headers-edge-rockchip64` and nothing
removed; after it `dpkg -s linux-headers-edge-rockchip64` shows it
installed; after remove it is gone.

### D10. Holding the kernel packages

    sudo hwtool kernel hold                                 # type yes
    apt-mark showhold                                       # record
    sudo hwtool kernel switch vendor --dry-run              # must refuse
    sudo apt update && apt list --upgradable 2>/dev/null | grep -E 'linux-|armbian-firmware'
    sudo hwtool kernel unhold                               # type yes

Pass: `apt-mark showhold` lists the image, dtb, U-Boot (and headers and
firmware where installed) packages; `hwtool kernel status` says "Held
packages: ..."; the switch refuses and names `hwtool kernel unhold`; after
unhold `apt-mark showhold` is empty.

### D11. Boot options

    hwtool bootenv show                                     # record
    cat /proc/cmdline                                       # record

Pass: the "Kernel command line" that `bootenv show` prints matches
`/proc/cmdline`, except that `ubootpart=` shows a placeholder instead of the
partition's PARTUUID.

    sudo hwtool bootenv set verbosity=7                     # type yes
    sudo hwtool bootenv set extraargs=hwtool.test=1         # type yes

Reboot. Pass: `/proc/cmdline` contains `loglevel=7` and `hwtool.test=1`.
Then:

    sudo hwtool bootenv set 'extraargs=a;b'                 # must refuse
    sudo hwtool bootenv set rootdev=/dev/sda1               # must refuse
    sudo hwtool bootenv unset verbosity                     # type yes
    sudo hwtool bootenv unset extraargs                     # type yes

Reboot. Pass: `loglevel=1` again, `hwtool.test=1` gone, and backups of
each change are in `/var/backups/hwtool/`.

### D12. CPU frequency

    hwtool cpu show                                         # record

Pass: two policies, policy0 "Cortex-A53" CPUs 0-3 and policy4
"Cortex-A72" CPUs 4-7, with their governors and frequency lists.

    sudo hwtool cpu set --policy policy4 --max 1800000 --dry-run   # record
    sudo hwtool cpu set --policy policy4 --max 1800000            # type yes
    cat /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq  # 1800000

Reboot. Pass: `scaling_max_freq` is still 1800000 and
`systemctl status hwtool-cpufreq.service` shows it ran without errors.
Then:

    sudo hwtool cpu set --policy policy0 --governor performance --dry-run   # warns about heat
    sudo hwtool cpu reset                                   # type yes

Reboot. Pass: `scaling_max_freq` of policy4 is back to its top value and
`/etc/hwtool/cpufreq.conf` is gone.

### D13. User overlay from a file

Use the D2 overlay source (`roxora-test.dtso`); if D2 left it installed,
remove it first with `sudo hwtool overlays remove roxora-test`.

    sudo hwtool overlays add roxora-test.dtso --dry-run     # record
    sudo hwtool overlays add roxora-test.dtso               # type yes

Pass: if `dtc` was missing the dry run first installs
`device-tree-compiler` and shows its `Inst` line; after the add
`/boot/overlay-user/roxora-test.dtbo` exists and `user_overlays=` names it.
Reboot; `cat /proc/device-tree/chosen/roxora-hwtool-test` prints ok. Then:

    sudo hwtool overlays remove roxora-test                 # type yes

Reboot. Pass: the property is gone, and the dtbo is kept in
`/var/backups/hwtool/<time>/boot/overlay-user/`.

### D14. Move the system to a USB drive (ROCK 4D)

Use a USB 3 drive with nothing on it you want to keep, in a blue USB 3 port.
As for D7, blank the eMMC and remove any bootable NVMe drive first: U-Boot
checks the SD card, the eMMC, SCSI and NVMe before USB.

    hwtool info                                             # the drive is listed as usb
    sudo hwtool boot migrate --target /dev/sda --dry-run    # must refuse: needs --write-spi
    sudo hwtool boot migrate --target /dev/sda --write-spi --dry-run   # record
    sudo hwtool boot migrate --target /dev/sda --write-spi  # type yes

Power off, remove the SD card, power on. Pass: `findmnt /` shows
`/dev/sda1`. Record the serial log lines where U-Boot scans and finds the
USB drive.

On the CM5-IO the same command must refuse with "needs U-Boot in SPI flash,
and this board's U-Boot package has no SPI writer". A SATA drive (through an
adapter that shows as SATA, not USB) must refuse on both boards with "built
without SATA support".

### D15. Swap file

Do it on both boards, booted from the SD card after a fresh first boot, so
the swap file is the one cloud-init made.

    hwtool swap show                                        # record
    swapon --show; grep swap /etc/fstab                     # record

Pass: `swap show` lists `/swap.img` as active with the size `swapon --show`
prints, its fstab line (cloud-init 25.1 and later write it without
`comment=cloudconfig`; record which), the memory size, and "zram: in use
(armbian-zram-config)" with `/dev/zram0` active at priority 5.

    sudo hwtool swap set 1G --dry-run                       # record
    sudo hwtool swap set 1G                                 # type yes
    swapon --show; ls -l /swap.img; grep -c swap.img /etc/fstab

Pass: the plan runs `swapoff /swap.img` first; afterwards `/swap.img` is
active with 1 GiB, mode `-rw-------`, and fstab has exactly one line for it,
`/swap.img none swap sw,comment=cloudconfig 0 0`. `/etc/fstab` is backed up
in `/var/backups/hwtool/<time>/etc/fstab`. Reboot. Pass: `swapon --show`
shows `/swap.img` again and `grep -c swap.img /etc/fstab` is still 1.

    sudo hwtool swap set 64G --dry-run                      # must refuse
    sudo hwtool swap set 9G --dry-run                       # must refuse on a 4 GiB board

Pass: the first says it does not fit or leaves less than a quarter of the
file system free; the second says it is more than twice the memory and names
`--force`.

    sudo hwtool swap swappiness 20                          # type yes

Reboot. Pass: `sysctl vm.swappiness` prints 20 and
`/etc/sysctl.d/60-hwtool-swap.conf` has `vm.swappiness = 20`. Set it back with
`sudo hwtool swap swappiness 60`.

    sudo hwtool swap off                                    # type yes

Pass: `swapon --show` lists only zram, `/swap.img` is gone, fstab has no
line for it. Reboot and check the same (no swap unit fails:
`systemctl --failed` is empty). Finally `sudo hwtool swap set 2G` to leave a
swap file again.

Optional, the memory check: with a 1 GiB swap file, fill memory until
`swapon --show` reports several hundred MiB used on `/swap.img` (for example
`stress-ng --vm 1 --vm-bytes 90% --timeout 60s` in a second terminal, while
it runs), then `sudo hwtool swap set 2G --dry-run`. Pass: if
MemAvailable is less than the used swap plus 256 MiB, it refuses with "cannot
be switched off now".

### D16. Pin header interfaces

Use the device names `hwtool info` and the commands below print; they are
not fixed.

    hwtool interfaces list                                  # record

Pass: ROCK 4D lists 20 functions, CM5-IO 10, each with header pins, and
"Pins the board uses itself" (ROCK 4D 8, 10, 27, 28; CM5-IO 8, 10, 16, 18,
28).

Conflicts (ROCK 4D):

    sudo hwtool interfaces enable spi1-m0 i2c9-m1 --dry-run  # must refuse: share pins
    sudo hwtool interfaces enable i2c8-m1 i2c8-m2 --dry-run  # must refuse: same controller

I2C, SPI, UART and PWM at once (ROCK 4D; these share no pins):

    sudo hwtool interfaces enable i2c8-m2 spi1-m0 uart4-m1 pwm1-ch3-m1 --dry-run   # record
    sudo hwtool interfaces enable i2c8-m2 spi1-m0 uart4-m1 pwm1-ch3-m1             # type yes

Reboot. Pass:

- `ls /dev/i2c-8` exists; with a device on pins 16 (SCL) and 18 (SDA),
  `sudo i2cdetect -y 8` (package `i2c-tools`) shows its address;
- `ls /dev/spidev1.*` shows `spidev1.0` and `spidev1.1`; with a jumper from
  pin 19 (MOSI) to pin 21 (MISO), a transfer reads back what it sent (for
  example `spidev_test -D /dev/spidev1.0 -v` if available, or a short
  Python `spidev` script);
- with a jumper from pin 11 (TX) to pin 15 (RX):
  `stty -F /dev/ttyS4 115200 raw -echo; (sleep 1; echo roxora >/dev/ttyS4) & timeout 3 cat /dev/ttyS4`
  prints `roxora` (record the device if it is not ttyS4: `dmesg | grep ttyS`);
- `ls /sys/class/pwm/` has a new `pwmchip`; record
  `dmesg | grep -i pwm` and `cat /sys/kernel/debug/pinctrl/*/pinmux-pins | grep -i pwm1`.

Then `sudo hwtool interfaces list` marks the four as `[x]`, and the
functions that share their pins say "cannot be enabled with ... (enabled)".

    sudo hwtool interfaces disable i2c8-m2 spi1-m0 uart4-m1 pwm1-ch3-m1    # type yes

Reboot. Pass: the devices above are gone and `user_overlays=` in
`/boot/armbianEnv.txt` no longer names them.

1-Wire (both boards, if a DS18B20 or another 1-Wire device is at hand):
wire its data line to pin 7 with a 4.7 kOhm pull-up to 3.3 V (pin 1), then

    sudo hwtool interfaces enable w1-gpio-pin7              # type yes; reboot

Pass: `ls /sys/bus/w1/devices/` shows the device (for a DS18B20, a `28-...`
directory whose `temperature` is plausible). Disable it again.

CM5-IO: repeat the I2C and UART part with `i2c3-m0` (pins 5 SCL, 3 SDA)
and `uart3-m0` (pins 23 TX, 19 RX; `/dev/i2c-3` and `/dev/ttyS3` from the DTB aliases), recording what you see.

### D17. Bootloader version and update

    sudo hwtool boot version                                # record
    hwtool info | tail                                      # same summary

Pass: one line per SPI flash and SD/eMMC device, each "up to date",
"older", "newer", "different" or "none", with the version string, and
"(the board starts from here)" on the device the board really starts from
(check the first U-Boot line on the serial console after a reboot: its
version string matches that line).

    sudo hwtool boot update-bootloader --dry-run            # record

Pass: if that device is up to date it refuses with "already has the
installed U-Boot"; otherwise the plan is the same as
`write-bootloader --allow-booted-device` for that device. If it differs on
your board, run it (type yes), reboot, and run `boot version` again. Pass:
"up to date" and the serial console shows the package's version.

Also in the GTK app, Boot page, "Bootloader Version": Check asks for the
password and fills the same states; Update appears only when the start
device differs.

### D18. Boot order (ROCK 4D; CM5-IO only the refusal)

    sudo hwtool boot order show                             # record

Pass on the ROCK 4D: the built-in order `mmc0 mmc1 scsi nvme usb pxe dhcp`,
the environment at `/dev/mtd0` 0xc00000, and "Saved boot order: none" on a
board that never saved one. On the CM5-IO: "cannot be changed" with the
reason naming the U-Boot build setting.

ROCK 4D, with U-Boot in SPI flash and a bootable SD card:

    sudo hwtool boot order set nvme mmc0 mmc1 scsi usb pxe dhcp --dry-run   # record
    sudo hwtool boot order set nvme mmc0 mmc1 scsi usb pxe dhcp             # type yes
    sudo fw_printenv -c /etc/hwtool/fw_env.config boot_targets

Pass: it prints the new order. Reboot with the serial console attached.
Pass: U-Boot no longer prints a bad-CRC or "using default environment"
warning, scans nvme before mmc0 (record those lines), and with no NVMe
system still boots the SD card.

    sudo hwtool boot order reset                            # type yes

Reboot. Pass: U-Boot prints that it uses the default environment, and
`hwtool boot order show` reports no saved order.

### D19. LEDs, temperatures, fan

    hwtool leds list                                        # record
    sudo hwtool leds set <the heartbeat LED> none           # type yes

Pass: that LED stops blinking at once, and its section in
`/etc/armbian-leds.conf` has `trigger=none`. Pull the power (no clean
shutdown) and power on. Pass: it stays off. Set it back with
`sudo hwtool leds set <LED> heartbeat`.

    hwtool fan show                                         # record

Pass: every thermal zone with a plausible temperature and its trip points,
"Fan: none" on both boards, and the notes that there is no pwm-fan node and
that trips cannot be changed.

### D20. Wi-Fi country (ROCK 4D)

    hwtool wifi country                                     # record
    sudo hwtool wifi country DE --dry-run                   # record
    sudo hwtool wifi country DE                             # type yes
    iw reg get                                              # record

Pass: `iw reg get` shows `global` country DE; the aic8800 phy is listed as
self-managed with country 00 (the plan warned about this).
`/etc/modprobe.d/hwtool-wifi.conf` has `options cfg80211
ieee80211_regdom=DE`. Reboot. Pass: `iw reg get` global is still DE.

Untested option, record the result either way:

    sudo hwtool wifi country DE --aic8800-follow-country    # type yes; reboot
    iw reg get; dmesg | grep -iE 'aic|regdom|CAUTION'

Record whether the phy is still self-managed and which country it shows,
whether "CAUTION: USING PERMISSIVE CUSTOM REGULATORY RULES" is gone, and
whether Wi-Fi still scans and connects (`nmcli dev wifi list`). Then
`sudo hwtool wifi country DE` without the option and reboot, to go back to
the driver's own rules.

### D21. PWM fan

ROCK 4D: a 5 V fan on the 2-pin fan connector (mind the polarity).
CM5-IO: the kit's fan on CN32. Nothing on header pin 28 of the CM5-IO.

    hwtool fan show                                         # record; Fan: none
    sudo hwtool fan enable --dry-run                        # record
    sudo hwtool fan enable                                  # type yes

Pass: the plan writes `/etc/hwtool/fan.dtso`, compiles it with `dtc -@`
(installing `device-tree-compiler` first if missing), installs
`/boot/overlay-user/hwtool-fan.dtbo`, adds `hwtool-fan` to `user_overlays`
and says a reboot is needed. On the CM5-IO, `hwtool interfaces list` now shows
pin 28 as used by the fan and `pwm2-ch6-m3` as blocked by it.

Reboot.

    hwtool fan show                                         # record
    ls /sys/class/hwmon/*/name | xargs grep -l pwmfan
    cat /sys/class/thermal/thermal_zone*/type               # find package-thermal

Pass: "Fan: yes" with a speed; a `pwm-fan` cooling device with max state 4;
package-thermal lists four `active` trips at 50, 60, 70 and 80 C plus its
critical trip. Below 50 C the fan is off.

    sudo hwtool fan set 100                                 # type yes; the fan runs at full speed
    sudo hwtool fan set 30                                  # slower
    sudo hwtool fan auto                                    # back to the curve

Pass: the speed follows each command; `fan show` says the governor is
`user_space` after `set` and `step_wise` after `auto`.

Load the SoC (for example `stress-ng --cpu 8 --timeout 300s`) and record
every 10 s `cat /sys/class/thermal/thermal_zone0/temp` (or the package zone)
and `hwtool fan show | grep Fan:`. Pass: the fan steps up at about 50, 60,
70 and 80 C and steps down about 5 C lower after the load stops.

    sudo hwtool fan enable --curve 45:40,65:100             # type yes; reboot

Pass: two active trips at 45 and 65 C, cooling-levels 0 102 255.

    sudo hwtool fan disable                                 # type yes; reboot

Pass: no pwm-fan device, `user_overlays` without `hwtool-fan`, pin 28 free
again on the CM5-IO.

Optional, a fan on a header PWM pin through a transistor (ROCK 4D, pin 35):
`sudo hwtool fan enable --pwm pwm1-ch3-m1`, reboot, same checks.

UEFI image: `sudo hwtool fan enable --dry-run` must refuse with the
"UEFI image:" reason; `hwtool fan show` works.

The connectors have no tachometer line, so there is no RPM reading.

## Part E: UEFI image

For `roxora-generic-rk3576-uefi-<release>-edge-<version>.img.xz`, on a board with
UEFI firmware (edk2-rk3576 on the ROCK 4D or the CM5-IO). The image is
marked `hardware-tested` when E1 to E7 pass on at least one board; name the
board and the firmware version in the report. Parts C and D do not apply:
Roxora Imager and hwtool deal with the U-Boot boot method.

### E1. Firmware

Install the firmware as its project describes (on the ROCK 4D into SPI NOR,
on the CM5-IO onto eMMC or SD). Pass: the firmware's front page appears on
HDMI and its messages on the serial console (1500000 baud). Note the firmware
version and its device tree settings (ACPI or device tree; on edk2-rk3576
the ROCK 4D defaults to device tree, the CM5-IO to both).

### E2. Write and boot

Write the image to a USB drive or an NVMe drive (an SD card also works on
the ROCK 4D, and on the CM5-IO when the firmware is on the eMMC), as in A3.
Power on.

Pass, on the serial console: the GRUB menu appears and counts down from 3
seconds, `Loading Linux ...` and `Loading initial ramdisk ...` are printed,
the kernel log follows, and a `login:` prompt appears on the serial console
and on HDMI. B2, B3 and B4 pass; the host name is `generic-rk3576-uefi`.

### E3. The kernel uses the firmware's device tree

    cat /proc/device-tree/model; echo
    cat /proc/cmdline
    ls /sys/firmware/efi
    dmesg | grep -i -e 'efi:' -e acpi | head -20

Pass: the model is the board's, `/proc/cmdline` has `earlycon console=ttyS0,1500000n8
console=tty1`, `/sys/firmware/efi` exists, and the kernel says ACPI is
disabled or not used. Ethernet, USB, NVMe and HDMI work as in B3.

### E4. Update and GRUB

Do B5. Then:

    grep -E '^[[:space:]]*(linux|initrd|devicetree)' /boot/grub/grub.cfg
    ls -l /boot/efi/EFI/BOOT/ /boot/efi/EFI/

Pass: grub.cfg names the kernel B5 installed, with no `devicetree` line;
`EFI/BOOT/BOOTAA64.EFI` is present. If B5 updated GRUB (`grub-efi-arm64`),
also `EFI/ubuntu/grubaa64.efi`, and the update printed no `efibootmgr` or
NVRAM error.

### E5. Reboot into the new kernel

    sudo reboot
    uname -r

Pass: GRUB starts the new kernel, `uname -r` shows the version from B5.

### E6. Roll back the kernel

As B7, without the `linux-dtb` package (it is not installed on this image):

    sudo apt install --allow-downgrades linux-image-edge-rockchip64=<older>
    sudo reboot
    uname -r

Pass: the GRUB menu offers the older kernel and the board boots it. Then
`sudo apt full-upgrade` and one more reboot return it to the current kernel.

### E7. Armbian's device tree through the firmware override

After E4 and E5, check that the device trees on the EFI system partition are
the running kernel's:

    ls /boot/efi/dtb/rockchip/
    for f in /boot/efi/dtb/rockchip/*.dtb; do
        cmp "$f" "/usr/lib/linux-image-$(uname -r)/rockchip/${f##*/}" || echo "DIFFERS: $f"
    done

Pass: the board's file (`rk3576-rock-4d.dtb`, `rk3576-armsom-cm5-io.dtb`) is
there and no line says `DIFFERS`.

Turn the override on as in
[install.md](install.md#using-armbians-device-tree-instead-of-the-firmwares)
and reboot. Pass: the board boots to the login prompt, B3 passes (Ethernet,
USB, NVMe, HDMI), and `cat /proc/device-tree/model` shows the board. Note
anything that works with one device tree and not the other. Then set the
option back to Disabled, reboot, and check that E3 passes again.

### E8. hwtool on the UEFI image

On a board booted from the `generic-rk3576-uefi` image (edk2-rk3576), first
with the firmware's own device tree, then with its "DTB override" option
pointing at Armbian's DTB for the board on the ESP.

    hwtool --version                                        # 0.1.0 is preinstalled; record
    hwtool info                                             # record
    hwtool uefi status                                      # record

Pass: "UEFI image (GRUB), device tree from the firmware", the firmware
vendor and version (from DMI; record if they show "unknown"), the model and
"SoC: rk3576" from the device tree, and the number of DTBs under
`/boot/efi/dtb/rockchip/`. No U-Boot package is listed.

These must refuse with a reason that starts with "UEFI image:" and change
nothing:

    hwtool overlays list
    hwtool interfaces list
    hwtool bootenv show
    sudo hwtool boot version
    sudo hwtool boot write-bootloader --target spi --dry-run
    sudo hwtool boot update-bootloader --dry-run
    hwtool boot order show
    sudo hwtool kernel switch vendor --dry-run
    sudo hwtool boot migrate --target /dev/nvme0n1 --dry-run   # any device hwtool info lists

These must work as on the other images: `hwtool kernel status` (branch
edge only), `sudo hwtool kernel hold --dry-run`, `hwtool cpu show`,
`hwtool leds list`, `hwtool fan show`, `hwtool wifi country`,
`hwtool swap show`, `hwtool npu status`.

Now enable the firmware's DTB override (edk2 setup menu; record the menu
path and the file chosen), boot, and run `hwtool uefi status` again. Pass:
"device tree from the firmware's DTB override (/boot/efi/dtb/rockchip/<file>)"
and a similarity of 98% or more; with the override off it said "firmware"
with a lower share (record both numbers, they set the threshold).

In the GTK app: the Board and Boot pages show "UEFI Firmware" with the
firmware and the device tree source; Overlays and Pin Header show "Not Used
on UEFI Images" with the reason. Take a screenshot of each.

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
