# Reference package lists

`verify/verify-image.sh` compares the packages installed in a Roxora image
with what Ubuntu itself installs. Every package that is not in the reference
must match a hardware-layer pattern (first record of
`userpatches/roxora/apt/roxora-hardware.pref.in`) or be listed with a reason in
`allowlist`.

| File | Source | Downloaded | SHA-256 |
| --- | --- | --- | --- |
| `noble-server-cloudimg-arm64.manifest` | https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-arm64.manifest | 2026-11-11 | `820cdc3ef86f90ed996308913718960b6dbd1bccf8cd7cfad4032d0344f60711` |
| `noble-minimal-cloudimg-arm64.manifest` | https://cloud-images.ubuntu.com/minimal/releases/noble/release-20261105/ubuntu-24.04-minimal-cloudimg-arm64.manifest | 2026-11-11 | `0bae060ea20da8ae7ba24746e7d3cb69c40c8e68cb35c3459c427e9478423c4c` |

The server cloud image is the reference the check uses: it is Ubuntu's own
arm64 server image for 24.04, the closest official image to a Roxora minimal
server image. The minimal cloud image manifest is kept for comparison; it is a
smaller set than Roxora installs.

Each manifest line is `<package>[:<arch>]<tab><version>`. Only the package
names are compared; versions move with every Ubuntu update.

To refresh the reference, download the manifest of a newer dated release
directory, replace the file, and update the table above.
