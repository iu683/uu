#!/bin/bash

red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }

HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')
export SECRET=${SECRET:-$(echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32)}
WORKDIR="$HOME/mtp" && mkdir -p "$WORKDIR"
pgrep -x mtg > /dev/null && pkill -9 mtg >/dev/null 2>&1

# ==================== 获取公网 IP ====================
get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。"
}

# ==================== 检查/添加 TCP 端口 ====================
check_port () {
  port_list=$(devil port list)
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

# ==================== 获取 Devil Vhost IP ====================
get_ip() {
    IP_LIST=($(devil vhost list | awk '/^[0-9]+/ {print $1}'))
    if [[ ${#IP_LIST[@]} -ge 1 ]]; then
        IP1=${IP_LIST[0]}
        IP2=${IP_LIST[1]:-}
        IP3=${IP_LIST[2]:-}
    else
        red "没有可用的 IP，请检查 devil vhost"
        exit 1
    fi
}

# ==================== 下载并运行 mtg ====================
download_run(){
    if [ -e "${WORKDIR}/mtg" ]; then
        cd ${WORKDIR} && chmod +x mtg
        nohup ./mtg run -b 0.0.0.0:$MTP_PORT $SECRET --stats-bind=127.0.0.1:$MTP_PORT >/dev/null 2>&1 &
    else
        mtg_url=""
        wget -q -O "${WORKDIR}/mtg" "$mtg_url"

        if [ -e "${WORKDIR}/mtg" ]; then
            cd ${WORKDIR} && chmod +x mtg
            nohup ./mtg run -b 0.0.0.0:$MTP_PORT $SECRET --stats-bind=127.0.0.1:$MTP_PORT >/dev/null 2>&1 &
        fi        
    fi
}

# ==================== 生成 TG 分享链接 ====================
generate_info() {
    purple "\n分享链接:\n"
    LINKS=""
    [[ -n "$IP1" ]] && LINKS+="tg://proxy?server=$IP1&port=$MTP_PORT&secret=$SECRET"
    [[ -n "$IP2" ]] && LINKS+="\n\ntg://proxy?server=$IP2&port=$MTP_PORT&secret=$SECRET"
    [[ -n "$IP3" ]] && LINKS+="\n\ntg://proxy?server=$IP3&port=$MTP_PORT&secret=$SECRET"

    green "$LINKS\n"
    echo -e "$LINKS" > $WORKDIR/link.txt

    cat > ${WORKDIR}/restart.sh <<EOF
#!/bin/bash
pkill mtg
cd ${WORKDIR}
nohup ./mtg run -b 0.0.0.0:$MTP_PORT $SECRET --stats-bind=127.0.0.1:$MTP_PORT >/dev/null 2>&1 &
EOF
}

# ==================== Systemd ====================
setup_systemd() {
    SERVICE_FILE="/etc/systemd/system/mtp.service"

    sudo tee $SERVICE_FILE > /dev/null <<EOF
[Unit]
Description=MTProto Proxy Service
After=network.target

[Service]
Type=simple
User=$USERNAME
WorkingDirectory=$WORKDIR
EnvironmentFile=$WORKDIR/env.conf
ExecStart=$WORKDIR/mtg run -b 0.0.0.0:$MTP_PORT $SECRET --stats-bind=127.0.0.1:$MTP_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable mtp.service
    sudo systemctl start mtp.service
    green "✅ systemd 服务已创建并启动，MTProto 将开机自启"
}

# ==================== 安装主流程 ====================
install(){
    read -rp "请输入自定义端口（留空使用默认随机端口）: " CUSTOM_PORT

    purple "正在安装...\n"

    if [[ "$HOSTNAME" =~ mtp ]]; then
        if [[ -n "$CUSTOM_PORT" ]]; then
            MTP_PORT=$CUSTOM_PORT
            green "使用自定义端口: $MTP_PORT"
        else
            check_port
        fi

        get_ip
        download_run
        generate_info

        # 创建环境文件
        ENV_FILE="$WORKDIR/env.conf"
        cat > "$ENV_FILE" <<EOF
MTP_PORT=$MTP_PORT
SECRET=$SECRET
EOF
        green "✅ 环境文件已生成: $ENV_FILE"
    else
        if [[ -n "$CUSTOM_PORT" ]]; then
            PORT=$CUSTOM_PORT
            MTP_PORT=$(($PORT + 1))
            green "使用自定义端口: $PORT (MTP_PORT=$MTP_PORT)"
            download_mtg
        else
            download_mtg
        fi
    fi

    # 自动创建 systemd 服务
    setup_systemd
}

install
