# saq

Initramfs builder for the [Faseela](https://github.com/mrdevmohamed/faseela) Linux distribution.

SAQ builds one initramfs per installed kernel. Each image contains a static
BusyBox, the storage and filesystem modules selected by `modules.list` (plus
their dependencies and firmware), and a small `/init` that mounts the root
filesystem and hands over to `/usr/lib/systemd/systemd`.

**Faseela supports systemd only.** SAQ has no alternate-init option, no
`init=` override, and no runit or generic `/sbin/init` fallback.

## Usage

```sh
saq [--all | --kernel VERSION] [--prune] [--update-default]
    [--root DIR] [--dry-run] [--quiet]
```

The kernel package calls SAQ from its hooks:

```toml
post_install = "/usr/sbin/saq --all --prune --update-default"
post_remove  = "/usr/sbin/saq --prune --update-default"
```

- `--all` builds every installed kernel in a separate process.
- `--update-default` atomically updates `/boot/vmlinuz` and
  `/boot/initramfs.img` to the newest kernel with a valid image.
- The previous default pair is retained as real `*.old` files unless
  `--no-keep-old` is passed.
- `--root DIR` operates on another root filesystem.
- Equal inputs produce byte-identical images.

## Faseela live ISO

```sh
saq-live-iso [--kernel-version V] [--kernel FILE] [--busybox FILE]
             [--vol-id NAME] [--compression xz|zstd|gzip] [--serial]
             ROOTFS OUT.iso
```

The root filesystem must contain `/usr/lib/systemd/systemd`. The builder
creates a BIOS/UEFI live ISO with a passwordless `live` account, a read-only
SquashFS root and an optional persistent overlay. The root directory is read
without modification.

The live kernel command line supports `nolive`, `nopersist`, `rootdelay=`,
`iso-scan/filename=`, `break`, `break=postmount` and `quiet`. It does not
select or override PID 1.

## Kernel command line

The installed-system initramfs understands:

- `root=` using a device path, UUID, LABEL, PARTUUID or PARTLABEL
- `rootfstype=` and `rootflags=`
- `ro` / `rw`
- `rootwait` and `rootdelay=N`
- `break` / `break=postmount`
- `quiet`

The initramfs always starts `/usr/lib/systemd/systemd` after mounting the
installed root. Rescue shells remain available before and after mounting root.

## Modules and firmware

`share/saq/modules.list` is the default module set. Local additions and
exclusions belong in `/etc/saq/modules.d/*.list`. Dependencies are resolved
from the kernel's `modules.dep`; firmware referenced by selected modules is
copied into the image and decompressed when needed.

## Build and test

```sh
make install DESTDIR=/tmp/pkg
make check
```

The tests validate shell syntax, linting, generated initramfs contents,
module/firmware closure and live ISO structure. They do not replace real BIOS
and UEFI QEMU boots of a freshly installed Faseela disk.

## Layout

- `src/saq`: installed-kernel initramfs generator
- `src/saq-live-iso`: Faseela live ISO builder
- `share/saq/init`: installed-system initramfs entry point
- `share/saq/init-live`: live initramfs entry point
- `share/saq/modules.list` and `modules-live.list`: module sets
