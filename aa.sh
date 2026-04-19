#!/bin/bash
# ========================================
# DrissionPage 管理脚本（绿色菜单版）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="DrissionPage"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}请用 root 运行${RESET}"
        exit 1
    fi
}

install_dp() {
    echo -e "${YELLOW}▶ 安装 $APP_NAME${RESET}"

    apt update

    echo -e "${GREEN}▶ 安装 Python${RESET}"
    apt install -y python3 python3-pip

    echo -e "${GREEN}▶ 安装 DrissionPage${RESET}"
    pip3 install -U DrissionPage

    echo -e "${GREEN}▶ 安装 Chromium${RESET}"
    apt install -y chromium || apt install -y chromium-browser

    echo -e "${GREEN}▶ 安装依赖${RESET}"
    apt install -y fonts-liberation libnss3 libatk-bridge2.0-0 libx11-xcb1 \
        libxcb-dri3-0 libxcomposite1 libxdamage1 libxrandr2 libgbm1 libasound2

    echo -e "${GREEN}✔ 安装完成${RESET}"
}

test_dp() {
    echo -e "${YELLOW}▶ 测试 $APP_NAME${RESET}"

    cat > /tmp/test_dp.py <<EOF
from DrissionPage import ChromiumPage, ChromiumOptions

co = ChromiumOptions()
co.headless(True)
co.set_argument('--no-sandbox')
co.set_argument('--disable-dev-shm-usage')

page = ChromiumPage(co)
page.get('https://www.baidu.com')

print("标题:", page.title)
EOF

    python3 /tmp/test_dp.py || {
        echo -e "${RED}✘ 测试失败${RESET}"
        return
    }

    echo -e "${GREEN}✔ 测试成功${RESET}"
}

uninstall_dp() {
    echo -e "${YELLOW}▶ 卸载 $APP_NAME${RESET}"

    pip3 uninstall -y DrissionPage || true

    echo -e "${GREEN}▶ 删除 Chromium${RESET}"
    apt remove -y chromium chromium-browser || true
    apt autoremove -y

    echo -e "${GREEN}✔ 卸载完成${RESET}"
}

menu() {
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     DrissionPage 菜单管理       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装${RESET}"
    echo -e "${GREEN}2. 测试${RESET}"
    echo -e "${GREEN}3. 卸载${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    read -r -p $'\033[32m请输入选项: \033[0m' choice

    case $choice in
        1) install_dp ;;
        2) test_dp ;;
        3) uninstall_dp ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

check_root

while true; do
    menu
    echo
    read -p "按回车继续..."
done
