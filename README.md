# Roxora build

Roxora builds images for Rockchip boards that pair Armbian's kernel, device
tree, U-Boot and firmware with a stock Ubuntu userspace. Only hardware
packages come from Armbian; userspace updates come from the Ubuntu archive.

This repository holds the build: an Armbian extension, a wrapper that drives a
pinned [armbian/build](https://github.com/armbian/build) checkout, and a check
that runs on every image.

Website: https://roxora-os.github.io

## Status

Early. Images are built and checked in CI only; none has been tested on a
board yet, and there are no releases to download. Every image stays a
pre-release until it passes the [hardware test](docs/hardware-test.md).

## Supported boards

From [`boards.conf`](boards.conf):

| Board | SoC | Ubuntu | Kernel branch | Status |
| --- | --- | --- | --- | --- |
| Radxa ROCK 4D | RK3576 | 24.04 (noble) | edge | ci-only |
| ArmSoM CM5-IO | RK3576 | 24.04 (noble) | edge | ci-only |

`ci-only` means the image builds and passes `verify/verify-image.sh` in CI;
nobody has booted it yet. Images are minimal server images. Log in as
`ubuntu` with the password `ubuntu`; you must change it at the first login.

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

- [Architecture](docs/architecture.md): the two layers, apt pinning, the boot
  method, what Roxora does not do.
- [What Roxora keeps from Armbian](docs/bsp-classification.md): every file
  and change, and the reason for it.
- [Adding a board](docs/adding-a-board.md)
- [Hardware test](docs/hardware-test.md)
- [Release contract](docs/release-contract.md): file names, release files,
  the catalog.
- [FAQ](docs/faq.md)

## Contact

Issues and pull requests: https://github.com/roxora-os/build

Email: oss@gahingwoo.com

## License

GPL-2.0, see [LICENSE](LICENSE).

Roxora is based on Ubuntu and Armbian. It is not affiliated with or endorsed
by Canonical, the Armbian project or Rockchip.
