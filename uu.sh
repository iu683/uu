#!/bin/sh
# ====================================================
# Alpine Linux Snell V5 专用管理脚本 (支持自定义配置)
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
SNELL_BIN="$SNELL_DIR/snell-server"

# ================== 工具函数 ==================

install_glibc() {
    if [ ! -f "/usr/glibc-compat/lib/ld-linux-x86-64.so.2" ]; then
        echo -e "${GREEN}[信息] 安装 glibc 兼容层...${RESET}"
        apk add --no-cache wget ca-certificates
        wget -q -O /etc/apk/keys/sgerrand.rsa.pub https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub
        wget -t 3 -T 10 https://github.com/sgerrand/alpine-pkg-glibc/releases/download/2.35-r1/glibc-2.35-r1.apk
        apk add --force-overwrite glibc-2.35-r1.apk
        rm -f glibc-2.35-r1.apk
    fi
    mkdir -p /lib64
    ln -sf /usr/glibc-compat/lib/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2
    ln -sf /usr/glibc-compat/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
}

check_deps() {
    echo -e "${GREEN}[信息] 检查依赖...${RESET}"
    apk add --no-cache wget unzip curl gcompat libstdc++ upx
    [ "$(uname -m)" = "x86_64" ] && install_glibc
}

get_public_ip() {
    curl -4s --max-time 5 https://api.ipify.org || curl -4s --max-time 5 https://ip.sb || echo "YOUR_IP"
}

# ================== 安装与自定义配置 ==================
install_snell() {
    check_deps
    mkdir -p $SNELL_DIR
    cd $SNELL_DIR

    # 1. 自定义配置交互
    echo -e "\n${YELLOW}--- 自定义配置 (直接回车使用默认值) ---${RESET}"
    
    read -p "请输入监听端口 [默认随机]: " input_port
    PORT=${input_port:-$(shuf -i 10000-60000 -n 1)}
    
    read -p "请输入 PSK 密钥 [默认随机]: " input_psk
    PSK=${input_psk:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)}
    
    read -p "是否开启 IPv6? (true/false) [默认 false]: " input_ipv6
    IPV6=${input_ipv6:-false}

    read -p "请输入 DNS [默认 1.1.1.1,8.8.8.8]: " input_dns
    DNS=${input_dns:-"1.1.1.1,8.8.8.8"}

    # 2. 下载与脱壳
    ARCH=$(uname -m)
    [ "$ARCH" = "x86_64" ] && ARCH_LABEL="amd64"
    [ "$ARCH" = "aarch64" ] && ARCH_LABEL="aarch64"

    echo -e "${GREEN}\n[1/2] 下载并解压 Snell v5.0.1...${RESET}"
    curl -L --retry 3 -o snell.zip "https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-${ARCH_LABEL}.zip"
    unzip -o snell.zip && rm -f snell.zip

    echo -e "${YELLOW}[2/2] 执行 UPX 脱壳处理...${RESET}"
    chmod +x snell-server
    upx -d snell-server >/dev/null 2>&1 || true

    # 3. 写入配置
    cat > $SNELL_CONFIG <<EOF
[snell-server]
listen = 0.0.0.0:$PORT
psk = $PSK
ipv6 = $IPV6
tfo = true
dns = $DNS
EOF

    # 4. 创建服务
    cat > $SNELL_INIT <<EOF
#!/sbin/openrc-run
name="snell-server"
command="$SNELL_BIN"
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

    # 5. 完成输出
    IP=$(get_public_ip)
    echo -e "\n${GREEN}====================================${RESET}"
    echo -e "${GREEN}安装完成！${RESET}"
    echo -e "${YELLOW}端口: $PORT${RESET}"
    echo -e "${YELLOW}PSK:  $PSK${RESET}"
    echo -e "${YELLOW}Surge 配置行:${RESET}"
    echo -e "$(hostname) = snell, $IP, $PORT, psk=$PSK, version=5, tfo=true"
    echo -e "${GREEN}====================================${RESET}"
    
    sleep 2
    pgrep snell-server >/dev/null && echo -e "${GREEN}服务状态: 正在运行${RESET}" || echo -e "${RED}服务状态: 启动失败${RESET}"
}

# ================== 菜单系统 ==================
show_menu() {
    clear
    echo -e "${GREEN}====== Snell Alpine 管理 (支持自定义) ======${RESET}"
    echo "1. 安装 / 重装 (会提示自定义配置)"
    echo "2. 启动服务"
    echo "3. 停止服务"
    echo "4. 查看当前配置"
    echo "5. 卸载"
    echo "0. 退出"
}

while true; do
    show_menu
    read -p "选项: " choice
    case $choice in
        1) install_snell; read -p "按回车继续...";;
        2) rc-service snell start; read -p "按回车继续...";;
        3) rc-service snell stop; read -p "按回车继续...";;
        4) 
           [ -f "$SNELL_CONFIG" ] && { echo -e "${YELLOW}--- 当前配置 ---${RESET}"; cat "$SNELL_CONFIG"; } || echo "配置文件不存在"
           read -p "按回车继续...";;
        5) 
           rc-service snell stop || true
           rc-update del snell || true
           rm -rf $SNELL_DIR $SNELL_INIT
           echo "已卸载"; read -p "按回车继续...";;
        0) exit 0 ;;
    esac
done
