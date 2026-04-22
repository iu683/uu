#!/bin/sh
# ====================================================
# Alpine Linux Snell V5 专用管理脚本 (增强兼容性)
# ====================================================
set -e

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ================== 变量 ==================
SNELL_DIR="/etc/snell"
SNELL_CONFIG="$SNELL_DIR/snell-server.conf"
SNELL_INIT="/etc/init.d/snell"
LOG_FILE="/var/log/snell_manager.log"

# ================== 工具函数 ==================

# 关键：安装真正的 glibc 兼容层
install_glibc() {
    if [ ! -f "/usr/glibc-compat/lib/ld-linux-x86-64.so.2" ]; then
        echo -e "${GREEN}[信息] 检测到 Alpine 环境，正在安装 glibc 兼容层...${RESET}"
        apk add --no-cache wget ca-certificates
        wget -q -O /etc/apk/keys/sgerrand.rsa.pub https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub
        wget https://github.com/sgerrand/alpine-pkg-glibc/releases/download/2.35-r1/glibc-2.35-r1.apk
        apk add --force-overwrite glibc-2.35-r1.apk
        rm -f glibc-2.35-r1.apk
    fi
    
    # 强制建立动态链接软连接
    mkdir -p /lib64
    [ ! -L /lib64/ld-linux-x86-64.so.2 ] && ln -sf /usr/glibc-compat/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
}

check_deps() {
    echo -e "${GREEN}[信息] 检查并安装依赖 (upx/gcompat)...${RESET}"
    # 必须安装 upx，用于解压 Snell 二进制存根
    apk add --no-cache wget unzip curl gcompat libstdc++ upx
    # 如果是 x86_64 架构，执行 glibc 增强安装
    [ "$(uname -m)" = "x86_64" ] && install_glibc
}

create_user() {
    if ! id -u snell >/dev/null 2>&1; then
        adduser -S -D -H -s /sbin/nologin snell
    fi
}

get_public_ip() {
    curl -4s --max-time 5 https://api.ipify.org || curl -4s --max-time 5 https://ip.sb || echo "127.0.0.1"
}

check_port() {
    if netstat -tln | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

random_key() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

get_system_dns() {
    grep -E "^nameserver" /etc/resolv.conf | awk '{print $2}' | tr '\n' ',' | sed 's/,$//'
}

pause() {
    echo -e "${YELLOW}按回车键继续...${RESET}"
    read -r
}

# ================== 配置 Snell ==================
configure_snell() {
    echo -e "${GREEN}[配置] 开始设置 Snell 参数...${RESET}"
    mkdir -p $SNELL_DIR

    read -p "请输入端口 [默认随机]: " input_port
    port=${input_port:-$(shuf -i 10000-60000 -n 1)}
    check_port "$port" || return

    read -p "请输入密钥 [默认随机]: " key
    key=${key:-$(random_key)}

    obfs="off"
    ipv6="false"
    tfo="true"

    default_dns=$(get_system_dns)
    dns=${default_dns:-"1.1.1.1,8.8.8.8"}

    cat > $SNELL_CONFIG <<EOF
[snell-server]
listen = 0.0.0.0:$port
psk = $key
obfs = $obfs
ipv6 = $ipv6
tfo = $tfo
dns = $dns
EOF

    IP=$(get_public_ip)
    cat <<EOF > $SNELL_DIR/config.txt
# Surge Proxy Line:
$(hostname) = snell, $IP, $port, psk=$key, version=5, tfo=true, reuse=true, ecn=true
EOF
    echo -e "${GREEN}[完成] 配置已保存至 $SNELL_CONFIG${RESET}"
}

# ================== 安装 Snell ==================
install_snell() {
    check_deps
    create_user
    mkdir -p $SNELL_DIR
    cd $SNELL_DIR

    ARCH=$(uname -m)
    VERSION="v5.0.1"
    [ "$ARCH" = "x86_64" ] && ARCH_LABEL="amd64"
    [ "$ARCH" = "aarch64" ] && ARCH_LABEL="aarch64"

    echo -e "${GREEN}[信息] 下载 Snell ${VERSION} for ${ARCH_LABEL}...${RESET}"
    wget -qO snell.zip "https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-${ARCH_LABEL}.zip"
    unzip -o snell.zip
    rm -f snell.zip

    # --- 关键修改：脱壳 ---
    echo -e "${YELLOW}[注意] 正在进行 UPX 脱壳以适配 Alpine (musl)...${RESET}"
    upx -d snell-server >/dev/null 2>&1 || echo "无需脱壳或脱壳失败"
    # ---------------------

    chmod +x snell-server

    configure_snell

    # 创建 OpenRC 服务脚本
    cat > $SNELL_INIT <<EOF
#!/sbin/openrc-run

name="snell-server"
description="Snell Server v5"
command="$SNELL_DIR/snell-server"
command_args="-c $SNELL_CONFIG"
command_background="yes"
pidfile="/run/snell.pid"
command_user="root"

depend() {
    need net
    after firewall
}
EOF
    chmod +x $SNELL_INIT
    rc-update add snell default
    rc-service snell restart

    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}Snell v5 已安装并尝试启动${RESET}"
    cat $SNELL_DIR/config.txt
    echo -e "${GREEN}====================================${RESET}"
}

# ================== 菜单系统 ==================
show_menu() {
    clear
    echo -e "${GREEN}====== Snell Alpine 管理工具 (V5) ======${RESET}"
    echo "1. 安装/重装 Snell"
    echo "2. 卸载 Snell"
    echo "3. 启动服务"
    echo "4. 停止服务"
    echo "5. 重启服务"
    echo "6. 查看状态/配置"
    echo "0. 退出"
}

while true; do
    show_menu
    read -p "选项: " choice
    case $choice in
        1) install_snell; pause ;;
        2) 
            rc-service snell stop || true
            rc-update del snell || true
            rm -rf $SNELL_DIR $SNELL_INIT
            echo "已卸载"; pause ;;
        3) rc-service snell start; pause ;;
        4) rc-service snell stop; pause ;;
        5) rc-service snell restart; pause ;;
        6) 
            rc-service snell status
            [ -f "$SNELL_CONFIG" ] && { echo -e "${YELLOW}--- 配置文件 ---${RESET}"; cat "$SNELL_CONFIG"; }
            [ -f "$SNELL_DIR/config.txt" ] && { echo -e "${YELLOW}--- Surge 配置 ---${RESET}"; cat "$SNELL_DIR/config.txt"; }
            pause ;;
        0) exit 0 ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
done
