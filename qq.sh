#!/bin/bash

# ===== 颜色输出 =====
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }

# ===== 基本信息 =====
HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')
export SECRET=${SECRET:-$(echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32)}
WORKDIR="$HOME/mtp"
mkdir -p "$WORKDIR"

# 停掉旧进程
pgrep -x mtg > /dev/null && pkill -9 mtg >/dev/null 2>&1

# ===== 获取公网 IPv4 =====
get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IPv4 地址。"
}

# ===== 检查端口 =====
check_port() {
    local port_list tcp_ports udp_ports tcp_port1
    port_list=$(devil port list 2>/dev/null)
    tcp_ports=$(echo "$port_list" | grep -c "tcp")
    udp_ports=$(echo "$port_list" | grep -c "udp")

    if [[ $tcp_ports -lt 1 ]]; then
        red "没有可用的TCP端口,正在调整..."
        if [[ $udp_ports -ge 3 ]]; then
            udp_port_to_delete=$(echo "$port_list" | awk '/udp/ {print $1}' | head -n 1)
            devil port del udp $udp_port_to_delete
            green "已删除udp端口: $udp_port_to_delete"
        fi

        while true; do
            tcp_port=$(shuf -i 10000-65535 -n 1)
            result=$(devil port add tcp $tcp_port 2>&1)
            if [[ $result == *"Ok"* ]]; then
                green "已添加TCP端口: $tcp_port"
                tcp_port1=$tcp_port
                break
            else
                yellow "端口 $tcp_port 不可用，尝试其他端口..."
            fi
        done
    else
        tcp_ports=$(echo "$port_list" | awk '/tcp/ {print $1}')
        tcp_port1=$(echo "$tcp_ports" | sed -n '1p')
    fi

    devil binexec on >/dev/null 2>&1
    MTP_PORT=$tcp_port1
    green "使用 $MTP_PORT 作为TG代理端口"
}

# ===== 获取可用 IP =====
get_ip() {
    IP_LIST=($(devil vhost list 2>/dev/null | awk '/^[0-9]+/ {print $1}'))
    if [[ ${#IP_LIST[@]} -ge 1 ]]; then
        IP1=${IP_LIST[0]}
        IP2=${IP_LIST[1]:-}
        IP3=${IP_LIST[2]:-}
    else
        red "没有可用的 IP，请检查 devil vhost"
        exit 1
    fi
}

# ===== 下载 MTG 可执行文件 =====
download_mtg() {
    local arch cmd
    cmd=$(uname -m)
    case "$cmd" in
        x86_64|amd64) arch="amd64" ;;
        386) arch="386" ;;
        arm) arch="arm" ;;
        aarch64) arch="arm64" ;;
        *) arch="amd64" ;;
    esac

    wget -q -O "${WORKDIR}/mtg" "https://github.com/whunt1/onekeymakemtg/raw/master/builds/ccbuilds/mtg-linux-$arch"
    chmod +x "${WORKDIR}/mtg"

    export PORT=${PORT:-$(shuf -i 2000-10000 -n 1)}
    export MTP_PORT=$((PORT + 1))
}

# ===== 生成 systemd 服务 =====
create_service() {
cat <<"EOF" >/etc/systemd/system/mtg.service
[Unit]
Description=MTProto Proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=__WORKDIR__
Environment=PORT=__PORT__
Environment=MTP_PORT=__MTP_PORT__
Environment=SECRET=__SECRET__
ExecStart=__WORKDIR__/mtg run -b 0.0.0.0:$PORT $SECRET --stats-bind=127.0.0.1:$MTP_PORT
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

sed -i "s|__WORKDIR__|$WORKDIR|g; s|__PORT__|$PORT|g; s|__MTP_PORT__|$MTP_PORT|g; s|__SECRET__|$SECRET|g" /etc/systemd/system/mtg.service
}

# ===== 生成分享链接 =====
generate_info() {
    purple "\n分享链接:\n"
    LINKS=""
    [[ -n "$IP1" ]] && LINKS+="tg://proxy?server=$IP1&port=$MTP_PORT&secret=$SECRET"
    [[ -n "$IP2" ]] && LINKS+="\n\ntg://proxy?server=$IP2&port=$MTP_PORT&secret=$SECRET"
    [[ -n "$IP3" ]] && LINKS+="\n\ntg://proxy?server=$IP3&port=$MTP_PORT&secret=$SECRET"

    green "$LINKS\n"
    echo -e "$LINKS" > "$WORKDIR/link.txt"

    cat > "${WORKDIR}/restart.sh" <<EOF
#!/bin/bash
pkill mtg
cd $WORKDIR
systemctl restart mtg
EOF
    chmod +x "${WORKDIR}/restart.sh"
}

# ===== 显示公网分享链接 =====
show_link() {
    local ip
    ip=$(get_public_ip)
    purple "\nTG分享链接:\n"
    LINKS="tg://proxy?server=$ip&port=$PORT&secret=$SECRET"
    green "$LINKS\n"
    echo -e "$LINKS" > "$WORKDIR/link.txt"
}

# ===== 卸载 =====
uninstall() {
    systemctl stop mtg 2>/dev/null
    systemctl disable mtg 2>/dev/null
    rm -f /etc/systemd/system/mtg.service
    systemctl daemon-reload
    pkill -9 mtg 2>/dev/null
    rm -rf "$WORKDIR"
    green "MTProto 已卸载"
}

# ===== 安装 =====
install() {
    purple "正在安装..."
    check_port
    get_ip
    download_mtg
    create_service
    systemctl daemon-reload
    systemctl enable mtg
    systemctl start mtg
    generate_info
    show_link
    green "安装完成，MTProto 已自启动"
}

# ===== 执行安装 =====
install
