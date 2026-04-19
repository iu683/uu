#!/bin/bash
# ==========================================
# 通用主机名修改脚本 (支持 Alpine/Debian/Ubuntu/CentOS)
# ==========================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# 1. Root 检查
[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 请使用 root 权限运行${RESET}" && exit 1

# 2. 系统识别
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
else
    echo -e "${RED}❌ 无法识别系统类型${RESET}"
    exit 1
fi

# 3. 获取输入
current_hostname=$(hostname)
echo -e "${YELLOW}当前主机名: ${RESET}${current_hostname}"
read -p "请输入新的主机名: " new_hostname

# 验证输入是否为空
if [ -z "$new_hostname" ]; then
    echo -e "${RED}❌ 主机名不能为空${RESET}"
    exit 1
fi

echo -e "${YELLOW}正在将主机名从 ${current_hostname} 修改为 ${new_hostname} ...${RESET}"

# 4. 执行修改逻辑
case "$OS_ID" in
    alpine)
        # Alpine 修改逻辑
        echo "$new_hostname" > /etc/hostname
        hostname "$new_hostname"
        ;;
    debian|ubuntu|centos|rhel|rocky|almalinux|fedora)
        # 带有 systemd 的系统使用 hostnamectl (最稳妥)
        if command -v hostnamectl >/dev/null 2>&1; then
            hostnamectl set-hostname "$new_hostname"
        else
            # 兜底方案
            echo "$new_hostname" > /etc/hostname
            hostname "$new_hostname"
        fi
        ;;
    *)
        # 兼容其他 Linux
        echo "$new_hostname" > /etc/hostname
        hostname "$new_hostname"
        ;;
esac

# 5. 修改 /etc/hosts 文件 (防止 sudo 报错)
# 这一步非常重要，它会将旧的主机名替换为新的，或者在 127.0.1.1/127.0.0.1 行追加
if grep -q "$current_hostname" /etc/hosts; then
    sed -i "s/$current_hostname/$new_hostname/g" /etc/hosts
else
    # 如果 hosts 里没找到旧名称，则在第一行追加
    sed -i "1i 127.0.0.1 $new_hostname" /etc/hosts
fi

# 6. 验证
final_hostname=$(hostname)
if [ "$final_hostname" == "$new_hostname" ]; then
    echo -e "${GREEN}----------------------------------${RESET}"
    echo -e "${GREEN}✅ 主机名修改成功！${RESET}"
    echo -e "${YELLOW}新主机名: ${RESET}${final_hostname}"
    echo -e "${YELLOW}提示: 请重新连接 SSH 以查看终端提示符更新。${RESET}"
    echo -e "${YELLOW}当前时间: $(date +'%Y年%m月%d日 %H:%M:%S')${RESET}"
else
    echo -e "${RED}❌ 修改可能未完全成功，请手动检查 /etc/hostname${RESET}"
fi
