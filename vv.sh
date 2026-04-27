#!/usr/bin/env bash
# ==========================================
# Remnawave 一键管理脚本
# ==========================================

set -uo pipefail

INSTALL_DIR="/opt/remnawave"

GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
CYAN="\033[1;36m"
RESET="\033[0m"

info() { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()  { echo -e "${RED}[ERR ]${RESET} $*"; }

pause() { read -rp "$(echo -e ${CYAN}按回车继续...${RESET})"; }

# ==============================
# 安装
# ==============================
install_remnawave() {

    if [[ -d "$INSTALL_DIR" ]]; then
        warn "检测到已安装，跳过安装"
        return
    fi

    info "开始安装 Remnawave..."

    
    bash <(curl -sL https://raw.githubusercontent.com/iu683/uu/main/aa.sh)


    info "安装完成"
}

# ==============================
# 启动
# ==============================
start_service() {
    cd "$INSTALL_DIR" || { err "未安装"; return; }
    docker compose up -d
    info "已启动"
}

# ==============================
# 停止
# ==============================
stop_service() {
    cd "$INSTALL_DIR" || { err "未安装"; return; }
    docker compose down
    info "已停止"
}

# ==============================
# 重启
# ==============================
restart_service() {
    cd "$INSTALL_DIR" || { err "未安装"; return; }
    docker compose restart
    info "已重启"
}

# ==============================
# 日志
# ==============================
logs_service() {
    cd "$INSTALL_DIR" || { err "未安装"; return; }
    docker compose logs -f
}

# ==============================
# 状态
# ==============================
status_service() {
    cd "$INSTALL_DIR" || { err "未安装"; return; }
    docker compose ps
}

# ==============================
# 更新
# ==============================
update_service() {
    cd "$INSTALL_DIR" || { err "未安装"; return; }
    docker compose pull
    docker compose up -d
    info "更新完成"
}

# ==============================
# 卸载
# ==============================
uninstall_remnawave() {

    warn "将删除所有数据！"
    read -rp "确认卸载？(y/N): " confirm

    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    cd "$INSTALL_DIR" 2>/dev/null && docker compose down -v

    rm -rf "$INSTALL_DIR"
    rm -f /etc/nginx/sites-enabled/remnawave.conf
    rm -f /etc/nginx/sites-available/remnawave.conf

    systemctl restart nginx 2>/dev/null

    info "已彻底卸载"
}

# ==============================
# 菜单
# ==============================
menu() {
    clear
    echo -e "${GREEN}===Remnawave 管理菜单===${RESET}"
    echo -e "${CYAN}1.安装${RESET}"
    echo -e "${CYAN}2.启动${RESET}"
    echo -e "${CYAN}3.停止${RESET}"
    echo -e "${CYAN}4.重启${RESET}"
    echo -e "${CYAN}5.日志${RESET}"
    echo -e "${CYAN}6.状态${RESET}"
    echo -e "${CYAN}7.更新${RESET}"
    echo -e "${CYAN}8.卸载${RESET}"
    echo -e "${CYAN}0.退出${RESET}"
}

while true; do
    menu
    read -rp "$(echo -e ${CYAN}请选择操作: ${RESET})" num

    case "$num" in
        1) install_remnawave ;;
        2) start_service ;;
        3) stop_service ;;
        4) restart_service ;;
        5) logs_service ;;
        6) status_service ;;
        7) update_service ;;
        8) uninstall_remnawave ;;
        0) exit 0 ;;
        *) warn "无效选项" ;;
    esac

    pause
done
