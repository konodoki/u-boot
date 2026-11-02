#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0+
# Make a GPT-partitioned eMMC image for bxi-ground-station.
# U-Boot lives in SPI NOR; this image contains only the eMMC boot and rootfs.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOTFS_DIR=${1:-}
OUTPUT=${2:-"$SCRIPT_DIR/build/bxi-ground-station/emmc-bxi-ground-station.img"}
IMAGE_SIZE=${IMAGE_SIZE:-1800MiB}
BOOT_SIZE=${BOOT_SIZE:-256MiB}
KERNEL_IMAGE=${KERNEL_IMAGE:-}
DTB_IMAGE=${DTB_IMAGE:-}

usage() {
    cat <<USAGE
Usage: $0 ROOTFS_DIR [OUTPUT_IMAGE]

Create a GPT image for the 2 GB eMMC of bxi-ground-station.
Partition 1 is a FAT32 boot partition; partition 2 is an ext4 rootfs.
U-Boot is intentionally not included because it is installed in SPI NOR.

Environment:
  IMAGE_SIZE    image size (default: $IMAGE_SIZE; keep below eMMC capacity)
  BOOT_SIZE     boot partition size (default: $BOOT_SIZE)
  KERNEL_IMAGE  optional kernel Image to copy to the boot partition
  DTB_IMAGE     optional board DTB to copy to the boot partition

Example:
  KERNEL_IMAGE=/path/to/Image \\
  DTB_IMAGE=/path/to/rk3566-lubancat-1io.dtb \\
  $0 /path/to/rootfs build/bxi-ground-station/emmc.img
USAGE
}

if [[ ${1:-} == -h || ${1:-} == --help || -z $ROOTFS_DIR ]]; then
    usage
    exit $([[ -z $ROOTFS_DIR ]] && echo 2 || echo 0)
fi

if [[ ! -d $ROOTFS_DIR ]]; then
    echo "error: rootfs directory does not exist: $ROOTFS_DIR" >&2
    exit 1
fi
for command in sgdisk losetup mkfs.vfat mkfs.ext4 rsync awk; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "error: missing command: $command" >&2
        echo "       Ubuntu: sudo apt install -y gdisk dosfstools e2fsprogs rsync util-linux" >&2
        exit 1
    fi
done

if [[ -n $KERNEL_IMAGE && ! -f $KERNEL_IMAGE ]]; then
    echo "error: KERNEL_IMAGE does not exist: $KERNEL_IMAGE" >&2
    exit 1
fi
if [[ -n $DTB_IMAGE && ! -f $DTB_IMAGE ]]; then
    echo "error: DTB_IMAGE does not exist: $DTB_IMAGE" >&2
    exit 1
fi

mkdir -p "$(dirname -- "$OUTPUT")"
rm -f -- "$OUTPUT"

echo "==> Creating $OUTPUT ($IMAGE_SIZE)"
truncate -s "$IMAGE_SIZE" "$OUTPUT"
sgdisk --zap-all "$OUTPUT" >/dev/null
sgdisk \
    --new=1:32768:+"$BOOT_SIZE" \
    --typecode=1:0700 \
    --change-name=1:boot \
    --new=2:0:0 \
    --typecode=2:8300 \
    --change-name=2:rootfs \
    "$OUTPUT" >/dev/null

LOOP=""
BOOT_MNT=$(mktemp -d)
ROOT_MNT=$(mktemp -d)
cleanup() {
    set +e
    sync
    mountpoint -q "$BOOT_MNT" && sudo umount "$BOOT_MNT"
    mountpoint -q "$ROOT_MNT" && sudo umount "$ROOT_MNT"
    [[ -n $LOOP ]] && sudo losetup -d "$LOOP"
    rmdir "$BOOT_MNT" "$ROOT_MNT" 2>/dev/null || true
}
trap cleanup EXIT

LOOP=$(sudo losetup --find --show --partscan "$OUTPUT")
sudo udevadm settle 2>/dev/null || true
P1="${LOOP}p1"
P2="${LOOP}p2"
if [[ ! -b $P1 || ! -b $P2 ]]; then
    sudo partx --add "$LOOP" 2>/dev/null || true
    sudo udevadm settle 2>/dev/null || true
fi
if [[ ! -b $P1 || ! -b $P2 ]]; then
    echo "error: loop partition devices were not created for $LOOP" >&2
    exit 1
fi

echo "==> Formatting partitions"
sudo mkfs.vfat -F 32 -n BOOT "$P1" >/dev/null
sudo mkfs.ext4 -F -L rootfs "$P2" >/dev/null
sudo mount "$P2" "$ROOT_MNT"
sudo mount "$P1" "$BOOT_MNT"

echo "==> Copying rootfs"
sudo rsync -aHAX --numeric-ids --delete "$ROOTFS_DIR"/ "$ROOT_MNT"/

# If the rootfs already contains /boot, make its contents available on the
# separate FAT boot partition as well.  The source /boot remains harmless.
if [[ -d "$ROOTFS_DIR/boot" ]]; then
    sudo rsync -aHAX --delete "$ROOTFS_DIR/boot"/ "$BOOT_MNT"/
fi

if [[ -n $KERNEL_IMAGE ]]; then
    sudo install -m 0644 "$KERNEL_IMAGE" "$BOOT_MNT/Image"
fi
if [[ -n $DTB_IMAGE ]]; then
    sudo install -m 0644 "$DTB_IMAGE" \
        "$BOOT_MNT/$(basename -- "$DTB_IMAGE")"
fi

ROOT_PARTUUID=$(sudo blkid -s PARTUUID -o value "$P2")
KERNEL_NAME=${KERNEL_NAME:-Image}
DTB_NAME=${DTB_NAME:-$(basename -- "${DTB_IMAGE:-rk3566-lubancat-1io.dtb}")}

# Create an extlinux entry only when the caller supplied the boot artifacts,
# or when one does not already exist in the copied boot directory.
if [[ -n $KERNEL_IMAGE || -n $DTB_IMAGE ]]; then
    sudo mkdir -p "$BOOT_MNT/extlinux"
    if [[ ! -f "$BOOT_MNT/extlinux/extlinux.conf" ]]; then
        sudo tee "$BOOT_MNT/extlinux/extlinux.conf" >/dev/null <<CONF
label bxi-ground-station
    kernel /$KERNEL_NAME
    fdt /$DTB_NAME
    append root=PARTUUID=$ROOT_PARTUUID rootwait rw
CONF
    fi
fi

sync
sudo umount "$BOOT_MNT"
sudo umount "$ROOT_MNT"
sudo losetup -d "$LOOP"
LOOP=""
trap - EXIT
rmdir "$BOOT_MNT" "$ROOT_MNT" 2>/dev/null || true

echo "==> Image created: $OUTPUT"
sgdisk --print "$OUTPUT"
echo "    rootfs PARTUUID: $ROOT_PARTUUID"
echo "    flash with: rkdeveloptool wl 0x0 $OUTPUT"
