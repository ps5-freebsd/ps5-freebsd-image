#!/bin/sh
set -eu

SRC=${1:?usage: build-freebsd-root-qemu.sh <freebsd-src> <destdir> <vm-image> [vm-user] [ssh-key]}
DESTDIR=${2:?usage: build-freebsd-root-qemu.sh <freebsd-src> <destdir> <vm-image> [vm-user] [ssh-key]}
VM_IMAGE=${3:?usage: build-freebsd-root-qemu.sh <freebsd-src> <destdir> <vm-image> [vm-user] [ssh-key]}
VM_USER=${4:-freebsd}
SSH_KEY=${5:-}

KERNCONF=${KERNCONF:-PS5}
TARGET=${TARGET:-amd64}
TARGET_ARCH=${TARGET_ARCH:-amd64}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}
SSH_PORT=${FREEBSD_QEMU_SSH_PORT:-10022}
MEMORY=${FREEBSD_QEMU_MEMORY:-8192}
CPUS=${FREEBSD_QEMU_CPUS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}
WORKDIR=${FREEBSD_QEMU_WORKDIR:-/qemu-work}

if [ ! -d "$SRC/sys" ]; then
    echo "FreeBSD source tree not found: $SRC" >&2
    exit 1
fi
if [ ! -f "$VM_IMAGE" ]; then
    echo "FreeBSD VM image not found: $VM_IMAGE" >&2
    exit 1
fi

for tool in qemu-system-x86_64 qemu-img ssh scp tar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool is required for the QEMU FreeBSD backend" >&2
        exit 1
    fi
done

mkdir -p "$WORKDIR" "$(dirname "$DESTDIR")"
OVERLAY="$WORKDIR/freebsd-build-overlay.qcow2"
PIDFILE="$WORKDIR/qemu.pid"
READY="$WORKDIR/.ssh-ready"
rm -f "$OVERLAY" "$PIDFILE" "$READY"

case "$VM_IMAGE" in
    *.raw|*.img) BACKING_FMT=raw ;;
    *) BACKING_FMT=qcow2 ;;
esac
qemu-img create -f qcow2 -F "$BACKING_FMT" -b "$VM_IMAGE" "$OVERLAY" >/dev/null

SSH_OPTS="-p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
SCP_OPTS="-P $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
if [ -n "$SSH_KEY" ]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
    SCP_OPTS="$SCP_OPTS -i $SSH_KEY"
fi

cleanup() {
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
    fi
}
trap cleanup EXIT INT TERM

echo "=== QEMU: boot FreeBSD build VM ==="
if [ -e /dev/kvm ]; then
    ACCEL="kvm:tcg"
    CPU_MODEL="${FREEBSD_QEMU_CPU:-host}"
else
    ACCEL="tcg"
    CPU_MODEL="${FREEBSD_QEMU_CPU:-max}"
fi

qemu-system-x86_64 \
    -daemonize \
    -pidfile "$PIDFILE" \
    -m "$MEMORY" \
    -smp "$CPUS" \
    -machine accel="$ACCEL" \
    -cpu "$CPU_MODEL" \
    -drive file="$OVERLAY",if=virtio,format=qcow2 \
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
    -device virtio-net-pci,netdev=net0 \
    -display none

echo "=== QEMU: wait for SSH on localhost:$SSH_PORT ==="
for _ in $(seq 1 180); do
    if ssh $SSH_OPTS "$VM_USER@127.0.0.1" true >/dev/null 2>&1; then
        touch "$READY"
        break
    fi
    sleep 2
done
if [ ! -f "$READY" ]; then
    echo "Timed out waiting for FreeBSD VM SSH" >&2
    exit 1
fi

REMOTE_SRC="freebsd-src"
REMOTE_DEST="ps5-root"
REMOTE_TAR="ps5-root.tar"

echo "=== QEMU: copy FreeBSD source into VM ==="
ssh $SSH_OPTS "$VM_USER@127.0.0.1" "rm -rf '$REMOTE_SRC' '$REMOTE_DEST' '$REMOTE_TAR' && mkdir -p '$REMOTE_SRC'"
tar -C "$SRC" --exclude .git -cf - . | ssh $SSH_OPTS "$VM_USER@127.0.0.1" "tar -C '$REMOTE_SRC' -xf -"

echo "=== QEMU: buildworld/buildkernel/installworld/installkernel ==="
ssh $SSH_OPTS "$VM_USER@127.0.0.1" \
    "set -eu; \
     cd '$REMOTE_SRC'; \
     sudo make -j'$JOBS' TARGET='$TARGET' TARGET_ARCH='$TARGET_ARCH' buildworld; \
     sudo make -j'$JOBS' TARGET='$TARGET' TARGET_ARCH='$TARGET_ARCH' KERNCONF='$KERNCONF' buildkernel; \
     sudo rm -rf '$REMOTE_DEST'; \
     sudo mkdir -p '$REMOTE_DEST'; \
     sudo make TARGET='$TARGET' TARGET_ARCH='$TARGET_ARCH' DESTDIR=\$PWD/'$REMOTE_DEST' installworld; \
     sudo make TARGET='$TARGET' TARGET_ARCH='$TARGET_ARCH' DESTDIR=\$PWD/'$REMOTE_DEST' distribution; \
     sudo make TARGET='$TARGET' TARGET_ARCH='$TARGET_ARCH' KERNCONF='$KERNCONF' DESTDIR=\$PWD/'$REMOTE_DEST' installkernel; \
     sudo tar -C '$REMOTE_DEST' -cf '$REMOTE_TAR' .; \
     sudo chown '$VM_USER' '$REMOTE_TAR'"

echo "=== QEMU: copy FreeBSD DESTDIR back ==="
rm -rf "$DESTDIR"
mkdir -p "$DESTDIR"
scp $SCP_OPTS "$VM_USER@127.0.0.1:$REMOTE_SRC/$REMOTE_TAR" "$WORKDIR/$REMOTE_TAR"
tar -C "$DESTDIR" -xf "$WORKDIR/$REMOTE_TAR"

echo "=== QEMU: FreeBSD root installed at $DESTDIR ==="
