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

## Release packages

From 2026.11.5 on, each release also has release packages: `roxora-release`
and one package per flavor (`roxora-cli`, `roxora-desktop-gnome-minimal`,
`roxora-desktop-gnome`), built from the tagged commit
(`userpatches/roxora/packages/`), in the images and in
[Roxora's apt repository](https://roxora-os.github.io/apt/) (see
[architecture.md](architecture.md#roxoras-apt-repository)).

- Their version is the release version, `+` and the Ubuntu version:
  `2026.11.5+24.04`, `2026.11.5+26.04`, and `+26.10` for Ubuntu 26.10. A
  beta would be `2026.12.0~beta.1+24.04`, which sorts before the release.
- `ROXORA_RELEASE` in `userpatches/roxora/roxora-repo.conf` is that version
  without the Ubuntu part. `release.yml` stops unless it is the tag's
  version, so it is raised before a release is tagged, in the commit that
  starts the release's changes to the packages.
- roxora-os/apt builds them from the tag and publishes them within the hour
  after the release is published (betas are not published there yet). A
  published version never changes.
- On a system they write `/etc/roxora-release` (a link to
  `/usr/lib/roxora-release`): shell variable assignments, read by tools
  such as hwtool. Consumers ignore keys they do not know.

| Key | Meaning |
| --- | --- |
| `ROXORA_VERSION` | Roxora release, `YYYY.MM.N`. |
| `ROXORA_FLAVOR` | `cli`, `gnome-minimal` or `gnome`. |
| `ROXORA_UBUNTU_CODENAME` | Ubuntu release, `noble`, `resolute` or `stonking`. |
| `ROXORA_PACKAGE` | The flavor package that wrote the file. |

A system that has no `/etc/roxora-release` runs an image up to 2026.11.4
that has not been updated as in
[install.md](install.md#updating-to-a-new-roxora-release).

## Image files

One image per line of `boards.conf`:

    roxora-<board>-<release>-<branch>-<version>.img.xz             command line image
    roxora-<board>-<release>-<branch>-<flavor>-<version>.img.xz    desktop image

Examples: `roxora-radxa-rock-4d-noble-edge-2026.11.0.img.xz`,
`roxora-radxa-rock-4d-noble-edge-gnome-minimal-2026.11.5.img.xz`.

- `<board>` is the Armbian board name (`radxa-rock-4d`), or for a UEFI image
  `generic-<soc>-uefi` (`generic-rk3576-uefi`); `<release>` the Ubuntu codename (`noble`),
  `<branch>` the Armbian kernel branch (`edge`).
- `<flavor>` is `gnome-minimal` (Ubuntu's minimal GNOME desktop) or `gnome`
  (the full one). The command line image, flavor `cli`, has no flavor in
  its name, as before the desktop images existed. A version starts with a
  digit and a flavor with a letter, so the two forms cannot be mistaken for
  each other. Every other file of an image (`.sha256`, `.verify.txt`,
  `-spi.img`) carries the image's name, flavor included.
- The file is a whole-disk image compressed with xz. It is written as is to
  an SD card, USB drive, eMMC or NVMe. A board image has the bootloader
  inside it at 32 KiB. A UEFI image has none: it has a GPT with an EFI
  system partition, and the board's UEFI firmware, installed separately,
  starts GRUB from it.

## Files in each release

For every image:

| File | Content |
| --- | --- |
| `roxora-...img.xz` | The image, when it is smaller than 1900 MiB. |
| `roxora-...img.xz.part1`, `.part2`, ... | The image in parts, when it is larger (see [Images in parts](#images-in-parts)); the whole file is then not in the release. |
| `roxora-...img.xz.sha256` | `sha256sum` output for the image file, one line. For an image in parts it is that of the joined file. |
| `roxora-...verify.txt` | The output of `verify/verify-image.sh` for that image. |
| `roxora-...-spi.img` | Only for boards that boot from SPI NOR (the ROCK 4D): the U-Boot SPI image from the same build as the disk image. It is written to the SPI flash, not to a card. UEFI images never have one. Each flavor of a board's image has its own copy, from its own build of the same U-Boot. |
| `roxora-...-spi.img.sha256` | `sha256sum` output for the SPI image. |

Once per release:

| File | Content |
| --- | --- |
| `SHA256SUMS` | `sha256sum` output for every other file in the release. It lists the parts of a split image, not the joined file. |
| `roxora-catalog.json` | The catalog described below. |

The images, SPI images, `SHA256SUMS` and `roxora-catalog.json` also carry a
build provenance attestation from the release workflow (from 2026.11.3 on),
checked with `gh attestation verify <file> --repo roxora-os/build`. An image
in parts is attested twice: whole, before it is split, so a file joined
from its parts verifies, and each part on its own.

## Images in parts

GitHub refuses a release file of 2 GiB (2147483648 bytes) or more. An image
whose `.img.xz` is larger than 1900 MiB (1992294400 bytes) is therefore
published in parts, from 2026.11.4 on; so far those are the desktop images.

- The parts are `<file>.part1`, `<file>.part2` and so on, where `<file>` is
  the image file name. Each is 1900 MiB except the last, which holds the
  rest. There are at most nine, so `<file>.part*` sorts in order.
- The parts are the bytes of the `.img.xz` cut in order, nothing added.
  Joined in order they are the file: `cat <file>.part* > <file>`, then
  `sha256sum -c <file>.sha256`.
- The whole `.img.xz` is not attached to the release. `<file>.sha256` is,
  and names the joined file.
- In the catalog such an image has `parts` and no `url` (below).

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
- The status is per image, flavors apart: a tested command line image says
  nothing about the desktop image of the same board.
- The release notes list the images in each group. The "Mark
  hardware-tested" workflow changes an image's status, and can publish a
  beta as a release. It takes `BOARD`, `BOARD:RELEASE`,
  `BOARD:RELEASE:BRANCH` or `BOARD:RELEASE:BRANCH:FLAVOR`; a shorter form
  marks every image it matches, so name the flavor when only one was tested.

## Catalog

`roxora-catalog.json` is UTF-8 JSON. Consumers must ignore fields they do not
know, so fields can be added without a new schema number. Removing or changing
the meaning of a field increments `schema`.

One field became optional without a new schema number: `images[].url`, in
2026.11.4, for images published in parts. Those are the desktop images,
which no earlier release had, so no entry that existed before lost its
`url`. A consumer written before then that requires `url` skips such an
image instead of offering a link that does not exist; that is the reason
the field is left out and not pointed at a file the release does not hold.

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
          "flavor": "cli",
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
| `images[].ubuntu_version` | string | Ubuntu version number (`VERSION` in `userpatches/roxora/releases.conf`). Long term support releases are those of April in even years (`24.04`, `26.04`); others, such as `26.10`, are supported for nine months. |
| `images[].branch` | string | Armbian kernel branch. |
| `images[].flavor` | string, optional | `cli` for a command line image, `gnome-minimal` or `gnome` for an image with Ubuntu's GNOME desktop (`ubuntu-desktop-minimal`, `ubuntu-desktop`); `FLAVOR` column of `boards.conf`. Catalogs from releases before the desktop images do not have it; consumers then take `cli`. More flavors may be added; a consumer shows one it does not know by this name. Board, release, branch and flavor together name one image of a release. |
| `images[].kernel` | string | Kernel version in the image (`uname -r` without the branch suffix). |
| `images[].file` | string | Image file name, as under [Image files](#image-files). |
| `images[].url` | string, optional | Download URL of the image. Absent when the image is published in parts: there is then no single file to download, and a consumer that can only take one URL leaves the image out. Every image has either `url` or `parts`. |
| `images[].size` | integer | Size of the `.img.xz` in bytes; for an image in parts, of the joined file. |
| `images[].sha256` | string | SHA-256 of the `.img.xz`, lower-case hex; for an image in parts, of the joined file. |
| `images[].parts` | array, optional | Present only for an image published in parts ([Images in parts](#images-in-parts)), from 2026.11.4 on: the parts in the order to join them, two or more. `file`, `size` and `sha256` of the image describe the result. |
| `images[].parts[].file` | string | Part file name, `<file>.part<n>` with `n` counting from 1. |
| `images[].parts[].url` | string | Download URL of the part. |
| `images[].parts[].size` | integer | Size of the part in bytes. The sizes add up to `images[].size`. |
| `images[].parts[].sha256` | string | SHA-256 of the part, lower-case hex. |
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
