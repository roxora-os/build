# Adding a board

A board can be added when Armbian already supports it. Roxora adds no board
support of its own (see [architecture.md](architecture.md)); adding a board
means checking what Armbian puts into its image and making sure only the
hardware layer stays.

## 1. Check the board exists in Armbian at the pinned commit

Use the armbian/build commit in [`armbian.ref`](../armbian.ref), not Armbian's
current main branch. `./build.sh` fetches it into `cache/armbian-build`, or
check it out yourself:

    git clone https://github.com/armbian/build armbian-build
    git -C armbian-build checkout "$(cat armbian.ref)"

In that checkout:

- `config/boards/<board>.conf` (standard support) or `.csc` (community
  support) must exist. `.wip`, `.eos` and `.tvb` boards are not candidates.
- `KERNEL_TARGET` in that file must list the branch you want (`edge` first).
- Note `BOARDFAMILY`, the boot method (`BOOTSCRIPT` and `BOOTENV_FILE`, or
  `SRC_EXTLINUX`) and every `enable_extension` line. Roxora's checks assume
  the U-Boot boot script method the current boards use; a board that boots
  differently needs a closer look before it is added.
- Check which packages Armbian's repository publishes for the board and branch
  (`linux-u-boot-<board>-<branch>`, the kernel and dtb of its family). Roxora
  takes updates of these from Armbian. If a package is not published, for
  example the U-Boot of a community board, the image still works but that
  package never gets updates.

`./compile.sh config-dump-json BOARD=<board> BRANCH=<branch> RELEASE=noble
BUILD_MINIMAL=yes BUILD_DESKTOP=no` prints the resolved configuration and
runs without root.

## 2. Add the board to boards.conf

Add one line to [`boards.conf`](../boards.conf):

    # BOARD          BRANCH  RELEASE  STATUS   SOC     VENDOR  NAME
    radxa-rock-4d    edge    noble    ci-only  rk3576  Radxa   Radxa ROCK 4D

- `BOARD` is Armbian's board name (the file name without extension).
- `BRANCH` is the Armbian kernel branch, `RELEASE` the Ubuntu codename.
- `STATUS` is `ci-only` for a new board. It becomes `hardware-tested` only
  after [hardware-test.md](hardware-test.md) has passed on the board.
- `SOC` is lower case (`rk3576`).
- `VENDOR` is the board maker as people write it, one word (`Radxa`); the
  imager and the website group boards by it.
- `NAME` is the name people know the board by, with the vendor
  (`Radxa ROCK 4D`); it is the rest of the line.

`build.sh`, the extension, the CI matrix and the website all read this file.

Add the board's BSP package to
[`verify/reference/allowlist`](../verify/reference/allowlist), the same way as
the existing ones:

    armbian-bsp-cli-<board>-<branch>  board support package, filtered to its hardware parts (docs/bsp-classification.md); built with the image

## 3. Check the board support package

[bsp-classification.md](bsp-classification.md) lists every file of the BSP
package of the current boards and says which layer it belongs to. A new board
can bring more. Look in the pinned armbian/build checkout for:

- Files copied into the BSP package. `packages/bsp/common` goes to every
  board and is already classified. Board and family files come from
  `config/optional/boards/<board>/_packages/bsp-cli/`,
  `config/optional/families/<family>/_packages/bsp-cli/` and from
  `family_tweaks_bsp` in the family file
  (`config/sources/families/<family>.conf` and the files it includes), which
  often copies from `packages/bsp/<dir>/`.
- Board or family hooks that write into the root filesystem outside any
  package: functions in the board file such as `post_family_tweaks__*`, and
  `family_tweaks` in the family file.
- Extensions the board enables, for example `radxa-aic8800` on the
  ROCK 4D, which builds the Wi-Fi driver with DKMS. Read each one: what it
  installs, from where, and whether it needs kernel headers.

Classify each new file or change the same way as bsp-classification.md:

- Hardware layer (needed to boot or to drive the board's hardware): keep
  it, and add a row to the "Kept" table.
- Distro layer (changes how Ubuntu looks or behaves): remove it. Paths in
  the BSP package go to
  [`bsp-remove.list`](../userpatches/roxora/bsp-remove.list); files written
  into the root filesystem go to
  [`rootfs-remove.list`](../userpatches/roxora/rootfs-remove.list). Add a row
  to the "Removed" table with the reason.
- An Ubuntu package file the board changes on purpose (rare): add it to
  [`keep-modified.list`](../userpatches/roxora/keep-modified.list) with a
  comment, and explain it in bsp-classification.md. Otherwise the extension
  restores it and the build fails if it cannot.

If the board needs kernel headers for a DKMS module, check that its extension
sets `INSTALL_HEADERS=yes`; the roxora extension turns headers off by default.
Headers are a hardware-layer package and are updated from Armbian with the
kernel.

When a file is hard to classify, compare the Roxora image with an image Armbian
builds from the same commit without the extension, and list the files that
differ.

## 4. Build in CI

Open a pull request with the changes. The [Build](../.github/workflows/build.yml)
workflow runs for changes to `boards.conf`, `userpatches/` and `verify/`, and
builds and verifies every line of `boards.conf`. It can also be started by
hand from the Actions tab. Images, verify output and Armbian's build logs are
uploaded as workflow artifacts.

A local build needs root (Armbian's build uses sudo) or Docker:

    ./build.sh BOARD=<board> BRANCH=<branch> RELEASE=noble

## 5. Verify the image

[`verify/verify-image.sh`](../verify/verify-image.sh) runs in CI after the
build. To run it yourself (root and an arm64 host):

    sudo verify/verify-image.sh output/roxora-<board>-noble-<branch>-dev.img.xz

Every line must say `PASS`. What to look at when one fails:

- `packages`: a package that is neither in Ubuntu's server image nor hardware
  layer. Find out what pulls it in. Allowlist it only with a reason, and only
  if it comes from the Ubuntu archive.
- `apt`: an Armbian package outside the hardware patterns is the candidate.
  The pin file is shared by all boards; do not widen it for one board without
  a discussion in an issue first.
- `files`: a removed path is back, or an Ubuntu file differs from its
  package. Usually a board hook from step 3 that is not handled yet.
- `boot`: the boot script, `armbianEnv.txt`, kernel, `uInitrd`, device tree or
  the bootloader at 32 KiB is missing or does not match the packages. On a
  UEFI image (`boot: UEFI`): the EFI system partition, GRUB or `grub.cfg`
  is not as described in
  [architecture.md](architecture.md#uefi-images).

## 6. Test on the board

Run every step of [hardware-test.md](hardware-test.md) on the board: flash,
serial console, first boot, network, warm boot, update from the archives,
reboot into a new kernel and roll back. Also check the hardware the board's
BSP files and extensions are for, for example the Wi-Fi interface after a
kernel update when its driver is built with DKMS.

Write down the board's boot order (which media the BootROM tries, and in what
order) in hardware-test.md if it differs from the boards already there.

Every new release starts with all its images marked `ci-only`. When the test
passes on a release's image, the maintainer runs the "Mark hardware-tested"
workflow for that release and board, which updates the release's catalog and
notes (see [release-contract.md](release-contract.md)). Set the board's
`STATUS` in `boards.conf` to `hardware-tested` at the same time, so the Boards
page shows it.

## A UEFI image for another SoC

A UEFI image is not for one board but for every board of a SoC that runs
UEFI firmware (see [architecture.md](architecture.md#uefi-images)). It has
its own name, `generic-<soc>-uefi`, and its own board file in
[`userpatches/config/boards/`](../userpatches/config/boards), because Armbian
has no such board. Everything UEFI images share is in
[`userpatches/roxora/uefi/board.inc`](../userpatches/roxora/uefi/board.inc).

1. Copy [`generic-rk3576-uefi.conf`](../userpatches/config/boards/generic-rk3576-uefi.conf)
   to `generic-<soc>-uefi.conf` and set:
   - `BOARD_NAME`;
   - `BOARDFAMILY`: the Armbian family whose `edge` kernel the SoC's boards
     use (`rk35xx` for RK3576, `rockchip-rk3588` for RK3588; at the pinned
     commit both give `linux-image-edge-rockchip64`, see
     `config/sources/families/include/rockchip64_common.inc`);
   - `BOOT_SOC`: the SoC, lower case;
   - `ROXORA_UEFI_SERIAL`: the kernel console on the SoC's debug UART, as
     `console=` takes it (`ttyS0,1500000n8` on RK3576, `ttyS2,1500000n8` on
     RK3588).
2. Add one line per Ubuntu release to `boards.conf`, with `VENDOR`
   `Generic` and a `NAME` that says which boards it is for:

       generic-rk3588-uefi      edge    noble    ci-only  rk3588  Generic RK3588 boards with UEFI firmware

3. Add `armbian-bsp-cli-generic-<soc>-uefi-edge-grub` to
   [`verify/reference/allowlist`](../verify/reference/allowlist) (Armbian adds
   `-grub` to the BSP package name of GRUB images).
4. Check the family file for anything that assumes U-Boot beyond the boot
   script and its environment, which `board.inc` already turns off.

CI builds the image, runs `verify-image.sh` on it (the UEFI checks are
chosen because the image has an EFI system partition) and boots it in QEMU.
Then test it on at least one board with the firmware, following
[hardware-test.md](hardware-test.md#part-e-uefi-image).
