#!/usr/bin/env bash
# Smoke test for saq on a fake root filesystem.
#
# Needs: bash, gcc, cpio, gzip, xz, zstd, kmod (depmod/modinfo) and a *static*
# busybox on the host that has findfs/modprobe/switch_root (Debian/Ubuntu:
# busybox-static). It cannot boot the result; it checks what the image holds.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$HERE/src/saq"

for tool in gcc cpio gzip xz zstd depmod modinfo busybox; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "smoke: missing tool: $tool" >&2
        exit 2
    }
done

T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
ROOT="$T/root"
pass=0

ok() {
    pass=$((pass + 1))
    echo "ok   - $*"
}
fail() {
    echo "FAIL - $*" >&2
    exit 1
}
check() { # check "description" command...
    local what="$1"
    shift
    if "$@"; then ok "$what"; else fail "$what"; fi
}
run() { "$GEN" --root "$ROOT" --quiet "$@"; }

# ---- fake root ------------------------------------------------------------
make_module() { # make_module NAME FIRMWARE...
    local name="$1" info="license=GPL" fw
    shift
    for fw in "$@"; do info+="\\0firmware=$fw"; done
    printf '__attribute__((section(".modinfo"), used)) static const char i[] = "%b";\n' "$info" >"$T/$name.c"
    gcc -c -o "$T/$name.ko" "$T/$name.c"
}

make_kernel() { # make_kernel VERSION
    local v="$1" d="$ROOT/lib/modules/$1/kernel"
    mkdir -p "$d/drivers" "$d/fs"
    echo "fake kernel $v" >"$ROOT/boot/vmlinuz-$v"
    cp "$T/ahci.ko" "$d/drivers/ahci.ko"
    xz -c "$T/ahci.ko" >"$d/drivers/ahci.ko.xz"
    rm "$d/drivers/ahci.ko"
    cp "$T/libahci.ko" "$d/drivers/libahci.ko"
    zstd -q -c "$T/ext4.ko" >"$d/fs/ext4.ko.zst"
    cat >"$ROOT/lib/modules/$v/modules.dep" <<DEP
kernel/drivers/ahci.ko.xz: kernel/drivers/libahci.ko
kernel/drivers/libahci.ko:
kernel/fs/ext4.ko.zst:
DEP
}

mkdir -p "$ROOT"/{boot,usr/bin,usr/lib/firmware/test,usr/lib/firmware/glob}
cp "$(command -v busybox)" "$ROOT/usr/bin/busybox"
echo "firmware blob" | xz -c >"$ROOT/usr/lib/firmware/test/fw.bin.xz"
echo "glob a" >"$ROOT/usr/lib/firmware/glob/a.bin"
echo "glob b" | zstd -q -c >"$ROOT/usr/lib/firmware/glob/b.bin.zst"

make_module ahci test/fw.bin test/missing.bin
make_module libahci
make_module ext4 'glob/*.bin'
make_kernel 6.1.0-test
make_kernel 6.2.0-test

# ---- tests --------------------------------------------------------------------
busybox sh -n "$HERE/share/saq/init" && ok "init script parses with BusyBox ash"
check "--help works" "$GEN" --help
check "--version works" "$GEN" --version
rc=0
"$GEN" --bogus >/dev/null 2>&1 || rc=$?
check "unknown option exits 2" test "$rc" = 2
rc=0
"$GEN" --all --kernel x >/dev/null 2>&1 || rc=$?
check "--all and --kernel are exclusive" test "$rc" != 0

before="$(find "$ROOT/boot" | sort)"
run --all --prune --update-default --dry-run >/dev/null
check "--dry-run changes nothing" test "$before" = "$(find "$ROOT/boot" | sort)"

run --all --prune --update-default 2>"$T/stderr" || fail "--all --prune --update-default"
ok "--all builds every kernel"
for v in 6.1.0-test 6.2.0-test; do
    check "image for $v exists" test -s "$ROOT/boot/initramfs-$v.img"
    check "image for $v is valid gzip" gzip -t "$ROOT/boot/initramfs-$v.img"
done
check "default kernel is the newest" test "$(readlink "$ROOT/boot/vmlinuz")" = "vmlinuz-6.2.0-test"
check "default initramfs is the newest" test "$(readlink "$ROOT/boot/initramfs.img")" = "initramfs-6.2.0-test.img"
check "missing firmware is reported" grep -q 'test/missing.bin' "$T/stderr"

X="$T/extract"
mkdir "$X"
(cd "$X" && gzip -dc "$ROOT/boot/initramfs-6.2.0-test.img" | cpio -idm --quiet)
M="$X/lib/modules/6.2.0-test/kernel"
check "/init is executable" test -x "$X/init"
check "/init matches the shipped script" cmp -s "$X/init" "$HERE/share/saq/init"
check "busybox is included" test -x "$X/bin/busybox"
check "applet links exist" test "$(readlink "$X/bin/switch_root")" = busybox
check "findfs applet is linked" test -L "$X/bin/findfs"
check "xz module is decompressed" test -f "$M/drivers/ahci.ko"
check "zstd module is decompressed" test -f "$M/fs/ext4.ko"
check "module dependency is pulled in" test -f "$M/drivers/libahci.ko"
check "modules.dep is regenerated for the image" grep -q '^kernel/drivers/ahci.ko:' "$X/lib/modules/6.2.0-test/modules.dep"
check "xz firmware is decompressed" test "$(cat "$X/lib/firmware/test/fw.bin")" = "firmware blob"
check "glob firmware is expanded (plain file)" test -f "$X/lib/firmware/glob/a.bin"
check "glob firmware is expanded (zstd file)" test "$(cat "$X/lib/firmware/glob/b.bin")" = "glob b"
check "/etc/modules lists ahci" grep -qx ahci "$X/etc/modules"
check "/etc/modules lists ext4" grep -qx ext4 "$X/etc/modules"
check "builtin/absent modules are not listed" test "$(grep -c nvme "$X/etc/modules" || true)" = 0

cp "$ROOT/boot/initramfs-6.2.0-test.img" "$T/first.img"
run --kernel 6.2.0-test
check "builds are reproducible" cmp -s "$T/first.img" "$ROOT/boot/initramfs-6.2.0-test.img"

mkdir -p "$ROOT/etc/saq/modules.d"
printf '# local override\n!ext4\n' >"$ROOT/etc/saq/modules.d/local.list"
run --kernel 6.2.0-test
rm -rf "$X"
mkdir "$X"
(cd "$X" && gzip -dc "$ROOT/boot/initramfs-6.2.0-test.img" | cpio -idm --quiet)
check "'!module' in modules.d removes a module" test ! -f "$X/lib/modules/6.2.0-test/kernel/fs/ext4.ko"
rm "$ROOT/etc/saq/modules.d/local.list"

rm "$ROOT/boot/vmlinuz-6.1.0-test"
run --prune --update-default
check "--prune removes images of removed kernels" test ! -e "$ROOT/boot/initramfs-6.1.0-test.img"
check "--prune keeps images of installed kernels" test -s "$ROOT/boot/initramfs-6.2.0-test.img"

# A broken kernel must not stop the others, but must make the run fail.
make_kernel 6.3.0-test
rm -rf "$ROOT/lib/modules/6.2.0-test"
rm -f "$ROOT/boot/initramfs-6.2.0-test.img" "$ROOT/boot/initramfs-6.3.0-test.img"
rc=0
run --all --update-default 2>/dev/null || rc=$?
check "--all fails when one kernel cannot be built" test "$rc" != 0
check "--all still builds the healthy kernel" test -s "$ROOT/boot/initramfs-6.3.0-test.img"
check "--update-default skips kernels without an image" test "$(readlink "$ROOT/boot/vmlinuz")" = "vmlinuz-6.3.0-test"

check "no temporary files are left behind" test -z "$(find "$ROOT/boot" -name '.initramfs-*.tmp.*')"

echo "all $pass checks passed"
