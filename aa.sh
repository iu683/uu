cat > /root/install-ssh-login-tg-alert.sh <<'INSTALL_EOF'
#!/usr/bin/env bash
set -euo pipefail

# ===== 颜色 =====
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
BOLD='\033[1m'
RESET='\033[0m'

SCRIPT_PATH="/usr/local/bin/ssh-login-alert.sh"
ENV_FILE="/root/.tg-ssh-alert.env"
PAM_FILE="/etc/pam.d/sshd"
PAM_LINE="session optional pam_exec.so seteuid ${SCRIPT_PATH}"

info() { echo -e "${CYAN}$*${RESET}"; }
ok() { echo -e "${GREEN}$*${RESET}"; }
warn() { echo -e "${YELLOW}$*${RESET}"; }
err() { echo -e "${RED}$*${RESET}"; }

menu() {
    clear
    echo -e "${GREEN}"
    echo "=================================="
    echo " SSH 登录 Telegram 通知管理"
    echo "=================================="
    echo "1. 安装通知"
    echo "2. 卸载（保留配置）"
    echo "3. 彻底卸载（删除配置）"
    echo "0. 退出"
    echo "=================================="
    echo -e "${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r CHOICE
}

if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 执行"
    exit 1
fi

uninstall_common() {

    if [ -f "$PAM_FILE" ]; then
        if grep -Fq "$SCRIPT_PATH" "$PAM_FILE"; then
            cp "$PAM_FILE" "${PAM_FILE}.bak.$(date +%Y%m%d%H%M%S)"
            sed -i "\#${SCRIPT_PATH}#d" "$PAM_FILE"
            ok "已移除 PAM 接入"
        fi
    fi

    if [ -f "$SCRIPT_PATH" ]; then
        rm -f "$SCRIPT_PATH"
        ok "已删除通知脚本"
    fi
}

install_alert() {

    echo
    echo -ne "${GREEN}请输入 Telegram Bot Token: ${RESET}"
    read -r TG_BOT_TOKEN

    echo -ne "${GREEN}请输入 Telegram Chat ID: ${RESET}"
    read -r TG_CHAT_ID

    echo -ne "${GREEN}请输入服务器公网 IP（留空自动检测）: ${RESET}"
    read -r SERVER_PUBLIC_IP

    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        err "Bot Token 或 Chat ID 不能为空"
        exit 1
    fi

    ok "安装 curl..."

    if command -v apt >/dev/null 2>&1; then
        apt update
        apt install -y curl
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl
    fi

    cat > "$ENV_FILE" <<EOF
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP}"
EOF

    chmod 600 "$ENV_FILE"

cat > "$SCRIPT_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/root/.tg-ssh-alert.env"
[ -f "$ENV_FILE" ] || exit 0
source "$ENV_FILE"

[ "${PAM_TYPE:-}" = "open_session" ] || exit 0

USER_NAME="${PAM_USER:-unknown}"
REMOTE_HOST="${PAM_RHOST:-unknown}"
TTY_NAME="${PAM_TTY:-unknown}"
SERVER_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"

if [ -n "${SERVER_PUBLIC_IP:-}" ]; then
    SERVER_IP="$SERVER_PUBLIC_IP"
else
    SERVER_IP="$(curl -4 -fsS https://api.ipify.org 2>/dev/null || echo unknown)"
fi

LOGIN_TIME="$(date "+%Y-%m-%d %H:%M:%S %Z")"

MESSAGE="🔐 SSH 登录通知

主机: ${SERVER_HOSTNAME}
公网IP: ${SERVER_IP}
用户: ${USER_NAME}
来源IP: ${REMOTE_HOST}
终端: ${TTY_NAME}
时间: ${LOGIN_TIME}"

curl -fsS \
-X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
-d "chat_id=${TG_CHAT_ID}" \
--data-urlencode "text=${MESSAGE}" \
>/dev/null 2>&1 || true
EOF

    chmod 700 "$SCRIPT_PATH"

    if grep -Fq "$SCRIPT_PATH" "$PAM_FILE"; then
        warn "PAM 已存在配置，跳过"
    else
        cp "$PAM_FILE" "${PAM_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        echo "$PAM_LINE" >> "$PAM_FILE"
        ok "PAM 已接入"
    fi

    TEST_MSG="✅ SSH 登录通知安装成功

主机: $(hostname)
时间: $(date '+%F %T')"

    if curl -fsS \
    -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${TEST_MSG}" >/dev/null; then
        ok "测试消息发送成功"
    else
        warn "测试消息发送失败"
    fi

    ok "安装完成，请新开 SSH 登录测试"
}

while true; do
    menu
    case "$CHOICE" in
        1)
            install_alert
            ;;
        2)
            uninstall_common
            warn "配置文件已保留：$ENV_FILE"
            ;;
        3)
            uninstall_common
            rm -f "$ENV_FILE"
            ok "已彻底卸载"
            ;;
        0)
            exit 0
            ;;
        *)
            err "无效选项"
            ;;
    esac

    echo
    read -rp "按回车返回菜单..." _
done

INSTALL_EOF

chmod +x /root/install-ssh-login-tg-alert.sh
bash /root/install-ssh-login-tg-alert.sh
