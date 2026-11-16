# saq

Initramfs tool for the [Faseela](https://github.com/mrdevmohamed/faseela) distro, or any Linux distro.

`saq` builds `/boot/initramfs-VERSION.img` for every kernel
installed in `/boot`: a static BusyBox, the storage and filesystem modules from
`modules.list` (with their dependencies and firmware) and a small `/init` that
mounts the root filesystem and hands over to runit. That is what saq is, and
none of it changed. Next to it, the `saq-live-iso` script turns any root filesystem
into a bootable live ISO (see below); it uses `saq --live` for the live initramfs.

The code started as faseela-repo PR #44 and lives here so it can be versioned,
tested and packaged on its own.

## Usage

```
saq [--all | --kernel VERSION] [--prune] [--update-default]
                    [--root DIR] [--dry-run] [--quiet]
```

The kernel package calls it from its hooks:

```
post_install = "/usr/sbin/saq --all --prune --update-default"
post_remove  = "/usr/sbin/saq --prune --update-default"
```

- `--all` builds every kernel in a separate process, so a broken old kernel
  cannot stop the new one from getting its image. The exit status is non-zero
  if any of them failed.
- `--update-default` points `/boot/vmlinuz` and `/boot/initramfs.img` at the
  newest kernel that has an image, atomically. On a filesystem without symlinks
  (a FAT `/boot`) it copies the files instead.
- `--update-default` also keeps the pair it replaces as `/boot/vmlinuz.old` and `/boot/initramfs.img.old`. They are real files that no package owns: the kernel package's hook runs after the old kernel is already gone, so saq copies each pair (`*.snap`) when it publishes it and promotes that copy to `*.old` when the next, different pair is published. It is "the previous default", not "known good". The initramfs holds the storage modules, so it boots, but `/lib/modules` of an older release is gone and only built-in drivers are available. `--no-keep-old` turns this off. Costs about one kernel plus one initramfs of space for each of the two copies; if `/boot` is full only a warning is printed.
- `--root DIR` works on another root, e.g. a freshly installed system.
- Images are reproducible: equal inputs give byte-identical output. Set
  `SOURCE_DATE_EPOCH` to stamp them with a real time.

## Live ISO from any root: `saq-live-iso`

```
saq-live-iso [--init PATH] [--kernel-version V] [--kernel FILE] [--busybox FILE]
             [--vol-id NAME] [--compression xz|zstd|gzip] [--serial] ROOTFS OUT.iso
```

`ROOTFS` is a directory or a tarball (`.tar`, `.tar.gz`, `.tar.xz`, `.tar.zst`,
`.tar.bz2`) of a complete root: `/usr`, `/etc`, a kernel image in `/boot` and its
modules (with `modules.dep`) in `/lib/modules`. A directory is only read, never
modified. The result is an ISO that boots on BIOS and UEFI from a CD, from a USB
stick written with `dd`, or as a plain **file on a [Ventoy](https://www.ventoy.net/)
stick** (copy it there, pick it in the Ventoy menu).

The live session has a **`live` user with no password** (root has none either), in
the groups that exist on the root (`wheel`, `sudo`, `video`, `audio`, ...), a home from
`/etc/skel`, and no password for `doas` or `sudo` (whichever the root has). Log in as
`live`; nothing is written to disk. On PAM systems the login must accept empty
passwords (`nullok`, the default on Debian, Ubuntu, Fedora and Arch). Kernel
arguments: `nolive` (no live user), `nopersist`, `init=`, `rootdelay=`,
`iso-scan/filename=`, `break`, `quiet`. An ext4 partition labelled `LIVE_PERSIST`
keeps the changes.

How the medium is found (`share/saq/init-live`), on every pass of a 30 s wait: a block
device that *is* the ISO (CD, `dd` stick, or the device-mapper device Ventoy builds), or
an ISO *file* on any partition — they are mounted read-only and `*.iso` up to three
directories deep is tried (`iso-scan/filename=/path.iso` or `findiso=` names it). exFAT
(Ventoy's default), NTFS, FAT and ext4 data partitions work when the kernel has the
driver. The ISO also has `/boot/grub/loopback.cfg`, so from a GRUB prompt:

```
loopback loop (hd0,1)/ISO/my.iso
set iso_path=/ISO/my.iso
export iso_path
set root=(loop)
configfile /boot/grub/loopback.cfg
```

The kernel needs `isofs` (ISO 9660), `squashfs`, `overlay` and `loop`, built in or as
modules; the module names go through `modules-live.list`. The root's init is found
automatically (`/usr/bin/runit`, `/sbin/init`, `/usr/lib/systemd/systemd`) or given with
`--init`. If the root has no static BusyBox (with `chown chmod grep sed cp`), pass
`--busybox FILE`. Host tools: `mksquashfs`, `grub-mkrescue`, `xorriso`, `mtools`.

Checked in QEMU (BIOS GRUB from a CD, an ISO file on a FAT partition with and without
`iso-scan`, and `loopback.cfg`) with an Ubuntu kernel. Not yet checked: UEFI, secure boot,
exFAT/NTFS data partitions, a real Ventoy stick. Ventoy's own boot modes are not
under our control: use its normal or GRUB2 mode and report what happens.

`saq --live --kernel VERSION --output FILE [--root DIR] [--busybox FILE]` builds just the
initramfs, never touching the root.

## GRUB fallback entry

saq only maintains the files. A static `grub.cfg` that boots the aliases can add one more entry for the previous pair (same `root=`/options as the main entry):

```
menuentry "Faseela (previous kernel)" {
    linux  /boot/vmlinuz.old root=UUID=... ro
    initrd /boot/initramfs.img.old
}
```

## Choosing modules

`share/saq/modules.list` is the default set. To change it on a
system, add files to `/etc/saq/modules.d/*.list`: one or more module
names per line, `#` for comments, and `!name` to drop a default.

```
# /etc/saq/modules.d/local.list
nvidia-drm
!btrfs
```

Modules built into the kernel are skipped silently. Dependencies come from the
kernel's `modules.dep`, and firmware named by the included modules is copied in
(compressed files are unpacked, globs such as `amdgpu/*.bin` are expanded).

## Kernel command line

`root=` (`/dev/..`, `UUID=`, `LABEL=`, `PARTUUID=`, `PARTLABEL=`),
`rootfstype=`, `rootflags=`, `ro`/`rw` (default `ro`), `rootwait`,
`rootdelay=N` (give up after N seconds, default 30), `init=` (default
`/usr/bin/runit`), `break` / `break=postmount` (open a shell before or after
mounting root), `quiet`.

`PARTUUID=` and `PARTLABEL=` depend on what the BusyBox `findfs` can resolve;
prefer `UUID=`.

## What BusyBox must provide

Static, with `sh mount umount mkdir mknod switch_root modprobe findfs sleep cat`
(the generator checks this and refuses to build otherwise). `modprobe` must be
the full one, not `MODPROBE_SMALL`, because modules are loaded by name from the
generated `modules.dep`.

## Not implemented yet

LUKS unlock, LVM activation, mdraid assembly and network root. The kernel
modules for device-mapper and RAID are included, but nothing in `/init` uses
them yet.

## Install and test

```
make install DESTDIR=/tmp/pkg      # PREFIX=/usr by default
make check                         # shellcheck + smoke test
```

The smoke test builds fake kernels, modules and firmware in a temporary root and
inspects the images. It needs `gcc`, `cpio`, `xz`, `zstd`, `kmod`, `shellcheck`
and a static `busybox` (on Debian/Ubuntu: `busybox-static`). It cannot boot an
image; that still has to be tried in QEMU or on hardware.

## Layout

```
src/saq          the generator   -> /usr/sbin/
share/saq/init     /init of the image
share/saq/modules.list
tests/smoke.sh
```
