# saq

Initramfs tool for the [Faseela](https://github.com/mrdevmohamed/faseela) distro.

`saq` builds `/boot/initramfs-VERSION.img` for every kernel
installed in `/boot`: a static BusyBox, the storage and filesystem modules from
`modules.list` (with their dependencies and firmware) and a small `/init` that
mounts the root filesystem and hands over to runit. The live ISO keeps its own
initramfs; this is for installed systems.

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
