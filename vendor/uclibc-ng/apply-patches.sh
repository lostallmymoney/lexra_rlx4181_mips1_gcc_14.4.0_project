#!/bin/bash
# apply-patches.sh <uclibc-ng-source-dir> - apply this tree's
# patches/ set to a COPY of the pristine uClibc-ng 1.0.59 source.
#
# The vendored source in src/ is pristine upstream (tag v1.0.59);
# every Sengled adaptation lives in patches/ and is applied to the
# build-time copies the toolchain scripts make of it - never to
# src/ itself. Called by GCC-14.4-Lexra-RLX4181/build-toolchain.sh
# (both uClibc-ng build copies: the atexit harvest and the sysroot
# build) and by GCC-14.4-Lexra-RLX4181/build-shipped-runtime.sh
# (the shipped build), always before the copy is configured.
#
# Idempotent: a patch that reverse-applies cleanly is already in
# and is skipped. Fail-loud: a patch that applies neither forward
# nor reverse aborts the build - a silently half-patched source is
# the failure mode this step exists to kill. After applying, the
# patched state of all three adaptations is verified by content.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:?usage: apply-patches.sh <uclibc-ng-source-dir>}"
[ -d "$TARGET" ] || { echo "ERROR: no such uClibc-ng source dir: $TARGET" >&2; exit 1; }

for p in "$HERE"/patches/*.patch; do
    name="$(basename "$p")"
    if patch --dry-run -R -p1 -d "$TARGET" < "$p" >/dev/null 2>&1; then
        echo "  uClibc-ng patch $name: already applied"
    elif patch --dry-run -p1 -d "$TARGET" < "$p" >/dev/null 2>&1; then
        patch -p1 -d "$TARGET" < "$p" >/dev/null
        echo "  uClibc-ng patch $name: applied"
    else
        echo "ERROR: uClibc-ng patch $name applies neither forward nor" >&2
        echo "reverse to $TARGET - the source is neither pristine nor" >&2
        echo "patched; refusing to build on a half-patched source." >&2
        exit 1
    fi
done

# Post-application verification, by content (the same conditions
# build-toolchain.sh asserts again on the installed sysroot header).
grep -q '^#if defined _FILE_OFFSET_BITS && _FILE_OFFSET_BITS == 64$' "$TARGET/include/features.h" \
    && grep -q 'vendor uClibc 0.9.30.3' "$TARGET/include/features.h" \
    && ! grep -q 'is not supported by uClibc-ng' "$TARGET/include/features.h" \
    || { echo "ERROR: $TARGET/include/features.h is not in the patched (002) state" >&2; exit 1; }
grep -q '^#include <unistd.h>$' "$TARGET/libc/sysdeps/linux/common/adjtimex.c" \
    || { echo "ERROR: $TARGET/libc/sysdeps/linux/common/adjtimex.c is not in the patched (003) state" >&2; exit 1; }
grep -q '__builtin_signbit(x)' "$TARGET/libc/stdio/_fpmaxtostr.c" \
    || { echo "ERROR: $TARGET/libc/stdio/_fpmaxtostr.c is not in the patched (001) state" >&2; exit 1; }
echo "  uClibc-ng patches verified in $TARGET"
