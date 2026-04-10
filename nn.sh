#!/usr/bin/env bash

set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/Z1rconium/Auto-DynamicIP/refs/heads/main/monitor_ip.sh"
BASE_DIR="${HOME}/ip_monitor"
SCRIPT_PATH="${BASE_DIR}/monitor_ip.sh"
CONFIG_FILE="${BASE_DIR}/manager.conf"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
BLUE="\033[34m"
RESET="\033[0m"

mkdir -p "$BASE_DIR"

# 默认配置
DEFAULT_IP_LOG_FILE="${BASE_DIR}/.current_ip_log"
DEFAULT_IMAGE_DIR="${BASE_DIR}"
DEFAULT_LOG_FILE="${BASE_DIR}/ip_monitor.log"

msg() {
    echo -e "${GREEN}[INFO]${RESET} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${RESET} $1"
}

err() {
    echo -e "${RED}[ERROR]${RESET} $1"
}

title() {
    echo -e "\n${CYAN}==== $1 ====${RESET}"
}

pause() {
    read -rp "按回车继续..."
}

load_config() {
    TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
    TG_CHAT_ID="${TG_CHAT_ID:-}"
    IP_LOG_FILE="${IP_LOG_FILE:-$DEFAULT_IP_LOG_FILE}"
    IMAGE_DIR="${IMAGE_DIR:-$DEFAULT_IMAGE_DIR}"
    LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"
    CRON_EXPR="${CRON_EXPR:-*/5 * * * *}"

    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
IP_LOG_FILE="${IP_LOG_FILE}"
IMAGE_DIR="${IMAGE_DIR}"
LOG_FILE="${LOG_FILE}"
CRON_EXPR="${CRON_EXPR}"
EOF
    msg "配置已保存到: $CONFIG_FILE"
}

detect_pkg_manager() {
    if command -v apt >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    else
        echo ""
    fi
}

install_dependencies() {
    title "安装/更新依赖"

    local pm
    pm=$(detect_pkg_manager)

    if [ -z "$pm" ]; then
        err "未检测到支持的包管理器（apt/dnf/yum/apk）"
        return 1
    fi

    msg "检测到包管理器: $pm"

    case "$pm" in
        apt)
            sudo apt update
            sudo apt install -y curl bash ansilove grep sed gawk cron
            ;;
        dnf)
            sudo dnf install -y curl bash ansilove grep sed gawk cronie
            ;;
        yum)
            sudo yum install -y curl bash ansilove grep sed gawk cronie
            ;;
        apk)
            sudo apk add curl bash ansilove grep sed awk
            ;;
    esac

    msg "依赖安装完成"

    if ! command -v ansilove >/dev/null 2>&1; then
        warn "未检测到 ansilove，原脚本图片功能可能不可用"
    fi
}

download_script() {
    title "下载/更新 monitor_ip.sh"

    mkdir -p "$BASE_DIR"
    msg "下载脚本到: $SCRIPT_PATH"
    curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    msg "下载完成"
}

ensure_script_exists() {
    if [ ! -f "$SCRIPT_PATH" ]; then
        err "未找到主脚本: $SCRIPT_PATH"
        warn "请先执行“下载/更新 monitor_ip.sh”"
        return 1
    fi
}

configure_script() {
    title "配置 Telegram 和路径"

    load_config

    read -rp "请输入 TG_BOT_TOKEN [当前: ${TG_BOT_TOKEN:-未设置}]: " input_token
    read -rp "请输入 TG_CHAT_ID [当前: ${TG_CHAT_ID:-未设置}]: " input_chat
    read -rp "请输入 IP_LOG_FILE [当前: ${IP_LOG_FILE}]: " input_ip_log
    read -rp "请输入 IMAGE_DIR [当前: ${IMAGE_DIR}]: " input_image_dir
    read -rp "请输入 LOG_FILE [当前: ${LOG_FILE}]: " input_log_file

    [ -n "${input_token:-}" ] && TG_BOT_TOKEN="$input_token"
    [ -n "${input_chat:-}" ] && TG_CHAT_ID="$input_chat"
    [ -n "${input_ip_log:-}" ] && IP_LOG_FILE="$input_ip_log"
    [ -n "${input_image_dir:-}" ] && IMAGE_DIR="$input_image_dir"
    [ -n "${input_log_file:-}" ] && LOG_FILE="$input_log_file"

    if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
        err "TG_BOT_TOKEN 和 TG_CHAT_ID 不能为空"
        return 1
    fi

    mkdir -p "$(dirname "$IP_LOG_FILE")"
    mkdir -p "$IMAGE_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$IP_LOG_FILE" "$LOG_FILE"

    save_config

    ensure_script_exists || return 1

    sed -i "s|^TG_BOT_TOKEN=.*|TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"|" "$SCRIPT_PATH"
    sed -i "s|^TG_CHAT_ID=.*|TG_CHAT_ID=\"$TG_CHAT_ID\"|" "$SCRIPT_PATH"
    sed -i "s|^IP_LOG_FILE=.*|IP_LOG_FILE=\"$IP_LOG_FILE\"|" "$SCRIPT_PATH"
    sed -i "s|^IMAGE_DIR=.*|IMAGE_DIR=\"$IMAGE_DIR\"|" "$SCRIPT_PATH"
    sed -i "s|^LOG_FILE=.*|LOG_FILE=\"$LOG_FILE\"|" "$SCRIPT_PATH"

    msg "主脚本配置已写入"
}

cron_menu_help() {
    cat <<'EOF'
Cron 表达式示例：
  */5 * * * *      每 5 分钟
  */10 * * * *     每 10 分钟
  0 * * * *        每小时整点
  0 */6 * * *      每 6 小时
  0 8 * * *        每天 08:00
  0 8 * * 1        每周一 08:00
EOF
}

set_cron_job() {
    title "设置定时任务"

    load_config
    ensure_script_exists || return 1

    echo "当前 Cron 表达式: ${CRON_EXPR:-未设置}"
    cron_menu_help
    echo

    read -rp "请输入新的 Cron 表达式（直接回车保留当前）: " input_cron
    if [ -n "${input_cron:-}" ]; then
        CRON_EXPR="$input_cron"
    fi

    if [ -z "${CRON_EXPR:-}" ]; then
        err "Cron 表达式不能为空"
        return 1
    fi

    local cron_job="${CRON_EXPR} /bin/bash ${SCRIPT_PATH} >/dev/null 2>&1"

    local current_cron
    current_cron="$(crontab -l 2>/dev/null || true)"

    current_cron="$(echo "$current_cron" | sed "\|$SCRIPT_PATH|d")"

    {
        echo "$current_cron"
        echo "$cron_job"
    } | sed '/^[[:space:]]*$/d' | crontab -

    save_config
    msg "定时任务已设置:"
    echo "  $cron_job"
}

remove_cron_job() {
    title "删除定时任务"

    local current_cron
    current_cron="$(crontab -l 2>/dev/null || true)"

    if [ -z "$current_cron" ]; then
        warn "当前用户没有任何 crontab"
        return 0
    fi

    if echo "$current_cron" | grep -F "$SCRIPT_PATH" >/dev/null 2>&1; then
        echo "$current_cron" | sed "\|$SCRIPT_PATH|d" | crontab -
        msg "已删除与 monitor_ip.sh 相关的定时任务"
    else
        warn "未找到相关定时任务"
    fi
}

run_test() {
    title "手动运行测试"

    load_config
    ensure_script_exists || return 1

    msg "开始执行..."
    /bin/bash "$SCRIPT_PATH" || true
    msg "执行完成"

    if [ -f "$LOG_FILE" ]; then
        echo
        echo "最近日志："
        tail -n 20 "$LOG_FILE" || true
    fi
}

show_config() {
    title "当前配置"

    load_config

    echo "BASE_DIR      : $BASE_DIR"
    echo "SCRIPT_PATH   : $SCRIPT_PATH"
    echo "CONFIG_FILE   : $CONFIG_FILE"
    echo "TG_BOT_TOKEN  : ${TG_BOT_TOKEN:-未设置}"
    echo "TG_CHAT_ID    : ${TG_CHAT_ID:-未设置}"
    echo "IP_LOG_FILE   : ${IP_LOG_FILE:-未设置}"
    echo "IMAGE_DIR     : ${IMAGE_DIR:-未设置}"
    echo "LOG_FILE      : ${LOG_FILE:-未设置}"
    echo "CRON_EXPR     : ${CRON_EXPR:-未设置}"

    echo
    echo "当前 Crontab 中相关任务："
    crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH" || echo "未设置"
}

view_logs() {
    title "查看日志"

    load_config

    if [ ! -f "$LOG_FILE" ]; then
        warn "日志文件不存在: $LOG_FILE"
        return 0
    fi

    echo "1) 查看最后 50 行"
    echo "2) 实时跟踪 tail -f"
    read -rp "请选择 [1-2]: " log_choice

    case "${log_choice:-1}" in
        1)
            tail -n 50 "$LOG_FILE"
            ;;
        2)
            tail -f "$LOG_FILE"
            ;;
        *)
            warn "无效选项"
            ;;
    esac
}

uninstall_all() {
    title "卸载"

    echo "将执行以下操作："
    echo "- 删除 cron 定时任务"
    echo "- 删除安装目录: $BASE_DIR"
    echo "- 删除管理配置文件"
    echo
    read -rp "确认卸载？[y/N]: " confirm

    if [[ ! "${confirm:-N}" =~ ^[Yy]$ ]]; then
        warn "已取消卸载"
        return 0
    fi

    remove_cron_job || true

    if [ -d "$BASE_DIR" ]; then
        rm -rf "$BASE_DIR"
        msg "已删除目录: $BASE_DIR"
    fi

    msg "卸载完成"
    exit 0
}

show_menu() {
    clear || true
    echo -e "${BLUE}==============================${RESET}"
    echo -e "${BLUE}   IP Monitor  菜单管理工具${RESET}"
    echo -e "${BLUE}==============================${RESET}"
    echo " 1. 安装依赖"
    echo " 2. 安装IPMonitor"
    echo " 3. 配置 Telegram 和路径"
    echo " 4. 设置定时任务（自定义）"
    echo " 5. 删除定时任务"
    echo " 6. 手动运行测试"
    echo " 7. 查看当前配置"
    echo " 8. 查看日志"
    echo " 9. 卸载"
    echo " 0. 退出"
}

main() {
    load_config

    while true; do
        show_menu
        read -rp "请选择操作: " choice
        echo

        case "$choice" in
            1)
                install_dependencies
                pause
                ;;
            2)
                download_script
                pause
                ;;
            3)
                configure_script
                pause
                ;;
            4)
                set_cron_job
                pause
                ;;
            5)
                remove_cron_job
                pause
                ;;
            6)
                run_test
                pause
                ;;
            7)
                show_config
                pause
                ;;
            8)
                view_logs
                pause
                ;;
            9)
                uninstall_all
                pause
                ;;
            0)
                msg "已退出"
                exit 0
                ;;
            *)
                warn "无效选项，请重新输入"
                pause
                ;;
        esac
    done
}

main
