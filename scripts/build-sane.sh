#!/bin/bash
# Builds the SANE driver that goes inside Dual Scan III.app into ../sane/:
# only the avision backend (Dimage Scan Dual III), as one static library with the
# backend preloaded, plus a static libusb. The app then needs nothing outside itself.
# Both are universal (Apple silicon and Intel), built once per architecture and joined with lipo.
# Skips the build when ../sane already holds this commit.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

# SANE master with Dual IV support in avision (not in a release yet).
SANE_COMMIT=7bf6abe2bd1b1cb916aa87b6a377a7ee70313eb3
# libusb from its release, built here so it is universal too (Homebrew's is one architecture).
LIBUSB_VERSION=1.0.27
LIBUSB_SHA256=ffaa41d741a8a3bee244ac8e54a72ea05bf2879663c098c82fc5757853441575
ARCHS=(arm64 x86_64)
# The oldest macOS the app runs on; keep it the same as in app/project.yml.
export MACOSX_DEPLOYMENT_TARGET=14.0
SRC="$ROOT/build/sane-src"
WORK="$ROOT/build/sane-arch"
OUT="$ROOT/sane"
# Our fixes on top of that commit; the stamp changes whenever a patch does, so it rebuilds.
PATCHES=("$ROOT"/scripts/sane-patches/*.patch)
STAMP="$SANE_COMMIT $(cat "${PATCHES[@]}" | shasum | cut -c1-12) libusb-$LIBUSB_VERSION ${ARCHS[*]} macOS-$MACOSX_DEPLOYMENT_TARGET"

if [ "$(cat "$OUT/.commit" 2>/dev/null)" = "$STAMP" ] && [ -f "$OUT/lib/libsane.a" ]; then
  echo "SANE $SANE_COMMIT is already built."
  exit 0
fi

for tool in autoconf automake glibtoolize pkg-config; do
  command -v $tool >/dev/null 2>&1 || {
    echo "$tool is missing. Install with:  brew install autoconf autoconf-archive automake libtool pkgconf gettext"
    exit 1
  }
done
NCPU="$(sysctl -n hw.ncpu)"
HOST_ARCH="$(uname -m)"
host_flag() { [ "$1" = "$HOST_ARCH" ] && return; echo "--host=$1-apple-darwin"; }
rm -rf "$WORK"
mkdir -p "$WORK"

# libusb, static, per architecture.
TARBALL="$ROOT/build/libusb-$LIBUSB_VERSION.tar.bz2"
if ! echo "$LIBUSB_SHA256  $TARBALL" | shasum -a 256 -c --status 2>/dev/null; then
  curl -fsSL -o "$TARBALL" "https://github.com/libusb/libusb/releases/download/v$LIBUSB_VERSION/libusb-$LIBUSB_VERSION.tar.bz2"
  echo "$LIBUSB_SHA256  $TARBALL" | shasum -a 256 -c --status || { echo "libusb download doesn't match its checksum"; exit 1; }
fi
for arch in "${ARCHS[@]}"; do
  mkdir -p "$WORK/libusb-src-$arch"
  tar xjf "$TARBALL" -C "$WORK/libusb-src-$arch" --strip-components 1
  (cd "$WORK/libusb-src-$arch" &&
   ./configure --prefix="$WORK/libusb-$arch" $(host_flag $arch) CC="clang -arch $arch" CFLAGS="-O2" \
     --disable-shared --enable-static >/dev/null &&
   make -j"$NCPU" >/dev/null && make install >/dev/null)
done

if [ ! -d "$SRC/.git" ]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin https://gitlab.com/sane-project/backends.git
fi
git -C "$SRC" fetch -q --depth 1 origin "$SANE_COMMIT"
git -C "$SRC" checkout -q --force FETCH_HEAD
git -C "$SRC" clean -qfdx
for p in "${PATCHES[@]}"; do git -C "$SRC" apply "$p"; done

cd "$SRC"
# A shallow checkout has no tags to take the version from.
echo "1.4.0.352-7bf6" > .tarball-version
./autogen.sh >/dev/null
for arch in "${ARCHS[@]}"; do
  # A copy of the tree per architecture, so the builds don't mix.
  cp -R "$SRC" "$WORK/sane-src-$arch"
  # dll-preload.h stores backend functions untyped; new clang makes that an error.
  (cd "$WORK/sane-src-$arch" &&
   PKG_CONFIG_PATH="$WORK/libusb-$arch/lib/pkgconfig" \
   ./configure --prefix="$WORK/sane-$arch" $(host_flag $arch) BACKENDS="avision" CC="clang -arch $arch" \
     LIBS="-framework IOKit -framework CoreFoundation -framework Security" \
     CFLAGS="-O2 -Wno-error=incompatible-function-pointer-types" \
     --disable-shared --enable-static --enable-preload \
     --with-usb --without-snmp --without-avahi --without-libcurl --without-poppler-glib \
     --without-usb-record-replay --without-gphoto2 --without-v4l --without-systemd \
     --without-libjpeg --without-libtiff --without-libpng \
     --disable-locking --disable-nls >/dev/null &&
   make -j"$NCPU" >/dev/null && make install >/dev/null)
done

# One universal copy: headers and config from the first build, the libraries joined.
rm -rf "$OUT"
cp -R "$WORK/sane-${ARCHS[0]}" "$OUT"
lipo -create $(for a in "${ARCHS[@]}"; do echo "$WORK/sane-$a/lib/libsane.a"; done) -output "$OUT/lib/libsane.a"
lipo -create $(for a in "${ARCHS[@]}"; do echo "$WORK/libusb-$a/lib/libusb-1.0.a"; done) -output "$OUT/lib/libusb-static.a"
lipo -info "$OUT/lib/libsane.a" "$OUT/lib/libusb-static.a"
# The config the app ships with: only avision, no firmware upload.
printf 'avision\n' > "$OUT/etc/sane.d/dll.conf"
echo "$STAMP" > "$OUT/.commit"
echo "Built SANE $STAMP into sane/"
