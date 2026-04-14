#!/bin/sh

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m'

SS_BIN="/usr/local/bin/ssserver"
STLS_BIN="/usr/local/bin/shadow-tls"

SS_CONF_DIR="/etc/shadowsocks-rust"
SS_CONF_FILE="${SS_CONF_DIR}/config.json"
SS_NODE_FILE="${SS_CONF_DIR}/node.txt"

SS_INIT="/etc/init.d/shadowsocks-rust"
STLS_INIT="/etc/init.d/shadowtls"

LOG_DIR="/var/log"
SS_LOG="${LOG_DIR}/shadowsocks-rust.log"
STLS_LOG="${LOG_DIR}/shadowtls.log"

# root 检查
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行此脚本${NC}"
    exit 1
fi

# 架构检测
ARCH=$(uname -m)
case "${ARCH}" in
    x86_64)
        SSR_ARCH="x86_64-unknown-linux-musl"
        STLS_ARCH="x86_64-unknown-linux-musl"
        ;;
    aarch64)
        SSR_ARCH="aarch64-unknown-linux-musl"
        STLS_ARCH="aarch64-unknown-linux-musl"
        ;;
    *)
        echo -e "${RED}不支持的架构: ${ARCH}${NC}"
        exit 1
        ;;
esac

install_deps() {
    echo -e "${BLUE}安装依赖...${NC}"
    apk update >/dev/null 2>&1
    apk add curl wget tar xz gzip unzip openssl ca-certificates >/dev/null 2>&1 || {
        echo -e "${RED}依赖安装失败${NC}"
        exit 1
    }
}

cleanup() {
    echo -e "${BLUE}清理旧环境...${NC}"
    [ -f "${STLS_INIT}" ] && rc-service shadowtls stop >/dev/null 2>&1
    [ -f "${SS_INIT}" ] && rc-service shadowsocks-rust stop >/dev/null 2>&1
    [ -f "${STLS_INIT}" ] && rc-update del shadowtls default >/dev/null 2>&1
    [ -f "${SS_INIT}" ] && rc-update del shadowsocks-rust default >/dev/null 2>&1

    rm -f "${SS_BIN}" "${STLS_BIN}" "${SS_INIT}" "${STLS_INIT}"
    rm -rf "${SS_CONF_DIR}"
}

download_ssrust() {
    echo -e "${BLUE}下载 shadowsocks-rust...${NC}"
    SSR_VER=$(curl -sL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep '"tag_name":' | head -n1 | cut -d'"' -f4)
    [ -z "${SSR_VER}" ] && SSR_VER="v1.22.0"

    SSR_FILE="shadowsocks-${SSR_VER#v}.${SSR_ARCH}.tar.xz"
    SSR_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${SSR_VER}/${SSR_FILE}"

    mkdir -p /tmp/ssrust_extract
    curl -fL -o /tmp/${SSR_FILE} "${SSR_URL}" || {
        echo -e "${RED}下载 shadowsocks-rust 失败${NC}"
        exit 1
    }

    tar -xJf /tmp/${SSR_FILE} -C /tmp/ssrust_extract || {
        echo -e "${RED}解压 shadowsocks-rust 失败${NC}"
        exit 1
    }

    install -m 755 /tmp/ssrust_extract/ssserver "${SS_BIN}" || {
        echo -e "${RED}安装 ssserver 失败${NC}"
        exit 1
    }

    rm -rf /tmp/${SSR_FILE} /tmp/ssrust_extract
}

download_shadowtls() {
    echo -e "${BLUE}下载 ShadowTLS...${NC}"
    STLS_VER=$(curl -sL https://api.github.com/repos/ihciah/shadow-tls/releases/latest | grep '"tag_name":' | head -n1 | cut -d'"' -f4)
    [ -z "${STLS_VER}" ] && STLS_VER="v0.2.25"

    STLS_FILE="shadow-tls-${STLS_ARCH}.tar.xz"
    STLS_URL="https://github.com/ihciah/shadow-tls/releases/download/${STLS_VER}/${STLS_FILE}"

    mkdir -p /tmp/shadowtls_extract
    curl -fL -o /tmp/${STLS_FILE} "${STLS_URL}" || {
        echo -e "${RED}下载 ShadowTLS 失败${NC}"
        exit 1
    }

    tar -xJf /tmp/${STLS_FILE} -C /tmp/shadowtls_extract || {
        echo -e "${RED}解压 ShadowTLS 失败${NC}"
        exit 1
    }

    find /tmp/shadowtls_extract -type f -name "shadow-tls*" | head -n1 | xargs -I {} install -m 755 {} "${STLS_BIN}"

    [ ! -f "${STLS_BIN}" ] && {
        echo -e "${RED}安装 ShadowTLS 失败${NC}"
        exit 1
    }

    rm -rf /tmp/${STLS_FILE} /tmp/shadowtls_extract
}

write_ss_config() {
    mkdir -p "${SS_CONF_DIR}"

    cat > "${SS_CONF_FILE}" <<EOF
{
    "server": "127.0.0.1",
    "server_port": ${SS_PORT},
    "password": "${SS_PASSWORD}",
    "method": "${SS_METHOD}",
    "mode": "tcp_and_udp",
    "timeout": 300,
    "fast_open": false
}
EOF
}

write_ss_service() {
    cat > "${SS_INIT}" <<EOF
#!/sbin/openrc-run
description="Shadowsocks Rust Server"
command="${SS_BIN}"
command_args="-c ${SS_CONF_FILE}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${SS_LOG}"
error_log="${SS_LOG}"
depend() {
    need net
    after firewall
}
EOF
    chmod +x "${SS_INIT}"
    rc-update add shadowsocks-rust default >/dev/null 2>&1
}

write_stls_service() {
    cat > "${STLS_INIT}" <<EOF
#!/sbin/openrc-run
description="ShadowTLS Server"
command="${STLS_BIN}"
command_args="--v3 server --listen 0.0.0.0:${STLS_PORT} --server 127.0.0.1:${SS_PORT} --tls ${TLS_DOMAIN}:443 --password ${STLS_PASSWORD}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${STLS_LOG}"
error_log="${STLS_LOG}"
depend() {
    need net
    after firewall
}
EOF
    chmod +x "${STLS_INIT}"
    rc-update add shadowtls default >/dev/null 2>&1
}

show_result() {
    IP4=$(curl -s4 ifconfig.me)
    IP6=$(curl -s6 ifconfig.me)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    SS_BASE64=$(printf '%s' "${SS_METHOD}:${SS_PASSWORD}" | openssl base64 -A)

    echo ""
    echo -e "${GREEN}================ 安装完成 ==================${NC}"
    echo -e "${GREEN}Shadowsocks Rust 状态:${NC} $(pidof ssserver >/dev/null && echo '运行中' || echo '未运行')"

    if [ "${ENABLE_STLS}" = "y" ]; then
        echo -e "${GREEN}ShadowTLS 状态:${NC} $(pidof shadow-tls >/dev/null && echo '运行中' || echo '未运行')"
    fi

    echo "------------------------------------------------"

    cat > "${SS_NODE_FILE}" <<EOF
================ Shadowsocks Rust 节点信息 ================

主机名: ${HOSTNAME}
加密方式: ${SS_METHOD}
密码: ${SS_PASSWORD}

[纯 Shadowsocks]
服务器: ${IP4}
端口: ${PUBLIC_SS_PORT}

ss://${SS_BASE64}@${IP4}:${PUBLIC_SS_PORT}#${HOSTNAME}-SS

EOF

    if [ -n "${IP6}" ]; then
        cat >> "${SS_NODE_FILE}" <<EOF
IPv6:
ss://${SS_BASE64}@[${IP6}]:${PUBLIC_SS_PORT}#${HOSTNAME}-SS-IPv6

EOF
    fi

    if [ "${ENABLE_STLS}" = "y" ]; then
        cat >> "${SS_NODE_FILE}" <<EOF
[Shadowsocks + ShadowTLS]
ShadowTLS 服务器: ${IP4}
ShadowTLS 端口: ${STLS_PORT}
ShadowTLS 密码: ${STLS_PASSWORD}
TLS SNI: ${TLS_DOMAIN}

客户端填写参考:
- SS服务器: ${IP4}
- SS端口: ${STLS_PORT}
- SS密码: ${SS_PASSWORD}
- 加密方式: ${SS_METHOD}
- 插件/协议: shadowtls
- shadowtls版本: v3
- shadowtls密码: ${STLS_PASSWORD}
- sni: ${TLS_DOMAIN}

EOF

        if [ -n "${IP6}" ]; then
            cat >> "${SS_NODE_FILE}" <<EOF
IPv6 ShadowTLS:
- SS服务器: [${IP6}]
- SS端口: ${STLS_PORT}
- SS密码: ${SS_PASSWORD}
- 加密方式: ${SS_METHOD}
- 插件/协议: shadowtls
- shadowtls版本: v3
- shadowtls密码: ${STLS_PASSWORD}
- sni: ${TLS_DOMAIN}

EOF
        fi
    fi

    cat >> "${SS_NODE_FILE}" <<EOF
==========================================================
EOF

    if [ -n "${IP4}" ]; then
        echo -e "${BLUE}[IPv4]${NC}"
        echo -e "${GREEN}纯 SS:${NC}"
        echo -e "${YELLOW}ss://${SS_BASE64}@${IP4}:${PUBLIC_SS_PORT}#${HOSTNAME}-SS${NC}"
        echo ""
    fi

    if [ "${ENABLE_STLS}" = "y" ]; then
        echo -e "${GREEN}SS + ShadowTLS:${NC}"
        echo -e "服务器: ${YELLOW}${IP4}${NC}"
        echo -e "端口: ${YELLOW}${STLS_PORT}${NC}"
        echo -e "SS密码: ${YELLOW}${SS_PASSWORD}${NC}"
        echo -e "加密: ${YELLOW}${SS_METHOD}${NC}"
        echo -e "ShadowTLS密码: ${YELLOW}${STLS_PASSWORD}${NC}"
        echo -e "SNI: ${YELLOW}${TLS_DOMAIN}${NC}"
        echo ""
    fi

    if [ -n "${IP6}" ]; then
        echo -e "${BLUE}[IPv6]${NC}"
        echo -e "${GREEN}纯 SS:${NC}"
        echo -e "${YELLOW}ss://${SS_BASE64}@[${IP6}]:${PUBLIC_SS_PORT}#${HOSTNAME}-SS-IPv6${NC}"
        echo ""
    fi

    echo "------------------------------------------------"
    echo -e "${GREEN}节点信息已保存到: ${SS_NODE_FILE}${NC}"
}

do_update() {
    echo -e "${BLUE}更新程序文件...${NC}"
    [ -f "${SS_INIT}" ] && rc-service shadowsocks-rust stop >/dev/null 2>&1
    [ -f "${STLS_INIT}" ] && rc-service shadowtls stop >/dev/null 2>&1
    install_deps
    download_ssrust
    if [ -f "${STLS_INIT}" ] || [ -f "${STLS_BIN}" ]; then
        download_shadowtls
    fi
    [ -f "${SS_INIT}" ] && rc-service shadowsocks-rust start >/dev/null 2>&1
    [ -f "${STLS_INIT}" ] && rc-service shadowtls start >/dev/null 2>&1
    echo -e "${GREEN}更新完成${NC}"
    exit 0
}

# 参数处理
if [ "$1" = "uninstall" ]; then
    cleanup
    echo -e "${GREEN}卸载完成${NC}"
    exit 0
fi

if [ "$1" = "update" ]; then
    do_update
fi

install_deps

echo ""
read -p "请输入 Shadowsocks 密码(留空随机生成): " SS_PASSWORD
[ -z "${SS_PASSWORD}" ] && SS_PASSWORD=$(openssl rand -base64 16 | tr -d '\n')

read -p "请输入加密方式 [默认 aes-256-gcm]: " SS_METHOD
[ -z "${SS_METHOD}" ] && SS_METHOD="aes-256-gcm"

case "${SS_METHOD}" in
    aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305)
        ;;
    *)
        echo -e "${RED}当前脚本仅允许: aes-128-gcm / aes-256-gcm / chacha20-ietf-poly1305${NC}"
        exit 1
        ;;
esac

read -p "是否启用 ShadowTLS? [y/N]: " ENABLE_STLS
[ -z "${ENABLE_STLS}" ] && ENABLE_STLS="n"

if [ "${ENABLE_STLS}" = "y" ] || [ "${ENABLE_STLS}" = "Y" ]; then
    ENABLE_STLS="y"
else
    ENABLE_STLS="n"
fi

if [ "${ENABLE_STLS}" = "y" ]; then
    read -p "请输入 ShadowTLS 对外端口 [默认 443]: " STLS_PORT
    [ -z "${STLS_PORT}" ] && STLS_PORT=443

    read -p "请输入伪装 SNI 域名 [默认 www.cloudflare.com]: " TLS_DOMAIN
    [ -z "${TLS_DOMAIN}" ] && TLS_DOMAIN="www.cloudflare.com"

    read -p "请输入 ShadowTLS 密码(留空随机生成): " STLS_PASSWORD
    [ -z "${STLS_PASSWORD}" ] && STLS_PASSWORD=$(openssl rand -hex 16)

    SS_PORT=60001
    PUBLIC_SS_PORT=${STLS_PORT}
else
    read -p "请输入 Shadowsocks 对外端口 [默认随机 20000-60000]: " SS_PORT
    [ -z "${SS_PORT}" ] && SS_PORT=$((RANDOM%40000+20000))
    PUBLIC_SS_PORT=${SS_PORT}
fi

case "${SS_PORT}" in
    ''|*[!0-9]*)
        echo -e "${RED}端口必须为数字${NC}"
        exit 1
        ;;
esac

if [ "${ENABLE_STLS}" = "y" ]; then
    case "${STLS_PORT}" in
        ''|*[!0-9]*)
            echo -e "${RED}ShadowTLS 端口必须为数字${NC}"
            exit 1
            ;;
    esac
fi

echo ""
echo -e "${GREEN}SS 加密: ${SS_METHOD}${NC}"
echo -e "${GREEN}SS 密码: ${SS_PASSWORD}${NC}"
if [ "${ENABLE_STLS}" = "y" ]; then
    echo -e "${GREEN}ShadowTLS: 已启用${NC}"
    echo -e "${GREEN}ShadowTLS端口: ${STLS_PORT}${NC}"
    echo -e "${GREEN}SNI: ${TLS_DOMAIN}${NC}"
    echo -e "${GREEN}ShadowTLS密码: ${STLS_PASSWORD}${NC}"
else
    echo -e "${GREEN}ShadowTLS: 未启用${NC}"
    echo -e "${GREEN}SS端口: ${SS_PORT}${NC}"
fi
echo ""

cleanup
install_deps
download_ssrust
write_ss_config
write_ss_service

if [ "${ENABLE_STLS}" = "y" ]; then
    download_shadowtls
    write_stls_service
fi

rc-service shadowsocks-rust restart >/dev/null 2>&1 || rc-service shadowsocks-rust start >/dev/null 2>&1

if [ "${ENABLE_STLS}" = "y" ]; then
    rc-service shadowtls restart >/dev/null 2>&1 || rc-service shadowtls start >/dev/null 2>&1
fi

sleep 2
show_result
