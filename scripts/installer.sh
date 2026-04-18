#!/bin/sh
# =============================================================================
# ImgFlash v3 - Interactive Disk Image Installer
# =============================================================================
# Runs as PID 1 inside initramfs. Uses static GNU dd for progress display.
# =============================================================================

IMAGE_FILE="/image/image.img"
DD="/bin/dd"

# ---------------------------------------------------------------------------
# Disk enumeration via /sys/block (no lsblk needed)
# ---------------------------------------------------------------------------

get_disks() {
    for d in /sys/block/sd* /sys/block/nvme* /sys/block/vd* /sys/block/hd*; do
        [ -d "$d" ] || continue
        [ "$(cat "$d/ro" 2>/dev/null)" = "0" ] || continue
        basename "$d"
    done
}

get_size_gb() {
    local sectors=$(cat "/sys/block/$1/size" 2>/dev/null)
    local bytes=$((sectors * 512))
    local gb=$((bytes / 1073741824))
    local mb=$(( (bytes % 1073741824) * 100 / 1073741824 ))
    printf "%d.%d" "$gb" "$mb"
}

get_model() {
    local model=""
    [ -f "/sys/block/$1/device/model" ] && model=$(cat "/sys/block/$1/device/model" 2>/dev/null)
    [ -f "/sys/block/$1/device/name" ] && model=$(cat "/sys/block/$1/device/name" 2>/dev/null)
    echo "${model:-Unknown}"
}

is_mounted() {
    grep -qE "^/dev/${1}p?[0-9]*[[:space:]]" /proc/mounts 2>/dev/null
}

# ---------------------------------------------------------------------------
# UI functions
# ---------------------------------------------------------------------------

show_disks() {
    clear
    echo "=========================================="
    echo "    ImgFlash - Disk Image Installer"
    echo "=========================================="
    echo ""
    echo "Available disks:"
    echo ""

    local disks=$(get_disks)
    local i=1

    for d in $disks; do
        local size=$(get_size_gb "$d")
        local model=$(get_model "$d")
        printf "%2d. /dev/%-12s %5s GB  %s\n" $i "$d" "$size" "$model"
        i=$((i + 1))
    done

    echo ""
}

select_disk() {
    local disks=$(get_disks)
    local count=$(echo $disks | wc -w)

    [ $count -eq 0 ] && echo "ERROR: No writable disks found!" && exit 1

    while true; do
        read -p "Select disk [1-$count, 0=Shell]: " choice

        [ "$choice" = "0" ] && echo "Dropping to shell." && exec /bin/sh

        if echo "$choice" | grep -qE '^[0-9]+$'; then
            if [ $choice -ge 1 ] && [ $choice -le $count ]; then
                local i=1
                for d in $disks; do
                    [ $i -eq $choice ] && echo "$d" && return 0
                    i=$((i + 1))
                done
            fi
        fi
        echo "Invalid selection."
    done
}

confirm() {
    local disk=$1
    local img_bytes=$(wc -c < "$IMAGE_FILE" 2>/dev/null || echo 0)
    local img_gb=$((img_bytes / 1073741824))
    local disk_size=$(get_size_gb "$disk")

    if is_mounted "$disk"; then
        echo ""
        echo "ERROR: /dev/$disk is currently mounted!"
        return 1
    fi

    echo ""
    echo "!!! WARNING !!!"
    echo "Target: /dev/$disk ($disk_size GB)"
    echo "Image:  $img_gb GB"
    echo ""
    echo "*** This will ERASE ALL DATA on /dev/$disk! ***"
    echo ""
    read -p "Type 'YES' to proceed: " answer

    [ "$answer" = "YES" ]
}

do_install() {
    local disk=$1

    if [ ! -f "$IMAGE_FILE" ]; then
        echo "ERROR: Image file not found!"
        return 1
    fi

    echo ""
    echo "Writing to /dev/$disk ..."
    echo ""

    if "$DD" if="$IMAGE_FILE" of="/dev/$disk" bs=4M status=progress conv=fsync 2>&1; then
        sync
        echo ""
        echo "Write complete. Syncing..."
        sync
        echo "Installation complete!"
        return 0
    else
        echo ""
        echo "Installation failed!"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

main() {
    while true; do
        show_disks

        local disk=$(select_disk)
        [ -z "$disk" ] && continue

        if confirm "$disk"; then
            if do_install "$disk"; then
                echo ""
                echo "Rebooting in 5 seconds..."
                sleep 5
                reboot -f
            fi
            echo ""
            read -p "Press Enter to continue..."
        fi
    done
}

main || {
    echo ""
    echo "Installer exited unexpectedly. Dropping to shell."
    exec /bin/sh
}
