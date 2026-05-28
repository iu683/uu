#!/usr/bin/env bash
#
# Socks5 管理面板
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

readonly WORKDIR="/root/Socks5"
readonly META_FILE="${WORKDIR}/meta.env"
readonly CONFIG_S5="${WORKDIR}/config.json"
readonly CONFIG_3PROXY="${WORKDIR}/3proxy.cfg"
readonly SERVICE_FILE="/etc/systemd/system/s5.service"
readonly DEFAULT_PORT=1080
readonly DEFAULT_USER="s5user"

# 终端颜色代码
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# =========================================================
# 2. 工具函数
# =========================================================
info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }
has_command() { type -P "$1" > /dev/null 2>&1; }

random_port() { shuf -i 20000-60000 -n 1; }
random_pass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12; }

get_best_ip() {
    local ip
    for svc in "https://icanhazip.com" "https://ifconfig.me"; do
        ip=$(curl -s --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
    done
    echo "127.0.0.1"
}

urlencode() {
    local s="$1"
    python3 -c "import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe=''))" "$s" 2>/dev/null || printf '%s' "$s"
}

# =========================================================
# 3. 配置与部署核心
# =========================================================
save_meta() {
    mkdir -p "${WORKDIR}"
    cat > "${META_FILE}" <<EOF
PORT='${PORT}'
USERNAME='${USERNAME}'
PASSWORD='${PASSWORD}'
BIN_TYPE='${BIN_TYPE}'
EOF
    chmod 600 "${META_FILE}"
}

load_meta() {
    [[ -f "${META_FILE}" ]] && source "${META_FILE}"
}

create_service() {
    cat > "${WORKDIR}/start.sh" <<EOF
#!/usr/bin/env bash
source ${META_FILE}
case "\$BIN_TYPE" in
    3proxy) exec 3proxy ${CONFIG_3PROXY} ;;
    microsocks) exec microsocks -i :: -p \$PORT -u \$USERNAME -P \$PASSWORD ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "${WORKDIR}/start.sh"

    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Socks5 Service
After=network.target

[Service]
WorkingDirectory=${WORKDIR}
ExecStart=${WORKDIR}/start.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable s5 >/dev/null 2>&1
}

# =========================================================
# 4. 业务流程模块
# =========================================================
install_flow() {
    echo -e "${GREEN}--- 安装配置 ---${RESET}"
    read -rp "监听端口 (回车随机): " PORT
    PORT=${PORT:-$(random_port)}
    read -rp "用户名 (默认: ${DEFAULT_USER}): " USERNAME
    USERNAME=${USERNAME:-$DEFAULT_USER}
    read -rp "密码 (留空随机): " PASSWORD
    PASSWORD=${PASSWORD:-$(random_pass)}

    # 简化的安装探测 (优先使用 microsocks)
    if has_command microsocks; then BIN_TYPE="microsocks"
    elif has_command 3proxy; then BIN_TYPE="3proxy"
    else error "未找到支持的实现"; return 1; fi

    save_meta
    create_service
    systemctl restart s5
    info "安装完成！"
    pause
}

show_config() {
    load_meta
    local ip=$(get_best_ip)
    echo -e "${GREEN}=== 节点信息 ===${RESET}"
    echo "Socks5: socks://${USERNAME}:${PASSWORD}@${ip}:${PORT}"
    echo "Telegram: https://t.me/socks?server=${ip}&port=${PORT}&user=$(urlencode "$USERNAME")&pass=$(urlencode "$PASSWORD")"
    pause
}

# =========================================================
# 5. 主菜单
# =========================================================
menu() {
    [[ $EUID -ne 0 ]] && error "请使用 root 用户运行。" && exit 1
    while true; do
        clear
        load_meta
        local status=$(systemctl is-active --quiet s5 && echo -e "${GREEN}运行中" || echo -e "${RED}未运行")
        
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}      Socks5 代理管理面板      ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "状态: $status ${RESET}"
        echo -e "端口: ${YELLOW}${PORT:-未配置}${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "1. 安装 Socks5"
        echo -e "2. 卸载 Socks5"
        echo -e "3. 启动 Socks5"
        echo -e "4. 停止 Socks5"
        echo -e "5. 查看节点连接信息"
        echo -e "0. 退出"
        echo -e "${GREEN}================================${RESET}"

        read -rp "请选择: " choice
        case "$choice" in
            1) install_flow ;;
            2) systemctl stop s5; rm -rf "${WORKDIR}" "${SERVICE_FILE}"; systemctl daemon-reload; info "已卸载"; pause ;;
            3) systemctl start s5; info "已启动"; pause ;;
            4) systemctl stop s5; info "已停止"; pause ;;
            5) show_config ;;
            0) exit 0 ;;
            *) error "无效选项" ;;
        esac
    done
}

menu "$@"
