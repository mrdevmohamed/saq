#!/usr/bin/env bash
# Tests of the live side of saq: share/saq/init-live, `saq --live`, saq-live-iso.
#
# Needs what smoke.sh needs; the ISO part also needs mksquashfs, grub-mkrescue,
# xorriso and mtools (Debian: squashfs-tools grub-pc-bin grub-efi-amd64-bin xorriso
# mtools) and is skipped with a notice when they are missing. It cannot boot the
# result (the live boot was checked in QEMU, see README); it checks what the image holds.
# shellcheck disable=SC2016 # patterns for GRUB/sh code are literal on purpose
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAQ="$HERE/src/saq"
ISO_TOOL="$HERE/src/saq-live-iso"
INIT="$HERE/share/saq/init-live"

for tool in gcc cpio gzip depmod busybox; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "live: missing tool: $tool" >&2
        exit 2
    }
done

T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
pass=0
ok() {
    pass=$((pass + 1))
    echo "ok   - $*"
}
fail() {
    echo "FAIL - $*" >&2
    exit 1
}
check() {
    local what="$1"
    shift
    if "$@"; then ok "$what"; else fail "$what"; fi
}

# ---- the init script ---------------------------------------------------------------
busybox sh -n "$INIT" && ok "init-live parses with BusyBox ash"
check "media scan reads iso-scan/filename and findiso" grep -q 'iso-scan/filename=\*' "$INIT"
check "device-mapper devices are scanned (Ventoy)" grep -q '/dev/mapper/\*' "$INIT"
check "an ISO file is loop-mounted" grep -q 'mount -t iso9660 -o ro,loop' "$INIT"
check "the host partition stays mounted for the loop" grep -q 'mount -o move /iso-host /newroot/media/iso-host' "$INIT"

# make_live_user, extracted and run on a scratch root. uid 1000 is taken on purpose.
R="$T/r"
mkdir -p "$R/etc/skel" "$R/etc/sudoers.d" "$R/home" "$R/bin"
printf 'root:x:0:0:r:/root:/bin/sh\nalice:x:1000:1000::/home/alice:/bin/sh\n' >"$R/etc/passwd"
printf 'root:x:0:\nalice:x:1000:\nwheel:x:10:\nvideo:x:44:bob\naudio:x:29:\nsudo:x:27:live\n' >"$R/etc/group"
printf 'root:*:19980:0:::::\n' >"$R/etc/shadow"
printf 'permit persist :wheel\n' >"$R/etc/doas.conf"
echo skel >"$R/etc/skel/.profile"
sed -n '/^# >>> live-user/,/^# <<< live-user/p' "$INIT" | sed 's/chown -R "\$uid:\$gid" "\$r\/home\/live"/true/' >"$T/lu.sh"
runlu() { sh -c ". '$T/lu.sh'; make_live_user '$R'"; }
runlu
runlu # twice: persistence re-applies it at every boot
check "live user gets the first free uid" test "$(grep -c '^live:x:1001:1001:' "$R/etc/passwd")" = 1
check "live user has an empty password" grep -q '^live::' "$R/etc/shadow"
check "root is unlocked in the live session" grep -q '^root::' "$R/etc/shadow"
check "existing groups get live exactly once" bash -c "grep -q '^wheel:x:10:live\$' '$R/etc/group' && grep -q '^video:x:44:bob,live\$' '$R/etc/group' && grep -q '^audio:x:29:live\$' '$R/etc/group' && grep -q '^sudo:x:27:live\$' '$R/etc/group'"
check "missing groups are not invented" bash -c "! grep -q '^render:' '$R/etc/group'"
check "private group exists once" test "$(grep -c '^live:x:1001:' "$R/etc/group")" = 1
check "home is filled from /etc/skel" test -f "$R/home/live/.profile"
check "doas rule added once" test "$(grep -c '^permit nopass live$' "$R/etc/doas.conf")" = 1
check "sudoers drop-in is written" grep -q 'live ALL=(ALL) NOPASSWD: ALL' "$R/etc/sudoers.d/90-saq-live"
check "banner is added once" test "$(grep -c 'Live session: log in as' "$R/etc/issue")" = 1
check "a root with bash gets bash" bash -c "! grep -q ':/bin/bash\$' '$R/etc/passwd'" # none here: /bin/sh

# ---- saq --live ----------------------------------------------------------------------
ROOT="$T/root"
mkdir -p "$ROOT"/{usr/bin,usr/lib/modules/6.9.0-live/kernel/fs,etc}
cp "$(command -v busybox)" "$ROOT/usr/bin/busybox"
printf '__attribute__((section(".modinfo"), used)) static const char i[] = "license=GPL";\n' >"$T/m.c"
gcc -c -o "$ROOT/usr/lib/modules/6.9.0-live/kernel/fs/isofs.ko" "$T/m.c"
gcc -c -o "$ROOT/usr/lib/modules/6.9.0-live/kernel/fs/exfat.ko" "$T/m.c"
echo 'kernel/fs/isofs.ko:
kernel/fs/exfat.ko:' >"$ROOT/usr/lib/modules/6.9.0-live/modules.dep"
BEFORE="$(cd "$ROOT" && find . | sort)"
rc=0
"$SAQ" --live --root "$ROOT" --kernel 6.9.0-live --quiet >/dev/null 2>&1 || rc=$?
check "--live without --output is refused" test "$rc" != 0
rc=0
"$SAQ" --live --root "$ROOT" --kernel 6.9.0-live --output "$T/x.img" --prune >/dev/null 2>&1 || rc=$?
check "--live with --prune is refused" test "$rc" != 0
rc=0
"$SAQ" --root "$ROOT" --kernel 6.9.0-live --output "$T/x.img" >/dev/null 2>&1 || rc=$?
check "--output without --live is refused" test "$rc" != 0
"$SAQ" --live --root "$ROOT" --kernel 6.9.0-live --output "$T/live.img" --quiet
check "--live leaves the root untouched (no /boot, no lock file)" test "$BEFORE" = "$(cd "$ROOT" && find . | sort)"
X="$T/x"
mkdir "$X"
(cd "$X" && gzip -dc "$T/live.img" | cpio -idm --quiet)
check "image has the live init" cmp -s "$X/init" "$INIT"
check "image has the mount points" test -d "$X/iso-host" -a -d "$X/cdrom" -a -d "$X/ro" -a -d "$X/rw"
check "live applets are linked (chown, chmod, grep, sed, cp)" bash -c "for a in chown chmod grep sed cp; do test -L '$X/bin/'\$a || exit 1; done"
check "isofs is staged and listed" bash -c "grep -qx isofs '$X/etc/modules'"
check "exfat (Ventoy's default) is staged and listed" bash -c "grep -qx exfat '$X/etc/modules'"

# ---- saq-live-iso ----------------------------------------------------------------------
bash -n "$ISO_TOOL" && ok "saq-live-iso parses"
check "--help works" "$ISO_TOOL" --help
rc=0
"$ISO_TOOL" >/dev/null 2>&1 || rc=$?
check "no arguments exits 2" test "$rc" = 2
rc=0
"$ISO_TOOL" --bogus "$ROOT" "$T/o.iso" >/dev/null 2>&1 || rc=$?
check "unknown option exits non-zero" test "$rc" != 0
rc=0
"$ISO_TOOL" --init relative "$ROOT" "$T/o.iso" >/dev/null 2>&1 || rc=$?
check "--init must be absolute" test "$rc" != 0

if command -v mksquashfs >/dev/null && command -v grub-mkrescue >/dev/null && command -v xorriso >/dev/null && command -v mformat >/dev/null; then
    printf 'root:x:0:0:r:/root:/bin/sh\n' >"$ROOT/etc/passwd"
    printf 'root:x:0:\nwheel:x:10:\n' >"$ROOT/etc/group"
    mkdir -p "$ROOT/boot" "$ROOT/usr/sbin"
    echo "fake kernel" >"$ROOT/boot/vmlinuz-6.9.0-live"
    printf '#!/bin/sh\n' >"$ROOT/usr/sbin/init"
    chmod 755 "$ROOT/usr/sbin/init"
    # no kernel image: refused with a hint (a directory is never modified)
    mv "$ROOT/boot/vmlinuz-6.9.0-live" "$T/k"
    rc=0
    "$ISO_TOOL" "$ROOT" "$T/o.iso" >"$T/err" 2>&1 || rc=$?
    check "a root without a kernel image is refused" bash -c "test $rc != 0 && grep -q -- '--kernel FILE' '$T/err'"
    mv "$T/k" "$ROOT/boot/vmlinuz-6.9.0-live"
    BEFORE="$(cd "$ROOT" && find . | sort)"
    "$ISO_TOOL" --vol-id TESTLIVE --init /usr/sbin/init "$ROOT" "$T/live.iso" >"$T/log" 2>&1 || {
        cat "$T/log" >&2
        fail "saq-live-iso builds an ISO from a directory"
    }
    ok "saq-live-iso builds an ISO from a directory"
    check "the directory is not modified" test "$BEFORE" = "$(cd "$ROOT" && find . | sort)"
    ls_iso() { xorriso -indev "$T/live.iso" -ls "$1" 2>/dev/null; }
    for f in /boot/vmlinuz /boot/initramfs.img /boot/grub/grub.cfg /boot/grub/loopback.cfg /live/rootfs.squashfs; do
        check "ISO holds $f" bash -c "xorriso -indev '$T/live.iso' -ls '$(dirname "$f")' 2>/dev/null | grep -q '$(basename "$f")'"
    done
    xorriso -osirrox on -indev "$T/live.iso" -extract /boot/grub "$T/grub" >/dev/null 2>&1
    check "grub.cfg has three entries" test "$(grep -c '^menuentry' "$T/grub/grub.cfg")" = 3
    check "every kernel line carries \${isoparam} and init=" test "$(grep -c '^    linux .*init=/usr/sbin/init .*\${isoparam}' "$T/grub/grub.cfg")" = 3
    check "loopback.cfg has the same entries" test "$(grep -c '^menuentry' "$T/grub/loopback.cfg")" = 3
    check "Ventoy's iso_path becomes iso-scan/filename" grep -q 'set isoparam="iso-scan/filename=${iso_path}"' "$T/grub/grub.cfg"
    check "isoparam is defined before the first entry" bash -c "test \$(grep -n 'set isoparam=\"\"' '$T/grub/grub.cfg' | head -1 | cut -d: -f1) -lt \$(grep -n '^menuentry' '$T/grub/grub.cfg' | head -1 | cut -d: -f1)"
    check "the volume id is set" bash -c "xorriso -indev '$T/live.iso' -pvd_info 2>&1 | grep -q 'Volume Id.*TESTLIVE'"
    # tarball input (root needed for ownership; skipped otherwise)
    if [[ "$EUID" -eq 0 ]]; then
        (cd "$T" && tar -czf root.tar.gz -C "$ROOT" .)
        "$ISO_TOOL" --init /usr/sbin/init "$T/root.tar.gz" "$T/tar.iso" >"$T/log2" 2>&1 || {
            cat "$T/log2" >&2
            fail "saq-live-iso builds an ISO from a tarball"
        }
        ok "saq-live-iso builds an ISO from a tarball"
    else
        echo "skip - tarball input needs root"
    fi
else
    echo "skip - ISO build tests need mksquashfs, grub-mkrescue, xorriso and mtools"
fi

echo "all $pass checks passed"
