#!/usr/bin/env bash
# ====================================================================
# NaiveProxy 官方原生双进程架构 (Caddy + Naive) 一体化安装与管理面板
# SPDX-License-Identifier: MIT
# ====================================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# 核心路径 hardcoded 规范
NAIVE_VERSION="122.0.6261.94-1"
NAIVE_CONFIG_DIR="/etc/naive"
CADDY_CONFIG_DIR="/etc/caddy"
CADDY_CONFIG_FILE="/etc/caddy/Caddyfile"
WEB_WWW_DIR="/var/www/html"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

generate_random_password() {
    dd if=/dev/random bs=18 count=1 status=none | base64 | tr -d '+/=' | cut -c 1-12
}

check_environment() {
    [[ $EUID -ne 0 ]] && { error "请切换至 root 用户运行此脚本"; exit 1; }
    apt update -y >/dev/null 2>&1
    apt install -y libnss3 xz-utils curl wget vim libcap2-bin >/dev/null 2>&1
    
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        ARCH_TAG="amd64"
        NAIVE_ARCH="linux-x64"
    elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        ARCH_TAG="arm64"
        NAIVE_ARCH="linux-arm64"
    else
        error "❌ 不支持的系统架构：$ARCH"; exit 1
    fi
}

get_service_status() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        echo -e "${GREEN}运行中${RESET}"
    else
        echo -e "${RED}未运行${RESET}"
    fi
}

get_current_domain_port() {
    if [[ -f "$CADDY_CONFIG_FILE" ]]; then
        local line
        line=$(grep -oE '^[^{[:space:]]+' "$CADDY_CONFIG_FILE" | head -n 1 || echo "")
        echo -e "${YELLOW}${line}${RESET}"
    else
        echo -e "${RED}未配置${RESET}"
    fi
}

install_naive_official() {
    check_environment
    info "正在下载官方 NaiveProxy 核心程序..."
    local naive_url="https://github.com/klzgrad/naiveproxy/releases/download/v${NAIVE_VERSION}/naiveproxy-v${NAIVE_VERSION}-${NAIVE_ARCH}.tar.xz"
    local dir_name="naiveproxy-v${NAIVE_VERSION}-${NAIVE_ARCH}"
    
    cd /root
    wget -q --show-progress -O naive_server.tar.xz "$naive_url"
    tar -xf naive_server.tar.xz
    chmod +x "${dir_name}/naive"
    cp "${dir_name}/naive" /usr/local/bin/
    rm -rf naive_server.tar.xz "$dir_name"

    info "正在下载集成 ForwardProxy 插件的定制版 Caddy 内核..."
    local caddy_url="https://github.com/passeway/naiveproxy/releases/latest/download/caddy-linux-${ARCH_TAG}"
    wget -q --show-progress -O /usr/bin/caddy "$caddy_url"
    chmod +x /usr/bin/caddy
    setcap cap_net_bind_service=+ep /usr/bin/caddy

    echo "------------------------------------------------"
    read -rp "1. 请输入您的解析域名 (例如 vvcxa.vfz.dpdns.org): " DOMAIN
    [[ -z "$DOMAIN" ]] && { error "域名不能为空！"; return 1; }
    read -rp "2. 请输入对外客户端连接端口 [默认 443]: " PORT
    PORT=${PORT:-443}
    read -rp "3. 请输入验证用户名 [默认 admin]: " USERNAME
    USERNAME=${USERNAME:-"admin"}
    read -rp "4. 请输入验证密码 [留空随机生成强密码]: " PASSWORD
    PASSWORD=${PASSWORD:-$(generate_random_password)}
    echo "------------------------------------------------"

    # 建立经典 Nginx 样式伪装网站
    mkdir -p "$WEB_WWW_DIR"
    echo "<h1>Welcome to nginx!</h1>" > "${WEB_WWW_DIR}/index.html"

    # 注入 Naive 内部监听配置
    mkdir -p "$NAIVE_CONFIG_DIR"
    cat << EOF > "$NAIVE_CONFIG_DIR/config.json"
{
  "listen": "https://127.0.0.1:8080",
  "padding": true
}
EOF

    # 注入 Caddyfile 规则
    mkdir -p "$CADDY_CONFIG_DIR"
    local caddy_listen="$DOMAIN"
    [[ "$PORT" != "443" ]] && caddy_listen="$DOMAIN:$PORT"

    cat << EOF > "$CADDY_CONFIG_FILE"
$caddy_listen {
    tls admin@gmail.com {
        protocols tls1.3
    }
    forward_proxy {
        basic_auth $USERNAME $PASSWORD
        hide_ip
        hide_via
        probe_resistance
        upstream https://127.0.0.1:8080
    }
    root * $WEB_WWW_DIR
    file_server
}
EOF

    # 注册 SystemD 守护文件
    cat << 'EOF' > /etc/systemd/system/naive.service
[Unit]
Description=NaiveProxy Server Service
After=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/naive /etc/naive/config.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    cat << 'EOF' > /etc/systemd/system/caddy.service
[Unit]
Description=Caddy ForwardProxy Gateway
After=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable naive caddy
    systemctl restart naive caddy

    info "🎉 官方解耦双进程版架构安装成功！"
    echo -e "分享链接:\n${CYAN}naive://${USERNAME}:${PASSWORD}@${DOMAIN}:${PORT}?padding=true#Native-Official${RESET}"
}

uninstall_all() {
    systemctl stop naive caddy >/dev/null 2>&1 || true
    systemctl disable naive caddy >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/naive.service /etc/systemd/system/caddy.service
    systemctl daemon-reload
    rm -f /usr/local/bin/naive /usr/bin/caddy
    rm -rf "$NAIVE_CONFIG_DIR" "$CADDY_CONFIG_DIR" "$WEB_WWW_DIR"
    info "解耦版 NaiveProxy 及其环境已彻底从您的 VPS 中卸载清理！"
}

show_client_config() {
    if [[ -f "$CADDY_CONFIG_FILE" ]]; then
        echo -e "${GREEN}====== 核心联动的 Caddy 路由规则 ======${RESET}"
        cat "$CADDY_CONFIG_FILE"
        echo "------------------------------------------------"
        warn "提示: 请直接在本地 v2rayN/小火箭/NekoBox 中新建本地 Naive/HTTP 节点"
        warn "对照上述配置中提取出的 域名、端口、用户名(basic_auth)和密码 进行绑定"
    else
        error "未检测到有效的 Caddyfile 配置文件，请先执行安装！"
    fi
}

# =========================================================
# 面板无限循环主菜单
# =========================================================
while true; do
    clear
    echo -e "${GREEN}==================================================${RESET}"
    echo -e "${GREEN}      NaiveProxy (官方解耦原生版) 综合管理面板     ${RESET}"
    echo -e "${GREEN}==================================================${RESET}"
    echo -e "${GREEN}1. Naive 核心进程状态  :${RESET} $(get_service_status naive)"
    echo -e "${GREEN}2. Caddy 证书网关状态  :${RESET} $(get_service_status caddy)"
    echo -e "${GREEN}3. 当前服务端连接入口  :${RESET} $(get_current_domain_port)"
    echo -e "${GREEN}==================================================${RESET}"
    echo -e "  ${CYAN}1. 干净安装 NaiveProxy 官方原生系统${RESET}"
    echo -e "  ${CYAN}2. 启动所有双进程服务${RESET}"
    echo -e "  ${CYAN}3. 停止所有双进程服务${RESET}"
    echo -e "  ${CYAN}4. 一键重启双进程系统 (重新热加载配置/证书)${RESET}"
    echo -e "  ${CYAN}5. 查看 Caddy 前端网关实时日志 (排查网络流向)${RESET}"
    echo -e "  ${CYAN}6. 查看 Naive 后端核心真实日志 (排查握手解密)${RESET}"
    echo -e "  ${CYAN}7. 调取核心配置参数与排查向导${RESET}"
    echo -e "  ${RED}8. 彻底卸载清理 NaiveProxy 系统${RESET}"
    echo -e "  ${YELLOW}0. 退出管理控制台${RESET}"
    echo -e "${GREEN}==================================================${RESET}"
    
    read -r -p "请输入对应的业务操作代号 [0-8]: " opt || true
    case "$opt" in
        1) install_naive_official; pause ;;
        2) systemctl start naive caddy; info "双服务挂载指令已激活！"; sleep 1 ;;
        3) systemctl stop naive caddy; warn "服务已全部离线！"; sleep 1 ;;
        4) systemctl restart naive caddy; info "双子系统已执行全局热重启！"; sleep 1 ;;
        5) echo -e "${GREEN}正在对接 Caddy 系统流日志 (Ctrl+C 挂断)...${RESET}"; journalctl -u caddy.service -f -n 50 --no-pager || true; pause ;;
        6) echo -e "${GREEN}正在对接 Naive 核心环流日志 (Ctrl+C 挂断)...${RESET}"; journalctl -u naive.service -f -n 50 --no-pager || true; pause ;;
        7) show_client_config; pause ;;
        8) read -r -p "确认要彻底清空服务器上该节点的一切数据吗？(y/n): " confirm
           [[ "$confirm" == "y" || "$confirm" == "Y" ]] && uninstall_all; pause ;;
        0) exit 0 ;;
        *) error "选项无效，请输入 0 至 8 之间的数字！"; sleep 1 ;;
    esac
done
