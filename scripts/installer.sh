#!/bin/sh
# =============================================================================
# ImgFlash - 交互式磁盘镜像安装器
# =============================================================================

IMAGE_FILE="/image/image.img"
DD_PID=""

# Ctrl+C 清理后台 dd 进程
trap 'echo ""; \
      if [ -n "$DD_PID" ]; then \
          kill -KILL $DD_PID 2>/dev/null; wait $DD_PID 2>/dev/null; DD_PID=""; \
          echo "Aborted by user!"; echo "Returning to menu..."; \
      fi' INT

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
        printf "%d.%02d GB" "$((mb / 1024))" "$(( (mb % 1024) * 100 / 1024 ))"
    else
        printf "%d MB" "$mb"
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
    local img_mb=$((img_bytes / 1048576))
    local img_size
    if [ $img_mb -ge 1024 ]; then
        img_size=$(printf "%d.%02d GB" "$((img_mb / 1024))" "$(( (img_mb % 1024) * 100 / 1024 ))")
    else
        img_size=$(printf "%d MB" "$img_mb")
    fi

    local disk_size=$(get_size_human "$disk")

    echo ""
    echo "+>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<<<<<+"
    echo ">>  !! DANGEROUS OPERATION CONFIRMATION !!  <<"
    echo "+>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<<<<<+"
    echo "Target device: /dev/$disk ($disk_size)"
    echo "Image size: $img_size"
    echo "--------------------------------------"
    echo "This will ERASE ALL DATA on /dev/$disk!"

    # 检查磁盘容量是否小于镜像
    local disk_sectors=$(cat "/sys/block/$disk/size" 2>/dev/null || echo 0)
    if [ $((disk_sectors / 2)) -lt $((img_bytes / 1024)) ]; then
        echo ">> !! WARNING: Disk is smaller than image! Write will fail !! <<"
        printf "Press Enter to return..."; read _
        return 1
    fi

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

    dd if="$IMAGE_FILE" of="$target" bs=4M conv=fsync &
    DD_PID=$!
    local start=$(date +%s)
    local prev_written=0

    while kill -0 $DD_PID 2>/dev/null; do
        sleep 0.5
        local written=$(awk '/wchar/ {print $2}' /proc/$DD_PID/io 2>/dev/null)
        local now=$(date +%s)
        local elapsed=$((now - start))
        [ $elapsed -lt 1 ] && elapsed=1

        if [ -n "$written" ] && [ "$written" -gt 0 ]; then
            local old_prev=$prev_written
            prev_written=$written

            local stats=$(awk -v wrk="$written" -v prev="$old_prev" -v tot="$total_bytes" -v dt="0.5" 'BEGIN {
                pct = wrk * 10000 / tot
                if (pct > 10000) pct = 10000
                wmb = wrk / 1048576
                spd = ((wrk - prev) / 1048576) / dt
                printf "%.0f %.0f %.1f", pct, wmb, spd
            }')
            set -- $stats
            local pct_hundredths=$1
            local written_mb=$2
            local speed_mb=$3

            printf "\r  Progress: [%3d.%02d%%]  %d/%d MB  %.2f MB/s  Elapsed: %02d:%02d  \033[K" \
                "$((pct_hundredths / 100))" "$((pct_hundredths % 100))" \
                "$written_mb" "$total_mb" \
                "$speed_mb" \
                "$((elapsed / 60))" "$((elapsed % 60))"
        else
            printf "\r  Elapsed: %02d:%02d  (reading stats...)  \033[K" \
                "$((elapsed / 60))" "$((elapsed % 60))"
        fi
    done

    wait $DD_PID
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