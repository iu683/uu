cat > /root/install-ssh-login-tg-alert.sh <<'INSTALL_EOF'
#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
CYAN='\033[36m'
RESET='\033[0m'

SCRIPT_PATH="/usr/local/bin/ssh-login-alert.sh"
ENV_FILE="/root/.tg-ssh-alert.env"
PAM_FILE="/etc/pam.d/sshd"
PAM_LINE="session optional pam_exec.so seteuid ${SCRIPT_PATH}"

ok(){ echo -e "${GREEN}$*${RESET}"; }
warn(){ echo -e "${YELLOW}$*${RESET}"; }
err(){ echo -e "${RED}$*${RESET}"; }
info(){ echo -e "${CYAN}$*${RESET}"; }

menu() {
clear
echo -e "${GREEN}"
echo "=================================="
echo " SSH 登录 Telegram 通知管理"
echo "=================================="
echo "1. 安装 / 修改配置"
echo "2. 卸载（保留配置）"
echo "3. 彻底卸载"
echo "0. 退出"
echo "=================================="
echo -e "${RESET}"
echo -ne "${GREEN}请输入选项: ${RESET}"
read -r CHOICE
}

[ "$(id -u)" -eq 0 ] || { err "请使用 root"; exit 1; }

uninstall_common() {
    grep -Fq "$SCRIPT_PATH" "$PAM_FILE" 2>/dev/null && \
    sed -i "\#${SCRIPT_PATH}#d" "$PAM_FILE" && \
    ok "已移除 PAM"

    [ -f "$SCRIPT_PATH" ] && rm -f "$SCRIPT_PATH" && ok "已删除通知脚本"
}

install_alert() {

echo
echo -ne "${GREEN}Telegram Bot Token: ${RESET}"
read -r TG_BOT_TOKEN

echo -ne "${GREEN}Telegram Chat ID: ${RESET}"
read -r TG_CHAT_ID

echo -ne "${GREEN}服务器公网IP（留空自动检测）: ${RESET}"
read -r SERVER_PUBLIC_IP

echo -ne "${GREEN}主机显示名称（留空默认hostname）: ${RESET}"
read -r CUSTOM_HOSTNAME

[ -n "$TG_BOT_TOKEN" ] || { err "Token不能为空"; exit 1; }
[ -n "$TG_CHAT_ID" ] || { err "ChatID不能为空"; exit 1; }

if command -v apt >/dev/null; then
    apt update && apt install -y curl
elif command -v dnf >/dev/null; then
    dnf install -y curl
elif command -v yum >/dev/null; then
    yum install -y curl
fi

cat > "$ENV_FILE" <<EOF
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP}"
CUSTOM_HOSTNAME="${CUSTOM_HOSTNAME}"
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

if [ -n "${CUSTOM_HOSTNAME:-}" ]; then
    SERVER_HOSTNAME="$CUSTOM_HOSTNAME"
else
    SERVER_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
fi

if [ -n "${SERVER_PUBLIC_IP:-}" ]; then
    SERVER_IP="$SERVER_PUBLIC_IP"
else
    SERVER_IP="$(curl -4 -fsS https://api.ipify.org 2>/dev/null || echo unknown)"
fi

LOGIN_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"

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

grep -Fq "$SCRIPT_PATH" "$PAM_FILE" || {
    echo "$PAM_LINE" >> "$PAM_FILE"
    ok "PAM 已接入"
}

TEST_HOST="${CUSTOM_HOSTNAME:-$(hostname)}"

curl -fsS \
-X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
-d "chat_id=${TG_CHAT_ID}" \
--data-urlencode "text=✅ SSH通知安装成功

主机: ${TEST_HOST}
时间: $(date '+%F %T')" >/dev/null && \
ok "测试消息发送成功"

ok "安装完成"
}

while true; do
menu
case "$CHOICE" in
1) install_alert ;;
2)
    uninstall_common
    warn "配置文件保留：$ENV_FILE"
    ;;
3)
    uninstall_common
    rm -f "$ENV_FILE"
    ok "已彻底卸载"
    ;;
0) exit 0 ;;
*) err "无效选项" ;;
esac

echo
echo -ne "${GREEN}按回车返回菜单...${RESET}"
read -r
done

INSTALL_EOF

chmod +x /root/install-ssh-login-tg-alert.sh
bash /root/install-ssh-login-tg-alert.sh
