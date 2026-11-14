# Reference package lists

`verify/verify-image.sh` compares the packages installed in a Roxora image
with what Ubuntu itself installs. Every package that is not in the reference
must match a hardware-layer pattern (first record of
`userpatches/roxora/apt/roxora-hardware.pref.in`) or be listed with a reason in
`allowlist`.

| File | Source | Downloaded | SHA-256 |
| --- | --- | --- | --- |
| `noble-server-cloudimg-arm64.manifest` | https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-arm64.manifest | 2026-11-11 | `820cdc3ef86f90ed996308913718960b6dbd1bccf8cd7cfad4032d0344f60711` |
| `resolute-server-cloudimg-arm64.manifest` | https://cloud-images.ubuntu.com/releases/resolute/release-20261016/ubuntu-26.04-server-cloudimg-arm64.manifest | 2026-11-12 | `830e68b0892d14e5e886048a2379a287f652c88ee3440e4aab0820f05cec8bd2` |
| `noble-minimal-cloudimg-arm64.manifest` | https://cloud-images.ubuntu.com/minimal/releases/noble/release-20261105/ubuntu-24.04-minimal-cloudimg-arm64.manifest | 2026-11-11 | `0bae060ea20da8ae7ba24746e7d3cb69c40c8e68cb35c3459c427e9478423c4c` |
| `noble-preinstalled-desktop-arm64+raspi.manifest` | https://cdimage.ubuntu.com/releases/noble/release/ubuntu-24.04.5-preinstalled-desktop-arm64+raspi.manifest | 2026-11-15 | `83948f6ada82ef64faad36f0a06f402774b927c2ec8a56bc02d6ba290ec5bba0` |
| `resolute-preinstalled-desktop-arm64+raspi.manifest` | https://cdimage.ubuntu.com/releases/resolute/release/ubuntu-26.04.1-preinstalled-desktop-arm64+raspi.manifest | 2026-11-15 | `9c2ed8c760153f2016b0ea0fe237a0a165c5b93b9a48ce5616ce34618ef07de5` |
| `noble-desktop-arm64.manifest` | https://cdimage.ubuntu.com/releases/noble/release/ubuntu-24.04.5-desktop-arm64.manifest | 2026-11-15 | `2821cb2c7c6e6968b27cec4246a0a2917646aae7050cf71ae9f25d406840bc57` |
| `resolute-desktop-arm64.manifest` | https://cdimage.ubuntu.com/releases/resolute/release/ubuntu-26.04.1-desktop-arm64.manifest | 2026-11-15 | `22ab2d3e86f5a21f4c54f4dc964507d5209cd8fa2533fdb17c80930209b07991` |

The server cloud image of the image's release is the reference the check
uses (picked by `VERSION_CODENAME` in the image's `/etc/os-release`): it is
Ubuntu's own arm64 server image for that release, the closest official image
to a Roxora command line image. The minimal cloud image manifest is kept for
comparison; it is a smaller set than Roxora installs.

A desktop image is a command line image with Ubuntu's desktop added, so its
reference is the server cloud image together with Ubuntu's desktop images:

- `gnome-minimal` (ubuntu-desktop-minimal): the server image and Ubuntu's
  preinstalled desktop image for the Raspberry Pi, Ubuntu's own arm64 desktop
  image that is written to a card as Roxora's are. Ubuntu publishes no
  preinstalled image of the minimal desktop alone; ubuntu-desktop depends on
  ubuntu-desktop-minimal, so the image of the full desktop (24.04) holds the
  minimal set, and the 26.04 one is the minimal desktop itself.
- `gnome` (ubuntu-desktop): those two and Ubuntu's live desktop image for
  arm64. The 26.04 preinstalled image no longer carries the full desktop
  (LibreOffice, Thunderbird and the rest of ubuntu-desktop); the live image
  does, for the installer's extended selection.

Packages of those images that are only for the Raspberry Pi or the installer
do not matter: a reference package that is not installed is not an error.
The check reads the flavor from the image: ubuntu-desktop installed is
`gnome`, only ubuntu-desktop-minimal is `gnome-minimal`, neither is `cli`.

Each manifest line is `<package>[:<arch>]<tab><version>`. Only the package
names are compared; versions move with every Ubuntu update. The live image
manifests also list the snaps Ubuntu seeds (`snap:<name><tab><channel><tab><revision>`);
the check skips those lines, and
[`userpatches/roxora/desktop/snaps.list`](../../userpatches/roxora/desktop/snaps.list)
is made from them.

To refresh the reference, download the manifest of a newer dated release
directory, replace the file, and update the table above.
