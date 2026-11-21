#!/bin/bash
# build-shipped-runtime.sh - promote the shipped runtime set into
# GCC-14.4-Lexra-RLX4181/runtime-ng/.
#
# PROMOTION ONLY (the v42 unification): this script compiles
# nothing. The four DSOs are built ONCE by step 0.0's
# build-toolchain.sh, on the one ground the whole project runs
# on: the sysroot uClibc-ng (the hub's 2.6.30 kernel headers,
# generic C string routines, LINUXTHREADS - built into the
# toolchain sysroot and installed there) and the toolchain's
# target libgcc/libstdc++, configured against that same
# sysroot so their probes measured the ground they ship on.
# Before the unification this script built a second uClibc and
# a second GCC target-library tree in step 2.1 to reach that
# ground; both are gone.
#
# What stays here, because promotion is the last gate before
# the image:
#   - the ground asserts: the uClibc build copy's .config must
#     carry the linuxthreads model (never an NPTL leftover),
#     and the libstdc++ must be mips1 (0x1007) with NO
#     __tls_get_addr import - the orphaned native-TLS import
#     that nothing on the shipped ground provides (the v35
#     ship-gate failure this build exists to prevent);
#   - the Lexra gate on the promoted set: zero rdhwr encodings.
#
# Called by HUMAN_SCRIPTS/2.1_BUILD_NEW_ROOTFS.sh when the
# promotion is missing (step 2.1 promotes the runtime it
# ships); also runnable standalone once the toolchain exists.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$HERE")"
TC="$HERE/toolchain"
PROMO="$HERE/runtime-ng"
UB2="$HERE/build-gcc-uclibc-sysroot"
TCLIB="$TC/mips-buildroot-linux-uclibc/lib"

[ -x "$TC/bin/mips-buildroot-linux-uclibc-gcc" ] || {
    echo "ERROR: project toolchain not built - run build-toolchain.sh (step 0.0) first" >&2; exit 1; }

# ------------------------------------------------------------ sources
LD_SRC="$UB2/src/lib/ld-uClibc-1.0.59.so"
LIBC_SRC="$UB2/src/lib/libuClibc-1.0.59.so"
LIBGCC_S="$TCLIB/libgcc_s.so.1"
LIBSTDCXX="$TCLIB/libstdc++.so.6.0.33"
for f in "$LD_SRC" "$LIBC_SRC" "$LIBGCC_S" "$LIBSTDCXX"; do
    [ -f "$f" ] || {
        echo "ERROR: toolchain product missing: $f" >&2
        echo "Step 0.0 (build-toolchain.sh) builds all four - run it first." >&2
        exit 1; }
done

# ------------------------------------------------------------ ground asserts
# The uClibc build copy must be the converged one - refuse to
# promote an NPTL-era leftover (same guards its configure
# carried; a silent drift here poisons the image).
CFG="$UB2/src/.config"
[ -f "$CFG" ] || { echo "ERROR: sysroot uClibc build copy has no .config ($CFG)" >&2; exit 1; }
grep -q '^UCLIBC_HAS_LINUXTHREADS=y' "$CFG" || {
    echo "ERROR: sysroot uClibc .config is not on the linuxthreads model - re-run build-toolchain.sh" >&2; exit 1; }
grep -q '^# UCLIBC_HAS_THREADS_NATIVE is not set' "$CFG" || {
    echo "ERROR: sysroot uClibc .config still enables NPTL - re-run build-toolchain.sh" >&2; exit 1; }
! grep -q '^UCLIBC_HAS_TLS=y' "$CFG" || {
    echo "ERROR: sysroot uClibc .config still enables TLS - re-run build-toolchain.sh" >&2; exit 1; }

# The atexit poison guard, applied to the pair: the merged
# e_flags must be the mips1 set (0x1007), never the mips32 set
# a stock sysroot member would stamp.
"$TC/bin/mips-buildroot-linux-uclibc-readelf" -h "$LIBSTDCXX" | grep -m1 Flags | grep -q '0x1007' || {
    echo "ERROR: toolchain libstdc++.so is not mips1 (e_flags) - refusing to promote" >&2; exit 1; }
# The defect the ground discipline exists to prevent: an
# orphaned native-TLS import that nothing on the shipped
# ground provides.
! "$TC/bin/mips-buildroot-linux-uclibc-nm" -D -u "$LIBSTDCXX" | grep -q '__tls_get_addr' || {
    echo "ERROR: toolchain libstdc++.so imports __tls_get_addr - it was configured against an NPTL ground; re-run build-toolchain.sh" >&2; exit 1; }

# ------------------------------------------------------------ promotion
STRIP="$TC/bin/mips-buildroot-linux-uclibc-strip"
NM="$TC/bin/mips-buildroot-linux-uclibc-nm"
OBJDUMP="$TC/bin/mips-buildroot-linux-uclibc-objdump"

mkdir -p "$PROMO"
rm -f "$PROMO"/*.so "$PROMO"/*.so.* "$PROMO"/*.exports.txt

promote() { # $1 = source file, $2 = shipped name
    "$STRIP" -o "$PROMO/$2" "$1"
    chmod 755 "$PROMO/$2"
    "$NM" -D --defined-only "$PROMO/$2" | awk 'NF >= 3 {print $NF}' \
        | sed 's/@.*//' | sort -u > "$PROMO/$2.exports.txt"
    echo "  promoted $2: $(stat -c%s "$PROMO/$2") bytes, $(wc -l < "$PROMO/$2.exports.txt") exports"
}

echo "Promoting the shipped runtime set into $PROMO ..."
promote "$LD_SRC" "ld-uClibc-1.0.59.so"
promote "$LIBC_SRC" "libuClibc-1.0.59.so"
promote "$LIBGCC_S" "libgcc_s.so.1"
promote "$LIBSTDCXX" "libstdc++.so.6"

# Lexra gate on the whole shipped runtime set: zero rdhwr
# instructions - rdhwr traps to a kernel that does not emulate
# it on this platform. (lwl/lwr/swl/swr are NOT gated: the
# RLX4181 executes the unaligned pair natively - proven on the
# real hub 2026-11-21, the pairtest binary passing at every
# offset.) rdhwr must NOT be checked by mnemonic: this
# toolchain's objdump targets MIPS-I and renders rdhwr as
# '.word 0x7c03e83b', so a mnemonic grep is blind to it (proven
# on the NPTL sysroot libc: 915 encodings, 0 mnemonics). The
# rdhwr check therefore scans executable sections for the
# instruction encoding itself: SPECIAL3, rs=0, funct 0x3B.
python3 - "$PROMO" <<'PYEOF'
import os, struct, sys
promo = sys.argv[1]
bad = 0
for name in ("ld-uClibc-1.0.59.so", "libuClibc-1.0.59.so",
             "libgcc_s.so.1", "libstdc++.so.6"):
    data = open(os.path.join(promo, name), "rb").read()
    shoff = struct.unpack(">I", data[0x20:0x24])[0]
    shentsize = struct.unpack(">H", data[0x2E:0x30])[0]
    shnum = struct.unpack(">H", data[0x30:0x32])[0]
    hits = 0
    for i in range(shnum):
        off = shoff + i * shentsize
        shtype = struct.unpack(">I", data[off + 4:off + 8])[0]
        flags = struct.unpack(">I", data[off + 8:off + 12])[0]
        offset = struct.unpack(">I", data[off + 16:off + 20])[0]
        size = struct.unpack(">I", data[off + 20:off + 24])[0]
        if shtype != 1 or not (flags & 0x4):  # PROGBITS + EXECINSTR
            continue
        body = data[offset:offset + size]
        for j in range(0, len(body) - 3, 4):
            w = struct.unpack(">I", body[j:j + 4])[0]
            if (w & 0xFFE0003F) == 0x7C00003B:
                hits += 1
    print("  rdhwr encoding census %s: %d" % (name, hits))
    bad += hits
if bad:
    sys.stderr.write(
        "ERROR: shipped runtime carries %d rdhwr instructions - "
        "refusing to promote\n" % bad)
    sys.exit(1)
PYEOF
echo "Shipped runtime promoted: GCC-14.4-Lexra-RLX4181/runtime-ng/ (4 DSOs + export rosters)"
