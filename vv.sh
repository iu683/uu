#!/bin/bash

# ================== 颜色 ==================
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }

# ================== 基础设置 ==================
HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')
export SECRET=${SECRET:-$(echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32)}
WORKDIR="$HOME/mtproto"
mkdir -p "$WORKDIR"

# 杀掉旧进程
pgrep -x mtg >/dev/null && pkill -9 mtg >/dev/null 2>&1

# ================== 获取公网 IP ==================
get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。" && exit 1
}

# ================== 获取端口 ==================
get_port() {
    read -rp "请输入 MTProto 代理端口(直接回车使用随机端口): " MTP_PORT
    if [[ -z "$MTP_PORT" ]]; then
        MTP_PORT=$(shuf -i 20000-60000 -n 1)
        green "使用随机端口: $MTP_PORT"
    fi
}

# ================== 下载 MTG ==================
download_mtg() {
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch="amd64";;
        386) arch="386";;
        arm) arch="arm";;
        aarch64) arch="arm64";;
        *) arch="amd64";;
    esac

    MTG_URL="https://github.com/whunt1/onekeymakemtg/raw/master/builds/ccbuilds/mtg-linux-$arch"
    wget -q -O "$WORKDIR/mtg" "$MTG_URL"
    if [[ ! -s "$WORKDIR/mtg" ]]; then
        red "MTG 下载失败，请检查 URL 或网络"
        exit 1
    fi
    chmod +x "$WORKDIR/mtg"
    green "MTG 下载完成"
}

# ================== 启动 MTProto ==================
start_mtg() {
    nohup "$WORKDIR/mtg" run -b 0.0.0.0:$MTP_PORT $SECRET --stats-bind=127.0.0.1:$MTP_PORT >/dev/null 2>&1 &
    sleep 1
    if ! ps -ef | grep -v grep | grep mtg >/dev/null; then
        red "MTG 启动失败，请检查端口或权限"
        exit 1
    fi
    green "MTProto 已启动，端口: $MTP_PORT"
}

# ================== 开放防火墙端口 ==================
open_firewall() {
    if command -v ufw >/dev/null 2>&1; then
        ufw allow $MTP_PORT/tcp
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport $MTP_PORT -j ACCEPT
    fi
}

# ================== 生成分享链接 ==================
show_link() {
    ip=$(get_public_ip)
    LINK="tg://proxy?server=$ip&port=$MTP_PORT&secret=$SECRET"
    purple "\nTG分享链接:\n$LINK\n"
    echo -e "$LINK" > "$WORKDIR/link.txt"

    # 生成重启脚本
    cat > "$WORKDIR/restart.sh" <<EOF
#!/bin/bash
pkill mtg
cd "$WORKDIR"
nohup ./mtg run -b 0.0.0.0:$MTP_PORT \$SECRET --stats-bind=127.0.0.1:$MTP_PORT >/dev/null 2>&1 &
EOF
    chmod +x "$WORKDIR/restart.sh"

    purple "\n一键卸载命令: rm -rf $WORKDIR && pkill mtg"
}

# ================== 安装 ==================
install_mtproto() {
    purple "正在安装 MTProto，请稍等..."
    get_port
    download_mtg
    open_firewall
    start_mtg
    show_link
}

# ================== 卸载 ==================
uninstall_mtproto() {
    pkill mtg
    rm -rf "$WORKDIR"
    green "MTProto 已卸载"
}

# ================== 菜单 ==================
while true; do
    echo -e "\n1. 安装 MTProto"
    echo -e "2. 卸载 MTProto"
    echo -e "0. 退出"
    read -rp "请选择: " choice
    case $choice in
        1) install_mtproto ;;
        2) uninstall_mtproto ;;
        0) exit 0 ;;
        *) yellow "无效选项" ;;
    esac
done
