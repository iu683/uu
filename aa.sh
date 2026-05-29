#!/bin/sh

# =========================================================
# Xray VLESS-Reality 综合管理面板 (支持 Alpine/Debian/Ubuntu)
# =========================================================

set -e

# ================== 颜色定义 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# ================== 基础变量 ==================
XRAY_CONFIG="/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
LOG_PATH="/var/log/xray.log"
INFO_DAT="/etc/xray/info.dat"

# ================== 1. 环境自适应检查 ==================
pre_check() {
    ARCH=$(uname -m)
    case ${ARCH} in
        x86_64)  X_ARCH="64" ;;
        aarch64) X_ARCH="arm64-v8a" ;;
        *) echo -e "${RED}不支持的架构: ${ARCH}${RESET}"; exit 1 ;;
    esac

    if command -v apk >/dev/null; then
        PM="apk"; INIT_SYS="openrc"
    elif command -v apt >/dev/null; then
        PM="apt"; INIT_SYS="systemd"
    else
        echo -e "${RED}暂不支持此系统的包管理器${RESET}"; exit 1
    fi
}

# ================== 2. 辅助功能 ==================
info() { echo -e "${BLUE}[信息] $*${RESET}"; }
success() { echo -e "${GREEN}[成功] $*${RESET}"; }
error() { echo -e "${RED}[错误] $*${RESET}"; }

get_xray_status() {
    if [ "$INIT_SYS" = "openrc" ]; then
        if rc-service xray status 2>/dev/null | grep -q "started"; then
            echo -e "${GREEN}● 运行中${RESET}"
        else
            echo -e "${RED}● 未运行${RESET}"
        fi
    else
        if systemctl is-active --quiet xray 2>/dev/null; then
            echo -e "${GREEN}● 运行中${RESET}"
        else
            echo -e "${RED}● 未运行${RESET}"
        fi
    fi
}

get_xray_version() {
    [ -x "$XRAY_BIN" ] && $XRAY_BIN version 2>/dev/null | head -n 1 | awk '{print $2}' || echo "未安装"
}

get_public_ip() {
    curl -s4 ifconfig.me || curl -s6 ifconfig.me || echo "未知"
}

# ================== 3. 服务与配置管理 ==================
manage_service() {
    local action=$1
    if [ "$INIT_SYS" = "openrc" ]; then
        case $action in
            "install")
                cat << 'SERVICE' > /etc/init.d/xray
#!/sbin/openrc-run
description="Xray Reality Service"
command="/usr/local/bin/xray"
command_args="run -c /etc/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"
depend() { need net; after firewall; }
SERVICE
                chmod +x /etc/init.d/xray
                rc-update add xray default
                rc-service xray restart ;;
            *) rc-service xray $action ;;
        esac
    else
        case $action in
            "install")
                cat << EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
After=network.target nss-lookup.target
[Service]
User=root
ExecStart=${XRAY_BIN} run -c ${XRAY_CONFIG}
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable xray
                systemctl restart xray ;;
            *) systemctl $action xray ;;
        esac
    fi
}

write_config() {
    local port=$1 uuid=$2 domain=$3 priv_key=$4 short_id=$5
    cat << EOF > ${XRAY_CONFIG}
{
    "log": { "access": "${LOG_PATH}", "loglevel": "warning" },
    "inbounds": [
        {
            "tag": "dokodemo-in",
            "port": 4431,
            "protocol": "dokodemo-door",
            "settings": { "address": "${domain}", "port": 443, "network": "tcp" },
            "sniffing": { "enabled": true, "destOverride": ["tls"], "routeOnly": true }
        },
        {
            "listen": "0.0.0.0",
            "port": ${port},
            "protocol": "vless",
            "settings": {
                "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "127.0.0.1:4431",
                    "serverNames": ["${domain}"],
                    "privateKey": "${priv_key}",
                    "shortIds": ["${short_id}"],
                    "fingerprint": "chrome"
                }
            },
            "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
        }
    ],
    "outbounds": [{ "protocol": "freedom", "tag": "direct" }],
    "routing": {
        "rules": [
            { "type": "field", "inboundTag": ["dokodemo-in"], "domain": ["${domain}"], "outboundTag": "direct" },
            { "type": "field", "inboundTag": ["dokodemo-in"], "outboundTag": "block" }
        ]
    }
}
EOF
}

# ================== 4. 功能逻辑 (安装/修改/Socks5/SNI) ==================
download_xray() {
    info "正在处理依赖..."
    if [ "$PM" = "apk" ]; then
        apk update && apk add curl unzip openssl ca-certificates uuidgen tar gcompat libc6-compat jq >/dev/null 2>&1
    else
        apt update && apt install -y curl unzip openssl ca-certificates uuid-runtime tar jq >/dev/null 2>&1
    fi
    NEW_VER=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | head -n 1 | cut -d'"' -f4)
    [ -z "$NEW_VER" ] && NEW_VER="v24.12.31"
    curl -L -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${NEW_VER}/Xray-linux-${X_ARCH}.zip"
    mkdir -p /etc/xray /usr/local/share/xray /tmp/xray_tmp
    unzip -o /tmp/xray.zip -d /tmp/xray_tmp
    mv -f /tmp/xray_tmp/xray ${XRAY_BIN}
    mv -f /tmp/xray_tmp/*.dat /usr/local/share/xray/
    chmod +x ${XRAY_BIN}
    rm -rf /tmp/xray.zip /tmp/xray_tmp
}

do_install() {
    download_xray
    read -p "端口 (回车随机): " PORT
    [ -z "$PORT" ] && PORT=$((RANDOM%45535+20000))
    read -p "域名 (默认: www.amazon.com): " DOMAIN
    [ -z "$DOMAIN" ] && DOMAIN="www.amazon.com"
    UUID=$($XRAY_BIN uuid)
    KEYS=$($XRAY_BIN x25519)
    PRIV=$(echo "$KEYS" | grep "Private" | awk '{print $NF}')
    PUB=$(echo "$KEYS" | grep -E "Public|Password" | awk '{print $NF}')
    SID=$(openssl rand -hex 4)
    write_config "$PORT" "$UUID" "$DOMAIN" "$PRIV" "$SID"
    echo "PUB=$PUB" > $INFO_DAT
    manage_service "install"
    success "安装成功！"
    show_node
}

modify_config() {
    [ ! -f "$XRAY_CONFIG" ] && { error "未安装！"; return; }
    local curr_port=$(jq -r '.inbounds[1].port' $XRAY_CONFIG)
    local curr_uuid=$(jq -r '.inbounds[1].settings.clients[0].id' $XRAY_CONFIG)
    local curr_domain=$(jq -r '.inbounds[1].streamSettings.realitySettings.serverNames[0]' $XRAY_CONFIG)
    local curr_priv=$(jq -r '.inbounds[1].streamSettings.realitySettings.privateKey' $XRAY_CONFIG)
    local curr_sid=$(jq -r '.inbounds[1].streamSettings.realitySettings.shortIds[0]' $XRAY_CONFIG)

    echo -e "\n${CYAN}--- 修改配置 (回车保持现状) ---${RESET}"
    read -p "端口 [$curr_port]: " n_port; n_port=${n_port:-$curr_port}
    read -p "UUID [$curr_uuid]: " n_uuid; n_uuid=${n_uuid:-$curr_uuid}
    read -p "域名 [$curr_domain]: " n_domain; n_domain=${n_domain:-$curr_domain}

    write_config "$n_port" "$n_uuid" "$n_domain" "$curr_priv" "$curr_sid"
    manage_service "restart" && success "修改成功"
}

configure_socks5_outbound() {
    [ ! -f "$XRAY_CONFIG" ] && return
    echo -e "\n1) 开启Socks5出口  2) 恢复直连"
    read -p "选择: " s_choice
    if [ "$s_choice" = "1" ]; then
        read -p "地址: " s_addr; read -p "端口: " s_port
        read -p "用户名: " s_user; [ -n "$s_user" ] && read -p "密码: " s_pass
        if [ -n "$s_user" ]; then
            out=$(jq -n --arg a "$s_addr" --arg p "$s_port" --arg u "$s_user" --arg s "$s_pass" '[{"protocol":"socks","settings":{"servers":[{"address":$a,"port":($p|tonumber),"users":[{"user":$u,"pass":$s}]}]},"tag":"proxy"}]')
        else
            out=$(jq -n --arg a "$s_addr" --arg p "$s_port" '[{"protocol":"socks","settings":{"servers":[{"address":$a,"port":($p|tonumber)}]},"tag":"proxy"}]')
        fi
        tmp=$(mktemp); jq --argjson o "$out" '.outbounds = $o' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
        manage_service "restart" && success "已启用Socks5"
    elif [ "$s_choice" = "2" ]; then
        tmp=$(mktemp); jq '.outbounds = [{"protocol":"freedom","tag":"direct"}]' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
        manage_service "restart" && success "恢复直连"
    fi
}

select_sni() {
    info "正在进行 SNI 延迟测试..."
    local SNI_LIST="www.amazon.com www.apple.com www.microsoft.com www.cloudflare.com www.cisco.com"
    for s in $SNI_LIST; do
        start=$(date +%s%N)
        if curl -Is --connect-timeout 2 "https://$s" >/dev/null 2>&1; then
            end=$(date +%s%N); diff=$(( (end - start) / 1000000 ))
            echo -e "${GREEN}$s -> ${diff}ms${RESET}"
        else
            echo -e "${RED}$s -> 连接失败${RESET}"
        fi
    done
}

show_node() {
    [ ! -f "$XRAY_CONFIG" ] && return
    local PORT=$(jq -r '.inbounds[1].port' $XRAY_CONFIG)
    local UUID=$(jq -r '.inbounds[1].settings.clients[0].id' $XRAY_CONFIG)
    local DOMAIN=$(jq -r '.inbounds[1].streamSettings.realitySettings.serverNames[0]' $XRAY_CONFIG)
    local SID=$(jq -r '.inbounds[1].streamSettings.realitySettings.shortIds[0]' $XRAY_CONFIG)
    local PUB=$(cat $INFO_DAT | cut -d'=' -f2)
    local IP=$(get_public_ip)
    echo -e "\n${GREEN}====== Reality 节点链接 ======${RESET}"
    echo -e "${YELLOW}vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#Reality_Node${RESET}\n"
}

# ================== 5. 主循环菜单 ==================
main_menu() {
    while true; do
        clear
        status=$(get_xray_status)
        version=$(get_xray_version)
        [ -f "$XRAY_CONFIG" ] && port_show=$(jq -r '.inbounds[1].port' $XRAY_CONFIG) || port_show="-"

        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}   Xray Vless+Reality 管理面板   ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}状态   :${RESET} $status"
        echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
        echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e " 1. 安装 Xray Vless+Reality"
        echo -e " 2. 更新 Xray"
        echo -e " 3. 卸载 Xray"
        echo -e " 4. 修改配置"
        echo -e " 5. 启动 Xray"
        echo -e " 6. 停止 Xray"
        echo -e " 7. 重启 Xray"
        echo -e " 8. 查看日志"
        echo -e " 9. 查看节点配置"
        echo -e "10. 配置Socks5出口"
        echo -e "11. SNI域名优选 ✨"
        echo -e " 0. 退出"
        echo -e "${GREEN}================================${RESET}"
        read -p "请输入选项: " choice

        case $choice in
            1) do_install ;;
            2) download_xray && manage_service "restart" && success "已更新" ;;
            3) manage_service "stop"; rm -rf /etc/xray /usr/local/bin/xray /etc/init.d/xray /etc/systemd/system/xray.service; success "已卸载" ;;
            4) modify_config ;;
            5) manage_service "start" ;;
            6) manage_service "stop" ;;
            7) manage_service "restart" ;;
            8) tail -n 50 $LOG_PATH ;;
            9) show_node ;;
            10) configure_socks5_outbound ;;
            11) select_sni ;;
            0) exit 0 ;;
            *) error "无效输入" ;;
        esac
        read -p "按回车返回菜单..." temp
    done
}

pre_check
main_menu
