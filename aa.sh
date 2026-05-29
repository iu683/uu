#!/bin/sh

# =========================================================
# Xray VLESS-Reality 管理面板 (Alpine 专用 - 双栈/防刷/优选)
# =========================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW="\033[33m"
NC='\033[0m'

# 路径定义
CONF_PATH="/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
LOG_PATH="/var/log/xray.log"
NODE_FILE="/etc/xray/node.txt"

# 获取架构
ARCH=$(uname -m)
case ${ARCH} in
    x86_64)  X_ARCH="64" ;;
    aarch64) X_ARCH="arm64-v8a" ;;
    *) echo "不支持的架构"; exit 1 ;;
esac

# 1. 环境清理
do_cleanup() {
    echo -e "${BLUE}正在清理旧环境...${NC}"
    [ -f /etc/init.d/xray ] && rc-service xray stop 2>/dev/null && rc-update del xray default 2>/dev/null
    rm -rf /etc/xray /usr/local/share/xray ${XRAY_BIN} ${LOG_PATH} /etc/init.d/xray
}

# 2. 安装依赖并下载内核
download_xray() {
    echo -e "${BLUE}安装依赖 (含 Alpine 兼容库)...${NC}"
    apk update && apk add curl unzip openssl ca-certificates uuidgen tar gcompat libc6-compat jq > /dev/null 2>&1

    echo -e "${BLUE}获取最新版本...${NC}"
    NEW_VER=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | head -n 1 | cut -d'"' -f4)
    [ -z "$NEW_VER" ] && NEW_VER="v24.12.31"
    
    echo -e "${GREEN}下载版本: ${NEW_VER}${NC}"
    curl -L -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${NEW_VER}/Xray-linux-${X_ARCH}.zip"
    
    mkdir -p /etc/xray /usr/local/share/xray /tmp/xray_tmp
    unzip -o /tmp/xray.zip -d /tmp/xray_tmp
    mv -f /tmp/xray_tmp/xray ${XRAY_BIN}
    mv -f /tmp/xray_tmp/*.dat /usr/local/share/xray/
    chmod +x ${XRAY_BIN}
    rm -rf /tmp/xray.zip /tmp/xray_tmp
}

# 3. 核心安装逻辑
do_install() {
    do_cleanup
    download_xray

    echo ""
    read -p "请输入 Reality 端口 (直接回车随机): " PORT
    [ -z "$PORT" ] && PORT=$((RANDOM%45535+20000))
    read -p "请输入伪装域名 (默认: www.amazon.com): " DEST_DOMAIN
    [ -z "$DEST_DOMAIN" ] && DEST_DOMAIN="www.amazon.com"

    echo -e "${BLUE}生成密钥对与配置...${NC}"
    X_KEYS_ALL=$(${XRAY_BIN} x25519 2>/dev/null)
    UUID=$(${XRAY_BIN} uuid 2>/dev/null)
    PRIVATE_KEY=$(echo "${X_KEYS_ALL}" | grep "PrivateKey" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "${X_KEYS_ALL}" | grep -E "Password|Public" | head -n 1 | awk '{print $NF}')
    SHORT_ID=$(openssl rand -hex 4)

    # 写入带防刷逻辑的配置
    cat << CONF > ${CONF_PATH}
{
    "log": { "access": "${LOG_PATH}", "loglevel": "warning" },
    "inbounds": [
        {
            "tag": "dokodemo-in",
            "port": 4431,
            "protocol": "dokodemo-door",
            "settings": { "address": "${DEST_DOMAIN}", "port": 443, "network": "tcp" },
            "sniffing": { "enabled": true, "destOverride": ["tls"], "routeOnly": true }
        },
        {
            "listen": "0.0.0.0",
            "port": ${PORT},
            "protocol": "vless",
            "settings": {
                "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision" }],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "127.0.0.1:4431",
                    "serverNames": ["${DEST_DOMAIN}"],
                    "privateKey": "${PRIVATE_KEY}",
                    "shortIds": ["${SHORT_ID}"],
                    "fingerprint": "chrome"
                }
            },
            "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
        }
    ],
    "outbounds": [
        { "protocol": "freedom", "settings": { "domainStrategy": "UseIP" }, "tag": "direct" },
        { "protocol": "blackhole", "tag": "block" }
    ],
    "routing": {
        "rules": [
            { "type": "field", "inboundTag": ["dokodemo-in"], "domain": ["${DEST_DOMAIN}"], "outboundTag": "direct" },
            { "type": "field", "inboundTag": ["dokodemo-in"], "outboundTag": "block" }
        ]
    }
}
CONF

    # 写入 OpenRC 服务
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
    rc-service xray restart

    # 保存节点信息供查看
    save_node_info "$PORT" "$DEST_DOMAIN" "$UUID" "$PUBLIC_KEY" "$SHORT_ID"
    success_msg
}

# 4. 保存与展示节点信息
save_node_info() {
    local PORT=$1 DEST_DOMAIN=$2 UUID=$3 PUBLIC_KEY=$4 SHORT_ID=$5
    local IP4=$(curl -s4 ifconfig.me || echo "")
    local IP6=$(curl -s6 ifconfig.me || echo "")
    local HOSTNAME=$(hostname -s | sed 's/ /_/g')

    cat > ${NODE_FILE} <<EOF
================ Xray Reality 节点信息 ================
UUID: ${UUID}
PublicKey: ${PUBLIC_KEY}
ShortID: ${SHORT_ID}
端口: ${PORT}
域名: ${DEST_DOMAIN}

--- IPv4 节点 ---
vless://${UUID}@${IP4}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${HOSTNAME}_v4

--- IPv6 节点 ---
vless://${UUID}@[${IP6}]:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${HOSTNAME}_v6
=======================================================
EOF
}

success_msg() {
    echo -e "${GREEN}================ 安装完成 ===================${NC}"
    rc-service xray status
    echo -e "节点信息已保存在: ${NODE_FILE}"
    echo "------------------------------------------------"
    cat ${NODE_FILE}
}

# 5. 高级功能 (Socks5/SNI)
configure_socks5() {
    [ ! -f "$CONF_PATH" ] && echo "未安装" && return
    read -p "请输入 Socks5 地址: " S_ADDR
    read -p "请输入 Socks5 端口: " S_PORT
    # 使用 jq 修改出口协议
    tmp=$(mktemp)
    jq --arg a "$S_ADDR" --arg p "$S_PORT" '.outbounds[0] = {"protocol":"socks","settings":{"servers":[{"address":$a,"port":($p|tonumber)}]},"tag":"proxy"}' $CONF_PATH > $tmp && mv $tmp $CONF_PATH
    rc-service xray restart
    echo -e "${GREEN}Socks5 出口配置成功！${NC}"
}

select_sni() {
    echo -e "${BLUE}正在测试 SNI 延迟...${NC}"
    for s in www.amazon.com www.microsoft.com www.apple.com www.cloudflare.com; do
        start=$(date +%s%N)
        curl -Is --connect-timeout 2 https://$s >/dev/null 2>&1 && {
            end=$(date +%s%N); echo -e "$s -> $(( (end - start) / 1000000 ))ms"
        } || echo -e "$s -> 失败"
    done
}

# ================== 管理面板界面 ==================
main_menu() {
    clear
    status=$(rc-service xray status 2>/dev/null | grep -q "started" && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}未运行${NC}")
    version=$($XRAY_BIN version 2>/dev/null | head -n 1 | awk '{print $2}')
    port=$(jq -r '.inbounds[1].port' $CONF_PATH 2>/dev/null || echo "-")

    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}   Xray Vless+Reality 管理面板   ${NC}"
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}状态   :${NC} $status"
    echo -e "${GREEN}版本   :${NC} ${YELLOW}${version:-未安装}${NC}"
    echo -e "${GREEN}端口   :${NC} ${YELLOW}${port}${NC}"
    echo -e "${GREEN}================================${NC}"
    echo -e " 1. 安装 Xray Vless+Reality"
    echo -e " 2. 更新 Xray 内核"
    echo -e " 3. 卸载 Xray"
    echo -e " 4. 修改配置 (端口/域名)"
    echo -e " 5. 启动 Xray"
    echo -e " 6. 停止 Xray"
    echo -e " 7. 重启 Xray"
    echo -e " 8. 查看日志"
    echo -e " 9. 查看节点配置"
    echo -e "10. 配置Socks5出口"
    echo -e "11. SNI域名优选✨"
    echo -e " 0. 退出"
    echo -e "${GREEN}================================${NC}"
    read -p "请输入选项: " choice

    case $choice in
        1) do_install ;;
        2) download_xray && rc-service xray restart && echo "更新完成" ;;
        3) do_cleanup ;;
        4) do_install ;; # 重新安装即可覆盖配置
        5) rc-service xray start ;;
        6) rc-service xray stop ;;
        7) rc-service xray restart ;;
        8) tail -n 50 $LOG_PATH ;;
        9) cat ${NODE_FILE} ;;
        10) configure_socks5 ;;
        11) select_sni ;;
        0) exit 0 ;;
    esac
    read -p "按回车返回..." temp
    main_menu
}

main_menu
