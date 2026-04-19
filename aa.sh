#!/bin/bash

# 颜色定义
BGreen='\033[1;32m'
BRed='\033[1;31m'
BYellow='\033[1;33m'
BBlue='\033[1;34m'
BPurple='\033[1;35m'
BCyan='\033[1;36m'
White='\033[1;37m'
BOrange='\033[1;38;5;208m'
NC='\033[0m'


# 脚本元数据
VERSION="1.2"
SCRIPT_PATH="/root/toolt.sh"
SCRIPT_URL="https://raw.githubusercontent.com/Polarisiu/tool/main/toolt.sh" # 替换为你脚本的实际URL

# --- 1. 更新功能 (优化版) ---
update_script() {
    echo -e "${BBlue}正在从服务器获取最新版本...${NC}"
    # 下载到临时文件，避免下载失败导致原脚本损坏
    curl -sL "$SCRIPT_URL" -o "${SCRIPT_PATH}.tmp"
    if [ $? -eq 0 ] && [ -s "${SCRIPT_PATH}.tmp" ]; then
        mv "${SCRIPT_PATH}.tmp" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        echo -e "${BGreen}更新完成! ${NC}"
        sleep 1
        # 关键：exec 会用新进程替换旧进程，用户无需重新输入 t
        exec bash "$SCRIPT_PATH"
    else
        echo -e "${BRed}更新失败，请检查网络连接。${NC}"
        rm -f "${SCRIPT_PATH}.tmp"
        any_key_to_continue
    fi
}

# --- 2. 卸载功能 (清理版) ---
uninstall_script() {
    echo -e "${BRed}正在卸载工具箱并清理快捷键...${NC}"
    # 清理所有快捷方式
    rm -f /usr/local/bin/t
    rm -f /usr/local/bin/T
    # 删除主脚本自身
    rm -f "$SCRIPT_PATH"
    echo -e "${BGreen}卸载完成! 期待再次见到您。${NC}"
    exit 0
}

# 按键继续函数
any_key_to_continue() {
    echo ""
    echo -e "${BYellow}操作已完成，按任意键继续...${NC}"
    read -n 1 -s -r -p ""
}

# 获取实时系统状态
get_sys_status() {
    MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
    MEM_PCT=$((MEM_USED * 100 / (MEM_TOTAL + 1))) # 防止除零
    DISK_TOTAL=$(df -h / | awk '/\// {print $2}' | tail -n 1)
    DISK_USED=$(df -h / | awk '/\// {print $3}' | tail -n 1)
    DISK_PCT=$(df -h / | awk '/\// {print $5}' | tail -n 1)
    CPU_PCT=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1"%"}')
    OS=$(grep -w "PRETTY_NAME" /etc/os-release | cut -d '"' -f2)
    UPTIME=$(uptime -p | sed 's/up //g; s/ weeks/周/g; s/ week/周/g; s/ days/天/g; s/ day/天/g; s/ hours/小时/g; s/ hour/小时/g; s/ minutes/分钟/g; s/ minute/分钟/g')
    ARCH=$(uname -m)
}

# 顶部看板
draw_banner() {
    clear
    echo -e "${BCyan}"
    echo "   _______ ____   ____  _      "
    echo "  |__   __/ __ \ / __ \| |     "
    echo "     | | | |  | | |  | | |     "
    echo "     | | | |  | | |  | | |     "
    echo "     | | | |__| | |__| | |____ "
    echo "     |_|  \____/ \____/|______|"
    echo -e "  ${BYellow}>> VPS 综合管理工具箱(快捷指令:T/t) <<${NC}"
    
    get_sys_status
    echo -e "${BCyan}┌──────────────────────────────────────────┐${NC}"
    echo -e "   系统状态：${BGreen}正常${NC}"                                    
    printf "   内存占用：%-38s \n" "${MEM_USED}M / ${MEM_TOTAL}M (${MEM_PCT}%)"
    printf "   磁盘占用：%-38s \n" "${DISK_USED} / ${DISK_TOTAL} (${DISK_PCT})"
    printf "   CPU 使用：%-38s \n" "${CPU_PCT}"
    echo -e "${BCyan}└──────────────────────────────────────────┘${NC}"
    echo -e " 💻 系统 : ${BYellow}$OS${NC}"
    echo -e " 🧩 架构 : ${BYellow}$ARCH${NC}"
    echo -e " 🚀 运行 : ${BYellow}$UPTIME${NC}"
    echo -e "${BCyan}────────────────────────────────────────────${NC}"
}

# 一级主菜单
main_menu() {
    draw_banner
    echo -e "${BYellow}1. 系统维护${NC}"
    echo -e "${BYellow}2. 网络安全${NC}"
    echo -e "${BYellow}3. 网络检测${NC}"
    echo -e "${BYellow}4. 网络代理${NC}"
    echo -e "${BYellow}5. 网络监控${NC}"
    echo -e "${BYellow}6. 玩具熊ʕ•ᴥ•ʔ${NC}"
    echo -e "${BGreen}8. 更新工具箱${NC}"
    echo -e "${BGreen}9. 卸载工具箱${NC}"
    echo -e "${BRed}0. 退出${NC}"
}

# 二级菜单处理逻辑
menu_system() {
    while true; do
        draw_banner
        echo -e "${BYellow}1. 更新系统${NC}"
        echo -e "${BYellow}2. 系统信息${NC}"
        echo -e "${BYellow}3. 系统清理${NC}"
        echo -e "${BYellow}4. 修改主机名${NC}"
        echo -e "${BYellow}5. 修改Root密码${NC}"
        echo -e "${BYellow}6. 修改SSH端口${NC}"
        echo -e "${BYellow}7. 设置SWAP内存${NC}"
        echo -e "${BYellow}8. 重装系统(DD)${NC}"
        echo -e "${BYellow}9. 系统重启${NC}"
        echo -e "${BRed}0. 返回主菜单${NC}"
        read -p "请输入选择: " sub
        case "$sub" in
            1) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpsup.sh) ; any_key_to_continue ;;
            2) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpsx.sh) ; any_key_to_continue ;;
            3) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpsq.sh) ; any_key_to_continue ;;
            4) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/hostname.sh) ; any_key_to_continue ;;
            5) sudo passwd root ; any_key_to_continue ;;
            6) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpssshdk.sh) ; any_key_to_continue ;;
            7) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpsswap.sh) ; any_key_to_continue ;;
            8) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/VPSDD.sh) ; any_key_to_continue ;;
            9) sudo reboot ;;
            0) break ;;
        esac
    done
}

menu_network() {
    while true; do
        draw_banner
        echo -e "${BYellow}1. 开启BBR加速"
        echo -e "${BYellow}2. 切换v4/v6"
        echo -e "${BYellow}3. 开放所有端口"
        echo -e "${BYellow}4. DNS 设置"
        echo -e "${BYellow}5. AkileDNS"
        echo -e "${BYellow}6. SSH密钥登录"
        echo -e "${BYellow}7. Fail2Ban防刷"
        echo -e "${BYellow}8. CF WARP"
        echo -e "${BYellow}9. EasyTier组网"
        echo -e "${BRed}0. 返回主菜单${NC}"
        read -p "请输入选择: " sub
        case "$sub" in
            1) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/BBR.sh) ; any_key_to_continue ;;
            2) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/qhwl.sh) ; any_key_to_continue ;;
            3) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/opendk.sh) ; any_key_to_continue ;;
            4) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/DNS.sh) ; any_key_to_continue ;;
            5) wget -qO- https://raw.githubusercontent.com/akile-network/aktools/refs/heads/main/akdns.sh | bash ; any_key_to_continue ;;
            6) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/sshkey.sh) ; any_key_to_continue ;;
            7) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/Fail2Ban.sh) ; any_key_to_continue ;;
            8) wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh ; any_key_to_continue ;;
            9) bash <(curl -sL https://raw.githubusercontent.com/ceocok/c.cococ/refs/heads/main/easytier.sh) ; any_key_to_continue ;;
            0) break ;;
        esac
    done
}

menu_test() {
    while true; do
        draw_banner
        echo -e "${BYellow}1. 流媒体解锁测试"
        echo -e "${BYellow}2. 回程线路测试"
        echo -e "${BYellow}3. NodeQuality"
        echo -e "${BRed}0. 返回主菜单${NC}"
        read -p "请输入选择: " sub
        case "$sub" in
            1) bash <(curl -L -s https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh) ; any_key_to_continue ;;
            2) curl https://raw.githubusercontent.com/ludashi2020/backtrace/main/install.sh -sSf | sh ; any_key_to_continue ;;
            3) bash <(curl -sL https://run.NodeQuality.com) ; any_key_to_continue ;;
            0) break ;;
        esac
    done
}

menu_proxy() {
    while true; do
        draw_banner
        echo -e "${BYellow}1. 3x-ui 面板"
        echo -e "${BYellow}2. Realm 转发"
        echo -e "${BYellow}3. SS-Xray-2go"
        echo -e "${BYellow}4. vless-all-in-one"
        echo -e "${BRed}0. 返回主菜单${NC}"
        read -p "请输入选择: " sub
        case "$sub" in
            1) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/3xui.sh) ; any_key_to_continue ;;
            2) wget -qO- https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh | sudo bash -s install ; any_key_to_continue ;;
            3) bash <(curl -Ls https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh) ; any_key_to_continue ;;
            4) wget -O vless-server.sh https://raw.githubusercontent.com/Zyx0rx/vless-all-in-one/main/vless-server.sh && chmod +x vless-server.sh && ./vless-server.sh ; any_key_to_continue ;;
            0) break ;;
        esac
    done
}

menu_jk() {
    while true; do
        draw_banner
        echo -e "${BYellow}1. 流量狗"
        echo -e "${BYellow}2. DDNS"
        echo -e "${BRed}0. 返回主菜单${NC}"
        read -p "请输入选择: " sub
        case "$sub" in
            1) wget -O port-traffic-dog.sh https://raw.githubusercontent.com/zywe03/realm-xwPF/main/port-traffic-dog.sh && chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh ; any_key_to_continue ;;
            2) bash <(wget -qO- https://raw.githubusercontent.com/mocchen/cssmeihua/mochen/shell/ddns.sh) ; any_key_to_continue ;;
            0) break ;;
        esac
    done
}

menu_app() {
    while true; do
        draw_banner
        echo -e "${BYellow}1. Emby反代"
        echo -e "${BYellow}2. 关闭哪吒V1SSH"
        echo -e "${BYellow}3. 卸载探针"
        echo -e "${BRed}0. 返回主菜单${NC}"
        read -p "请输入选择: " sub
        case "$sub" in
            1) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/Embyfd.sh) ; any_key_to_continue ;;
            2) sed -i 's/disable_command_execute: false/disable_command_execute: true/' /opt/nezha/agent/config.yml && systemctl restart nezha-agent ; any_key_to_continue ;;
            3) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/agent.sh) ; any_key_to_continue ;;
            0) break ;;
        esac
    done
}

# --- 程序入口 ---



while true; do
    main_menu
    read -p "请输入分类编号: " choice
    case "$choice" in
        1) menu_system ;;
        2) menu_network ;;
        3) menu_test ;;
        4) menu_proxy ;;
        5) menu_jk ;;
        6) menu_app ;;
        8) update_script ;;
        9) uninstall_script ;;
        0) exit 0 ;;
        *) echo -e "${BRed}无效输入${NC}" && sleep 1 ;;
    esac
done
