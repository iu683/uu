#!/bin/sh

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW="\033[33m"
NC='\033[0m'

CONF_PATH="/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
LOG_PATH="/var/log/xray.log"
NODE_FILE="/etc/xray/node.txt"

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请以 root 身份运行此脚本${NC}"
    exit 1
fi

# 获取架构
ARCH=$(uname -m)
case ${ARCH} in
    x86_64)  X_ARCH="64" ;;
    aarch64) X_ARCH="arm64-v8a" ;;
    *) echo -e "${RED}不支持的架构: ${ARCH}${NC}"; exit 1 ;;
esac

# 清理函数
do_cleanup() {
    echo -e "${BLUE}正在清理旧环境...${NC}"
    [ -f /etc/init.d/xray ] && rc-service xray stop 2>/dev/null
    [ -f /etc/init.d/xray ] && rc-update del xray default 2>/dev/null
    rm -rf /etc/xray /usr/local/share/xray ${XRAY_BIN} ${LOG_PATH} /etc/init.d/xray
}

# 下载 Xray
download_xray() {
    echo -e "${BLUE}安装依赖...${NC}"
    apk update >/dev/null 2>&1
    apk add curl unzip openssl ca-certificates tar gcompat libc6-compat >/dev/null 2>&1

    echo -e "${BLUE}获取最新版本...${NC}"
    NEW_VER=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | head -n 1 | cut -d'"' -f4)
    [ -z "$NEW_VER" ] && NEW_VER="v24.12.31"

    echo -e "${GREEN}下载版本: ${NEW_VER}${NC}"
    curl -fL -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${NEW_VER}/Xray-linux-${X_ARCH}.zip" || {
        echo -e "${RED}Xray 下载失败${NC}"
        exit 1
    }

    mkdir -p /etc/xray /usr/local/share/xray /tmp/xray_tmp
    unzip -o /tmp/xray.zip -d /tmp/xray_tmp >/dev/null 2>&1 || {
        echo -e "${RED}解压失败${NC}"
        exit 1
    }

    mv -f /tmp/xray_tmp/xray ${XRAY_BIN}
    mv -f /tmp/xray_tmp/*.dat /usr/local/share/xray/ 2>/dev/null
    chmod +x ${XRAY_BIN}
    rm -rf /tmp/xray.zip /tmp/xray_tmp
}

# 更新
do_update() {
    if [ ! -f "${XRAY_BIN}" ]; then
        echo -e "${RED}未安装 Xray${NC}"
        exit 1
    fi
    echo -e "${BLUE}保留配置更新二进制文件...${NC}"
    rc-service xray stop 2>/dev/null
    download_xray
    rc-service xray start 2>/dev/null
    echo -e "${GREEN}更新成功！${NC}"
    exit 0
}

# 参数处理
if [ "$1" = "uninstall" ]; then
    do_cleanup
    echo -e "${GREEN}卸载完成${NC}"
    exit 0
fi

if [ "$1" = "update" ]; then
    do_update
fi

# 默认安装流程
do_cleanup
download_xray

# 用户输入
echo ""
read -p "请输入 Shadowsocks 端口 (默认随机 20000-65535): " PORT
if [ -z "$PORT" ]; then
    PORT=$((RANDOM%45535+20000))
    echo "使用随机端口: $PORT"
fi

case "$PORT" in
    ''|*[!0-9]*)
        echo -e "${RED}端口必须为数字${NC}"
        exit 1
        ;;
esac

if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo -e "${RED}端口范围必须在 1-65535${NC}"
    exit 1
fi

read -p "请输入加密方式 [默认: aes-256-gcm]: " METHOD
[ -z "$METHOD" ] && METHOD="aes-256-gcm"

case "$METHOD" in
    aes-128-gcm|aes-256-gcm|chacha20-poly1305|2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
        ;;
    *)
        echo -e "${RED}不支持的加密方式: ${METHOD}${NC}"
        exit 1
        ;;
esac

PASSWORD=$(openssl rand -base64 16 | tr -d '\n')

echo ""
echo -e "${GREEN}端口: ${PORT}${NC}"
echo -e "${GREEN}加密方式: ${METHOD}${NC}"
echo -e "${GREEN}密码: ${PASSWORD}${NC}"
echo ""

# 写配置
cat <<EOF > ${CONF_PATH}
{
  "log": {
    "access": "${LOG_PATH}",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "shadowsocks",
      "settings": {
        "method": "${METHOD}",
        "password": "${PASSWORD}",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

# 服务配置
cat << 'SERVICE' > /etc/init.d/xray
#!/sbin/openrc-run
description="Xray Shadowsocks"
command="/usr/local/bin/xray"
command_args="run -c /etc/xray/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
depend() { need net; after firewall; }
SERVICE

chmod +x /etc/init.d/xray
rc-update add xray default >/dev/null 2>&1
rc-service xray restart

sleep 2

PID=$(pidof xray)
IP4=$(curl -s4 ifconfig.me)
IP6=$(curl -s6 ifconfig.me)
HOSTNAME=$(hostname -s | sed 's/ /_/g')

# 生成 ss:// 链接
SS_BASE64=$(printf '%s' "${METHOD}:${PASSWORD}" | openssl base64 -A)
SS_LINK4=""
SS_LINK6=""

[ -n "$IP4" ] && SS_LINK4="ss://${SS_BASE64}@${IP4}:${PORT}#${HOSTNAME}"
[ -n "$IP6" ] && SS_LINK6="ss://${SS_BASE64}@[${IP6}]:${PORT}#${HOSTNAME}"

echo ""
echo -e "${GREEN}================ 安装完成 ===================${NC}"
[ -n "$PID" ] && echo -e "运行状态: ${GREEN}运行中 (PID: $PID)${NC}" || echo -e "运行状态: ${RED}启动失败${NC}"
echo -e "配置文件: ${BLUE}${CONF_PATH}${NC}"
echo "------------------------------------------------"

if [ -n "$IP4" ]; then
    echo -e "${BLUE}[IPv4 节点信息]${NC}"
    echo -e "${GREEN}服务器:${NC} ${IP4}"
    echo -e "${GREEN}端口:${NC} ${PORT}"
    echo -e "${GREEN}密码:${NC} ${PASSWORD}"
    echo -e "${GREEN}加密:${NC} ${METHOD}"
    echo -e "${YELLOW}${SS_LINK4}${NC}"
    echo ""
fi

if [ -n "$IP6" ]; then
    echo -e "${BLUE}[IPv6 节点信息]${NC}"
    echo -e "${GREEN}服务器:${NC} ${IP6}"
    echo -e "${GREEN}端口:${NC} ${PORT}"
    echo -e "${GREEN}密码:${NC} ${PASSWORD}"
    echo -e "${GREEN}加密:${NC} ${METHOD}"
    echo -e "${YELLOW}${SS_LINK6}${NC}"
    echo ""
fi

echo "------------------------------------------------"

cat > ${NODE_FILE} <<EOF
================ Shadowsocks 节点信息 ================

服务器: $(hostname)
端口: ${PORT}
加密方式: ${METHOD}
密码: ${PASSWORD}

---------------- IPv4 ----------------
服务器: ${IP4}
ss://${SS_BASE64}@${IP4}:${PORT}#${HOSTNAME}

---------------- IPv6 ----------------
服务器: ${IP6}
ss://${SS_BASE64}@[${IP6}]:${PORT}#${HOSTNAME}

=====================================================
EOF

echo -e "${GREEN}节点信息已保存: ${NODE_FILE}${NC}"
