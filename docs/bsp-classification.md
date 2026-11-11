# What Roxora keeps from Armbian

Roxora uses Armbian for the hardware layer only. This page lists everything
Armbian's build puts into a minimal Ubuntu 24.04 image for the supported
boards, says which layer it belongs to, and what Roxora does with it.

- **Hardware layer**: needed to boot the board and drive its hardware, or
  part of the boot method. Kept.
- **Distro layer**: changes how the system looks or behaves compared with
  stock Ubuntu. Removed, or replaced with what Ubuntu ships.

The lists the build actually uses are in
[`userpatches/roxora/`](../userpatches/roxora): `bsp-remove.list`,
`rootfs-remove.list` and `keep-modified.list`. `verify/verify-image.sh`
checks every image against the same lists.

Source: armbian/build at the commit in [`armbian.ref`](../armbian.ref)
(3b7191306d36, 2026-11-10), and images of both boards built from it without
Roxora's changes.

## Board support package

The package is `armbian-bsp-cli-<board>-<branch>` (for example
`armbian-bsp-cli-radxa-rock-4d-edge`), plus a transitional
`armbian-bsp-cli-<board>` that only depends on it. For both supported boards
its files are `packages/bsp/common` from armbian/build plus a few generated
files; the two packages are identical apart from their names. Roxora builds
the package with the distro-layer files removed, so they are never installed,
and with maintainer scripts that keep only the boot-related steps. The package
keeps Armbian's name and is never upgraded from Armbian's repository (see
[architecture.md](architecture.md)).

### Kept

| Path | What it does | Layer | Reason |
| --- | --- | --- | --- |
| `/etc/armbian-release` | Board, family, kernel image type, overlay directory | hardware | Read by the initramfs hook and the overlay tool |
| `/usr/share/armbian/boot.cmd`, `/usr/share/armbian/armbianEnv.txt` | Copies of the boot script and boot environment | hardware | Boot method; the postinst restores `/boot/boot.cmd` and `boot.scr` from them if they are missing |
| `/etc/initramfs/post-update.d/99-uboot` | Wraps each initramfs as `/boot/uInitrd-<version>` with `mkimage` and points `/boot/uInitrd` at it | hardware | The boot script loads `uInitrd` |
| `/etc/kernel/postinst.d/xx-initramfs-cleanup`, `/etc/kernel/postrm.d/xx-initramfs-cleanup` | Removes initramfs files of kernels that are no longer installed | hardware | Keeps `/boot` consistent across kernel updates |
| `/etc/modprobe.d/8189fs.conf`, `/etc/modprobe.d/r8723bs.conf` | Turns off power management in two Realtek Wi-Fi drivers | hardware | Wi-Fi bring-up for USB and SDIO adapters |
| `/etc/udev/rules.d/10-wifi-disable-powermanagement.rules` | Turns Wi-Fi power save off when an interface appears | hardware | Wi-Fi bring-up; SDIO Wi-Fi on these boards drops with power save on |
| `/etc/udev/rules.d/50-usb-realtek-net.rules` | Selects the Ethernet configuration of Realtek USB network adapters | hardware | USB network adapter bring-up |
| `/etc/udev/rules.d/90-chromium-video.rules` | Names V4L2 decoder devices `/dev/video-dec*` | hardware | Stable names for the hardware video decoders |
| `/lib/udev/rules.d/71-axp-power-button.rules` | Lets systemd handle AXP PMIC power buttons | hardware | Power button; harmless on boards without an AXP PMIC |
| `/lib/systemd/system/armbian-led-state.service`, `/usr/lib/armbian/armbian-led-state-save.sh`, `/usr/lib/armbian/armbian-led-state-restore.sh` | Saves LED triggers at shutdown and restores them at boot | hardware | Board LEDs |
| `/usr/sbin/armbian-add-overlay` | Compiles and installs a user device tree overlay | hardware | Device tree overlays |
| `DEBIAN/triggers` (`activate update-initramfs`) | Rebuilds the initramfs when the package changes | hardware | Boot method |

### Removed

| Path | What it does | Layer | Reason |
| --- | --- | --- | --- |
| `/etc/apt/apt.conf.d/02-armbian-compress-indexes`, `02-armbian-postupdate`, `71-armbian-no-recommends`, `81-armbian-no-languages`, `/usr/lib/armbian/armbian-apt-updates` | Changes apt: gzip-compressed indexes, no recommended packages, no translations, an update counter after every apt run | distro | Changes how apt behaves compared with Ubuntu |
| `/etc/cron.daily/armbian-featured` | Downloads a "featured" feed for the login tips | distro | Message of the day |
| `/etc/cron.daily/armbian-ram-logging`, `/lib/systemd/system/armbian-ramlog.service`, `/usr/lib/armbian/armbian-ramlog`, `/etc/systemd/system/logrotate.service`, `/lib/systemd/system/systemd-journald.service.d/override.conf`, `/etc/default/armbian-ramlog.dpkg-dist` | Keeps `/var/log` in RAM and writes it back periodically | distro | Ramlog default |
| `/lib/systemd/system/armbian-zram-config.service`, `/usr/lib/armbian/armbian-zram-config`, `/etc/default/armbian-zram-config.dpkg-dist` | Swap and `/tmp` on zram | distro | Zram default |
| `/etc/cron.d/armbian-check-battery`, `/usr/lib/armbian/armbian-check-battery-shutdown`, `/usr/lib/armbian/armbian-allwinner-battery` | Low battery shutdown for Allwinner PMICs | distro | Not used on these boards; disabled by default anyway |
| `/etc/cron.d/armbian-truncate-logs`, `/usr/lib/armbian/armbian-truncate-logs` | Truncates logs every 15 minutes | distro | Part of ramlog |
| `/etc/cron.d/armbian-updates` | Counts available updates for the login message | distro | Message of the day |
| `/etc/update-motd.d/00-clear` to `99-blank` (11 scripts), `/etc/default/armbian-motd.dpkg-dist` | Armbian's login message: header, system info, tips, IP, containers | distro | Ubuntu's own message of the day is used |
| `/etc/profile.d/armbian-check-first-login.sh`, `armbian-check-first-login-reboot.sh`, `/usr/lib/armbian/armbian-firstlogin` | First-login wizard: root password, user, locale | distro | Replaced by a default account created when the image is built (`roxora`, password `roxora`, to be changed at the first login); root stays locked as on Ubuntu |
| `/lib/systemd/system/armbian-firstrun.service`, `/usr/lib/armbian/armbian-firstrun`, `/etc/default/armbian-firstrun.dpkg-dist` | First boot tasks: new SSH host keys, random MAC addresses in `armbianEnv.txt`, tuning profile | distro | Replaced by cloud-init, which regenerates the SSH host keys. The boot environment of these boards sets no MAC address |
| `/lib/systemd/system/armbian-resize-filesystem.service`, `/usr/lib/armbian/armbian-resize-filesystem` | Grows the root partition and filesystem at first boot | distro | Replaced by cloud-init's growpart and resizefs |
| `/lib/systemd/system/armbian-disable-autologin.service`, `armbian-disable-autologin.timer` | Removes the console autologin after first login | distro | Roxora never enables autologin |
| `/lib/systemd/system/armbian-hardware-monitor.service`, `/usr/lib/armbian/armbian-hardware-monitor` | Logs hardware information at boot | distro | Diagnostics for Armbian's tools |
| `/lib/systemd/system/armbian-hardware-optimize.service`, `/usr/lib/armbian/armbian-hardware-optimization`, `/usr/lib/armbian/armbian-audio-config` | At every boot: I/O scheduler `none` on flash, CPU governor and limits from `/etc/default/cpufrequtils`, ondemand tuning, unmutes mixer controls, rewrites USB storage quirks into `armbianEnv.txt`, rewrites logrotate paths for ramlog | distro | Generic tuning with no RK3576 specific step; the kernel defaults are used |
| `/lib/systemd/system/armbian-luks-rekey.service`, `/usr/lib/armbian/armbian-luks-rekey` | Re-keys an encrypted root at first boot | distro | Not used by Roxora images |
| `/lib/systemd/system/getty@tty1.service.d/10-noclear.conf`, `/lib/systemd/system/serial-getty@.service.d/10-term.conf`, `/lib/systemd/system/systemd-modules-load.service.d/10-timeout.conf` | Changes stock systemd units: no screen clear on tty1, `TERM=linux` on serial consoles, a module loading timeout | distro | Stock Ubuntu units are used |
| `/etc/NetworkManager/conf.d/zz-10-override-wifi-random-mac-disable.conf`, `zz-20-override-wifi-powersave-disable.conf` | NetworkManager Wi-Fi defaults | distro | NetworkManager is not part of minimal images |
| `/etc/profile.d/armbian-lang.sh`, `/etc/skel/.bash_aliases`, `/etc/profile.d/armbian-activate-profile-sync-daemon.sh`, `/usr/lib/systemd/user/psd*.d/armbian-not-root.conf` | Shell defaults, aliases, profile-sync-daemon | distro | Changes the user environment |
| `/usr/lib/sysctl.d/55-bsp-default.conf` | Sysctl defaults copied from the distribution package | distro | Ubuntu's own defaults apply |
| `/usr/lib/tmpfiles.d/armbian-hibernation.conf` | Hibernation image size | distro | Tuning |
| `/var/lib/polkit-1/localauthority/50-local.d/*.pkla` (5 files) | Extra rights for `plugdev` and `netdev` users | distro | Changes permissions compared with Ubuntu |
| `/etc/X11/xorg.conf.d/01-armbian-defaults.conf` | X server defaults | distro | No X server in minimal images |
| `/usr/bin/armbian-debug`, `/usr/bin/armbianmonitor`, `/usr/bin/armbian-upgrade`, `/usr/sbin/ddbr` | Debug upload, monitor, upgrade and backup tools | distro | Armbian's own tools |
| `/usr/bin/armbian-install`, `/usr/lib/nand-sata-install`, `/usr/lib/armbian-install/exclude.txt` | Install to eMMC or NVMe; now only a shim that runs `armbian-config` | distro | `armbian-config` is not installed, so the shim cannot work |
| `/usr/lib/armbian/armbian-common` | Shell library of the removed scripts | distro | Nothing kept uses it |
| `/usr/share/armbian/armbian-user-icon.png`, `/usr/share/pixmaps/armbian-logo*` (5 files), `/usr/share/initramfs-tools/conf-hooks.d/armbian-plymouth` | Branding | distro | Branding |
| `/etc/armbian-distribution-status`, `/etc/armbian.txt` | Release support table and build information for the login message and `armbian-config` | distro | Read only by removed tools. `armbian.txt` is written into the package after the extension runs, so it is deleted from the root filesystem instead |

### Maintainer scripts

| Script step | Layer | Action | Reason |
| --- | --- | --- | --- |
| preinst: set `COMPRESS=gzip` in `/etc/initramfs-tools/initramfs.conf` | hardware | keep | Boot method: Armbian's images boot with gzip initramfs files wrapped as uInitrd; Ubuntu's zstd default is not validated on these boards |
| preinst: drop `vm.swappiness=100` from `/etc/sysctl.conf`, run `sysctl --system` | distro | remove | Only cleans up after older Armbian packages |
| preinst: replace Ubuntu Pro messages with "Support Armbian" | distro | remove | Branding |
| preinst: delete old Armbian motd, profile and init files, remove `02-armbian-periodic` and the stock unattended-upgrades trigger | distro | remove | Clean-up of older Armbian packages; changes Ubuntu's update settings |
| preinst: fix lightdm ownership | distro | remove | No display manager |
| postinst: enable ramlog, copy settings from log2ram | distro | remove | Ramlog |
| postinst: add `RESUME=none` to `initramfs.conf` | hardware | keep | Avoids a boot delay waiting for a resume device that does not exist |
| postinst: recreate `/boot/boot.cmd` and `boot.scr` when missing or forced | hardware | keep | Boot method |
| postinst: link `/etc/motd` to `/var/run/motd`, delete Ubuntu's `00-header` and `10-help-text` | distro | remove | Message of the day |
| postinst: move `.dpkg-dist` defaults into place | distro | remove | Files of removed services |
| postinst: create groups `audio video plugdev input dialout netdev bluetooth render users games i2c gpio spi docker`, set `EXTRA_GROUPS` in `/etc/adduser.conf` | mixed | keep `i2c gpio spi` only | The udev rules of the kernel use these three groups; adding every new user to many groups changes Ubuntu's defaults |
| postinst: enable `armbian-hardware-monitor`, `armbian-hardware-optimize`, `armbian-zram-config`, `armbian-led-state` | mixed | keep `armbian-led-state` only | Others are removed |
| postrm: disable the services above | mixed | keep `armbian-led-state` only | |
| Package `Depends: fping` | distro | kept as a dependency | Installing the package requires it; nothing in Roxora runs it |

## Other Armbian packages in a minimal noble image

| Package | What it is | Layer | Action | Reason |
| --- | --- | --- | --- | --- |
| `linux-image-<branch>-<family>`, `linux-dtb-<branch>-<family>` | Kernel and device trees | hardware | keep, updated from Armbian | |
| `linux-u-boot-<board>-<branch>` | U-Boot and its install script | hardware | keep, updated from Armbian | |
| `armbian-firmware` | Firmware files | hardware | keep, updated from Armbian | |
| `linux-headers-<branch>-<family>` | Kernel headers | hardware | installed only where a board needs DKMS (ROCK 4D Wi-Fi), updated from Armbian with the kernel | DKMS modules are rebuilt for each new kernel |
| `armbian-base-files` | Armbian's `base-files`, with Armbian's `/etc/os-release` | distro | not installed (`KEEP_ORIGINAL_OS_RELEASE=yes`); the apt pin keeps the `base-files` that Armbian's repository publishes from replacing Ubuntu's | |
| `fake-ubuntu-advantage-tools` | Empty package that replaces Ubuntu Pro tooling | distro | removed after installation | Armbian installs it unconditionally on Ubuntu; no setting turns it off |
| `armbian-config` | Armbian's configuration tool, from its own repository `github.armbian.com/configng` | distro | not installed, repository not added | Armbian's build enables this extension for every image; Roxora replaces its two hooks |
| `armbian-zsh`, `armbian-plymouth-theme` | Shell setup, boot splash | distro | not installed | Only installed on non-minimal images or with `PLYMOUTH=yes` |

## Changes outside packages

Armbian's build also edits the root filesystem directly. Ubuntu package files it
edits are restored from the packages (checked with `dpkg --verify`); files it
creates are removed (`rootfs-remove.list`).

| Change (where in armbian/build) | Layer | Action |
| --- | --- | --- |
| journald `Storage=volatile`, compression and rate limits (`distro-specific.sh`) | distro | restored from systemd |
| Ubuntu motd scripts deleted, `motd-news` disabled (`distro-specific.sh`, BSP postinst) | distro | restored from base-files, and `motd-news.timer` enabled again |
| `fake-ubuntu-advantage-tools` installed, `20apt-esm-hook.conf` emptied (`distro-specific.sh`) | distro | package purged, empty file removed |
| unattended-upgrades auto-update config removed and debconf seeded to keep it off (`distro-specific.sh`) | distro | unattended-upgrades is installed and reconfigured with automatic updates on, as on Ubuntu's server images |
| `/etc/rc.local` installed (`distro-specific.sh`) | distro | removed |
| `/etc/systemd/sleep.conf.d/00-disable.conf`, all sleep states off (`distro-specific.sh`) | hardware | kept: suspend and resume are not validated on these boards with the edge kernel, and a board that does not wake up needs a power cycle |
| initramfs `COMPRESS=gzip` (`distro-specific.sh`, BSP preinst) | hardware | kept, as part of the boot method |
| `ondemand.service` disabled (`distro-specific.sh`) | none | the unit does not exist on noble |
| `/etc/issue`, `/etc/issue.net` set to "Armbian ..." (`distro-agnostic.sh`) | distro | restored from base-files |
| `/etc/legal` deleted (`distro-agnostic.sh`) | distro | restored from base-files |
| `kernel.printk` uncommented in `/etc/sysctl.conf` (`distro-agnostic.sh`) | distro | restored from procps |
| rsyslog `xconsole` and `KLogPermitNonKernelFacility` lines commented out (`distro-agnostic.sh`) | distro | restored from rsyslog |
| `/usr/bin/tzselect` text changed (`post-tweaks.sh`) | distro | restored from libc-bin |
| `PermitRootLogin yes` and `PubkeyAuthentication yes` in `/etc/ssh/sshd_config` (`distro-agnostic.sh`) | distro | restored from openssh-server's template `/usr/share/openssh/sshd_config` |
| hosts line of `/etc/nsswitch.conf` rewritten (`distro-agnostic.sh`) | distro | restored from libc-bin's template `/usr/share/libc-bin/nsswitch.conf` |
| execute bit removed from every `/etc/update-motd.d` script until the first-login wizard has run (`distro-agnostic.sh`) | distro | execute bit restored; Ubuntu ships them executable |
| `tmpfs /tmp` added to `/etc/fstab` (`partitioning.sh`) | distro | line removed; Ubuntu keeps `/tmp` on the root filesystem |
| `start-stop-daemon` left different from dpkg's after removing the build-time diversion (`post-tweaks.sh`) | distro | restored from dpkg |
| root password `1234`, `/root/.not_logged_in_yet`, `/root/.bash_aliases`, root dotfiles from `/etc/skel` (`distro-agnostic.sh`) | distro | root locked as on Ubuntu, wizard trigger and aliases removed, dotfiles from base-files |
| console autologin overrides for `getty@` and `serial-getty@` (`distro-agnostic.sh`) | distro | not created (`CONSOLE_AUTOLOGIN=no`) |
| time zone copied from the build machine (`main-config.sh`) | distro | `Etc/UTC` |
| `/etc/default/cpufrequtils`, `/etc/default/armbian-tuning-profile` (`distro-agnostic.sh`) | distro | removed; no tuning profile |
| `/etc/default/rng-tools` line added (`distro-agnostic.sh`) | distro | removed (rng-tools is not installed) |
| `/etc/securetty` with the serial console (`distro-agnostic.sh`) | distro | removed; Ubuntu's PAM setup does not read it |
| `/boot/boot.bmp` Armbian logo (`distro-agnostic.sh`) | distro | removed; the boot script does not show it |
| serial getty enabled on `ttyS0` at 1500000 baud (`distro-agnostic.sh`) | hardware | kept |
| hostname set to the board name (`distro-agnostic.sh`) | hardware | kept |
| `systemd-firstboot.service` masked | hardware | kept: it would prompt on the serial console at first boot; cloud-init does the first-boot setup |
| `/etc/apt/sources.list.d/armbian.sources` with `main noble-utils noble-desktop` | hardware | kept, pinned (see architecture.md) |
| Audio device names for HDMI, DP and the ES8316 codec (`/etc/udev/rules.d/90-naming-audios.rules`, board config) | hardware | kept |
| netplan `10-dhcp-all-interfaces.yaml`, `00-armbian.network.readme`, `networkd.conf.d/mac-duid.conf`, wait-online `--any` and `apt-daily-upgrade` drop-ins (net-systemd-networkd extension) | distro | removed; cloud-init writes the network configuration from the image's seed (DHCP on wired Ethernet), as on Ubuntu's server images |
| `armbian-config.sources` (armbian-config extension) | distro | not created |
| ROCK 4D: AIC8800 Wi-Fi and Bluetooth driver built with DKMS, firmware from Radxa's releases (radxa-aic8800 extension) | hardware | kept |
| ROCK 4D: `update-alternatives` makes `gcc-14` the default `gcc` (radxa-aic8800 extension, for the DKMS build of the Wi-Fi driver) | hardware | kept; it changes the default compiler on the ROCK 4D image only |
