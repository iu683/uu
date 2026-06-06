#!/bin/bash
# ==========================================
# Windows ARM/一键重装系统高级脚本
# ==========================================

green="\033[32m"
red="\033[31m"
yellow="\033[33m"
purple="\033[1;35m"
re="\033[0m"

# 定义核心源与代理源
BASE_URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
PROXY_URL="https://v6.gh-proxy.org/https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
FINAL_URL=""

# 网络检查函数：默认直连，失败自动切换代理
check_network() {
    
    # 1. 尝试直连 (5秒超时)
    if curl -s --connect-timeout 5 --head "$BASE_URL" | head -n 1 | grep -qE "200|301|302"; then
        FINAL_URL="$BASE_URL"
    # 2. 直连失败，尝试代理
    else
        echo -e "${yellow}直连超时，正在尝试通过代理节点加载...${re}"
        if curl -s --connect-timeout 5 --head "$PROXY_URL" | head -n 1 | grep -qE "200|301|302"; then
            FINAL_URL="$PROXY_URL"
        else
            echo -e "${red}错误：直连与代理均无法访问，请检查网络设置。${re}"
            exit 1
        fi
    fi
}

# 统一下载重装核心脚本
download_script() {
    check_network
    echo -e "${yellow}正在下载重装核心...${re}"
    curl -so reinstall.sh "$FINAL_URL"
    
    if [ $? -ne 0 ] || [ ! -s reinstall.sh ]; then
        echo -e "${red}下载失败，尝试使用 wget 备用下载...${re}"
        wget -qO reinstall.sh "$FINAL_URL"
    fi

    if [ ! -s reinstall.sh ]; then
        echo -e "${red}错误：无法下载 reinstall.sh，请检查权限或网络！${re}"
        exit 1
    fi
    chmod +x reinstall.sh
}

# 方案 1：ISO 方式
install_via_iso() {
    clear
    echo -e "${purple}==========================================${re}"
    echo -e "${yellow} 正在执行：方案 1 - ISO 方式重装 Windows 11${re}"
    echo -e "${purple}==========================================${re}"
    echo -e "${green}提示：大概 1-2 分钟后提示 reboot，届时请转移到 cloudshell 观察。${re}"
    echo -e "${green}系统登录信息 -> 用户名: administrator  密码: 123@@@${re}"
    echo "------------------------------------------"
    
    read -p "确认要开始吗？(y/n): " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        download_script
        bash reinstall.sh windows \
          --image-name='Windows 11 enterprise ltsc 2024' \
          --iso 'https://drive.massgrave.dev/X23-81950_26100.1742.240906-0331.ge_release_svc_refresh_CLIENT_ENTERPRISES_OEM_A64FRE_en-us.iso'
    else
        main_menu
    fi
}

# 方案 2：DD 包方式
install_via_dd() {
    clear
    echo -e "${purple}==========================================${re}"
    echo -e "${yellow} 正在执行：方案 2 - DD 包方式重装 (推荐)${re}"
    echo -e "${purple}==========================================${re}"
    echo -e "${green}提示：大概 1-2 分钟后提示 reboot，届时请转移到 cloudshell 观察。${re}"
    echo -e "${green}系统登录信息 -> 用户名: administrator  密码: 123@@@${re}"
    echo "------------------------------------------"
    
    read -p "确认要开始吗？(y/n): " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        download_script
        bash reinstall.sh dd --img https://r2.hotdog.eu.org/win11-arm-with-pagefile-15g.xz
    else
        main_menu
    fi
}

# 主菜单
main_menu() {
    clear
    echo -e "${green}==========================================${re}"
    echo -e "${green}          Windows11 重装系统菜单          ${re}"
    echo -e "${green}==========================================${re}"
    echo -e "${green}1.${re} ISO 方式 (Windows 11 Enterprise LTSC 2024)"
    echo -e "${green}2.${re} DD 包方式 (Win11 ARM 15G) ${purple}[推荐]${re}"
    echo -e "${green}0.${re} 退出"

    read -p $'\033[32m请选择操作: \033[0m' choice
    case $choice in
        1)
            install_via_iso
            ;;
        2)
            install_via_dd
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${red}无效输入，请重新选择！${re}"
            sleep 15
            main_menu
            ;;
    esac
}

# 启动菜单
main_menu
