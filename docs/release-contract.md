# Release contract

This page describes what a Roxora release contains and how to read it. The
website, the Raspberry Pi Imager repository file and
[Roxora Imager](https://github.com/roxora-os/imager) all read releases
through this contract, so a change here is a change for all of
them.

## Versions and tags

- A version is `YYYY.MM.N`: the year and month of the release and a counter
  that starts at 0 within that month. Example: `2026.11.0`, then `2026.11.1`.
- The git tag is the version with a `v` in front: `v2026.11.0`.
- Pushing a tag of that form to `roxora-os/build` starts `release.yml`, which
  builds every line of `boards.conf`, verifies each image and publishes the
  GitHub release.

## Image files

One image per line of `boards.conf`:

    roxora-<board>-<release>-<branch>-<version>.img.xz

Example: `roxora-radxa-rock-4d-noble-edge-2026.11.0.img.xz`.

- `<board>` is the Armbian board name (`radxa-rock-4d`), or for a UEFI image
  `generic-<soc>-uefi` (`generic-rk3576-uefi`); `<release>` the Ubuntu codename (`noble`),
  `<branch>` the Armbian kernel branch (`edge`).
- The file is a whole-disk image compressed with xz. It is written as is to
  an SD card, USB drive, eMMC or NVMe. A board image has the bootloader
  inside it at 32 KiB. A UEFI image has none: it has a GPT with an EFI
  system partition, and the board's UEFI firmware, installed separately,
  starts GRUB from it.

## Files in each release

For every image:

| File | Content |
| --- | --- |
| `roxora-...img.xz` | The image. |
| `roxora-...img.xz.sha256` | `sha256sum` output for the image file, one line. |
| `roxora-...verify.txt` | The output of `verify/verify-image.sh` for that image. |
| `roxora-...-spi.img` | Only for boards that boot from SPI NOR (the ROCK 4D): the U-Boot SPI image from the same build as the disk image. It is written to the SPI flash, not to a card. UEFI images never have one. |
| `roxora-...-spi.img.sha256` | `sha256sum` output for the SPI image. |

Once per release:

| File | Content |
| --- | --- |
| `SHA256SUMS` | `sha256sum` output for every other file in the release. |
| `roxora-catalog.json` | The catalog described below. |

The images, SPI images, `SHA256SUMS` and `roxora-catalog.json` also carry a
build provenance attestation from the release workflow (from 2026.11.3 on),
checked with `gh attestation verify <file> --repo roxora-os/build`.

## Releases, betas and tested status

- A tag `vYYYY.MM.N` publishes a release: every image in it built and passed
  `verify-image.sh` in CI, and the UEFI images booted in QEMU
  (`verify/qemu-boot.sh`). A tag `vYYYY.MM.N-beta.N` publishes a beta, as a
  GitHub pre-release; its file names carry the same version, for example
  `roxora-radxa-rock-4d-resolute-edge-2026.12.1-beta.1.img.xz`.
- Each image carries a `status`:
  - `hardware-tested`: hardware-test.md passed on that board with this
    release's image.
  - `ci-only`: the image built and passed `verify-image.sh` in CI; nobody has
    booted it yet.
- The release notes list the images in each group. The "Mark
  hardware-tested" workflow changes an image's status, and can publish a
  beta as a release.

## Catalog

`roxora-catalog.json` is UTF-8 JSON. Consumers must ignore fields they do not
know, so fields can be added without a new schema number. Removing or changing
the meaning of a field increments `schema`.

    {
      "schema": 1,
      "release": {
        "tag": "v2026.11.0",
        "version": "2026.11.0",
        "date": "2026-11-20",
        "prerelease": false,
        "url": "https://github.com/roxora-os/build/releases/tag/v2026.11.0",
        "armbian_ref": "<full armbian/build commit SHA the images were built from>"
      },
      "images": [
        {
          "board": "radxa-rock-4d",
          "board_name": "Radxa ROCK 4D",
          "vendor": "Radxa",
          "soc": "rk3576",
          "release": "noble",
          "ubuntu_version": "24.04",
          "branch": "edge",
          "kernel": "7.3.4",
          "file": "roxora-radxa-rock-4d-noble-edge-2026.11.0.img.xz",
          "url": "https://github.com/roxora-os/build/releases/download/v2026.11.0/roxora-radxa-rock-4d-noble-edge-2026.11.0.img.xz",
          "size": 412345678,
          "sha256": "<sha256 of the .img.xz file>",
          "extract_size": 2466250752,
          "extract_sha256": "<sha256 of the decompressed .img>",
          "status": "ci-only",
          "verify_url": "https://github.com/roxora-os/build/releases/download/v2026.11.0/roxora-radxa-rock-4d-noble-edge-2026.11.0.verify.txt"
        }
      ]
    }

| Field | Type | Meaning |
| --- | --- | --- |
| `schema` | integer | Catalog format version, currently 1. |
| `release.tag` | string | Git tag. |
| `release.version` | string | Version, tag without `v`. |
| `release.date` | string | Release date, `YYYY-MM-DD`, UTC. |
| `release.prerelease` | boolean | True for a beta (tag `vYYYY.MM.N-beta.N`), false for a release. |
| `release.url` | string | GitHub release page. |
| `release.armbian_ref` | string | `armbian.ref` at the tagged commit. |
| `images[].board` | string | Armbian board name, or `generic-<soc>-uefi` for a UEFI image; first column of `boards.conf`. |
| `images[].board_name` | string | Board name for people, `NAME` column of `boards.conf`. For a UEFI image it names the boards it is for (`RK3576 boards with UEFI firmware`). |
| `images[].vendor` | string | Board maker, `VENDOR` column of `boards.conf`; `Generic` for a UEFI image. Catalogs from releases before 2026.11.1 do not have it; consumers then take the first word of `board_name`. |
| `images[].soc` | string | SoC, `SOC` column of `boards.conf`. |
| `images[].release` | string | Ubuntu codename. |
| `images[].ubuntu_version` | string | Ubuntu version number. |
| `images[].branch` | string | Armbian kernel branch. |
| `images[].kernel` | string | Kernel version in the image (`uname -r` without the branch suffix). |
| `images[].file` | string | Image file name. |
| `images[].url` | string | Download URL of the image. |
| `images[].size` | integer | Size of the `.img.xz` in bytes. |
| `images[].sha256` | string | SHA-256 of the `.img.xz`, lower-case hex. |
| `images[].extract_size` | integer | Size of the decompressed image in bytes. |
| `images[].extract_sha256` | string | SHA-256 of the decompressed image. |
| `images[].status` | string | `hardware-tested` or `ci-only`. |
| `images[].verify_url` | string | Download URL of the verify output. |
| `images[].firmware` | string, optional | `uefi` for an image without U-Boot that boots only on a board with UEFI firmware (such as edk2-rk3576) in its SPI flash. Absent for images that carry their own bootloader. |
| `images[].spi` | object, optional | Present only for boards with an SPI bootloader image. |
| `images[].spi.file` | string | SPI image file name. |
| `images[].spi.url` | string | Download URL of the SPI image. |
| `images[].spi.size` | integer | Size of the SPI image in bytes. |
| `images[].spi.sha256` | string | SHA-256 of the SPI image. |

The newest release's catalog is always at

    https://github.com/roxora-os/build/releases/latest/download/roxora-catalog.json

(GitHub's "latest" is the newest release, never a beta). To include betas,
read the list of releases from the GitHub API
(`GET /repos/roxora-os/build/releases`) and take `roxora-catalog.json` from
each release's assets.

[sample-catalog.json](sample-catalog.json) is a sample in this format with
made-up sizes and checksums, for testing consumers before real releases exist.
