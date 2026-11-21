#!/bin/sh
# make-patch.sh - the patch <-> state proof for this project.
#
# The repo form of the compiler is: pristine GCC 14.4.0 (fetched
# from ftp.gnu.org) + patches/002. The built form is
# the gcc-14.4.0-src/ tree those patches produce. This script proves
# the two forms are the same thing, and can regenerate one combined
# patch from the tree.
#
#   make-patch.sh          check: apply 002 to a fresh pristine
#                          extract and diff it against the in-tree
#                          gcc-14.4.0-src - exit 0 iff identical
#                          (download_prerequisites products are
#                          excluded: they are fetched inputs, not
#                          our changes).
#   make-patch.sh regen    write the combined pristine->tree patch
#                          to patches/003-full-state.patch.
#
# Needs: gcc-14.4.0-src/ present (a completed build-toolchain.sh
# run) and the pristine tarball - $HERE/gcc-14.4.0.tar.xz,
# /tmp/gcc-14.4.0.tar.xz, or a fresh download.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GCC_VERSION=14.4.0
SRC="$HERE/gcc-$GCC_VERSION-src"
TARBALL=""

for cand in "$HERE/gcc-$GCC_VERSION.tar.xz" "/tmp/gcc-$GCC_VERSION.tar.xz"; do
  if [ -f "$cand" ]; then TARBALL="$cand"; break; fi
done
if [ -z "$TARBALL" ]; then
  TARBALL="$HERE/gcc-$GCC_VERSION.tar.xz"
  echo "Downloading pristine GCC $GCC_VERSION ..."
  curl -fsSL -o "$TARBALL" \
    "https://ftp.gnu.org/gnu/gcc/gcc-$GCC_VERSION/gcc-$GCC_VERSION.tar.xz"
fi
if [ ! -d "$SRC" ]; then
  echo "ERROR: $SRC not found - run build-toolchain.sh first" >&2
  exit 1
fi

# download_prerequisites products: fetched inputs, never our diff.
EXCLUDES="-x gmp -x gmp-* -x mpfr -x mpfr-* -x mpc -x mpc-* \
-x isl -x isl-* -x gettext -x gettext-* \
-x *.tar.xz -x *.tar.gz -x *.tar.bz2"

WORK="$HERE/.make-patch-work"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "Extracting pristine GCC $GCC_VERSION ..."
tar --no-same-owner -C "$WORK" -xf "$TARBALL"
PRISTINE="$WORK/gcc-$GCC_VERSION"

MODE="${1:-check}"
case "$MODE" in
check)
  echo "Applying patches/002 ..."
  patch -p1 -d "$PRISTINE" < "$HERE/patches/002-crti-crtn-alignment.patch" >/dev/null
  echo "Diffing patched pristine vs $SRC ..."
  # shellcheck disable=SC2086
  if diff -r $EXCLUDES "$PRISTINE" "$SRC" > "$WORK/diff.out"; then
    echo "PATCH = STATE: the shipped patch reproduces the built tree exactly."
  else
    echo "DIFFERENCES FOUND (also kept in $WORK/diff.out until exit):" >&2
    head -50 "$WORK/diff.out" >&2
    trap - EXIT
    cp "$WORK/diff.out" "$HERE/make-patch-diff.txt"
    echo "Full diff saved to make-patch-diff.txt" >&2
    exit 1
  fi
  ;;
regen)
  OUT="$HERE/patches/003-full-state.patch"
  echo "Generating combined patch -> $OUT ..."
  # shellcheck disable=SC2086
  diff -ruN $EXCLUDES "$PRISTINE" "$SRC" \
    | sed -e "s|^--- $PRISTINE|--- a/gcc-$GCC_VERSION|" \
          -e "s|^+++ $SRC|+++ b/gcc-$GCC_VERSION|" \
          -e "s|^diff -ruN .* $PRISTINE/\(.*\) $SRC/.*|diff -ruN a/gcc-$GCC_VERSION/\1 b/gcc-$GCC_VERSION/\1|" \
    > "$OUT" || true
  echo "Wrote $OUT ($(wc -l < "$OUT") lines)."
  ;;
*)
  echo "usage: $0 [check|regen]" >&2
  exit 2
  ;;
esac
