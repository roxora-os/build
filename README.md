# Roxora build

Roxora builds images for Rockchip boards that pair Armbian's kernel, device
tree, U-Boot and firmware with a stock Ubuntu userspace. Only hardware
packages come from Armbian; userspace updates come from the Ubuntu archive.

This repository holds the build: an Armbian extension, a wrapper that drives a
pinned [armbian/build](https://github.com/armbian/build) checkout, and a check
that runs on every image.

Website: https://roxora-os.github.io

## Status

Releases are published on the
[releases page](https://github.com/roxora-os/build/releases). Their images
are built and checked in CI, and the UEFI images also boot in QEMU; a tag
`vYYYY.MM.N-beta.N` makes a beta (a GitHub pre-release) instead. Images that
have also passed the [hardware test](docs/hardware-test.md) on a board are
marked as tested: so far the Radxa ROCK 4D with Ubuntu 26.04.

Images include the command line part of
[hwtool](https://github.com/roxora-os/hwtool), Roxora's hardware tool
(device tree overlays, kernel branch, bootloader, NPU and more), pinned in
[`userpatches/roxora/hwtool.conf`](userpatches/roxora/hwtool.conf).
They also include Roxora's wallpapers (by DavidQyn with Ga Hing Woo,
CC BY-SA 4.0, from [roxora-os/design](https://github.com/roxora-os/design)),
in a package built from a pinned commit
([`userpatches/roxora/wallpapers/`](userpatches/roxora/wallpapers/)). They
show only once a GNOME desktop is installed: in the background list in
Settings, with Facet as the default.

## Supported boards

From [`boards.conf`](boards.conf):

| Board | SoC | Ubuntu | Kernel branch | Status |
| --- | --- | --- | --- | --- |
| Radxa ROCK 4D | RK3576 | 24.04 (noble) | edge | ci-only |
| ArmSoM CM5-IO | RK3576 | 24.04 (noble) | edge | ci-only |
| Radxa ROCK 4D | RK3576 | 26.04 (resolute) | edge | ci-only |
| ArmSoM CM5-IO | RK3576 | 26.04 (resolute) | edge | ci-only |
| RK3576 boards with UEFI firmware (`generic-rk3576-uefi`) | RK3576 | 24.04 (noble) | edge | ci-only |
| RK3576 boards with UEFI firmware (`generic-rk3576-uefi`) | RK3576 | 26.04 (resolute) | edge | ci-only |
| RK3576 boards with UEFI firmware (`generic-rk3576-uefi`) | RK3576 | 24.04 (noble) | vendor | ci-only |
| RK3576 boards with UEFI firmware (`generic-rk3576-uefi`) | RK3576 | 26.04 (resolute) | vendor | ci-only |

The `generic-rk3576-uefi` image is for any RK3576 board that runs UEFI firmware,
such as [edk2-rk3576](https://github.com/gahingwoo/edk2-rk3576). It carries
no U-Boot: the firmware starts Ubuntu's GRUB from the image and passes the
board's device tree to the kernel. See
[Installing Roxora](docs/install.md#rk3576-boards-with-uefi-firmware).

`ci-only` means the image builds and passes `verify/verify-image.sh` in CI;
nobody has booted it yet. Images are minimal server images. Log in as
`roxora` with the password `roxora`; you must change it at the first login.

## Building

Armbian's build needs root (it uses sudo) or Docker. CI builds on GitHub's
`ubuntu-24.04-arm` runners. Run:

    ./build.sh BOARD=radxa-rock-4d BRANCH=edge RELEASE=noble

`build.sh` fetches armbian/build at the commit in [`armbian.ref`](armbian.ref)
into `cache/`, adds the extension, and writes
`output/roxora-<board>-<release>-<branch>-<version>.img.xz` and its `.sha256`
file. `./build.sh --help` lists the options. Only combinations listed in
`boards.conf` are accepted.

To check an image:

    sudo verify/verify-image.sh output/roxora-radxa-rock-4d-noble-edge-dev.img.xz

## Documentation

- [Installing Roxora](docs/install.md): download, the ROCK 4D bootloader,
  boards with UEFI firmware, writing the image, the first login.
- [Architecture](docs/architecture.md): the two layers, apt pinning, the boot
  methods (U-Boot and UEFI), what Roxora does not do.
- [What Roxora keeps from Armbian](docs/bsp-classification.md): every file
  and change, and the reason for it.
- [Adding a board](docs/adding-a-board.md)
- [Hardware test](docs/hardware-test.md)
- [Release contract](docs/release-contract.md): file names, release files,
  the catalog.
- [FAQ](docs/faq.md)

## Contact

Issues and pull requests: https://github.com/roxora-os/build

Report problems with a Roxora image here, including kernel and board
problems. Report a problem to Armbian only if it also happens on an official
Armbian image.

Email: oss@gahingwoo.com

## License

GPL-2.0, see [LICENSE](LICENSE).

Roxora is based on Ubuntu and Armbian. It is not affiliated with or endorsed
by Canonical, the Armbian project or Rockchip.
