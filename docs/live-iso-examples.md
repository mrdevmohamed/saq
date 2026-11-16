# Live ISO examples: `saq-live-iso` on popular distros

`saq-live-iso` needs a root filesystem **with a kernel in it** (image in `/boot` or
`/usr/lib/modules/VERSION/vmlinuz`, modules with `modules.dep` in `/lib/modules`). The
minimal rootfs tarballs most distros publish have no kernel, so every recipe has the
same three steps:

1. get the distro's rootfs (tarball, `debootstrap`, `pacstrap`, `dnf --installroot`, ...),
2. install a kernel, an init system and `udev` into it (a chroot or the tool's own
   `--root` option),
3. unmount anything bound into it and run `saq-live-iso ROOT out.iso`.

Run as root (the roots belong to root). The result boots from a CD, a `dd`-written stick,
or as a file on a [Ventoy](https://www.ventoy.net/) stick; log in as **`live`** (empty
password). Build tools: `squashfs-tools xorriso mtools grub-pc-bin grub-efi-amd64-bin`
(Debian/Ubuntu names), plus a static `busybox` on the host unless the root has one
(`apt install busybox-static`, or `--busybox FILE`).

| distro | init | kernel lands in | checked |
|---|---|---|---|
| [Ubuntu / Debian](#ubuntu--debian) | systemd | `/boot/vmlinuz-VER` | **yes**: built, booted in QEMU, logged in as `live`, `sudo` works |
| [Arch Linux](#arch-linux) | systemd | `/usr/lib/modules/VER/vmlinuz` | commands not run |
| [Fedora](#fedora) | systemd | `/usr/lib/modules/VER/vmlinuz` | commands not run |
| [Alpine](#alpine) | OpenRC | `/boot/vmlinuz-lts` | commands not run |
| [Void](#void-linux) | runit | `/boot/vmlinuz-VER` | commands not run |
| [Any container image](#any-distro-through-its-container-image) | whatever it has | depends | commands not run |
| [Faseela](#faseela) | runit | `/boot/vmlinuz-VER` | the live initramfs is Faseela's own |

"Commands not run" means the recipe follows the distro's documented tooling but was not
executed here: expect to adjust a package name. The `saq-live-iso` step is the same
everywhere and is covered by `tests/live.sh`.

## Ubuntu / Debian

Checked with Ubuntu 24.04 (noble): 197 MB ISO, `login: live`, empty password, passwordless
`sudo`, root is an overlay. The same works for Debian by changing the suite and mirror.

```sh
sudo apt install debootstrap squashfs-tools xorriso mtools grub-pc-bin grub-efi-amd64-bin busybox-static

sudo debootstrap --variant=minbase \
    --include=systemd,systemd-sysv,udev,dbus,login,passwd,sudo,nano,iproute2,ca-certificates \
    noble /srv/ubuntu http://archive.ubuntu.com/ubuntu        # Debian: bookworm http://deb.debian.org/debian

sudo mount -t proc proc /srv/ubuntu/proc
sudo chroot /srv/ubuntu env DEBIAN_FRONTEND=noninteractive INITRD=No apt-get update
sudo chroot /srv/ubuntu env DEBIAN_FRONTEND=noninteractive INITRD=No \
    apt-get install -y --no-install-recommends linux-image-virtual     # Debian: linux-image-amd64
sudo umount /srv/ubuntu/proc

sudo saq-live-iso --vol-id UBUNTU_LIVE /srv/ubuntu ubuntu-live.iso
```

- `INITRD=No` skips the distro's initramfs: saq builds its own.
- `linux-image-virtual` is a small kernel; use `linux-image-generic` for real hardware (it
  needs `linux-firmware` for many Wi-Fi/GPU chips: add it to the install line).
- `udev` is required: without it systemd waits for `dev-ttyS0.device` and never starts a
  login on the serial console.
- Add a desktop to the chroot (`apt-get install ubuntu-desktop-minimal`, `task-gnome-desktop`,
  `xfce4`, ...) before the last step; the ISO then boots into it. The live user is in
  `sudo`, `video`, `audio`, `plugdev`, `render`, `input`.
- `mksquashfs` may print `Unrecognised xattr prefix system.posix_acl_default`: harmless.

## Arch Linux

```sh
sudo pacman -S arch-install-scripts squashfs-tools libisoburn mtools grub busybox   # on an Arch host
sudo pacstrap -c -K /srv/arch base linux linux-firmware nano sudo
sudo saq-live-iso --vol-id ARCH_LIVE /srv/arch arch-live.iso
```

From a non-Arch host, unpack `archlinux-bootstrap-x86_64.tar.zst` (rootfs is in the
`root.x86_64/` directory inside; `saq-live-iso` accepts the tarball and finds it), then
`arch-chroot` into it, `pacman-key --init && pacman-key --populate`, and
`pacman -S base linux linux-firmware sudo`. The kernel is found at
`/usr/lib/modules/VER/vmlinuz`. `pacstrap` runs `mkinitcpio`: harmless, saq ignores it.

## Fedora

```sh
sudo dnf --installroot=/srv/fedora --releasever=<N> --setopt=install_weak_deps=False \
    install -y @core kernel-core kernel-modules-core passwd sudo
sudo saq-live-iso --vol-id FEDORA_LIVE /srv/fedora fedora-live.iso
```

`<N>` is the Fedora release (e.g. `rpm -E %fedora` on a Fedora host). The kernel image is
`/usr/lib/modules/VER/vmlinuz`; if `kernel-core` left none (its scriptlets copy it with
`kernel-install`), pass `--kernel /srv/fedora/lib/modules/VER/vmlinuz`. If login is refused because of
SELinux labels (the squashfs carries the root's labels, the overlay may not), add
`--kernel-args "enforcing=0"`.

## Alpine

```sh
curl -LO https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/alpine-minirootfs-<VER>-x86_64.tar.gz
mkdir /srv/alpine && sudo tar -xpf alpine-minirootfs-<VER>-x86_64.tar.gz -C /srv/alpine
sudo cp /etc/resolv.conf /srv/alpine/etc/
sudo mount -t proc proc /srv/alpine/proc
sudo chroot /srv/alpine /bin/sh -c 'apk add alpine-base linux-lts linux-firmware-none busybox-static'
sudo umount /srv/alpine/proc

sudo saq-live-iso --busybox /srv/alpine/bin/busybox.static --vol-id ALPINE_LIVE /srv/alpine alpine-live.iso
```

Alpine's own `busybox` is dynamic (musl), so the initramfs takes `busybox.static`. The
kernel is `/boot/vmlinuz-lts` with `.ko.gz` modules (saq reads them). OpenRC (`/sbin/init`) is
found automatically.

## Void Linux

```sh
curl -LO https://repo-default.voidlinux.org/live/current/void-x86_64-ROOTFS-<DATE>.tar.xz
# the tarball has no kernel: unpack it, add one, then convert
mkdir /srv/void && sudo tar -xpf void-x86_64-ROOTFS-<DATE>.tar.xz -C /srv/void
sudo xbps-install -r /srv/void -R https://repo-default.voidlinux.org/current -Sy base-system linux
sudo saq-live-iso --vol-id VOID_LIVE /srv/void void-live.iso
```

(`xbps-install` is the static `xbps` tool from Void's repository.) Void uses runit, which
`saq-live-iso` starts by default.

## Any distro through its container image

Every distro publishes a container image that is just a rootfs. It has no kernel, so the
steps are the same: export, install a kernel with the distro's package manager, convert.

```sh
id=$(docker create debian:bookworm)          # fedora:latest, archlinux:latest, alpine:latest, ...
mkdir /srv/root && docker export "$id" | sudo tar -x -C /srv/root && docker rm "$id"
# chroot in, install: a kernel, an init system (systemd / openrc), udev, sudo, passwd
sudo saq-live-iso /srv/root my-live.iso
```

A tarball works as input too: `sudo saq-live-iso rootfs.tar.zst out.iso` extracts to a
temporary directory (root needed) and depmods it if the kernel package did not.

## Faseela

Faseela's own `bootstrap/mkiso.sh` stays the supported way to build the Faseela ISO. To use
`saq-live-iso` instead on a Faseela rootfs with a kernel installed:

```sh
sudo saq-live-iso --vol-id FASEELA faseela-rootfs/ faseela-live.iso   # runit is the default init
```

## Useful options

| | |
|---|---|
| `--init PATH` | init to start; default: first of `/usr/bin/runit`, `/sbin/init`, `/usr/lib/systemd/systemd` |
| `--kernel-version V` / `--kernel FILE` | pick the kernel when the root has several or the image is elsewhere |
| `--busybox FILE` | static BusyBox for the initramfs when neither root nor host has one |
| `--kernel-args "..."` | extra kernel arguments (`nomodeset`, `enforcing=0`, ...) |
| `--serial` | also send the console to `ttyS0` (QEMU, servers) |
| `--compression zstd` | faster to build and boot than `xz`, a bit larger |

Boot arguments in the live session: `nolive` (no live user), `nopersist`, `rootdelay=N`,
`iso-scan/filename=/path.iso`, `break`. An ext4 partition labelled `LIVE_PERSIST` keeps changes.
