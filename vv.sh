#!/bin/bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH
LANG=en_US.UTF-8

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

error_msg() { echo -e "${RED}[错误] $1${NC}"; }
warning_msg() { echo -e "${YELLOW}[警告] $1${NC}"; }
success_msg() { echo -e "${GREEN}[成功] $1${NC}"; }
info_msg() { echo -e "${BLUE}[信息] $1${NC}"; }

confirm() {
    local prompt="$1 (y/N): "
    local answer
    read -p "$prompt" answer </dev/tty
    case "$answer" in [Yy]|[Yy][Ee][Ss]) return 0 ;; *) return 1 ;; esac
}

check_root() {
    [ "$EUID" -ne 0 ] && { error_msg "请使用 root 权限运行此脚本。"; exit 1; }
}

get_system_disk_base() {
    local root_dev=$(df -P / | awk 'NR==2 {print $1}')
    local boot_dev=$(df -P /boot 2>/dev/null | awk 'NR==2 {print $1}')
    for dev in $root_dev $boot_dev; do
        echo "$dev" | sed -e 's/[0-9]*$//' -e 's/p[0-9]*$//'
    done | sort -u
}

is_system_disk() {
    local dev=$1
    local base=$(echo "$dev" | sed -e 's/[0-9]*$//' -e 's/p[0-9]*$//')
    local sys_disks=$(get_system_disk_base)
    for sd in $sys_disks; do
        [[ "$base" == "$sd" ]] && return 0
    done
    [[ "$base" =~ ^/dev/(sda|vda|xvda|hda|nvme0n1)$ ]] && return 0
    return 1
}

is_system_mountpoint() {
    local mp=$1
    case "$mp" in
        /|/boot|/boot/*|/usr|/usr/*|/var|/var/*|/tmp|/etc|/etc/*|/root|/proc|/sys|/dev)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

get_data_disks() {
    local sys_disks=$(get_system_disk_base)
    for disk in $(lsblk -d -o NAME,TYPE | grep disk | awk '{print $1}'); do
        local full_disk="/dev/$disk"
        local base=$(echo "$full_disk" | sed -e 's/[0-9]*$//' -e 's/p[0-9]*$//')
        local is_sys=0
        for sd in $sys_disks; do
            [[ "$base" == "$sd" ]] && is_sys=1 && break
        done
        [[ $is_sys -eq 1 ]] && continue
        [[ "$base" =~ ^/dev/(sda|vda|xvda|hda|nvme0n1)$ ]] && continue
        echo "$disk"
    done
}

force_unmount_disk() {
    local disk=$1
    if is_system_disk "/dev/$disk"; then
        error_msg "拒绝卸载系统盘 /dev/$disk！"
        return 1
    fi
    info_msg "正在强制卸载 /dev/$disk 相关的所有挂载点..."
    local mounts=$(mount | grep "^/dev/${disk}" | awk '{print $1}')
    for dev in $mounts; do
        umount "$dev" 2>/dev/null
        if mount | grep -q "^$dev "; then
            info_msg "普通卸载失败，使用懒卸载 (lazy)..."
            umount -l "$dev" 2>/dev/null
            sleep 1
        fi
    done
    if mount | grep -q "^/dev/${disk}"; then
        error_msg "无法卸载 /dev/$disk 的分区，请手动处理。"
        return 1
    fi
    success_msg "卸载完成。"
    return 0
}

view_disk_info() {
    clear
    echo -e "${CYAN}==================== 磁盘分区信息 ====================${NC}"
    echo ""
    echo -e "${GREEN}>>> lsblk 输出：${NC}"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE
    echo ""
    echo -e "${GREEN}>>> fdisk -l 输出（仅数据盘）：${NC}"
    for disk in $(get_data_disks); do
        fdisk -l "/dev/$disk" 2>/dev/null | head -n 20
    done
    echo ""
    read -p "按回车键返回主菜单..." dummy </dev/tty
}

mount_disk() {
    clear
    echo -e "${CYAN}==================== 挂载磁盘向导 ====================${NC}"

    local disks=($(get_data_disks))
    if [ ${#disks[@]} -eq 0 ]; then
        error_msg "未检测到可用数据盘。"
        read -p "按回车键返回主菜单..." dummy </dev/tty
        return
    fi

    echo -e "${BLUE}检测到以下数据盘:${NC}"
    local index=1
    for disk in "${disks[@]}"; do
        local size=$(lsblk -d -o NAME,SIZE | grep -w "$disk" | awk '{print $2}')
        local model=$(lsblk -d -o NAME,MODEL | grep -w "$disk" | awk '{$1=""; print $0}' | sed 's/^[ \t]*//')
        local mount_status="未挂载"
        mount | grep -q "^/dev/$disk" && mount_status="${YELLOW}已挂载${NC}"
        printf "  [%d] %-8s  %-10s  %-20s %b\n" "$index" "$disk" "$size" "$model" "$mount_status"
        ((index++))
    done

    local choice
    while true; do
        read -p "请输入要操作的磁盘编号 (1-${#disks[@]})，输入 0 返回: " choice </dev/tty
        [[ "$choice" == "0" ]] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#disks[@]} ]; then
            selected_disk="${disks[$((choice-1))]}"
            break
        else
            warning_msg "输入无效。"
        fi
    done
    info_msg "选择的磁盘: /dev/$selected_disk"

    if is_system_disk "/dev/$selected_disk"; then
        error_msg "选择的磁盘为系统盘，禁止操作！"
        read -p "按回车键返回..." dummy </dev/tty
        return
    fi

    local mount_point=""
    while true; do
        read -p "请输入挂载点目录 (绝对路径，例如 /data 或 /home，输入 0 返回): " mp </dev/tty
        [[ "$mp" == "0" ]] && return
        if [[ "$mp" != /* ]]; then
            warning_msg "必须是绝对路径。"
            continue
        fi
        if [[ "$mp" == "/" ]]; then
            warning_msg "不能挂载到根目录 /。"
            continue
        fi
        if mountpoint -q "$mp"; then
            warning_msg "目录 $mp 已被挂载。"
            continue
        fi
        if is_system_mountpoint "$mp"; then
            warning_msg "$mp 是系统关键目录，禁止作为挂载点。"
            continue
        fi
        mount_point="$mp"
        break
    done
    info_msg "挂载点: $mount_point"

    if [ -d "$mount_point" ] && [ -n "$(ls -A "$mount_point" 2>/dev/null)" ]; then
        warning_msg "目录 $mount_point 非空！"
        echo -e "${YELLOW}当前目录内容：${NC}"
        ls -la "$mount_point" | head -n 10
        echo -e "${RED}如果继续挂载，该目录内的所有文件将被永久删除！${NC}"
        if ! confirm "确定要清空 $mount_point 并继续挂载吗？"; then
            info_msg "操作已取消。"
            read -p "按回车键返回..." dummy </dev/tty
            return
        fi
        echo -e "${RED}最后一次警告：即将清空 $mount_point 目录！${NC}"
        if ! confirm "输入 yes 确认清空并继续 (yes/N): "; then
            info_msg "操作已取消。"
            read -p "按回车键返回..." dummy </dev/tty
            return
        fi
        info_msg "正在清空 $mount_point ..."
        rm -rf "$mount_point"/*
        success_msg "目录已清空。"
    fi

    if mount | grep -q "^/dev/$selected_disk"; then
        warning_msg "磁盘 /dev/$selected_disk 已有分区挂载。"
        if ! confirm "是否重新分区并格式化（将清除所有数据）？"; then
            local part1="/dev/${selected_disk}1"
            if [ -b "$part1" ]; then
                info_msg "尝试挂载已有分区 $part1 到 $mount_point"
                mkdir -p "$mount_point"
                mount "$part1" "$mount_point" || { error_msg "挂载失败。"; return; }
                sed -i "\|^$part1|d" /etc/fstab
                echo "$part1    $mount_point    ext4    defaults    0 0" >> /etc/fstab
                success_msg "挂载成功，已写入 /etc/fstab"
                df -h | grep "$mount_point"
                read -p "按回车键继续..." dummy </dev/tty
                return
            else
                error_msg "未找到分区 $part1。"
                read -p "按回车键返回..." dummy </dev/tty
                return
            fi
        fi
    fi

    if fdisk -l "/dev/$selected_disk" 2>/dev/null | grep -qiE "NTFS|FAT"; then
        warning_msg "检测到 Windows 分区！"
        confirm "格式化将清除所有数据，确定继续吗？" || return
    fi

    echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
    echo -e "${RED}!!  警告：即将对 /dev/$selected_disk 分区并格式化  !!${NC}"
    echo -e "${RED}!!  该磁盘上的所有数据都将被永久清除！        !!${NC}"
    echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
    confirm "确定要继续吗？" || return

    cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
    info_msg "已备份 /etc/fstab"

    force_unmount_disk "$selected_disk" || { read -p "按回车键返回..." dummy </dev/tty; return; }

    info_msg "正在清除分区表并创建新分区..."
    (
    echo d; echo d; echo d; echo d
    echo n; echo p; echo 1; echo; echo
    echo w
    ) | fdisk "/dev/$selected_disk" > /dev/null 2>&1

    partprobe "/dev/$selected_disk" 2>/dev/null || blockdev --rereadpt "/dev/$selected_disk" 2>/dev/null
    sleep 3

    local part1="/dev/${selected_disk}1"
    if [ ! -b "$part1" ]; then
        info_msg "fdisk 失败，尝试 parted 创建 GPT 分区..."
        parted -s "/dev/$selected_disk" mklabel gpt
        parted -s "/dev/$selected_disk" mkpart primary ext4 0% 100%
        partprobe "/dev/$selected_disk" 2>/dev/null
        sleep 3
        part1="/dev/${selected_disk}1"
        [ ! -b "$part1" ] && { error_msg "分区创建失败。"; return; }
    fi

    if mount | grep -q "^$part1 "; then
        umount -l "$part1" 2>/dev/null
        sleep 1
    fi

    info_msg "格式化 $part1 为 ext4..."
    mkfs.ext4 -F "$part1" || { error_msg "格式化失败。"; return; }

    mkdir -p "$mount_point"
    mount "$part1" "$mount_point" || { error_msg "挂载失败。"; return; }

    sed -i "\|^$part1|d" /etc/fstab
    echo "$part1    $mount_point    ext4    defaults    0 0" >> /etc/fstab

    success_msg "磁盘挂载完成！"
    df -h | grep "$mount_point"
    read -p "按回车键继续..." dummy </dev/tty
}

unmount_partition() {
    clear
    echo -e "${CYAN}==================== 卸载分区 ====================${NC}"

    echo -e "${GREEN}当前挂载的分区（仅数据盘）：${NC}"
    mount | grep "^/dev/" | while read line; do
        dev=$(echo "$line" | awk '{print $1}')
        mp=$(echo "$line" | awk '{print $3}')
        if is_system_disk "$dev" || is_system_mountpoint "$mp"; then
            continue
        fi
        echo "$line" | awk '{print NR")", $1, "->", $3}' | column -t
    done

    local count=$(mount | grep "^/dev/" | while read line; do
        dev=$(echo "$line" | awk '{print $1}')
        mp=$(echo "$line" | awk '{print $3}')
        is_system_disk "$dev" || is_system_mountpoint "$mp" || echo "1"
    done | wc -l)
    if [ "$count" -eq 0 ]; then
        info_msg "没有可卸载的数据盘分区。"
        read -p "按回车键返回主菜单..." dummy </dev/tty
        return
    fi

    echo ""
    read -p "请输入要卸载的设备名（如 /dev/vdb1）或挂载点（如 /home），输入 0 返回: " target </dev/tty
    [[ "$target" == "0" ]] && return

    local dev mp
    if [ -b "$target" ]; then
        dev="$target"
        mp=$(mount | grep "^$dev " | awk '{print $3}')
    elif [ -d "$target" ]; then
        mp="$target"
        dev=$(mount | grep " $mp " | awk '{print $1}')
    else
        error_msg "输入无效，不是设备文件也不是目录。"
        read -p "按回车键返回..." dummy </dev/tty
        return
    fi

    if [ -z "$dev" ] || [ -z "$mp" ]; then
        error_msg "未找到对应的挂载关系。"
        read -p "按回车键返回..." dummy </dev/tty
        return
    fi

    if is_system_disk "$dev"; then
        error_msg "拒绝卸载系统盘 $dev！"
        read -p "按回车键返回..." dummy </dev/tty
        return
    fi
    if is_system_mountpoint "$mp"; then
        error_msg "拒绝卸载系统关键目录 $mp！"
        read -p "按回车键返回..." dummy </dev/tty
        return
    fi

    info_msg "将卸载设备 $dev 从挂载点 $mp"
    if ! confirm "确定卸载吗？"; then
        info_msg "操作取消。"
        read -p "按回车键返回..." dummy </dev/tty
        return
    fi

    umount "$mp" 2>/dev/null
    if mountpoint -q "$mp"; then
        warning_msg "普通卸载失败，尝试强制卸载..."
        umount -l "$mp"
        sleep 1
        if mountpoint -q "$mp"; then
            error_msg "卸载失败，请手动处理。"
            read -p "按回车键返回..." dummy </dev/tty
            return
        fi
    fi

    sed -i "\|^$dev|d" /etc/fstab
    success_msg "卸载成功，并已从 /etc/fstab 移除条目。"
    read -p "按回车键继续..." dummy </dev/tty
}

view_disk_usage() {
    clear
    echo -e "${CYAN}==================== 磁盘使用情况 ====================${NC}"
    df -h
    echo ""
    read -p "按回车键返回主菜单..." dummy </dev/tty
}

show_menu() {
    clear
    echo -e " ${GREEN}==============================${NC}"
    echo -e " ${GREEN}        磁盘管理工具           ${NC}"
    echo -e " ${GREEN}==============================${NC}"
    echo -e " ${GREEN}1) 查看磁盘分区信息${NC}"
    echo -e " ${GREEN}2) 挂载磁盘(仅数据盘)${NC}"
    echo -e " ${GREEN}3) 卸载分区(仅数据盘)${NC}"
    echo -e " ${GREEN}4) 查看磁盘使用情况${NC}"
    echo -e " ${GREEN}0) 退出${NC}"
}


main() {
    check_root
    while true; do
        show_menu
        read -p " 请输入选项: " opt </dev/tty
        case "$opt" in
            1) view_disk_info ;;
            2) mount_disk ;;
            3) unmount_partition ;;
            4) view_disk_usage ;;
            0) exit 0 ;;
            *) warning_msg "无效选项，请重新输入。" ; sleep 1 ;;
        esac
    done
}

main
