# GCC-14.4-Lexra-RLX4181

A patched, reconfigured GCC 14.4.0 MIPS toolchain for the RTL8196E's Lexra
RLX4181 core, which needs several things a stock cross-compiler doesn't
provide. This file is the short, practical version.

## Configuration

The compiler is built for exactly one target:

- Target: `mips-buildroot-linux-uclibc`

- Architecture: `--with-arch=mips1` — MIPS I, the RLX4181's level

- ABI: `--with-abi=32` (o32)

- Floating point: `--with-float=soft` — the core has no FPU

- NaN encoding: `--with-nan=legacy`

- Languages: C and C++

- Version stamp: `--with-pkgversion='Sengled-lexra-patched-2026'`

- Loop optimizers: ISL is built in, so GCC's Graphite loop optimizations
  (`-floop-nest-optimize`, `-floop-block`, `-floop-interchange`, ...) are
  available. They fire only when a compile asks for them; default code
  generation is unchanged.

- Deliberately off: multilib (one target only), decimal float,
  libsanitizer, CLOOG, and initfini-array (the target ground uses the
  older init style).

There is no custom compiler mode for unaligned access: the RLX4181
executes `lwl`/`lwr`/`swl`/`swr` natively (proven on the real hub
2026-11-21 - see gotcha 1 below), so GCC is pristine in that respect.
The project's only shipped GCC patch is 002 (crti/crtn alignment).

The sysroot's C library is a separate recipe, built by the same script:
uClibc-ng against Linux 2.6.30 kernel headers, with 32-bit time and
linuxthreads — see the sections below.

## Inputs

Everything the build consumes is either vendored in this project or
downloaded by `build-toolchain.sh` itself — nothing is read from any
sibling tree:

- Vendored: `vendor/uclibc-ng/` (uClibc-ng v1.0.59 source, with its
  patch series and manifest) and `vendor/linux-2.6.30-kernel-headers/`
  (the Realtek SDK's Linux 2.6.30 header set).

- Downloaded by the script: the pristine GCC 14.4.0 tarball (patches
  001 + 002 applied), its prerequisites via download_prerequisites
  (GMP, MPFR, MPC, ISL), and the Bootlin base toolchain
  `mips32--uclibc--stable-2025.08-1` into `tools/` (SHA-256 verified;
  supplies binutils, GDB and the sysroot skeleton).

- By hand, in this project: `crt-src/crt1.S` (hand-written startup
  assembly), `crt-src/prebuilt/` (the five crt objects),
  `uclibc-sysroot-config.fragment`, and the configure flags pinned in
  `build-toolchain.sh`.

## Layout

- `toolchain/` — the actual usable compiler. A full copy of the original
  `tools/mips32--uclibc--stable-2025.08-1` (which stays untouched as a
  fallback), with the fixes below applied. **Use
  `toolchain/bin/mips-buildroot-linux-uclibc-gcc` for every binary in this
  project**, not the original toolchain.
- `toolchain/.stock-crt-backup/` — the original (broken-for-this-target)
  `crt1.o`/`crti.o`/`crtbegin.o`/`crtend.o`/`crtn.o`, kept for reference,
  plus the stock `uclibc_nonshared.a` whose `atexit.os` member was
  replaced with a mips1 rebuild (2026-11-07, see bug #6).
- `gcc-14.4.0-src/` — GCC source with the two patches applied (see below).
- `crt-src/crt1.S` — hand-written replacement for uClibc-ng's own `_start`
  (its prebuilt `crt1.o` has a Lexra-fatal bug no compile flag can fix).
- `crt-src/prebuilt/` — the five rebuilt crt objects, already installed
  into `toolchain/`, kept here too so they don't need re-deriving if
  `toolchain/` is ever regenerated from the stock copy.
- `build-gcc-mips1/` — the GCC build tree (`configure` + `make all-gcc
  all-target-libgcc all-target-libstdc++-v3`) that produced the
  installed compiler (C and C++) and the `crt-src/prebuilt/` objects.
  Needed if you ever have to rebuild
  `crtbegin.o`/`crtend.o`/`crti.o`/`crtn.o` again (see below); safe to
  delete otherwise and regenerate from `gcc-14.4.0-src/` if truly
  needed. `build-gcc-mips1-c-only/` is the retired C-only predecessor
  tree, kept for reference. `build-gcc-uclibc-sysroot/` is the uClibc-ng
  build `build-toolchain.sh` installs into the toolchain sysroot - since
  the v42 unification it is built on the shipped ground (the hub's
  2.6.30 kernel headers, generic string routines, linuxthreads), so it
  is also the source step 2.1's `build-shipped-runtime.sh` promotes the
  shipped libc pair from. (The retired `build-gcc-uclibc-nonshared/`,
  `build-gcc-uclibc-shipped/` and `build-gcc-libs-shipped/` trees are
  pre-unification leftovers; nothing builds from them.)

## Required compile/link flags for every binary in this project

```
-EB -mabi=32 -fno-pie -no-pie -march=mips1 -mfp32 -msoft-float -fno-builtin
```

No `-mstrict-align`: the unaligned pair executes natively on this
core, so GCC is left free to emit it (see gotcha 1 below).

## Two more gotchas found propagating this fix across all project binaries

**Never link `-static`.** `auth`/`tc` are dynamically linked and use the
*device's own* vendor-shipped `/lib/libc.so.0` at runtime - which is
already Lexra-native, since it's literally what the real firmware runs.
A `-static` binary instead bakes in **this toolchain's own copy of
`libc.a`** (from the sysroot, inherited unchanged from the original
Bootlin base and never rebuilt with any Lexra patch), which still
contains raw `movz`/`movn` (post-MIPS-I opcodes this core lacks)
from being built by the stock toolchain. `fwd` was reconstructed with `-static` and crashed with
`Illegal instruction` before printing anything; fixed by simply dropping
`-static` (no vendor original survived to confirm, but every other
binary in this project is dynamic, matching uClibc 0.9.30.3 convention,
and `fwd.c` does nothing that requires static linking). A freestanding,
`-nostdlib` binary with its own hand-written `_start` doing raw syscalls
(`hub-chmodx`, `ezsp_gateway`) is fine to link static/`-nostdlib` since
it never touches `libc.a` at all - verify with an opcode scan either way.

**C++ is fixed (2026-11-07).** The GCC rebuild now uses
`--enable-languages=c,c++` and installs `libstdc++-v3` built by the
patched compiler, so `g++` and `libstdc++.a`/`.so` are this project's
own 14.4.0 build (`0x1007` mips1, lexra-clean), and the sysroot's
libstdc++ copies are synced from the same build (GCC installs target
libraries into `<target>/lib` only; the Bootlin sysroot carries its own
copies under `sysroot/usr/lib` - `build-toolchain.sh` syncs them).
Before this, `g++` was still the stock Bootlin 14.3.0 driver, so every
C++ link silently used the stock 14.3.0 support directory (its
`crtbegin.o`/`crtend.o`/`libgcc.a`/`libgcc_eh.a`, all mips32) plus the
stock `libstdc++` - `iperf` linked at `e_flags 0x50001007` even though
every project object was mips1. One more stock object rode along in
every affected link: `uclibc_nonshared.a(atexit.os)` (see bug #6
below), now also replaced with a mips1 rebuild. Proof after the fix:
C++ and C hello-worlds and a C `atexit()` caller all link at `0x1007`;
`iperf` rebuilt fresh links at `0x1007`, lexra-clean, with its dynsym
set and NEEDED identical to before. Still compile-level proof only -
no C++ binary here is hardware-validated yet.

1. **`lwl`/`lwr`/`swl`/`swr` execute natively on the RLX4181.** This
   project originally assumed the opposite (the old Lexra patent story)
   and carried a patch 001 gating the pair off behind `-mstrict-align`;
   that premise is disproven. Proof, on the real hub 2026-11-21: a
   purpose-built test binary (unaligned loads and stores at every byte
   offset with bit-exact data checks, plus a 16-byte pair copy loop in
   the vendor bootcode's own shape) passed every check. The bootcode
   settles the emulation theory too: it installs its exception handler
   with an `lwl`/`lwr`/`swl`/`swr` copy *before* any kernel exists, in
   the window where no trap handler is installed yet - a core lacking
   the pair would die there every boot. Vendor binaries full of the
   pair (e.g. `sengled_gateway_app` storing packed work-node fields
   with `swl v1,0x71(v0); swr v1,0x74(v0)`) simply run natively; no
   kernel trap emulation is involved. Consequence: patch 001 is
   deleted, `-mstrict-align` is not used anywhere, and uClibc's
   arch-optimized string routines (which use the pair) are enabled.
   The instructions this core genuinely lacks are the ones
   `scan_bin_for_illegal_lexra` still bans (`movz`/`movn`/`clz`),
   plus `rdhwr`.
2. **No load-delay-slot interlocking** (tuned like the original R2000/R3000,
   confirmed by the Lexra GCC patch in
   `sengled-root/reference/rtl8196e-gateway/.../970-Lexra.patch`, which
   sets `TUNE_MIPS3000` for `TARGET_LEXRA`). Needs `-march=mips1`, which
   makes GCC/GAS insert the required filler `nop`s automatically — but
   this also means the toolchain's own prebuilt static startup objects
   (`crt1.o`, `crti.o`, `crtn.o`, `crtbegin.o`, `crtend.o`, linked into
   *every* binary regardless of that binary's own CFLAGS) had to be
   rebuilt with these flags too, since the stock ones are built for a
   generic interlocked MIPS32 pipeline.
3. **`.init_array` vs `.ctors`.** This device's uClibc 0.9.30.3 only
   understands the classic `.ctors` convention. Fixed by configuring GCC
   with `--disable-initfini-array`, and by keeping `--enable-shared
   --enable-libgomp` (matching the original Bootlin config exactly -
   flipping these to `--disable-*` silently reintroduces a
   single-entry `.init_array` for the `frame_dummy`/EH-frame-registration
   stub that crashes identically).

**Fourth gotcha, easy to reintroduce:** when rebuilding `crti.o`/`crtn.o`
with `-march=mips1`, their `.init`/`.fini` sections silently lose their
alignment (GAS's implicit default drops from 4 to 1 at this ISA level).
Since `crti.o`'s `.init` is first in the merged `.init` output section,
this can misalign `_init`'s final address - fine for a trivial test binary
(landed on an even offset by luck) but fatal (`SIGILL` at an odd `DT_INIT`
address, reproducible under QEMU) for a larger one like `auth`. Fixed by
adding an explicit `.align 2` after `.section .init,"ax",@progbits` and
`.section .fini,"ax",@progbits` in both files before compiling - verify
with `readelf -S crti.o | grep -A1 '\.init '` (alignment column must read
`4`), and check this on the *actual* binary you care about, not just a
trivial one, since this class of bug can pass a small test and still break
a bigger binary.

**Fifth gotcha, the most dangerous one - a toolchain-wide default, not a
per-object flag:** `--with-arch=mips32` at GCC configure time (an earlier,
seemingly-harmless choice, since every binary's own CFLAGS passed
`-march=mips1` explicitly anyway) means `libgcc.a` itself - built by the
plain `make all-target-libgcc`, using GCC's own *default* arch since
libgcc's build doesn't inherit a binary's per-file CFLAGS - silently
compiles its internal helper routines (e.g. the soft-float double-precision
emulation routines `__adddf3`/`__divdf3`/etc, pulled in by *any* binary
that does floating-point math, like `tc`'s rate calculations) for generic
MIPS32, which can use instructions Lexra doesn't have (observed: `clz`,
used for mantissa normalization in these routines) or, even when it
doesn't hit that, gets merged into the final `e_flags` as `EF_MIPS_ARCH_32`
instead of `EF_MIPS_ARCH_1` (GNU ld merges input objects' architecture
flags to the highest common one). A binary using no floating point (like
`auth`) never links these particular libgcc objects and never notices;
one that does (like `tc`) links fine, passes a static opcode scan of its
*own* code, and then hits `Illegal instruction` on real hardware from
inside a `libgcc.a` routine - QEMU won't catch this either, since Lexra's
missing instructions aren't modeled there. Similarly, GCC's default float
ABI without an explicit `--with-float=soft` at configure time is
**hard-float** - so even though every binary's CFLAGS said `-msoft-float`,
`libgcc.a`'s own float-emulation routines were themselves built
hard-float-ABI-tagged (`ld` warns about this: `"uses -msoft-float ...
uses -mhard-float"`), a silent calling-convention mismatch (args expected
in FPU registers that a soft-float caller never populates) that's even
worse than the `clz` issue since it doesn't require an unsupported opcode
to be wrong, just a bad register convention.

**Fix: `--with-arch=mips1 --with-float=soft` at GCC configure time**, so
`mips1`+soft-float is the toolchain's actual default, not something every
Makefile has to opt into per-object. After this, `crtbegin.o`/`crtend.o`
(rebuilt by the ordinary `make all-target-libgcc`, no manual flag
surgery needed anymore) come out correctly tagged automatically - verify
with `readelf -h crtbegin.o | grep Flags` (must say `mips1`, not `mips32`),
and spot-check a few `libgcc.a` members pulled out with `ar x` for the
opcodes above with `objdump -d` (use the toolchain's own
`mips-buildroot-linux-uclibc-objdump`, not the host one). **Every binary
using floating point needs re-validating on real hardware after this
class of fix** - a clean static opcode scan of the binary's own code is
not sufficient, since the actual crash was inside a *linked-in library*
routine, not anything the binary's own source controls.

**A sixth instance of the same bug class: uClibc's own static
archives** (the `atexit.os` instance is fixed, 2026-11-07 - see the
end of this section)**.** `libgcc.a` and `libstdc++.a` are GCC's own libraries,
fixed above by reconfiguring GCC itself - but `libc.a`, `uclibc_nonshared.a`,
`libpthread.a`, `libm.a`, etc in the sysroot are **uClibc-ng's** libraries,
inherited unchanged from the original stock Bootlin toolchain and never
rebuilt at all. `iperf` (the first binary needing `-lpthread` and, via
libstdc++, `atexit()`) surfaced this: `uclibc_nonshared.a(atexit.os)` is
still `mips32`-tagged, pulling the whole binary's e_flags up to `mips32`
even after everything else is fixed. `auth`/`tc`/`fwd` never hit this
purely because they never happened to need a symbol from the specific
unfixed archive members involved - the same archive is linked into every
dynamic binary, it just isn't always the specific object with a genuine
problem. **This is not fixable from GCC's side at all** - it needs a
uClibc-ng rebuild from source, configured against this same patched
compiler. **The `atexit.os` instance is fixed (2026-11-07):**
`build-toolchain.sh` builds the vendored uClibc-ng source
(`vendor/uclibc-ng/src`, defconfig + FPU off +
the sysroot's kernel headers) and swaps only the `atexit.os` member of
the sysroot's `uclibc_nonshared.a` for the mips1 rebuild - same
wrapper, disassembly-matched against the stock object, stock archive
kept in `toolchain/.stock-crt-backup/`. A C program calling `atexit()`
linked at `0x50001007` before the swap and `0x1007` after. The rest of
the stock archives stay as they are: a full sysroot install of the
rebuilt uClibc-ng (`libc.a`/`libc.so.0`/`libpthread.a`/etc) is the
rootfs libraries work, not done here. **Update (2026-11-09): that full
install is now done here** - `build-toolchain.sh` builds the in-tree
uClibc-ng under `uclibc-sysroot-config.fragment` (the Bootlin feature
config mirrored, except 32-bit time and no FPU) and installs it over
the sysroot's stock uClibc, restoring the hand crt objects afterwards.
The trigger was the time64 header mismatch: the stock build's 64-bit
`time_t` made every rebuilt program disagree with the hub's 32-bit-time
vendor libc on time-bearing struct layouts. The stock libc binaries
are gone from the sysroot after this step; `.stock-crt-backup/` still
holds only the pre-swap `uclibc_nonshared.a`. Measured non-issues, same stock
class: `libpthread_nonshared.a(pthread_atfork.oS)` (no project binary
references `pthread_atfork`) and `Scrt1.o` (only PIE links use it;
this project links `-no-pie`). A `-static` binary would still bake in
stock `libc.a` members - the standing "never link `-static`" rule
above is the guard. Treat binaries exercising not-yet-exercised libc
internals as unvalidated until they are checked the same way.

Once all five are fixed, **fully modern GCC 14.4 + fully modern binutils
`ld`** works correctly on real hardware - no old toolchain dependency
needed for anything. (An earlier investigation pass wrongly concluded an
old Realtek SDK linker was required; that was a confound from testing
old-ld against old-crt-files together. Once the crt files above are
rebuilt with `-march=mips1`, modern `ld` alone is sufficient.)

## Rebuilding the crt objects (if you ever need to, e.g. after a GCC bump)

```sh
cd build-gcc-mips1
make all-gcc all-target-libgcc   # crtbegin.o/crtend.o come out correctly
                                  # tagged automatically now (mips1/soft-float
                                  # are configure defaults) - no manual xgcc
                                  # flag surgery needed for these two anymore.
make install-gcc install-target-libgcc
```

`crt1.o` (hand-written, `crt-src/crt1.S`) and `crti.o`/`crtn.o` (need the
`.align 2` patch on top of `config/mips/crti.S`/`crtn.S`) still can't come
from the plain build - assemble/copy those from `crt-src/` as before and
install into `toolchain/mips-buildroot-linux-uclibc/sysroot/usr/lib/`.
**Install everything under its exact original filename** (`crtbegin.o` not
`crtbegin_mips1.o`) — GNU ld's default linker script matches
crtbegin/crtend by literal filename pattern to decide `.ctors` handling,
and a renamed file silently breaks that.

## Validating a binary

`qemu-mips -L <sysroot-with-device's-real-/lib>` catches bug #3 and
genuine misalignment, but not bugs #1/#2 (Lexra-specific, QEMU doesn't
model them) - a clean QEMU run is necessary but not sufficient. Only a
live run on the real device (telnet `10.42.0.136`) is conclusive. See the
`sengled-rtl8196e-lexra-toolchain` memory for the telnet/TFTP workflow and
how to relaunch telnetd if it's down.

### Two QEMU quirks to revisit when the kernel gets reconstructed

Both of these are emulator artifacts rather than target bugs, and both
stop being merely annoying once this project starts building its own
kernel - at that point the emulated and real kernels can be made to
match, and these go away.

1. **"Can't find a matching FPU mode"** - `qemu-mips` refuses to start
   *every* binary from the current toolchain. The cause is the
   `.MIPS.abiflags` ELF section that modern binutils emits and that the
   device's own 2.6.30 kernel predates entirely. Workaround for local
   debugging only: `objcopy --remove-section=.MIPS.abiflags` on a
   throwaway copy. Never ship a binary that was stripped this way just
   to make QEMU happy - fix the toolchain instead.

2. **QEMU emulates a far newer kernel than the device runs.** Its
   `getrandom()` works; the device's 2.6.30 kernel has no such syscall
   (it landed in Linux 3.17). This bit us for real: Dropbear's
   cross-compile configure check tested build-time *headers* rather than
   runtime kernel support, decided `getrandom()` was available, passed
   cleanly under QEMU, and segfaulted on the device. Any syscall newer
   than 2.6.30 will produce the same false pass. When picking a kernel
   version for the reconstruction, note that raising it also silently
   changes which of these checks start being legitimately true.

## How to Compile

### Quick one-off compile (shell)

```sh
source GCC-14.4-Lexra-RLX4181/env.sh
mips-buildroot-linux-uclibc-gcc -o foo foo.c $LEXRA_CFLAGS
```

### In a Makefile

Set the compiler, the flags and strip from `env.sh`'s values at the
top of the Makefile. Minimal Makefile:

```make
CC = /path/to/toolchain/bin/mips-buildroot-linux-uclibc-gcc
CFLAGS = -EB -mabi=32 -fno-pie -no-pie -march=mips1 -mfp32 -msoft-float -fno-builtin
STRIP = /path/to/toolchain/bin/mips-buildroot-linux-uclibc-strip

all: myprog

myprog: myprog.c
	$(CC) $(CFLAGS) -o $@ $<
	$(STRIP) --strip-all --remove-section=.note* --remove-section=.comment* $@

clean:
	$(RM) myprog

.PHONY: all clean
```

### Key flags (always required)

| Flag | Purpose |
|------|---------|
| `-EB` | Big-endian (matches Realtek SDK / device byte order) |
| `-mabi=32` | o32 ABI (matches vendor libc) |
| `-march=mips1` | MIPS-I ISA (no load-delay slots, Lexra-compatible) |
| `-msoft-float` | No FPU (RTL8196E has none) |
| `-fno-pie -no-pie` | Non-PIE executable (loaded at `0x400000`) |
| `-fno-builtin` | Avoid libc built-in redefinitions |

### Linking: dynamic vs static

**Prefer dynamic linking** (`-shared` / no `-static`) for most binaries — this
lets the device's own vendor `libc.so.0` (already Lexra-native) be used at
runtime, avoiding any sysroot `libc.a` baggage.

Only use `-static` or `-nostdlib` for freestanding helpers with a hand-written
`_start` doing raw syscalls (e.g. `hub-chmodx`, `ezsp_gateway`) that never
touch libc internals.

### After compiling: validate

```sh
# 1. Check ELF flags (must say "mips1", not "mips32")
readelf -h myprog | grep Flags

# 2. Scan for Lexra-unsupported opcodes
source GCC-14.4-Lexra-RLX4181/env.sh
scan_bin_for_illegal_lexra myprog    # should print nothing

# 3. Test under QEMU (catches alignment bugs, not Lexra-specific ones)
qemu-mips -L <sysroot-path> ./myprog
```

## License

GPL-3.0-or-later — see LICENSE. The patches in patches/ modify GCC
14.4.0, which is GPLv3+; the project's own scripts and sources are
released under the same terms. Vendored components keep their own
licenses: uClibc-ng is LGPL-2.1 (vendor/uclibc-ng/src/COPYING.LIB)
and the 2.6.30 kernel headers are GPLv2. The Bootlin base toolchain
and the pristine GCC source are fetched at build time under their
own terms.
