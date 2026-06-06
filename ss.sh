#!/bin/bash
# =========================================================
# 3X-UI 一键部署脚本 (Alpine Linux)
# =========================================================

green="\033[32m"
red="\033[31m"
yellow="\033[33m"
plain="\033[0m"

show_menu() {
    clear
    echo -e "${green}=== 3X-UI管理面板 ===${plain}"
    echo -e " ${green}1.安装${plain}"
    echo -e " ${green}2.卸载${plain}"
    echo -e " ${green}3.启动${plain}"
    echo -e " ${green}4.停止${plain}"
    echo -e " ${green}5.重启${plain}"
    echo -e " ${green}0.退出${plain}"
}

install_3xui() {
    echo -e "${yellow}正在更新依赖并安装 3X-UI...${plain}"
    apk update && apk add --no-cache curl bash gzip openssl
    
    # 执行官方/第三方安装脚本
    bash <(curl -Ls https://raw.githubusercontent.com/StarVM-OpenSource/3x-ui-Apline/refs/heads/main/install.sh)
    
    # ================= 修改部分 =================
    echo -e "${yellow}检测到安装完成，正在自动重启服务以应用配置...${plain}"
    sleep 2  # 稍微等待 2 秒确保上一步安装后的进程完全释放
    restart_3xui
    echo -e "${green}服务已成功重启，现在可以正常访问了！${plain}"
    # ============================================
}

uninstall_3xui() {
    echo -e "${red}正在卸载 3x-ui...${plain}"
    x-ui uninstall
}

start_3xui() {
    x-ui start
}

stop_3xui() {
    x-ui stop
}

restart_3xui() {
    x-ui restart
}

while true; do
    show_menu
    read -p "$(echo -e ${green}请选择:${plain}) " choice
    case "$choice" in
        1) install_3xui ;;
        2) uninstall_3xui ;;
        3) start_3xui ;;
        4) stop_3xui ;;
        5) restart_3xui ;;
        0) exit 0 ;;
        *) echo -e "${red}无效选择${plain}" ;;
    esac
    read -p "$(echo -e ${green}按回车返回菜单...${plain})"
done
