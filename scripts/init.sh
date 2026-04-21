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
mkdir -p /proc /sys /dev /run /tmp /media/cdrom /image \
    /dev/pts /dev/shm /etc /root /var/log

mount -t proc -o noexec,nosuid,nodev proc /proc
mount -t sysfs -o noexec,nosuid,nodev sysfs /sys
mount -t devtmpfs -o exec,nosuid,mode=0755,size=2M devtmpfs /dev 2>/dev/null \
    || mount -t tmpfs -o exec,nosuid,mode=0755,size=2M tmpfs /dev

mount -t devpts -o gid=5,mode=0620,noexec,nosuid devpts /dev/pts
mount -t tmpfs -o nodev,nosuid,noexec shm /dev/shm

[ -c /dev/null ] || mknod -m 666 /dev/null c 1 3
[ -c /dev/kmsg ] || mknod -m 660 /dev/kmsg c 1 11
[ -c /dev/ptmx ] || mknod -m 666 /dev/ptmx c 5 2

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
while read mod; do
    modprobe "$mod" 2>/dev/null
done < /etc/modules

# VMware virtual SCSI drivers
if grep -q VMware /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null; then
    echo "VMware detected, loading virtual SCSI drivers..."
    modprobe ata_piix 2>/dev/null
    modprobe mptspi 2>/dev/null
    modprobe sr_mod 2>/dev/null
fi

# --- Wait for block devices to settle ---
sleep 1

# --- Scan for boot media (ISO9660 with image.squashfs) ---
echo "Scanning for boot media..."
BOOT_DEV=""
TRIES=0
while [ $TRIES -lt 10 ]; do
    for dev in /dev/sr* /dev/sd* /dev/nvme* /dev/vd*; do
        [ -b "$dev" ] || continue
        if mount -t iso9660 -o ro "$dev" /media/cdrom 2>/dev/null; then
            if [ -f /media/cdrom/image.squashfs ]; then
                BOOT_DEV="$dev"
                break 2
            fi
            umount /media/cdrom
        fi
        if mount -t vfat -o ro "$dev" /media/cdrom 2>/dev/null; then
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

# --- Launch installer as child process (keep PID 1 for signal handling) ---
echo "Starting installer..."
/usr/bin/installer

# Installer exited - drop to shell
emergency_shell "Installer exited"