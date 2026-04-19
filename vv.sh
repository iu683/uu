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
    UPTIME=$(uptime -p | sed 's/up //')
    ARCH=$(uname -m)
}

# 顶部看板 (含彩色艺术字 Logo)
draw_banner() {
    clear
    # 打印炫彩 Logo
    echo -e "${BCyan}"
    echo "  __     ______  _____   _______ ____   ____  _      "
    echo "  \ \   / /  _ \|  __ \ /|__   __/ __ \ / __ \| |     "
    echo "   \ \_/ /| |_) | |__) |    | | | |  | | |  | | |     "
    echo "    \   / |  __/|  _  /     | | | |  | | |  | | |     "
    echo "     | |  | |   | | \ \     | | | |__| | |__| | |____ "
    echo "     |_|  |_|   |_|  \_\    |_|  \____/ \____/|______|"
    echo -e "                 ${BYellow}>> VPS 综合管理工具箱 <<${NC}"
    
    get_sys_status
    echo -e "${BCyan}┌──────────────────────────────────────────────────────┐${NC}"
    echo -e "${BCyan}│${NC}  系统状态：${BGreen}正常 ✔${NC}                                   ${BCyan}│${NC}"
    echo -e "${BCyan}│${NC}  📊 内存：${MEM_USED}M/${MEM_TOTAL}M (${MEM_PCT}%)                          ${BCyan}│${NC}"
    echo -e "${BCyan}│${NC}  💽 磁盘：${DISK_USED}/${DISK_TOTAL} (${DISK_PCT})                          ${BCyan}│${NC}"
    echo -e "${BCyan}│${NC}  ⚙ CPU ：${CPU_PCT}                                       ${BCyan}│${NC}"
    echo -e "${BCyan}└──────────────────────────────────────────────────────┘${NC}"
    echo -e " 💻 系统 : ${White}$OS${NC} (${ARCH})"
    echo -e " 🚀 在线 : ${White}$UPTIME${NC}"
    echo -e "${BCyan}────────────────────────────────────────────────────────${NC}"
}

# 一级主菜单
main_menu() {
    draw_banner
    echo -e " ${BBlue}【 主菜单分类 】${NC}"
    echo ""
    echo -e "  ${BGreen}1.${NC} 🛠  系统维护 (更新/清理/密码/端口/重启)"
    echo -e "  ${BYellow}2.${NC} 🛡  网络安全 (BBR/WARP/Fail2Ban/密钥)"
    echo -e "  ${BCyan}3.${NC} 🔍 测试监控 (解锁/测速/线路/探针)"
    echo -e "  ${BPurple}4.${NC} 🚀 应用转发 (3x-ui/Realm/VLESS/Emby)"
    echo ""
    echo -e "${BCyan}────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BRed}0.${NC} 退出脚本"
    echo ""
}

# --- 二级菜单函数 ---

menu_system() {
    while true; do
        draw_banner
        echo -e " ${BGreen}【 系统维护 】${NC}"
        printf "  %-25s %-25s\n" "1. 更新系统" "2. 系统信息查询"
        printf "  %-25s %-25s\n" "3. 系统清理" "4. 修改主机名"
        printf "  %-25s %-25s\n" "5. 修改Root密码" "6. 修改SSH端口"
        printf "  %-25s %-25s\n" "7. 设置SWAP内存" "8. 系统重启"
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
        echo -e " ${BYellow}【 网络安全 】${NC}"
        printf "  %-25s %-25s\n" "1. 开启BBR加速" "2. 切换v4/v6优先级"
        printf "  %-25s %-25s\n" "3. 开放所有端口" "4. DNS 设置"
        printf "  %-25s %-25s\n" "5. AkileDNS" "6. SSH密钥登录"
        printf "  %-25s %-25s\n" "7. Fail2Ban防刷" "8. CF WARP"
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
        echo -e " ${BCyan}【 测试监控 】${NC}"
        printf "  %-25s %-25s\n" "1. 流媒体解锁测试" "2. 回程线路测试"
        printf "  %-25s %-25s\n" "3. 节点质量测速" "4. 卸载哪吒探针"
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
        echo -e " ${BPurple}【 应用转发 】${NC}"
        printf "  %-25s %-25s\n" "1. 3x-ui 面板" "2. Realm 转发"
        printf "  %-25s %-25s\n" "3. 流量监控狗" "4. vless-all-in-one"
        printf "  %-25s %-25s\n" "5. SS-Xray-2go" "6. Emby反代配置"
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
