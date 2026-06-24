#!/bin/sh
set -eu

SRC=${1:?usage: build-freebsd-root.sh <freebsd-src> <destdir>}
DESTDIR=${2:?usage: build-freebsd-root.sh <freebsd-src> <destdir>}
KERNCONF=${KERNCONF:-PS5}
TARGET=${TARGET:-amd64}
TARGET_ARCH=${TARGET_ARCH:-amd64}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}

if [ ! -d "$SRC/sys" ]; then
    echo "FreeBSD source tree not found: $SRC" >&2
    exit 1
fi

if ! command -v make >/dev/null 2>&1; then
    echo "make is required to build FreeBSD" >&2
    exit 1
fi

mkdir -p "$DESTDIR"

echo "=== FreeBSD: buildworld KERNCONF=$KERNCONF ==="
make -C "$SRC" -j"$JOBS" TARGET="$TARGET" TARGET_ARCH="$TARGET_ARCH" buildworld

echo "=== FreeBSD: buildkernel KERNCONF=$KERNCONF ==="
make -C "$SRC" -j"$JOBS" TARGET="$TARGET" TARGET_ARCH="$TARGET_ARCH" KERNCONF="$KERNCONF" buildkernel

echo "=== FreeBSD: installworld DESTDIR=$DESTDIR ==="
make -C "$SRC" TARGET="$TARGET" TARGET_ARCH="$TARGET_ARCH" DESTDIR="$DESTDIR" installworld

echo "=== FreeBSD: installkernel DESTDIR=$DESTDIR ==="
make -C "$SRC" TARGET="$TARGET" TARGET_ARCH="$TARGET_ARCH" KERNCONF="$KERNCONF" DESTDIR="$DESTDIR" installkernel

echo "=== FreeBSD: distribution DESTDIR=$DESTDIR ==="
make -C "$SRC" TARGET="$TARGET" TARGET_ARCH="$TARGET_ARCH" DESTDIR="$DESTDIR" distribution

echo "=== FreeBSD root installed at $DESTDIR ==="
