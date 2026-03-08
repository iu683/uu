#!/bin/bash
# ========================================
# Hysteria 一键管理脚本（Host Docker + 自签证书 + 端口跳跃 + 必应伪装）
# 优化版：防重复规则 + 默认回车启用跳跃
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="hysteria"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/hysteria.yaml"
CONTAINER_NAME="hysteria"
NODE_INFO_FILE="$APP_DIR/node.txt"

JUMP_START=""
JUMP_END=""
PORT=""
MASQ_URL="https://bing.com"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi
    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2，请升级 Docker${RESET}"
        exit 1
    fi
}

check_port() {
    if ss -tuln | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

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
    echo "无法获取公网 IP 地址。" && return
}

generate_cert() {
    mkdir -p "$APP_DIR/cert"
    CERT_FILE="$APP_DIR/cert/server.crt"
    KEY_FILE="$APP_DIR/cert/server.key"
    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        echo -e "${YELLOW}正在生成自签证书...${RESET}"
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "$KEY_FILE" \
            -out "$CERT_FILE" \
            -subj "/CN=bing.com" \
            -days 36500
    fi
}

add_port_jump_rules() {

    if [[ -z "$JUMP_START" || -z "$JUMP_END" ]]; then
        return
    fi

    echo -e "${YELLOW}添加端口跳跃规则: $JUMP_START-$JUMP_END -> $PORT${RESET}"

    # 获取本机主IP（不依赖外网）
    SERVER_IP=$(hostname -I | awk '{print $1}')

    if [[ -z "$SERVER_IP" ]]; then
        echo -e "${RED}无法获取服务器IP，跳跃规则添加失败${RESET}"
        return
    fi

    echo -e "${GREEN}服务器IP: $SERVER_IP${RESET}"

    # 关闭 rp_filter（否则部分机器不转发）
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1

    # 删除旧规则（防止重复）
    while iptables -t nat -C PREROUTING -p udp \
        --dport $JUMP_START:$JUMP_END \
        -j DNAT --to-destination ${SERVER_IP}:$PORT 2>/dev/null
    do
        iptables -t nat -D PREROUTING -p udp \
            --dport $JUMP_START:$JUMP_END \
            -j DNAT --to-destination ${SERVER_IP}:$PORT
    done

    # 添加新规则（插入到最前面，避免被抢）
    iptables -t nat -I PREROUTING 1 -p udp \
        --dport $JUMP_START:$JUMP_END \
        -j DNAT --to-destination ${SERVER_IP}:$PORT

    # 放行 FORWARD（部分系统必须）
    iptables -C FORWARD -p udp --dport $PORT -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -p udp --dport $PORT -j ACCEPT

    echo -e "${GREEN}✅ 端口跳跃规则添加完成${RESET}"
}
remove_port_jump_rules() {

    if [[ -z "$JUMP_START" || -z "$JUMP_END" ]]; then
        return
    fi

    echo -e "${YELLOW}清理端口跳跃规则: $JUMP_START-$JUMP_END -> $PORT${RESET}"

    SERVER_IP=$(hostname -I | awk '{print $1}')

    while iptables -t nat -C PREROUTING -p udp \
        --dport $JUMP_START:$JUMP_END \
        -j DNAT --to-destination ${SERVER_IP}:$PORT 2>/dev/null
    do
        iptables -t nat -D PREROUTING -p udp \
            --dport $JUMP_START:$JUMP_END \
            -j DNAT --to-destination ${SERVER_IP}:$PORT
    done

    echo -e "${GREEN}✅ 跳跃规则已清理${RESET}"
}

install_app() {
    check_docker
    mkdir -p "$APP_DIR"

    read -p "请输入监听端口 [1025-65535, 默认随机]: " input_port
    if [[ -z "$input_port" ]]; then
        PORT=$(shuf -i 1025-65535 -n1)
    else
        PORT=$input_port
    fi
    check_port "$PORT" || return

    read -p "请输入密码（留空将自动生成16位随机密码）: " PASSWORD
    PASSWORD=${PASSWORD:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c16)}

    read -p "是否启用端口跳跃 [Y/n,回车默认Y]: " enable_jump
    enable_jump=$(echo "$enable_jump" | tr -d ' ')
    enable_jump=${enable_jump:-Y}

    case "$enable_jump" in
        Y|y)
            while true; do
                read -p "请输入端口范围起始端口 (10000-65535): " firstport
                read -p "请输入端口范围末尾端口: " endport

                if ! [[ "$firstport" =~ ^[0-9]+$ && "$endport" =~ ^[0-9]+$ ]]; then
                    echo "端口必须为数字"
                    continue
                fi

                if (( firstport < 10000 || firstport > 65535 || endport < 10000 || endport > 65535 )); then
                    echo "端口必须在 10000-65535"
                    continue
                fi

                if (( firstport >= endport )); then
                    echo "起始端口必须小于结束端口"
                    continue
                fi

                if (( PORT >= firstport && PORT <= endport )); then
                    echo "跳跃范围不能包含监听端口 $PORT"
                    continue
                fi

                JUMP_START=$firstport
                JUMP_END=$endport
                break
            done
            ;;
        N|n)
            echo "已关闭端口跳跃"
            ;;
        *)
            echo "输入无效，默认启用"
            ;;
    esac

    generate_cert
    add_port_jump_rules

    cat > "$CONFIG_FILE" <<EOF
listen: :$PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: $MASQ_URL
    rewriteHost: true
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  hysteria:
    image: tobyxdd/hysteria
    container_name: $CONTAINER_NAME
    restart: always
    network_mode: host
    volumes:
      - $APP_DIR/hysteria.yaml:/etc/hysteria.yaml
      - $APP_DIR/cert/server.crt:/etc/hysteria/server.crt
      - $APP_DIR/cert/server.key:/etc/hysteria/server.key
    command: ["server", "-c", "/etc/hysteria.yaml"]
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    IP=$(get_public_ip)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    echo -e "${GREEN}✅ Hysteria2 已启动${RESET}"
    echo -e "${YELLOW}🌐 服务端监听端口: ${PORT}${RESET}"
    echo -e "${YELLOW}🔑 密码: ${PASSWORD}${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    if [[ -n "$JUMP_START" ]]; then
        echo -e "${YELLOW}🟢 端口跳跃: $JUMP_START-$JUMP_END -> $PORT${RESET}"
    else
        echo -e "${YELLOW}🟢 端口跳跃: 未启用${RESET}"
    fi
    echo -e "${YELLOW}🟢 伪装网址: $MASQ_URL${RESET}"
    echo -e "${GREEN}📄 V6VPS替换IP地址为V6 ★${RESET}"
    echo -e "${GREEN}📄 端口跳跃只适配V4 ★${RESET}"
    echo -e "${GREEN}📄 客户端配置模板:${RESET}"
    echo -e "${YELLOW}V2rayN:${RESET}"
    echo -e "${YELLOW} hysteria2://$PASSWORD@$IP:$PORT/?sni=bing.com&insecure=1#$HOSTNAME${RESET}"
    echo -e "${YELLOW}Surge:${RESET}"
    echo -e "${YELLOW}$HOSTNAME = hysteria2, $IP, $PORT, password=$PASSWORD, skip-cert-verify=true, sni=www.bing.com${RESET}"
    cat > "$NODE_INFO_FILE" <<EOF
V2rayN
hysteria2://$PASSWORD@$IP:$PORT/?sni=bing.com&insecure=1#$HOSTNAME
Surge
$HOSTNAME = hysteria2, $IP, $PORT, password=$PASSWORD, skip-cert-verify=true, sni=www.bing.com
EOF
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Hysteria2 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart $CONTAINER_NAME
    echo -e "${GREEN}✅ Hysteria2 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f $CONTAINER_NAME
}

check_status() {
    docker ps | grep $CONTAINER_NAME
    read -p "按回车返回菜单..."
}

view_node_info() {

    if [ ! -f "$NODE_INFO_FILE" ]; then
        echo -e "${RED}未找到节点信息${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    echo
    echo -e "${GREEN}=== TUIC 节点信息 ===${RESET}"
    echo
    cat "$NODE_INFO_FILE"
    echo
    read -p "按回车返回菜单..."
}

uninstall_app() {
    remove_port_jump_rules

    docker stop $CONTAINER_NAME 2>/dev/null
    docker rm $CONTAINER_NAME 2>/dev/null
    rm -rf "$APP_DIR"

    echo -e "${RED}✅ Hysteria2 已卸载${RESET}"

    exit 0
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Hysteria2 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 查看节点信息${RESET}"
        echo -e "${GREEN}7) 卸载${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) view_node_info ;;
            7) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

menu
