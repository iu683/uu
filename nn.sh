#!/bin/bash
# ========================================
# EDUKY-Monitor 一键管理菜单
# 基于官方 run.sh
# ========================================

APP_NAME="EDUKY-Monitor"
APP_DIR="/opt/$APP_NAME"
RUN_SH="$APP_DIR/run.sh"
SERVICE_FILE="/etc/systemd/system/eduky-monitor.service"
LOG_FILE="$APP_DIR/logs.log"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

menu() {
  clear
  echo -e "${GREEN}=== EDUKY-Monitor 管理菜单 ===${RESET}"
  echo -e "${GREEN}1) 安装${RESET}"
  echo -e "${GREEN}2) 前台开发模式${RESET}"
  echo -e "${GREEN}3) 后台生产模式启动${RESET}"
  echo -e "${GREEN}4) 查看后台状态${RESET}"
  echo -e "${GREEN}5) 查看日志${RESET}"
  echo -e "${GREEN}6) 停止后台服务${RESET}"
  echo -e "${GREEN}7) 启用开机自启${RESET}"
  echo -e "${GREEN}8) 禁用开机自启${RESET}"
  echo -e "${GREEN}9) 卸载${RESET}"
  echo -e "${GREEN}0) 退出${RESET}"
  read -rp "$(echo -e ${GREEN}请选择: ${RESET})" choice
  case $choice in
    1) install_app ;;
    2) dev_mode ;;
    3) prod_start ;;
    4) prod_status ;;
    5) view_logs ;;
    6) prod_stop ;;
    7) enable_autostart ;;
    8) disable_autostart ;;
    9) uninstall_app ;;
    0) exit 0 ;;
    *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
  esac
}

install_app() {
  mkdir -p "$APP_DIR"
  if [ ! -f "$RUN_SH" ]; then
    git clone https://github.com/eduky/EDUKY-Monitor.git "$APP_DIR"
  fi

  # 检查 python3-venv
  if ! python3 -m venv --help >/dev/null 2>&1; then
    echo -e "${RED}❌ 系统缺少 python3-venv，请先安装${RESET}"
    echo -e "${YELLOW}sudo apt update && sudo apt install python3-venv -y${RESET}"
    read -p "安装完成后按回车继续..."
  fi

  cd "$APP_DIR" || exit
  chmod +x run.sh
  ./run.sh install
 
  echo -e "${GREEN}✅ 安装完成${RESET}"
  echo -e "${YELLOW}🌐 Web UI 地址: http://localhost:5000${RESET}"
  echo -e "${YELLOW}默认账号: admin / admin123${RESET}"
  read -p "按回车返回菜单..."
  menu
}

dev_mode() {
  cd "$APP_DIR" || exit
  ./run.sh dev
  menu
}

prod_start() {
  cd "$APP_DIR" || exit
  ./run.sh prod start
  echo -e "${GREEN}✅ 后台启动成功${RESET}"
  read -p "按回车返回菜单..."
  menu
}

prod_status() {
  cd "$APP_DIR" || exit
  ./run.sh prod status
  read -p "按回车返回菜单..."
  menu
}

view_logs() {
  cd "$APP_DIR" || exit
  ./run.sh logs
  read -p "按回车返回菜单..."
  menu
}

prod_stop() {
  cd "$APP_DIR" || exit
  ./run.sh prod stop
  echo -e "${GREEN}✅ 已停止后台服务${RESET}"
  read -p "按回车返回菜单..."
  menu
}

enable_autostart() {
  sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=EDUKY-Monitor Service
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/run.sh prod start
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable eduky-monitor
  sudo systemctl start eduky-monitor
  echo -e "${GREEN}✅ 已启用开机自启并启动服务${RESET}"
  read -p "按回车返回菜单..."
  menu
}

disable_autostart() {
  sudo systemctl stop eduky-monitor
  sudo systemctl disable eduky-monitor
  echo -e "${GREEN}✅ 已禁用开机自启并停止服务${RESET}"
  read -p "按回车返回菜单..."
  menu
}

uninstall_app() {
  read -rp "确定要卸载 EDUKY-Monitor 吗？此操作不可逆 (y/N): " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    prod_stop
    sudo rm -f "$SERVICE_FILE"
    rm -rf "$APP_DIR"
    sudo systemctl daemon-reload
    echo -e "${GREEN}✅ 已卸载 EDUKY-Monitor${RESET}"
  else
    echo -e "${YELLOW}取消卸载${RESET}"
  fi
  read -p "按回车返回菜单..."
  menu
}

menu
