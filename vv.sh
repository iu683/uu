cat << 'EOF' > tools.sh
#!/bin/bash

# 颜色定义
BGreen='\033[1;32m'
BRed='\033[1;31m'
BYellow='\033[1;33m'
BBlue='\033[1;34m'
BPurple='\033[1;35m'
BCyan='\033[1;36m'
White='\033[1;37m'
NC='\033[0m'

# 获取实时系统状态
get_sys_status() {
    MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
    MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))
    DISK_TOTAL=$(df -h / | awk '/\// {print $2}' | tail -n 1)
    DISK_USED=$(df -h / | awk '/\// {print $3}' | tail -n 1)
    DISK_PCT=$(df -h / | awk '/\// {print $5}' | tail -n 1)
    CPU_PCT=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1"%"}')
    OS=$(grep -w "PRETTY_NAME" /etc/os-release | cut -d '"' -f2)
    # 在线时间转中文
    UPTIME=$(uptime -p | sed 's/up //g; s/ days/天/g; s/ day/天/g; s/ hours/小时/g; s/ hour/小时/g; s/ minutes/分钟/g; s/ minute/分钟/g')
    ARCH=$(uname -m)
}

# 顶部看板
draw_banner() {
    clear
    echo -e "${BCyan}"
    echo " _______ ____   ____  _      "
    echo "|__   __/ __ \ / __ \| |     "
    echo "   | | | |  | | |  | | |     "
    echo "   | | | |  | | |  | | |     "
    echo "   | | | |__| | |__| | |____ "
    echo "   |_|  \____/ \____/|______|"
    echo -e "  ${BYellow}>> VPS 综合管理工具箱 <<${NC}"
    
    get_sys_status
    echo -e "${BCyan}┌───────────────────────────┐${NC}"
    echo -e " 系统状态：${BGreen}正常${NC}"                                   
    printf " 内存占用：%-38s \n" "${MEM_USED}M / ${MEM_TOTAL}M (${MEM_PCT}%)"
    printf " 磁盘占用：%-38s \n" "${DISK_USED} / ${DISK_TOTAL} (${DISK_PCT})"
    printf " CPU 使用：%-38s \n" "${CPU_PCT}"
    echo -e "${BCyan}└───────────────────────────┘${NC}"
    echo -e " 💻 系统 : ${White}$OS${NC} (${ARCH})"
    echo -e " 🚀 在线 : ${White}$UPTIME${NC}"
    echo -e "${BCyan}────────────────────────────${NC}"
}

# 一级主菜单 - 纯文字版
main_menu() {
    draw_banner
    echo -e " ${BBlue}功能分类${NC}"
    echo ""
    echo -e "  ${BYellow}1. 系统维护${NC}"
    echo -e "  ${BYellow}2. 网络安全${NC}"
    echo -e "  ${BYellow}3. 测试监控${NC}"
    echo -e "  ${BYellow}4. 应用转发${NC}"
    echo ""
    echo -e "${BCyan}────────────────────────────${NC}"
    echo -e "  ${BRed}0. 退出${NC}"
    echo ""
}

# 二级菜单 - 单列竖排
menu_system() {
    while true; do
        draw_banner
        echo -e " ${BGreen}系统维护${NC}"
        echo -e "  1. 更新系统"
        echo -e "  2. 系统信息查询"
        echo -e "  3. 系统清理"
        echo -e "  4. 修改主机名"
        echo -e "  5. 修改Root密码"
        echo -e "  6. 修改SSH端口"
        echo -e "  7. 设置SWAP内存"
        echo -e "  8. 系统重启"
        echo -e "  9. 重装系统(DD)"
        echo -e "\n  ${BRed}0. 返回主菜单${NC}"
        read -p " 请输入选择: " sub
        case "$sub" in
            1) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpsup.sh) ;;
            2) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpsx.sh) ;;
            3) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpsq.sh) ;;
            4) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/hostname.sh) ;;
            5) sudo passwd root ;;
            6) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpssshdk.sh) ;;
            7) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpsswap.sh) ;;
            8) sudo reboot ;;
            9) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/VPSDD.sh) ;;
            0) break ;;
        esac
    done
}

menu_network() {
    while true; do
        draw_banner
        echo -e " ${BYellow}网络安全${NC}"
        echo -e "  1. 开启BBR加速"
        echo -e "  2. 切换v4/v6优先级"
        echo -e "  3. 开放所有端口"
        echo -e "  4. DNS 设置"
        echo -e "  5. AkileDNS"
        echo -e "  6. SSH密钥登录"
        echo -e "  7. Fail2Ban防刷"
        echo -e "  8. CF WARP"
        echo -e "  9. EasyTier组网"
        echo -e "\n  ${BRed}0. 返回主菜单${NC}"
        read -p " 请输入选择: " sub
        case "$sub" in
            1) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/BBR.sh) ;;
            2) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/qhwl.sh) ;;
            3) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/opendk.sh) ;;
            4) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/DNS.sh) ;;
            5) wget -qO- https://raw.githubusercontent.com/akile-network/aktools/refs/heads/main/akdns.sh | bash ;;
            6) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/sshkey.sh) ;;
            7) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/Fail2Ban.sh) ;;
            8) wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh ;;
            9) bash <(curl -sL https://raw.githubusercontent.com/ceocok/c.cococ/refs/heads/main/easytier.sh) ;;
            0) break ;;
        esac
    done
}

menu_test() {
    while true; do
        draw_banner
        echo -e " ${BCyan}测试监控${NC}"
        echo -e "  1. 流媒体解锁测试"
        echo -e "  2. 回程线路测试"
        echo -e "  3. 节点质量测速"
        echo -e "  4. 卸载哪吒探针"
        echo -e "  5. 关闭哪吒V1指令执行"
        echo -e "\n  ${BRed}0. 返回主菜单${NC}"
        read -p " 请输入选择: " sub
        case "$sub" in
            1) bash <(curl -L -s https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh) ;;
            2) curl https://raw.githubusercontent.com/ludashi2020/backtrace/main/install.sh -sSf | sh ;;
            3) bash <(curl -sL https://run.NodeQuality.com) ;;
            4) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/agent.sh) ;;
            5) sed -i 's/disable_command_execute: false/disable_command_execute: true/' /opt/nezha/agent/config.yml && systemctl restart nezha-agent ;;
            0) break ;;
        esac
    done
}

menu_app() {
    while true; do
        draw_banner
        echo -e " ${BPurple}应用转发${NC}"
        echo -e "  1. 3x-ui 面板"
        echo -e "  2. Realm 转发"
        echo -e "  3. 流量监控狗"
        echo -e "  4. vless-all-in-one"
        echo -e "  5. SS-Xray-2go"
        echo -e "  6. Emby反代配置"
        echo -e "  7. DDNS 脚本"
        echo -e "\n  ${BRed}0. 返回主菜单${NC}"
        read -p " 请输入选择: " sub
        case "$sub" in
            1) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/3xui.sh) ;;
            2) wget -qO- https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh | sudo bash -s install ;;
            3) wget -O port-traffic-dog.sh https://raw.githubusercontent.com/zywe03/realm-xwPF/main/port-traffic-dog.sh && chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh ;;
            4) wget -O vless-server.sh https://raw.githubusercontent.com/Zyx0rx/vless-all-in-one/main/vless-server.sh && chmod +x vless-server.sh && ./vless-server.sh ;;
            5) bash <(curl -Ls https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh) ;;
            6) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/Embyfd.sh) ;;
            7) bash <(wget -qO- https://raw.githubusercontent.com/mocchen/cssmeihua/mochen/shell/ddns.sh) ;;
            0) break ;;
        esac
    done
}

# --- 程序入口 ---
while true; do
    main_menu
    read -p " 请输入分类编号 [0-4]: " choice
    case "$choice" in
        1) menu_system ;;
        2) menu_network ;;
        3) menu_test ;;
        4) menu_app ;;
        0) exit 0 ;;
        *) echo -e "${BRed}无效输入${NC}" && sleep 1 ;;
    esac
done
EOF

chmod +x tools.sh
./tools.sh
