#!/bin/sh
# =============================================================================
# ImgFlash - initramfs /init
# =============================================================================
# Pure initramfs-only boot: no rootfs, no overlayfs, no switch_root.
# The initramfs IS the final runtime environment.
# =============================================================================

emergency_shell() {
    echo ""
    echo "ERROR: $1"
    echo "Dropping to emergency shell."
    exec /bin/sh
}

# --- Install busybox symlinks (MUST be first - no other commands exist yet) ---
/bin/busybox --install -s
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# --- Mount virtual filesystems ---
mkdir -p /proc /sys /dev /dev/pts /dev/shm /run /tmp
mkdir -p /media/cdrom /image

mount -t proc -o noexec,nosuid,nodev proc /proc
mount -t sysfs -o noexec,nosuid,nodev sysfs /sys
mount -t devtmpfs -o exec,nosuid,mode=0755 devtmpfs /dev 2>/dev/null \
    || mount -t tmpfs -o exec,nosuid,mode=0755 tmpfs /dev

[ -c /dev/null ] || mknod -m 666 /dev/null c 1 3
[ -c /dev/kmsg ] || mknod -m 660 /dev/kmsg c 1 11

mount -t devpts -o gid=5,mode=0620,noexec,nosuid devpts /dev/pts
mount -t tmpfs -o nodev,nosuid,noexec shm /dev/shm

ln -sf /proc/mounts /etc/mtab

# --- Parse kernel command line ---
quiet=no
for opt in $(cat /proc/cmdline); do
    case "$opt" in
        quiet) quiet=yes ;;
        debug) set -x ;;
    esac
done

[ "$quiet" = "yes" ] && dmesg -n 1

echo "ImgFlash init starting..."

# --- Load kernel modules ---
echo "Loading kernel modules..."
modprobe -a squashfs isofs loop nls_cp437 nls_ascii 2>/dev/null
modprobe -a ahci nvme sd_mod sr_mod cdrom 2>/dev/null
modprobe -a xhci-hcd ehci-hcd usb-storage uas 2>/dev/null
modprobe -a virtio_blk virtio_pci virtio 2>/dev/null

# --- Wait for block devices to settle ---
sleep 2

# --- Scan for boot media (ISO9660 with image.squashfs) ---
echo "Scanning for boot media..."
BOOT_DEV=""
TRIES=0
while [ $TRIES -lt 10 ]; do
    for dev in /dev/sr* /dev/sd* /dev/nvme*; do
        [ -b "$dev" ] || continue
        if mount -t iso9660 -o ro "$dev" /media/cdrom 2>/dev/null; then
            if [ -f /media/cdrom/image.squashfs ]; then
                BOOT_DEV="$dev"
                break 2
            fi
            umount /media/cdrom
        fi
    done
    TRIES=$((TRIES + 1))
    sleep 1
done

[ -z "$BOOT_DEV" ] && emergency_shell "Boot media not found after 10 seconds."
echo "Boot media found: $BOOT_DEV"

# --- Mount image.squashfs as data container ---
echo "Mounting image..."
mount -t squashfs -o ro,loop /media/cdrom/image.squashfs /image \
    || emergency_shell "Failed to mount image.squashfs"

[ -f /image/image.img ] || emergency_shell "image.img not found in squashfs"

# --- Hand off to installer (becomes PID 1) ---
echo "Starting installer..."
exec /usr/bin/installer
emergency_shell "Failed to start installer"