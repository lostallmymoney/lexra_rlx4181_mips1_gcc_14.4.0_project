# Source this file to get the fixed Lexra-safe toolchain on PATH and the
# standard flags in your shell, for quick manual builds/experiments:
#
#   source GCC-14.4-Lexra-RLX4181/env.sh
#   mips-buildroot-linux-uclibc-gcc $LEXRA_CFLAGS -o foo foo.c
#
# For actual per-binary reconstructions, still write a real Makefile using
# these same values explicitly (see any existing bin/<name>/Makefile) -
# this file is for quick one-off compiles/checks, not the build system.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SENGLED_TOOLCHAIN="$HERE/toolchain"
export PATH="$SENGLED_TOOLCHAIN/bin:$PATH"
export CROSS_COMPILE="mips-buildroot-linux-uclibc-"
export CC="${SENGLED_TOOLCHAIN}/bin/mips-buildroot-linux-uclibc-gcc"
export CXX="${SENGLED_TOOLCHAIN}/bin/mips-buildroot-linux-uclibc-g++"
export AS="${SENGLED_TOOLCHAIN}/bin/mips-buildroot-linux-uclibc-as"
export LD="${SENGLED_TOOLCHAIN}/bin/mips-buildroot-linux-uclibc-ld"
export AR="${SENGLED_TOOLCHAIN}/bin/mips-buildroot-linux-uclibc-ar"
export STRIP="${SENGLED_TOOLCHAIN}/bin/mips-buildroot-linux-uclibc-strip"
export OBJDUMP="${SENGLED_TOOLCHAIN}/bin/mips-buildroot-linux-uclibc-objdump"
export READELF="${SENGLED_TOOLCHAIN}/bin/mips-buildroot-linux-uclibc-readelf"

# mips1/soft-float are the toolchain's own configure-time
# defaults now (see README.md), but every project Makefile still passes
# these explicitly for clarity - do the same in quick manual builds.
export LEXRA_CFLAGS="-EB -mabi=32 -fno-pie -no-pie -march=mips1 -mfp32 -msoft-float -fno-builtin"
export LEXRA_LDFLAGS="-EB -mabi=32 -fno-pie -no-pie -march=mips1 -mfp32 -msoft-float"

# Quick sanity check: scan a binary for Lexra-unsupported opcodes.
# Usage: scan_bin_for_illegal_lexra <path-to-binary>
scan_bin_for_illegal_lexra() {
    "$OBJDUMP" -d "$1" | grep -oiE '\bmovz\b|\bmovn\b|\bclz\b' | sort | uniq -c
}

echo "Sengled Lexra toolchain ready: CC=$CC"
echo "Use \$LEXRA_CFLAGS / \$LEXRA_LDFLAGS, or run scan_bin_for_illegal_lexra <binary> to check for unsupported opcodes."
