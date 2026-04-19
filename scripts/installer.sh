#!/bin/sh
# =============================================================================
# ImgFlash - 交互式磁盘镜像安装器
# =============================================================================
# 在 initramfs 中以 PID 1 运行，使用 BusyBox dd 写盘。
# =============================================================================

IMAGE_FILE="/image/image.img"

# ---------------------------------------------------------------------------
# 磁盘枚举（通过 /sys/block，无需 lsblk）
# ---------------------------------------------------------------------------

# 获取可写磁盘列表
get_disks() {
    for d in /sys/block/sd* /sys/block/nvme* /sys/block/vd* /sys/block/hd*; do
        [ -d "$d" ] || continue
        [ "$(cat "$d/ro" 2>/dev/null)" = "0" ] || continue
        basename "$d"
    done
}

# 人类可读的磁盘大小（KB 级计算，避免 32 位溢出）
get_size_human() {
    local sectors=$(cat "/sys/block/$1/size" 2>/dev/null)
    local mb=$((sectors / 2 / 1024))
    if [ $mb -ge 1024 ]; then
        echo "$((mb / 1024)).$(( (mb % 1024) / 10 )) GB"
    else
        echo "${mb} MB"
    fi
}

# 获取磁盘型号
get_model() {
    local model=""
    [ -f "/sys/block/$1/device/model" ] && model=$(cat "/sys/block/$1/device/model" 2>/dev/null)
    [ -f "/sys/block/$1/device/name" ] && model=$(cat "/sys/block/$1/device/name" 2>/dev/null)
    echo "${model:-Unknown}"
}

# 检查磁盘或其分区是否已挂载
is_mounted() {
    grep -q "^/dev/$1" /proc/mounts 2>/dev/null
}

# ---------------------------------------------------------------------------
# 交互界面
# ---------------------------------------------------------------------------

# 主菜单（磁盘列表即菜单）
show_menu() {
    clear
    echo "==========================================="
    echo "               IMG Installer"
    echo "==========================================="

    local disks=$(get_disks)
    local i=1

    echo " 0. Shell"
    for d in $disks; do
        local size=$(get_size_human "$d")
        local model=$(get_model "$d")
        printf " %d. /dev/%-12s %8s  %s\n" $i "$d" "$size" "$model"
        i=$((i + 1))
    done

    local count=$((i - 1))
    echo "==========================================="

    if [ $count -eq 0 ]; then
        echo "ERROR: No writable disks found!"
        return 1
    fi
    DISK_COUNT=$count
}

# 确认写入
confirm() {
    local disk=$1

    # 检查磁盘是否已挂载
    if is_mounted "$disk"; then
        echo ""
        echo "ERROR: /dev/$disk is currently mounted!"
        return 1
    fi

    # 获取镜像大小
    local img_bytes=$(stat -c '%s' "$IMAGE_FILE" 2>/dev/null || echo 0)
    local img_size
    if [ $img_bytes -ge 1073741824 ]; then
        img_size="$((img_bytes / 1073741824)).$(( (img_bytes % 1073741824) * 10 / 1073741824 )) GB"
    elif [ $img_bytes -ge 1048576 ]; then
        img_size="$((img_bytes / 1048576)).$(( (img_bytes % 1048576) * 10 / 1048576 )) MB"
    else
        img_size="$((img_bytes / 1024)) KB"
    fi

    local disk_size=$(get_size_human "$disk")

    echo ""
    echo "!! DANGEROUS OPERATION CONFIRMATION !!"
    echo "--------------------------------------"
    echo "Target device: /dev/$disk ($disk_size)"
    echo "Image size: $img_size"
    echo "--------------------------------------"
    echo "This will ERASE ALL DATA on /dev/$disk!"
    printf "Confirm write operation? (Type uppercase YES to proceed): "; read answer

    [ "$answer" = "YES" ]
}

# ---------------------------------------------------------------------------
# 写入
# ---------------------------------------------------------------------------

do_install() {
    local disk=$1
    local target="/dev/$disk"

    if [ ! -f "$IMAGE_FILE" ]; then
        echo "ERROR: Image file not found!"
        return 1
    fi

    local total_bytes=$(stat -c '%s' "$IMAGE_FILE" 2>/dev/null || echo 0)
    local total_mb=$((total_bytes / 1048576))

    echo ""
    echo "Writing to $target ..."
    echo "Please wait..."

    dd if="$IMAGE_FILE" of="$target" bs=4M conv=fsync &
    local dd_pid=$!
    local elapsed=0

    while kill -0 $dd_pid 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        local written=$(cat /proc/$dd_pid/io 2>/dev/null | awk '/wchar/ {print $2}')
        if [ -n "$written" ] && [ "$written" -gt 0 ]; then
            local written_mb=$((written / 1048576))
            local pct=0
            [ $total_mb -gt 0 ] && pct=$((written_mb * 100 / total_mb))
            printf "\r  Progress: [%3d%%]  %d/%d MB  Elapsed: %02d:%02d  \033[K" \
                "$pct" "$written_mb" "$total_mb" "$((elapsed / 60))" "$((elapsed % 60))"
        else
            printf "\r  Elapsed: %02d:%02d  (reading stats...)" \
                "$((elapsed / 60))" "$((elapsed % 60))"
        fi
    done

    wait $dd_pid
    local dd_status=$?

    echo ""

    if [ $dd_status -eq 0 ]; then
        echo "Installation complete!"
        return 0
    else
        echo "Installation failed!"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 主循环
# ---------------------------------------------------------------------------

DISK_COUNT=0

main() {
    while true; do
        show_menu || return 1

        printf "Your choice [0-$DISK_COUNT]: "; read choice

        [ "$choice" = "0" ] && { echo "Type 'exit' to return to installer."; /bin/sh; }

        if echo "$choice" | grep -qE '^[0-9]+$'; then
            if [ $choice -ge 1 ] && [ $choice -le $DISK_COUNT ]; then
                local disks=$(get_disks)
                local i=1
                local disk=""
                for d in $disks; do
                    [ $i -eq $choice ] && disk="$d" && break
                    i=$((i + 1))
                done

                if [ -n "$disk" ] && confirm "$disk"; then
                    if do_install "$disk"; then
                        echo ""
                        local sec=5
                        while [ $sec -gt 0 ]; do
                            printf "Rebooting in %d seconds...\n" "$sec"
                            sec=$((sec - 1))
                            sleep 1
                        done
                        reboot -f
                    fi
                    echo ""
                    printf "Press Enter to continue..."; read _
                fi
            fi
        fi
    done
}

main || {
    echo ""
    echo "Installer exited unexpectedly. Dropping to shell."
    exec /bin/sh
}