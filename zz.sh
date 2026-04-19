#!/bin/bash
# ========================================
# DrissionPage VPS 专用全自动安装脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="DrissionPage"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}✘ 请使用 root 用户或 sudo 运行此脚本${RESET}"
        exit 1
    fi
}

install_dp() {
    echo -e "${YELLOW}▶ 正在更新系统软件包...${RESET}"
    apt update -y

    echo -e "${GREEN}▶ 正在安装 Python3 和 Pip...${RESET}"
    apt install -y python3 python3-pip python3-venv

    echo -e "${GREEN}▶ 正在安装 DrissionPage...${RESET}"
    # 兼容新版系统（如 Ubuntu 24.04）的外部管理包限制
    pip3 install -U DrissionPage --break-system-packages || pip3 install -U DrissionPage

    echo -e "${GREEN}▶ 正在安装 Chromium 浏览器...${RESET}"
    apt install -y chromium-browser || apt install -y chromium

    echo -e "${GREEN}▶ 正在安装必要的底层依赖库 (防止报错)...${RESET}"
    
    # 基础依赖列表
    deps="libnss3 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 \
          libxcomposite1 libxdamage1 libxrandr2 libgbm1 libpango-1.0-0 \
          libcairo2 libxshmfence1 libglu1-mesa fonts-liberation libnss3-dev xvfb"

    # 执行安装
    apt install -y $deps

    # 针对 libasound2 的特殊兼容性处理
    echo -e "${YELLOW}▶ 正在处理音频依赖兼容性...${RESET}"
    apt install -y libasound2 || apt install -y libasound2t64

    # 针对 libatk1.0-0 的特殊兼容性处理
    apt install -y libatk1.0-0 || apt install -y libatk1.0-0t64
    
    echo -e "${GREEN}✔ 依赖库安装尝试完成${RESET}"

    echo -e "${GREEN}✔ 安装环境配置完成！${RESET}"
}

test_dp() {
    echo -e "${YELLOW}▶ 正在启动自动化测试...${RESET}"

    # 创建测试脚本
    cat > /tmp/test_dp.py <<EOF
from DrissionPage import ChromiumPage, ChromiumOptions
import os
import sys

try:
    co = ChromiumOptions()
    co.headless(True)  # VPS 必须开启无头模式
    co.set_argument('--no-sandbox')  # root 用户必须开启
    co.set_argument('--disable-dev-shm-usage')
    co.set_argument('--disable-gpu')

    # 尝试自动定位 Chromium 路径
    paths = ['/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome']
    for p in paths:
        if os.path.exists(p):
            co.set_browser_path(p)
            break

    print(f"正在启动浏览器...")
    page = ChromiumPage(co)
    page.get('https://www.baidu.com')
    
    title = page.title
    print(f"成功获取页面标题: {title}")
    
    if "百度" in title:
        print("测试结果: 成功")
    else:
        print("测试结果: 异常 (获取到的标题不正确)")
    
    page.quit()
except Exception as e:
    print(f"测试过程中出现错误: {e}")
    sys.exit(1)
EOF

    python3 /tmp/test_dp.py --break-system-packages 2>/dev/null || python3 /tmp/test_dp.py
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✔ DrissionPage 测试通过！${RESET}"
    else
        echo -e "${RED}✘ 测试失败，请检查上方报错信息${RESET}"
    fi
}

uninstall_dp() {
    echo -e "${YELLOW}▶ 正在卸载 $APP_NAME 及相关组件...${RESET}"

    # 1. 强制杀死所有相关进程（防止文件占用导致卸载失败）
    echo -e "${GREEN}▶ 停止所有运行中的 Chromium 进程...${RESET}"
    pkill -9 -f chromium 2>/dev/null
    pkill -9 -f DrissionPage 2>/dev/null

    # 2. 卸载 Python 库（包含依赖包）
    echo -e "${GREEN}▶ 正在卸载 Python 库...${RESET}"
    pip3 uninstall -y DrissionPage DownloadKit DataRecorder --break-system-packages 2>/dev/null || \
    pip3 uninstall -y DrissionPage DownloadKit DataRecorder 2>/dev/null

    # 3. 卸载 APT 版本的 Chromium
    echo -e "${GREEN}▶ 正在清理 APT 软件包...${RESET}"
    apt purge -y chromium-browser chromium chromium-common 2>/dev/null
    apt autoremove -y

    # 4. 彻底清理 Snap 版本的 Chromium (Ubuntu 默认安装方式)
    if command -v snap >/dev/null; then
        echo -e "${GREEN}▶ 正在清理 Snap 软件包...${RESET}"
        snap remove --purge chromium 2>/dev/null
    fi

    # 5. 清理残留的配置文件夹和缓存
    echo -e "${GREEN}▶ 正在清理残留配置和临时文件...${RESET}"
    rm -rf /usr/bin/chromium
    rm -rf /usr/bin/chromium-browser
    rm -rf ~/.config/chromium
    rm -rf ~/.cache/chromium
    rm -rf /tmp/.com.google.Chrome.*
    rm -rf /tmp/test_dp.py

    echo -e "${GREEN}✔ 卸载及深度清理完成！${RESET}"
}

menu() {
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    DrissionPage 部署管理    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装部署${RESET}"
    echo -e "${GREEN}2. 运行环境测试${RESET}"
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

# 脚本入口
check_root

while true; do
    menu
    echo
    read -p "按回车继续..." confirm
    clear
done
