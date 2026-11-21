#!/bin/bash
# Rebuilds the patched Lexra-aware GCC 14.4.0 toolchain from scratch.
# See README.md for what this fixes and why. Run from this directory.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC="$HERE/toolchain"
GCC_VERSION=14.4.0
# The vendored uClibc-ng source is pristine upstream; its Sengled
# adaptations live in $UCLIBC_NG/patches/ and are applied to each
# build copy below by $UCLIBC_NG/apply-patches.sh (idempotent,
# fail-loud) - the copies are the only sources any build consumes.
UCLIBC_NG="$HERE/vendor/uclibc-ng"

# The Bootlin base is this project's own download now (it used to
# be fetched by the sengled project's step 0.0 into a sibling
# tools/): fetched once into this project's tools/, SHA-256
# verified against Bootlin's published hash, exactly as 0.0 did.
BASE_NAME="mips32--uclibc--stable-2025.08-1"
BASE_DIR_URL="https://toolchains.bootlin.com/downloads/releases/toolchains/mips32/tarballs"
if [ ! -d "$HERE/tools/$BASE_NAME" ]; then
  echo "Downloading Bootlin base toolchain $BASE_NAME ..."
  mkdir -p "$HERE/tools"
  curl -fsSL -o "$HERE/tools/$BASE_NAME.tar.xz" "$BASE_DIR_URL/$BASE_NAME.tar.xz"
  curl -fsSL -o "$HERE/tools/$BASE_NAME.sha256" "$BASE_DIR_URL/$BASE_NAME.sha256"
  ( cd "$HERE/tools" && sha256sum -c "$BASE_NAME.sha256" )
  tar --no-same-owner -C "$HERE/tools" -xf "$HERE/tools/$BASE_NAME.tar.xz"
fi

if [ ! -d "$TC" ]; then
  echo "Copying base toolchain from tools/$BASE_NAME ..."
  cp -r "$HERE/tools/$BASE_NAME" "$TC"
fi

# The hand crt objects go into the sysroot BEFORE any building
# (the sengled flow's step 0.0 did this job; the standalone
# script owns it now): the base's stock crti.o is hard-float
# tagged, which kills the build's own libstdc++ link on the
# float-ABI mismatch, and the stock crt1.o dies on the Lexra's
# load-delay slot. Idempotent - same bytes every run.
SYSROOT_LIB="$TC/mips-buildroot-linux-uclibc/sysroot/usr/lib"
echo "Installing hand crt1.o / crti.o / crtn.o into the sysroot..."
for o in crt1.o crti.o crtn.o; do
  cp "$HERE/crt-src/prebuilt/$o" "$SYSROOT_LIB/$o"
done

if [ ! -d "$HERE/gcc-$GCC_VERSION-src" ]; then
  echo "Downloading and extracting GCC $GCC_VERSION source ..."
  curl -sL -o "/tmp/gcc-$GCC_VERSION.tar.xz" "https://ftp.gnu.org/gnu/gcc/gcc-$GCC_VERSION/gcc-$GCC_VERSION.tar.xz"
  tar --no-same-owner -C "$HERE" -xf "/tmp/gcc-$GCC_VERSION.tar.xz"
  mv "$HERE/gcc-$GCC_VERSION" "$HERE/gcc-$GCC_VERSION-src"
  echo "Applying patches/001-lexra-no-lwl-lwr.patch ..."
  patch -p1 -d "$HERE/gcc-$GCC_VERSION-src" < "$HERE/patches/001-lexra-no-lwl-lwr.patch"
  echo "Applying patches/002-crti-crtn-alignment.patch ..."
  patch -p1 -d "$HERE/gcc-$GCC_VERSION-src" < "$HERE/patches/002-crti-crtn-alignment.patch"
  ( cd "$HERE/gcc-$GCC_VERSION-src" && ./contrib/download_prerequisites )
fi

BUILD="$HERE/build-gcc-mips1"
# A build tree left over from the C-only era (--enable-languages=c) cannot
# grow a C++ frontend in place; move it aside and configure fresh. The
# configure line is recorded in the tree's config.log from minute one.
if [ -f "$BUILD/Makefile" ] && ! grep -q 'enable-languages=c,c++' "$BUILD/config.log" 2>/dev/null; then
  OLD="$HERE/build-gcc-mips1-c-only"
  [ -e "$OLD" ] && OLD="$HERE/build-gcc-mips1-c-only-$(date +%Y%m%d%H%M%S)"
  echo "Moving stale C-only build tree aside to $OLD ..."
  mv "$BUILD" "$OLD"
fi
mkdir -p "$BUILD"
cd "$BUILD"

if [ ! -f Makefile ]; then
  "$HERE/gcc-$GCC_VERSION-src/configure" \
    --prefix="$TC" \
    --sysconfdir="$TC/etc" \
    --enable-static \
    --target=mips-buildroot-linux-uclibc \
    --with-sysroot="$TC/mips-buildroot-linux-uclibc/sysroot" \
    --enable-__cxa_atexit \
    --with-gnu-ld \
    --disable-libssp \
    --disable-multilib \
    --disable-decimal-float \
    --enable-plugins \
    --enable-lto \
    --without-zstd \
    --disable-libquadmath \
    --disable-libquadmath-support \
    --disable-libsanitizer \
    --disable-initfini-array \
    --with-pkgversion='Sengled-lexra-patched-2026' \
    --without-cloog \
    --with-arch=mips1 \
    --with-abi=32 \
    --with-nan=legacy \
    --with-float=soft \
    --enable-languages=c,c++ \
    --with-build-time-tools="$TC/mips-buildroot-linux-uclibc/bin" \
    --enable-shared \
    --enable-libgomp \
    --enable-tls \
    --enable-threads \
    --disable-nls \
    --disable-bootstrap
fi

make -j"$(nproc)" all-gcc all-target-libgcc
# TAR_OPTIONS: this workspace's filesystem refuses chown, and GCC's
# install-headers-tar pipes through a hardcoded `tar xpf -` that dies on
# ownership preservation. GNU tar reads TAR_OPTIONS on every invocation.
make install-gcc install-target-libgcc TAR_OPTIONS="--no-same-owner"
# libgcc builds and installs HERE, before the sysroot swap: the
# sysroot uClibc's own link needs an installed libgcc (its ldso
# link dies with "cannot find libgcc" on a fresh tree
# otherwise - the first virgin-v42 run). libgcc can go first:
# it is freestanding and thread-model-agnostic (its pthread use
# is weak references only - no libc type layout enters it).
# libstdc++ is the opposite - its configure probes the libc
# and its headers brace-initialize pthread types - so
# libstdc++ alone waits for the swap below, and builds against
# the final sysroot.

# The atexit harvest that used to sit here is gone. It repaired ONE
# member (atexit.os) of the STOCK sysroot archive, and its only
# consumer was a target-library link against that stock archive.
# The target libraries now build after the sysroot swap below, by
# which point the whole archive is this project's own build -
# there is no stock member left to repair.
SYSROOT="$TC/mips-buildroot-linux-uclibc/sysroot"

# The sysroot uClibc itself: replace the Bootlin base's build with
# one built here, from the in-tree uClibc-ng source. This is THE
# libc build of the whole project (the unification Camille
# proposed, v42): the sysroot the families compile against and
# the runtime the image ships are this one build, on the shipped
# ground - the hub's 2.6.30 kernel headers, the generic C string
# routines, and the LINUXTHREADS thread model. Not NPTL: the
# hub's ground has no native TLS, and a libstdc++ configured
# against an NPTL libc imports __tls_get_addr, which nothing on
# the hub provides (the v35 ship-gate failure). Before the
# unification, step 2.1's build-shipped-runtime.sh built a
# second uClibc and a second GCC target-library tree to reach
# this same ground; it now only promotes what this build
# produces. The recipe is uclibc-sysroot-config.fragment over
# defconfig (the Bootlin feature mirror, except 32-bit time -
# the hub's vendor uClibc 0.9.30.3 is 32-bit time and the 64-bit
# headers corrupt every time-bearing struct layout at the
# vendor-libc boundary - and no FPU), plus the three shipped
# inputs applied at configure time below. Runs after the
# compiler build (the libc is compiled by this toolchain, pure
# mips1 objects) and before the target libraries, so they
# configure against this final sysroot. Skipped only when the
# installed sysroot already IS this build: 32-bit time AND
# linuxthreads AND no NPTL - an older NPTL sysroot is rebuilt,
# never trusted.
SYSROOT_SWAPPED=0
SYSROOT_CFG="$SYSROOT/usr/include/bits/uClibc_config.h"
if ! { [ -f "$SYSROOT_CFG" ] \
       && ! grep -q '^#define __UCLIBC_USE_TIME64__' "$SYSROOT_CFG" \
       && grep -q '^#define __UCLIBC_HAS_LINUXTHREADS__' "$SYSROOT_CFG" \
       && ! grep -q '^#define __UCLIBC_HAS_THREADS_NATIVE__' "$SYSROOT_CFG"; }; then
  SYSROOT_SWAPPED=1
  # uClibc's locale-data generation reads the HOST's generated locales:
  # with no host en_US / en_US.UTF-8 it silently emits empty tables and
  # the build dies later in gen_ldc. Generate them into a private
  # LOCPATH instead - no sudo, no system change, and a no-op on hosts
  # that already have them (the same pattern build-shipped-runtime.sh
  # uses for the shipped libc build).
  if ! locale -a 2>/dev/null | grep -qix 'en_US\.utf8' \
     || ! locale -a 2>/dev/null | grep -qix 'en_US'; then
    if [ ! -f /usr/share/i18n/locales/en_US ]; then
      echo "ERROR: this host has no locale source data (/usr/share/i18n/locales/en_US);" >&2
      echo "the uClibc locale build reads it. It ships in the 'locales' package -" >&2
      echo "install that package, then re-run." >&2
      exit 1
    fi
    LOCALE_PREFIX="$HERE/build-gcc-uclibc-sysroot/host-locales"
    if [ ! -d "$LOCALE_PREFIX/usr/lib/locale/en_US" ]; then
      mkdir -p "$LOCALE_PREFIX/usr/lib/locale"
      localedef --no-archive --prefix="$LOCALE_PREFIX" -i en_US -f UTF-8 en_US.UTF-8
      localedef --no-archive --prefix="$LOCALE_PREFIX" -i en_US -f ISO-8859-1 en_US
    fi
    export LOCPATH="$LOCALE_PREFIX/usr/lib/locale${LOCPATH:+:$LOCPATH}"
    echo "Host en_US locales absent - using private LOCPATH $LOCALE_PREFIX/usr/lib/locale"
  fi
  echo "Building the sysroot uClibc from the in-tree uClibc-ng source (32-bit time, linuxthreads, hub kernel headers) ..."
  UB2="$HERE/build-gcc-uclibc-sysroot"
  if [ ! -d "$UB2/src" ]; then
    mkdir -p "$UB2"
    cp -a --no-preserve=ownership "$UCLIBC_NG/src" "$UB2/src"
  fi
  # A build copy configured before the unification (NPTL model)
  # is never retargeted in place - uClibc does not rebuild every
  # TLS-dependent object on a thread-model change (the shipped
  # build's standing guard). Start that copy over.
  if [ -f "$UB2/src/.config" ] && ! grep -q '^UCLIBC_HAS_LINUXTHREADS=y' "$UB2/src/.config"; then
    echo "Existing sysroot uClibc build copy is not on the linuxthreads model - starting it over."
    rm -rf "$UB2/src"
    cp -a --no-preserve=ownership "$UCLIBC_NG/src" "$UB2/src"
  fi
  "$UCLIBC_NG/apply-patches.sh" "$UB2/src"
  # The hub's 2.6.30 kernel headers, vendored in
  # vendor/linux-2.6.30-kernel-headers (the Realtek SDK's set) -
  # the build compiles against a sanitized COPY (never the
  # vendored set itself), prepared by the patches in
  # patches-kernel-headers/ (idempotent, fail-loud; the patch
  # files carry the why for each edit: the linux/socket.h
  # __KERNEL__ gate, and dropping __NR_accept4, which the hub
  # kernel answers ENOSYS).
  KERNEL_HEADERS_SRC="$HERE/vendor/linux-2.6.30-kernel-headers"
  KERNEL_HEADERS_DIR="$UB2/kernel-headers"
  [ -d "$KERNEL_HEADERS_SRC/linux" ] || { echo "ERROR: hub kernel headers not found at $KERNEL_HEADERS_SRC" >&2; exit 1; }
  if [ ! -d "$KERNEL_HEADERS_DIR" ]; then
    mkdir -p "$UB2"
    cp -a --no-preserve=ownership "$KERNEL_HEADERS_SRC" "$KERNEL_HEADERS_DIR"
  fi
  for kh_patch in "$HERE/patches-kernel-headers"/*.patch; do
    if patch --dry-run -R -p1 -d "$KERNEL_HEADERS_DIR" < "$kh_patch" >/dev/null 2>&1; then
      echo "  kernel-headers patch $(basename "$kh_patch"): already applied"
    elif patch --dry-run -p1 -d "$KERNEL_HEADERS_DIR" < "$kh_patch" >/dev/null 2>&1; then
      patch -p1 -d "$KERNEL_HEADERS_DIR" < "$kh_patch" >/dev/null
      echo "  kernel-headers patch $(basename "$kh_patch"): applied"
    else
      echo "ERROR: kernel-headers patch $(basename "$kh_patch")" >&2
      echo "applies neither forward nor reverse to $KERNEL_HEADERS_DIR -" >&2
      echo "refusing to build against a half-patched header copy." >&2
      exit 1
    fi
  done
  grep -q '^#if defined(__KERNEL__)$' "$KERNEL_HEADERS_DIR/linux/socket.h" || {
    echo "ERROR: copied linux/socket.h does not carry the __KERNEL__-only guard (patch 001)" >&2; exit 1; }
  ! grep -q '__NR_accept4' "$KERNEL_HEADERS_DIR/asm/unistd.h" || {
    echo "ERROR: copied asm/unistd.h still defines __NR_accept4 (patch 002 not in effect)" >&2; exit 1; }
  (
    cd "$UB2/src"
    export PATH="$TC/bin:$PATH"
    if [ ! -f .config ]; then
      make ARCH=mips CROSS_COMPILE=mips-buildroot-linux-uclibc- defconfig
      # defconfig lands MIPS o32 + big-endian + legacy NaN; the fragment
      # then pins the Bootlin feature mirror + the two deviations. Both
      # fragment line forms are applied: NAME=value replaces, and a
      # "# NAME is not set" line replaces any NAME=... with itself.
      while IFS= read -r line; do
        case "$line" in
          \#\ *\ is\ not\ set)
            name="${line#\# }"; name="${name% is not set}"
            if grep -q "^$name=" .config; then
              sed -i "s|^$name=.*|$line|" .config
            elif ! grep -q "^# $name is not set" .config; then
              echo "$line" >> .config
            fi ;;
          *=*)
            name="${line%%=*}"
            if grep -q "^# $name is not set" .config; then
              sed -i "s|^# $name is not set|$line|" .config
            elif grep -q "^$name=" .config; then
              sed -i "s|^$name=.*|$line|" .config
            else
              echo "$line" >> .config
            fi ;;
        esac
      done < "$HERE/uclibc-sysroot-config.fragment"
      # The three shipped inputs, on top of the fragment:
      # 1. the hub's 2.6.30 kernel headers (the sanitized copy
      #    prepared above) - the syscall numbers and kernel
      #    structures this libc is built against are the hub's.
      sed -i 's|^KERNEL_HEADERS=.*|KERNEL_HEADERS="'"$KERNEL_HEADERS_DIR"'"|' .config
      grep -q '^KERNEL_HEADERS=' .config || echo 'KERNEL_HEADERS="'"$KERNEL_HEADERS_DIR"'"' >> .config
      # 2. generic C string routines - the arch-optimized ones
      #    target a newer MIPS than the hub's Lexra core.
      sed -i 's|^UCLIBC_HAS_STRING_ARCH_OPT=y|# UCLIBC_HAS_STRING_ARCH_OPT is not set|' .config
      grep -q '^UCLIBC_HAS_STRING_GENERIC_OPT=y' .config \
          || sed -i 's|^# UCLIBC_HAS_STRING_GENERIC_OPT is not set|UCLIBC_HAS_STRING_GENERIC_OPT=y|' .config
      # 3. linuxthreads, not NPTL - the hub's thread ground (see
      #    the block header above).
      sed -i 's|^UCLIBC_HAS_THREADS_NATIVE=y|# UCLIBC_HAS_THREADS_NATIVE is not set|' .config
      sed -i 's|^# UCLIBC_HAS_LINUXTHREADS is not set|UCLIBC_HAS_LINUXTHREADS=y|' .config
      grep -q '^UCLIBC_HAS_LINUXTHREADS=y' .config \
          || echo 'UCLIBC_HAS_LINUXTHREADS=y' >> .config
      make ARCH=mips CROSS_COMPILE=mips-buildroot-linux-uclibc- olddefconfig
      # The configured tree must carry the shipped ground -
      # refuse anything else (same guards the shipped build
      # carried; a silent drift here poisons every consumer).
      grep -q '^KERNEL_HEADERS="'"$KERNEL_HEADERS_DIR"'"' .config || {
        echo "ERROR: sysroot .config does not carry the hub KERNEL_HEADERS" >&2; exit 1; }
      grep -q '^# UCLIBC_HAS_STRING_ARCH_OPT is not set' .config || {
        echo "ERROR: sysroot .config still enables arch string routines" >&2; exit 1; }
      grep -q '^UCLIBC_HAS_LINUXTHREADS=y' .config || {
        echo "ERROR: sysroot .config is not on the linuxthreads model" >&2; exit 1; }
      grep -q '^# UCLIBC_HAS_THREADS_NATIVE is not set' .config || {
        echo "ERROR: sysroot .config still enables NPTL" >&2; exit 1; }
      ! grep -q '^UCLIBC_HAS_TLS=y' .config || {
        echo "ERROR: sysroot .config still enables TLS (rdhwr on this platform)" >&2; exit 1; }
      grep -q '^# UCLIBC_USE_TIME64 is not set' .config || {
        echo "ERROR: sysroot .config enables TIME64" >&2; exit 1; }
    fi
    # -j1, same Makerules .list race as the harvest build above.
    make -j1 ARCH=mips CROSS_COMPILE=mips-buildroot-linux-uclibc-
    make -j1 ARCH=mips CROSS_COMPILE=mips-buildroot-linux-uclibc- PREFIX="$SYSROOT" install
  )
  # install_startfiles overwrites the sysroot's crt1.o/crti.o/crtn.o
  # with uClibc's stock ones - put the hand-patched objects back (the
  # same copies step 0.0 installs; see the header notes there).
  for o in crt1.o crti.o crtn.o; do
    cp "$HERE/crt-src/prebuilt/$o" "$SYSROOT/usr/lib/$o"
  done
  # Drop the base build's versioned libc binaries; the symlinks now
  # point at the project build and nothing references the old files.
  NEWLIBC="$(basename "$(ls "$UB2/src/lib"/libuClibc-*.so | head -1)")"
  NEWLD="$(basename "$(ls "$UB2/src/lib"/ld-uClibc-*.so | grep -v 'ld-uClibc.so' | head -1)")"
  for f in "$SYSROOT/lib"/libuClibc-*.so "$SYSROOT/lib"/ld-uClibc-*.so; do
    case "$(basename "$f")" in
      "$NEWLIBC"|"$NEWLD") : ;;
      *) rm -f "$f" ;;
    esac
  done
  grep -q '__TIME_T_TYPE.*__SLONGWORD_TYPE' "$SYSROOT/usr/include/bits/typesizes.h" \
    || { echo "ERROR: installed sysroot headers are not 32-bit time - uClibc step failed."; exit 1; }
  echo "Sysroot uClibc replaced: $NEWLIBC (32-bit time, linuxthreads, project build)."
else
  echo "Sysroot uClibc already carries the converged build (32-bit time, linuxthreads) - uClibc step skipped."
fi

# Verification only - the correction itself is patch
# vendor/uclibc-ng/patches/
# 002-features-h-file-offset-bits.patch, applied to the sysroot
# build copy by apply-patches.sh above (which verifies the patched
# state in the source copy); this assert verifies the same patched
# state survived into the installed sysroot header. Forcing
# _FILE_OFFSET_BITS=64 makes every consumer of these headers
# reference *64 entry points the hub's vendor uClibc 0.9.30.3 never
# exported. Fail loudly if a future uClibc bump breaks the patch,
# rather than letting it poison every consumer build silently.
FH="$SYSROOT/usr/include/features.h"
grep -q '^#if defined _FILE_OFFSET_BITS && _FILE_OFFSET_BITS == 64$' "$FH" \
  && grep -q 'vendor uClibc 0.9.30.3' "$FH" \
  && ! grep -q 'is not supported by uClibc-ng' "$FH" \
  || { echo "ERROR: $FH does not carry the Sengled file-offset policy" >&2
       echo "from uClibc-ng patches/002-features-h-file-offset-bits.patch." >&2
       echo "Check that apply-patches.sh ran on the sysroot build copy," >&2
       echo "then rebuild the sysroot uClibc." >&2
       exit 1; }
echo "Sysroot features.h carries the file-offset policy edit - verified."

# libstdc++ builds HERE, against the final sysroot above
# (libgcc built before the swap - it is freestanding, and the
# libc build itself links against it). A build tree whose
# libstdc++ was configured against a DIFFERENT sysroot ground
# (an old-order or NPTL-era tree) cannot be trusted to have
# measured the current one: the ground is stamped, and on a
# mismatch its build directory is wiped so its configure
# re-runs against this sysroot. The compiler and libgcc are
# ground-independent here and are never rebuilt for this.
TARGET_LIBS_GROUND="linuxthreads-uclibc-ng-hubkh-v42"
GROUND_STAMP="$BUILD/.target-libs-ground"
LIBSTDCXX_BUILD="$BUILD/mips-buildroot-linux-uclibc/libstdc++-v3"
if [ -d "$LIBSTDCXX_BUILD" ] \
   && [ "$(cat "$GROUND_STAMP" 2>/dev/null || true)" != "$TARGET_LIBS_GROUND" ]; then
  echo "libstdc++ was configured against a different sysroot ground - wiping its build directory so its configure re-runs ..."
  rm -rf "$LIBSTDCXX_BUILD"
fi

# The build tree's fixed headers have the same staleness: GCC's
# fixincludes copies sysroot headers (pthread.h among them) into
# gcc/include-fixed when the compiler builds, and that copy
# shadows the sysroot's own header from then on. A copy made
# against the NPTL sysroot mixed with the linuxthreads
# pthreadtypes is exactly the pthread_mutex_t breakage the
# unification trial hit ("cannot convert '<brace-enclosed
# initializer list>' to 'int'" in libstdc++'s concurrence.h).
# Whenever the ground changed under this build tree - the swap
# just ran, or the stamp says the libraries have not been built
# on this ground - regenerate the fixed headers against the
# current sysroot and reinstall the compiler so the installed
# include-fixed copies refresh too.
if [ "$SYSROOT_SWAPPED" = 1 ] \
   || [ "$(cat "$GROUND_STAMP" 2>/dev/null || true)" != "$TARGET_LIBS_GROUND" ]; then
  echo "Refreshing the build tree's fixed headers against the current sysroot (fixincludes) and reinstalling the compiler ..."
  rm -rf "$BUILD/gcc/include-fixed" "$BUILD/gcc/stmp-fixinc"
  make -j"$(nproc)" all-gcc
  make install-gcc TAR_OPTIONS="--no-same-owner"
fi

# The older guard stays: an installed libstdc++ whose merged
# e_flags are not the mips1 set is forced to rebuild.
LIBSTDCXX_SO="$TC/mips-buildroot-linux-uclibc/lib/libstdc++.so.6.0.33"
if [ -f "$LIBSTDCXX_SO" ] && [ -d "$LIBSTDCXX_BUILD" ] && \
   ! "$TC/bin/mips-buildroot-linux-uclibc-readelf" -h "$LIBSTDCXX_SO" | grep -m1 Flags | grep -q '0x1007'; then
  echo "Installed libstdc++.so predates the sysroot swap (not 0x1007) - forcing its rebuild ..."
  rm -rf "$LIBSTDCXX_BUILD"
fi

make -j"$(nproc)" all-target-libstdc++-v3
make install-target-libstdc++-v3 TAR_OPTIONS="--no-same-owner"
printf '%s\n' "$TARGET_LIBS_GROUND" > "$GROUND_STAMP"

# GCC installs the target libraries into $TC/<target>/lib, but the Bootlin
# sysroot carries its own copies under sysroot/usr/lib (Buildroot stages
# them from the same build). install-target-libstdc++-v3 does not touch
# the sysroot copies, so without this step the sysroot's libstdc++ stays
# the stock mips32 build even though the compiler's own copy is rebuilt.
echo "Syncing rebuilt libstdc++ into the sysroot copies ..."
cp -a --no-preserve=ownership \
  "$TC/mips-buildroot-linux-uclibc/lib/"libstdc++.a \
  "$TC/mips-buildroot-linux-uclibc/lib/"libstdc++.so \
  "$TC/mips-buildroot-linux-uclibc/lib/"libstdc++.so.6 \
  "$TC/mips-buildroot-linux-uclibc/lib/"libstdc++.so.6.0.33 \
  "$TC/mips-buildroot-linux-uclibc/lib/"libstdc++.so.6.0.33-gdb.py \
  "$TC/mips-buildroot-linux-uclibc/lib/"libstdc++exp.a \
  "$TC/mips-buildroot-linux-uclibc/lib/"libstdc++fs.a \
  "$TC/mips-buildroot-linux-uclibc/sysroot/usr/lib/"

# Same for libgcc_s: the sysroot's copy is otherwise the stale
# Bootlin base build - the copy the shipped-runtime promotion
# always refused as a source. Ours replaces it, so no stale GCC
# runtime file remains anywhere in the sysroot.
echo "Syncing rebuilt libgcc_s into the sysroot copies ..."
cp -a --no-preserve=ownership \
  "$TC/mips-buildroot-linux-uclibc/lib/"libgcc_s.so \
  "$TC/mips-buildroot-linux-uclibc/lib/"libgcc_s.so.1 \
  "$TC/mips-buildroot-linux-uclibc/sysroot/usr/lib/"

# The shipped runtime (the rootfs C-library family) is not
# separately built anywhere: the sysroot uClibc above IS the
# shipped libc, and the target libraries above are the shipped
# libgcc_s/libstdc++. Step 2.1's build-shipped-runtime.sh only
# promotes those four files into GCC-14.4-Lexra-RLX4181/
# runtime-ng/ behind its Lexra/rdhwr gates - it compiles
# nothing.

echo ""
echo "Compiler installed. mips1/soft-float are now the configure DEFAULTS,"
echo "so crtbegin.o/crtend.o (built by all-target-libgcc above) are already"
echo "correct, and libstdc++ is this build's own (C++ included since"
echo "2026-11-07 - the stock Bootlin g++/libstdc++ are gone from the link"
echo "path). crt1.o/crti.o/crtn.o still need the hand-patched versions in"
echo "crt-src/ (crt1.S is entirely hand-written; crti.S/crtn.S need the"
echo ".align 2 patch) - copy crt-src/prebuilt/*.o into place, or rebuild from"
echo "crt-src/ and gcc-14.4.0-src/libgcc/config/mips/{crti,crtn}.S. Install"
echo "under their exact original filenames (see README.md)."
