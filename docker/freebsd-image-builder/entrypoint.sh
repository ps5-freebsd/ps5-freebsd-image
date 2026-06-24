#!/bin/bash
set -euo pipefail

IMG_SIZE="${IMG_SIZE:-8000}"
ROOT_LABEL="${ROOT_LABEL:-ps5root}"
BOOT_LABEL="${BOOT_LABEL:-PS5BOOT}"
FREEBSD_KERNEL="${FREEBSD_KERNEL:-/freebsd-root/boot/kernel/kernel}"
IMG="/output/ps5-freebsd.img"
TMPIMG="/output/.ps5-freebsd.img.tmp"
ROOTFS="/tmp/ps5-freebsd-root.ufs"
BOOTFS="/tmp/ps5-freebsd-boot.fat"
STAGE="/tmp/ps5-freebsd-root"

if [ ! -d /freebsd-root ]; then
    echo "ERROR: /freebsd-root is not mounted" >&2
    exit 1
fi
if [ ! -f "$FREEBSD_KERNEL" ]; then
    echo "ERROR: FreeBSD kernel not found: $FREEBSD_KERNEL" >&2
    exit 1
fi

if [ "$IMG_SIZE" -le 1024 ]; then
    echo "ERROR: IMG_SIZE must be larger than 1024 MiB" >&2
    exit 1
fi

BOOT_START_MB=1
ROOT_START_MB=500
BOOT_SIZE_MB=$((ROOT_START_MB - BOOT_START_MB))
ROOT_SIZE_MB=$((IMG_SIZE - ROOT_START_MB))
BOOT_START_SECTOR=$((BOOT_START_MB * 2048))
ROOT_START_SECTOR=$((ROOT_START_MB * 2048))
BOOT_END_SECTOR=$((ROOT_START_SECTOR - 1))

echo "=== Staging FreeBSD root ==="
rm -rf "$STAGE"
mkdir -p "$STAGE"
rsync -aHAX --numeric-ids /freebsd-root/ "$STAGE/"

mkdir -p "$STAGE/etc" "$STAGE/boot" "$STAGE/root"
cat > "$STAGE/etc/fstab" <<EOF
# Device              Mountpoint  FStype  Options  Dump  Pass#
/dev/gpt/${ROOT_LABEL} /          ufs     rw       1     1
EOF

if [ ! -f "$STAGE/etc/rc.conf" ]; then
    cat > "$STAGE/etc/rc.conf" <<'EOF'
hostname="ps5-freebsd"
ifconfig_DEFAULT="DHCP"
sshd_enable="NO"
dumpdev="NO"
EOF
fi

if [ ! -f "$STAGE/etc/ttys" ]; then
    touch "$STAGE/etc/ttys"
fi

echo "=== Creating UFS root image (${ROOT_SIZE_MB}MiB) ==="
rm -f "$ROOTFS"
makefs -t ffs -o version=2 -s "${ROOT_SIZE_MB}m" "$ROOTFS" "$STAGE"

echo "=== Creating FAT PS5 loader partition (${BOOT_SIZE_MB}MiB) ==="
rm -f "$BOOTFS"
truncate -s "${BOOT_SIZE_MB}M" "$BOOTFS"
mkfs.vfat -F32 -n "$BOOT_LABEL" "$BOOTFS"

mmd -i "$BOOTFS" ::/PS5
mmd -i "$BOOTFS" ::/PS5/FreeBSD
mcopy -i "$BOOTFS" "$FREEBSD_KERNEL" ::/PS5/FreeBSD/kernel
if [ -f /repo/boot/freebsd/kenv.txt ]; then
    mcopy -i "$BOOTFS" /repo/boot/freebsd/kenv.txt ::/PS5/FreeBSD/kenv.txt
fi
if [ -f /repo/boot/freebsd/vram.txt ]; then
    mcopy -i "$BOOTFS" /repo/boot/freebsd/vram.txt ::/PS5/FreeBSD/vram.txt
elif [ -f /repo/boot/vram.txt ]; then
    mcopy -i "$BOOTFS" /repo/boot/vram.txt ::/PS5/FreeBSD/vram.txt
fi

echo "=== Assembling GPT image (${IMG_SIZE}MiB) ==="
rm -f "$TMPIMG" "$IMG"
truncate -s "${IMG_SIZE}M" "$TMPIMG"
sgdisk --clear \
    --new=1:${BOOT_START_SECTOR}:${BOOT_END_SECTOR} \
    --typecode=1:ef00 \
    --change-name=1:"${BOOT_LABEL}" \
    --new=2:${ROOT_START_SECTOR}:0 \
    --typecode=2:a503 \
    --change-name=2:"${ROOT_LABEL}" \
    "$TMPIMG"

dd if="$BOOTFS" of="$TMPIMG" bs=1M seek="$BOOT_START_MB" conv=notrunc status=none
dd if="$ROOTFS" of="$TMPIMG" bs=1M seek="$ROOT_START_MB" conv=notrunc status=none
sync
mv "$TMPIMG" "$IMG"

echo "========================================"
echo "Done! $IMG (${IMG_SIZE}MB)"
echo "FAT path: /PS5/FreeBSD/kernel"
echo "Root:     ufs:/dev/gpt/${ROOT_LABEL}"
echo "Flash:    sudo dd if=$IMG of=/dev/sdX bs=4M status=progress"
echo "========================================"
