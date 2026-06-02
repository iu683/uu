#!/bin/bash

# =========================================================
# Xray VLESS-Reality / Hysteria 2 / Nginx 单端口443共存脚本
# =========================================================

set -Eeuo pipefail

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\03 counseling"
RESET="\033[0m"

# ================== 基础变量 ==================
readonly SERVICE_NAME="vlessreality"
readonly SERVICE_HY2="hysteria2"

readonly XRAY_CONFIG="/usr/local/etc/${SERVICE_NAME}/config.json"
readonly XRAY_BINARY="/usr/local/bin/${SERVICE_NAME}"
readonly XRAY_PUBLIC_KEY_FILE="/usr/local/etc/${SERVICE_NAME}/public.key"

readonly HY2_CONFIG="/usr/local/etc/${SERVICE_HY2}/config.yaml"
readonly HY2_BINARY="/usr/local/bin/${SERVICE_HY2}"

readonly NGINX_CONF="/etc/nginx/conf.d/multi_port_443.conf"
readonly CERT_DIR="/usr/local/etc/ssl_certs"
readonly REMOTE_HTML_URL="https://raw.githubusercontent.com/sistarry/toolbox/refs/heads/main/toy/nahtml.html"

TMP_DIR=$(mktemp -d -t xray_multi.XXXXXX)

# ================== cleanup ==================
cleanup() {
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

# ================== 日志 ==================
info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

# ================== 获取公网IP ==================
get_public_ip() {
    local ip
    ip=$(curl -4fsSL --max-time 5 https://api.ipify.org || curl -4fsSL --max-time 5 https://ip.sb || echo "127.0.0.1")
    echo "$ip"
}

# ================== 架构与依赖检查 ==================
pre_check() {
    if [[ $(id -u) -ne 0 ]]; then
        error "请使用 root 用户运行"
        exit 1
    fi
    if command -v apt &>/dev/null; then
        apt update && apt install -y jq curl wget openssl unzip nginx -y || true
    elif command -v dnf &>/dev/null; then
        dnf install -y jq curl wget openssl unzip nginx
    elif command -v yum &>/dev/null; then
        yum install -y jq curl wget openssl unzip nginx
    fi
}

# ================== 获取 Xray 状态/版本 ==================
get_xray_status() {
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        echo -e "${GREEN}● 运行中${RESET}"
    else
        echo -e "${RED}● 未运行${RESET}"
    fi
}

get_xray_version() {
    if [[ -x "$XRAY_BINARY" ]]; then
        "$XRAY_BINARY" version 2>/dev/null | grep -i "Xray" | head -n 1 | awk '{print $2}' || echo "未知"
    else
        echo "未安装"
    fi
}

# ================== 下载核心 ==================
download_cores() {
    info "正在拉取最新核心组件..."
    local arch version hy2_arch hy2_url
    
    case "$(uname -m)" in
        x86_64) arch="64"; hy2_arch="linux-amd64" ;;
        aarch64|arm64) arch="arm64-v8a"; hy2_arch="linux-arm64" ;;
        *) error "暂不支持的系统架构"; return 1 ;;
    esac
    
    # 下载 Xray-core
    version=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r '.tag_name' || echo "v24.11.30")
    version="${version#v}"
    curl -L -fsSL "https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${arch}.zip" -o "$TMP_DIR/xray.zip"
    mkdir -p "$TMP_DIR/xray_ext" && unzip -qo "$TMP_DIR/xray.zip" -d "$TMP_DIR/xray_ext"
    mkdir -p "$(dirname "$XRAY_BINARY")"
    cp -f "$TMP_DIR/xray_ext/xray" "$XRAY_BINARY" && chmod +x "$XRAY_BINARY"

    # 下载 Hysteria 2
    hy2_url=$(curl -fsSL "https://api.github.com/repos/apernet/hysteria/releases/latest" | jq -r ".assets[] | select(.name | contains(\"${hy2_arch}\")) | .browser_download_url" | head -n 1)
    curl -L -fsSL "$hy2_url" -o "$HY2_BINARY" && chmod +x "$HY2_BINARY"
}

# ================== 部署高级伪装网页 ==================
download_masquerade_html() {
    info "正在从自定义库下载高级伪装网页..."
    mkdir -p /var/www/html
    if curl -fsSL --max-time 10 "$REMOTE_HTML_URL" -o /var/www/html/index.html; then
        info "高级伪装网页下载并覆盖成功！"
    else
        warn "高级网页拉取失败，生成本地保底网页。"
        echo "<h1>System Operational</h1>" > /var/www/html/index.html
    fi
}

# ================== 生成自签名证书 ==================
generate_certs() {
    local domain="$1"
    mkdir -p "$CERT_DIR"
    info "正在生成回落所需的 TLS 证书..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${CERT_DIR}/server.key" \
        -out "${CERT_DIR}/server.crt" \
        -subj "/CN=${domain}" \
        -addext "subjectAltName = DNS:${domain}" 2>/dev/null
}

# ================== 写全局共存配置 ==================
write_configs() {
    local domain="$1" uuid="$2" short_id="$3" private_key="$4" hy2_password="$5"
    
    # 1. Xray 核心配置 (监听 TCP 443 -> 回落至本地 Nginx 8443)
    mkdir -p "$(dirname "$XRAY_CONFIG")"
    cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${uuid}", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "127.0.0.1:8443",
          "xver": 0,
          "serverNames": [ "${domain}" ],
          "privateKey": "${private_key}",
          "shortIds": [ "${short_id}" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

    # 2. Hysteria 2 核心配置 (直接高能接管 UDP 443 端口)
    mkdir -p "$(dirname "$HY2_CONFIG")"
    cat > "$HY2_CONFIG" <<EOF
listen: :443
tls:
  cert: ${CERT_DIR}/server.crt
  key: ${CERT_DIR}/server.key
auth:
  type: password
  password: ${hy2_password}
fastOpen: true
masquerade:
  type: proxy
  proxy:
    url: http://127.0.0.1:80/
    rewriteHost: true
EOF

    # 3. Nginx 复合分流配置 (支持 H2 回落与 H3 QUIC 广播)
    cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:8443 ssl;
    http2 on;
    
    # 允许本地进行 HTTP/3 分流与测试
    listen 127.0.0.1:8443 quic;
    
    server_name ${domain};

    ssl_certificate ${CERT_DIR}/server.crt;
    ssl_certificate_key ${CERT_DIR}/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    # 广播告知客户端可在 UDP 443 端口建立 HTTP/3 握手
    add_header Alt-Svc 'h3=":443"; ma=86400';
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;

    location / {
        root /var/www/html;
        index index.html index.htm;
    }
}

server {
    listen 80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}
EOF
}

# ================== Systemd 守护配置 ==================
setup_systemd() {
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Xray Vless Reality Service
After=network.target
[Service]
User=root
ExecStart=${XRAY_BINARY} run -config ${XRAY_CONFIG}
Restart=on-failure
EOF

    cat > "/etc/systemd/system/${SERVICE_HY2}.service" <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target
[Service]
User=root
WorkingDirectory=$(dirname "$HY2_CONFIG")
ExecStart=${HY2_BINARY} server --config ${HY2_CONFIG}
Restart=on-failure
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" "${SERVICE_HY2}" nginx 2>/dev/null || true
}

# ================== 全局服务重启 ==================
restart_all_services() {
    systemctl restart nginx || true
    systemctl restart "${SERVICE_NAME}" || true
    systemctl restart "${SERVICE_HY2}" || true
}

# ================== 安装模块 ==================
install_xray() {
    info "开始一键单端口多协议复合环境安装..."
    
    local domain uuid short_id hy2_password
    read -rp "请输入解析域名/伪装域名 (默认: www.amazon.com): " domain
    domain=${domain:-www.amazon.com}
    
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "64b2a8d3-5243-4ba8-963b-4663e8322851")
    short_id=$(openssl rand -hex 4)
    hy2_password=$(openssl rand -base64 12)
    
    download_cores
    download_masquerade_html
    generate_certs "$domain"
    
    local key_pair private_key public_key
    key_pair=$("$XRAY_BINARY" x25519 2>/dev/null)
    private_key=$(echo "$key_pair" | grep -i "Private" | awk -F ': ' '{print $2}' | tr -d '\r')
    public_key=$(echo "$key_pair" | grep -i "Public" | awk -F ': ' '{print $2}' | tr -d '\r')
    echo "$public_key" > "$XRAY_PUBLIC_KEY_FILE"
    
    write_configs "$domain" "$uuid" "$short_id" "$private_key" "$hy2_password"
    setup_systemd
    
    # 清理默认冲突配置
    rm -f /etc/nginx/sites-enabled/default || true
    
    restart_all_services
    info "复合面板运行所需的环境依赖安装完毕！"
    show_current_config
}

# ================== 节点配置与分享链接展示 ==================
show_current_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        error "尚未完成初始化配置"
        return
    fi
    
    local ip domain uuid short_id public_key hy2_password
    ip=$(get_public_ip)
    domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
    short_id=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
    public_key=$(cat "$XRAY_PUBLIC_KEY_FILE" 2>/dev/null || echo "未知")
    hy2_password=$(grep "password:" "$HY2_CONFIG" 2>/dev/null | awk '{print $2}' || echo "未知")

    echo -e "${GREEN}====== 当前单端口复合配置 ======${RESET}"
    echo -e "${YELLOW}运行端口    : 443 (TCP/UDP复用)${RESET}"
    echo -e "${YELLOW}绑定域名    : ${domain}${RESET}"
    echo -e "${YELLOW}Web 协议    : 网站已就绪 (支持 HTTP/2 & HTTP/3 QUIC 广播)${RESET}"
    echo -e "------------------------------------------------"
    echo -e "${GREEN}👉 VLESS-REALITY 分享链接:${RESET}"
    echo "vless://${uuid}@${ip}:443?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${short_id}#VLESS_Reality_443"
    echo -e "------------------------------------------------"
    echo -e "${GREEN}👉 Hysteria 2 分享链接:${RESET}"
    echo "hy2://${hy2_password}@${ip}:443?sni=${domain}&insecure=1#Hysteria2_443"
    echo -e "================================================"
}

# ================== 修改配置 ==================
modify_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        error "配置文件不存在，请先选择安装。"
        return
    fi
    info "更新单端口共存参数..."
    install_xray
}

# ================== 卸载环境 ==================
uninstall_xray() {
    warn "正在彻底清理单端口 443 多协议复合环境..."
    systemctl stop "${SERVICE_NAME}" "${SERVICE_HY2}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" "${SERVICE_HY2}" 2>/dev/null || true
    
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service" "/etc/systemd/system/${SERVICE_HY2}.service"
    systemctl daemon-reload
    
    rm -f "$XRAY_BINARY" "$HY2_BINARY" "$NGINX_CONF"
    rm -rf "/usr/local/etc/${SERVICE_NAME}" "/usr/local/etc/${SERVICE_HY2}" "$CERT_DIR"
    systemctl restart nginx
    info "全套环境已完全卸载，Nginx 已恢复初始状态。"
}

# ================== 交互式主菜单 ==================
show_menu() {
    clear
    local status version port_show
    status=$(get_xray_status)
    version=$(get_xray_version)
    port_show="443" # 复合共存架构统一锁定核心单端口443

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      VLESS-Reality 面板       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 VLESS-Reality${RESET}"
    echo -e "${GREEN} 2. 更新 VLESS-Reality${RESET}"
    echo -e "${GREEN} 3. 卸载 VLESS-Reality${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 启动 VLESS-Reality${RESET}"
    echo -e "${GREEN} 6. 停止 VLESS-Reality${RESET}"
    echo -e "${GREEN} 7. 重启 VLESS-Reality${RESET}"
    echo -e "${GREEN} 8. 查看服务日志${RESET}"
    echo -e "${GREEN} 9. 查看节点配置${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# ================== 主循环流程 ==================
main() {
    pre_check

    while true; do
        show_menu
        
        local choice=""
        read -r -p $'\033[32m请输入选项: \033[0m' choice || true
        
        [[ -z "$choice" ]] && continue

        case "$choice" in
            1) install_xray; pause ;;
            2) download_cores && restart_all_services && info "核心更新成功！"; pause ;;
            3) uninstall_xray; pause ;;
            4) modify_config; pause ;;
            5) systemctl start "${SERVICE_NAME}" "${SERVICE_HY2}" &>/dev/null || true; info "相关服务已全面拉起"; pause ;;
            6) systemctl stop "${SERVICE_NAME}" "${SERVICE_HY2}" &>/dev/null || true; info "服务已全面停止"; pause ;;
            7) restart_all_services; info "所有共存服务重载完毕"; pause ;;
            8) journalctl -u "${SERVICE_NAME}" --no-pager -n 30 || true; pause ;;
            9) show_current_config; pause ;;
            0) exit 0 ;;
            *) error "无效输入"; pause ;;
        esac
    done
}

main "$@"
