# uclibc-ng

The C library itself - `libc.a`/`libc.so.0`, `uclibc_nonshared.a`,
`libpthread_nonshared.a`, `ld-uClibc.so.0`, and the empty
`libpthread.a`/`libm.a`/`libdl.a`/`libcrypt.a`/`librt.a`/`libnsl.a`/
`libresolv.a` compatibility stubs. This is a **shared build** producing
the "10 standard runtime libraries" this project's `rootfs/lib/` tree
needs (see `lib/ld-uClibc.so.0/`, `lib/libc.so.0/`, `lib/libcrypt.so.0/`,
`lib/libdl.so.0/`, `lib/libm.so.0/`, `lib/libpthread.so.0/` -  each just
points back here rather than duplicating the source), not five/six
independent reconstructions.

- **Status:** builds, `mips1`, zero Lexra-unsupported opcodes across
  every `.a` member and both real `.so` files. Not yet hardware tested.
- **Fixes the "sixth bug"** documented in `GCC-14.4-Lexra-RLX4181/README.md`:
  uClibc-ng itself was never rebuilt with any of the Lexra fixes GCC got,
  even though it's linked into every dynamic binary in this project.
  Confirmed concretely by rebuilding `VANILLArecontruct/rootfs/bin/iperf/`
  against the new libs: its `e_flags` now read `mips1` (was `mips32`,
  from `uclibc_nonshared.a(atexit.os)` pulling the whole binary's merged
  ELF flags up).
- **Source:** `src/` - a pristine copy of
  [uclibc-ng](https://github.com/wbx-github/uclibc-ng) tag `v1.0.59`
  (commit `ae4a98f9612c7050b1bceb9c8340fe5ef9345e22` - the tag object
  itself is a dangling/unreachable ref upstream, so this is the commit
  it names). The tracked source is pristine; every Sengled
  adaptation lives in `patches/` beside `src/` and is applied to
  build-time copies of the source by `apply-patches.sh` (see
  "The source patches" below) - the builds never consume `src/`
  directly. The device's *original*
  libc is ancient classic uClibc 0.9.30.3; this is uClibc-ng, a modern
  actively-maintained fork - not byte-compatible, but that's this
  project's established direction (embrace the modern toolchain rather
  than replicate the ancient one exactly).
- **Compiler:** built with the already-patched
  `GCC-14.4-Lexra-RLX4181/toolchain/bin/mips-buildroot-linux-uclibc-gcc`.
  Its own configure-time defaults (`-march=mips1 -mfp32 -msoft-float`,
  from GCC's own earlier Lexra-fix pass) are what make this build
  Lexra-safe - `uClibc.config`'s `UCLIBC_EXTRA_CFLAGS` is deliberately
  left empty so nothing fights those defaults.
- **Config:** `uClibc.config` - MIPS o32, big-endian, soft-float/no-FPU,
  NPTL threading, C99 math, IPv6, wide-char and SUSv2/3/4 legacy-function
  support all on. See "Config choices and why" below for the two
  iteration-driven additions (WCHAR, SUSv*_LEGACY) and known gaps.
- **Build:** `./build.sh` (see its own header comment), or `./build.sh
  install` to also deploy into the toolchain sysroot and the sibling
  `lib/<name>/` dirs.

## The source patches

`patches/` holds the three Sengled adaptations to the pristine
source, mirroring the GCC toolchain's `patches/` arrangement:
`001-fpmaxtostr-builtin-signbit.patch` (below),
`002-features-h-file-offset-bits.patch` (restores the 1.0.54
conditional `_FILE_OFFSET_BITS` behaviour in `include/features.h`
- the Option-C edit) and `003-adjtimex-include-unistd.patch`
(`libc/sysdeps/linux/common/adjtimex.c` gains `<unistd.h>`, forced
by the v29 shipped build's 2.6.30 kernel headers). Each patch file
carries its own reasoning; `apply-patches.sh` applies the set to a
build copy, idempotently and fail-loud.

`patches/001` - `libc/stdio/_fpmaxtostr.c`: printf's float-formatting code calls
`signbit()` to detect `-nan`. On a normal (has-FPU) build,
`bits/mathinline.h` silently redefines `signbit(x)` as a compiler
builtin, so nobody notices this is an external call. On a genuinely
FPU-less soft-float build (`UCLIBC_HAS_FPU=n` - this device), no such
override exists, so it's a real call to `__signbit()`, which lives in
**libm**, not libc - and since `libc.so` is linked `-Wl,-z,defs` (no
undefined symbols allowed), the whole `lib/libc.so` link failed outright
with `undefined reference to '__signbit'`. Fixed by using
`__builtin_signbit()` instead - a compile-time bit-test intrinsic, no
libm call, no FPU instruction, safe on any target. This is a genuine
upstream uClibc-ng portability gap for no-FPU targets, not anything
Lexra-specific.

## A real Lexra-unsafe bug found and fixed in uClibc-ng itself

`src/libc/string/mips/memcpy.S` and `memset.S` are glibc's hand-written
MIPS-optimized string routines, which use `lwl`/`lwr`/`swl`/`swr`
(unaligned-load/store) unconditionally for speed - **hand-written
assembly bypasses GCC's `-march=mips1`/`-mstrict-align` codegen
restriction entirely**, since that only governs what the *compiler*
emits, not literal instruction mnemonics in a `.S` file. This is the
same class of bug as gotcha #1 in `GCC-14.4-Lexra-RLX4181/README.md`
(GCC's own `ISA_HAS_LWL_LWR` patch), just manifesting in libc's
assembly instead of compiler codegen. First build of this library
linked clean but `libc.so.0`'s opcode scan showed 27 `lwl`/26 `lwr`/
3 `swl` - traced to exactly these two files.

**Fix:** `UCLIBC_HAS_STRING_ARCH_OPT` is off in `uClibc.config`, which
makes the build fall back to `src/libc/string/generic/memcpy.c`/
`memset.c` (portable C, no hand-written asm, no Lexra-unsupported
opcodes) instead. Slower than the hand-tuned version, but correctness
over speed is this whole project's stated priority. No other files
under `libc/string/mips/` exist besides these two, so this option only
affects memcpy/memset.

**Reversed 2026-11-21:** the premise above is disproven. A test
binary built full of `lwl`/`lwr`/`swl`/`swr` (unaligned loads and
stores at every byte offset, bit-exact data checks, plus a 16-byte
pair copy loop) ran on the real hub and passed every check - the
RLX4181 executes the pair natively (the vendor bootcode also runs
it before any kernel exists, in the window where its exception
handler is not yet installed, so no trap emulation can explain it
either). `UCLIBC_HAS_STRING_ARCH_OPT` is enabled again in
build-toolchain.sh; the arch-optimized memcpy/memset are back.

## Config choices and why (iteration-driven, found via `iperf` test-builds)

Two config options in `uClibc.config` are on that a minimal/default
config would leave off, because disabling them broke real code during
validation:

- **`UCLIBC_HAS_WCHAR=y`** - without it, `<cstdlib>` in this toolchain's
  own (already-patched, separately-built) libstdc++ headers unconditionally
  declares `using ::mblen; using ::mbstowcs; ...` etc, which don't exist
  without wide-char support - **every C++ translation unit fails to
  compile** (`iperf`'s `Client.cpp` was the first hit). Wide-char
  support in libc is a hard prerequisite for this toolchain's C++
  support, not an optional extra.
- **`UCLIBC_SUSV2_LEGACY=y` / `UCLIBC_SUSV3_LEGACY=y` /
  `UCLIBC_SUSV3_LEGACY_MACROS=y` / `UCLIBC_SUSV4_LEGACY=y`** - without
  these, `usleep()` (POSIX.1-2001, marked obsolescent/removed in
  POSIX.1-2008, still called directly by huge amounts of real-world C
  code including `iperf`'s `Reporter.c`) isn't declared in
  `unistd.h`, an implicit-declaration compile error. The device's real
  original libc (uClibc 0.9.30.3, predating this SUSv3/SUSv4-legacy
  pruning distinction entirely) would have had all of these
  unconditionally; enabling them here restores that "everything a
  normal embedded Linux program expects" baseline uClibc-ng now gates
  behind opt-in flags.

## Known gaps (not chased down - flag for a follow-up if something needs them)

- **`iconv.h`/`libintl.h`/`utmp.h`/`utmpx.h`/`wordexp.h`/`thread_db.h`/
  `ucontext.h`/`ftw.h` are absent** from this build's own header output
  (`UCLIBC_HAS_LIBICONV`/`LIBINTL`/`UTMP`/`UTMPX`/`WORDEXP`/
  `PTHREADS_DEBUG_SUPPORT`/`CONTEXT_FUNCS`/`FTW` are all off) - so no
  `iconv()`, no `gettext()`, no login/wtmp tracking, no `wordexp()`, no
  gdb pthread debugging, no `makecontext`/`swapcontext`, no `ftw()`.
  `build.sh`'s header install is a non-destructive merge (`rsync`
  without `--delete`), so the *original* stock toolchain's copies of
  these headers are still physically present in the sysroot (harmless
  leftovers) - but calling any of these functions will now fail to
  **link** (declaration present, no implementation). If a future binary
  needs one of these, flip the matching option on in `uClibc.config`
  and re-run `build.sh install`.
- **DO_XSI_MATH (bessel functions) is off** - `j0`/`j1`/`jn`/`y0`/`y1`/
  `yn` aren't in libm. Enable `DO_XSI_MATH=y` if something needs them.
- **No separate `libpthread.so.0`/`libm.so.0`/`libdl.so.0`/
  `libcrypt.so.0`/`librt.so.0` files exist at all** - not a regression,
  see the sibling manifests for why, and confirmed identical in the
  original *unmodified* stock Bootlin toolchain (byte-identical 8-byte
  empty `.a` archives, same build date/config lineage).

## Validation performed

- `readelf -h`: `mips1` on every produced `.a` member and both real
  `.so` files (`libc.so.0`, `ld-uClibc.so.0`).
- `objdump -d | grep lwl/lwr/swl/swr/movz/movn/clz`: zero matches,
  across the *entire* `libc.a` (1,294+ members), `uclibc_nonshared.a`,
  `libpthread_nonshared.a`, and both shared objects.
- `iperf` rebuilt against the new libs: `e_flags` now `mips1` (was
  `mips32`). Confirms the documented bug is actually fixed, not just
  that this library builds clean in isolation.
- Not yet tested on real hardware.

## A note for the separate open bignum-crash investigation

While chasing the `memcpy`/`memset` lwl/lwr bug above, I specifically
checked uClibc-ng's own bignum/multi-precision code paths
(`libc/stdlib/random_r.c`'s Knuth generator does 32x32->64 multiplies;
the C99 libm's `e_pow.c`/`e_exp.c`/`e_log.c` do iterative
polynomial/rational-approximation arithmetic) for anything resembling
the RSA-crash symptom (works under qemu-mips, fails on real hardware).
Nothing jumped out - no hand-written assembly in libc/libm touches
64-bit or wider integer arithmetic the way the crashing SSH/RSA code
apparently does, and libc's own code is now confirmed opcode-clean.
This doesn't rule out a libgcc soft-float helper routine (`__muldi3`,
`__divdi3`, etc - GCC's territory, not uClibc-ng's) being the actual
culprit, which would explain "works under QEMU" (QEMU doesn't model
Lexra's missing instructions) - worth checking `libgcc.a`'s 64-bit
integer helpers specifically in that investigation, by analogy with the
already-documented `__adddf3`/`__divdf3` soft-float-double bug class in
`GCC-14.4-Lexra-RLX4181/README.md`.
