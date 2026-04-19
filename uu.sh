cat << 'EOF' > tools.sh
#!/bin/bash

# 颜色定义
BGreen='\033[1;32m'
BRed='\033[1;31m'
BYellow='\033[1;33m'
BBlue='\033[1;34m'
BPurple='\033[1;35m'
BCyan='\033[1;36m'
NC='\033[0m'

# 获取实时系统状态
get_sys_status() {
    # 内存使用率
    MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
    MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))

    # 磁盘使用率
    DISK_TOTAL=$(df -h / | awk '/\// {print $2}' | tail -n 1)
    DISK_USED=$(df -h / | awk '/\// {print $3}' | tail -n 1)
    DISK_PCT=$(df -h / | awk '/\// {print $5}' | tail -n 1)

    # CPU 使用率
    CPU_PCT=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1"%"}')

    # 系统基本信息
    OS=$(grep -w "PRETTY_NAME" /etc/os-release | cut -d '"' -f2)
    ARCH=$(uname -m)
    UPTIME=$(uptime -p | sed 's/up //')
}

show_menu() {
    get_sys_status
    clear
    echo -e "${BCyan}┌──────────────────────────────────────────────────────┐${NC}"
    echo -e "${BCyan}│${NC}  系统状态：${BGreen}正常 ✔${NC}                                   ${BCyan}│${NC}"
    echo -e "${BCyan}│${NC}  📊 内存：${MEM_USED}M/${MEM_TOTAL}M (${MEM_PCT}%)                          ${BCyan}│${NC}"
    echo -e "${BCyan}│${NC}  💽 磁盘：${DISK_USED}/${DISK_TOTAL} (${DISK_PCT})                          ${BCyan}│${NC}"
    echo -e "${BCyan}│${NC}  ⚙ CPU ：${CPU_PCT}                                       ${BCyan}│${NC}"
    echo -e "${BCyan}└──────────────────────────────────────────────────────┘${NC}"
    echo -e " 💻 系统 : ${BIWhite}$OS${NC}"
    echo -e " 🧩 架构 : ${BIWhite}$ARCH${NC}"
    echo -e " 🚀 在线 : ${BIWhite}$UPTIME${NC}"
    echo -e "${BCyan}────────────────────────────────────────────────────────${NC}"

    echo -e " ${BBlue}【 系统维护 】${NC}"
    printf "  %-25s %-25s\n" "${BGreen}01.${NC} 更新系统" "${BGreen}02.${NC} 系统信息查询"
    printf "  %-25s %-25s\n" "${BGreen}03.${NC} 系统清理" "${BGreen}04.${NC} 修改主机名"
    printf "  %-25s %-25s\n" "${BGreen}05.${NC} 修改Root密码" "${BGreen}06.${NC} 修改SSH端口"
    printf "  %-25s %-25s\n" "${BGreen}07.${NC} 开启BBR加速" "${BGreen}08.${NC} 设置SWAP内存"
    printf "  %-25s %-25s\n" "${BGreen}09.${NC} 系统重启" "${BGreen}10.${NC} 重装系统(DD)"

    echo -e "\n ${BBlue}【 网络安全 】${NC}"
    printf "  %-25s %-25s\n" "${BYellow}11.${NC} 切换v4/v6" "${BYellow}12.${NC} 开放所有端口"
    printf "  %-25s %-25s\n" "${BYellow}13.${NC} DNS 设置" "${BYellow}14.${NC} AkileDNS"
    printf "  %-25s %-25s\n" "${BYellow}15.${NC} SSH密钥登录" "${BYellow}16.${NC} Fail2Ban"
    printf "  %-25s %-25s\n" "${BYellow}17.${NC} CF WARP" "${BYellow}18.${NC} EasyTier组网"

    echo -e "\n ${BBlue}【 测试监控 】${NC}"
    printf "  %-25s %-25s\n" "${BCyan}19.${NC} 流媒体解锁" "${BCyan}20.${NC} 回程线路测试"
    printf "  %-25s %-25s\n" "${BCyan}21.${NC} 节点质量测速" "${BCyan}22.${NC} 卸载哪吒探针"
    echo -e "  ${BCyan}23.${NC} 关闭哪吒V1指令执行"

    echo -e "\n ${BBlue}【 应用转发 】${NC}"
    printf "  %-25s %-25s\n" "${BPurple}24.${NC} 3x-ui 面板" "${BPurple}25.${NC} Realm 转发"
    printf "  %-25s %-25s\n" "${BPurple}26.${NC} 流量监控狗" "${BPurple}27.${NC} vless-all-in-one"
    printf "  %-25s %-25s\n" "${BPurple}28.${NC} SS-Xray-2go" "${BPurple}29.${NC} Emby反代配置"
    echo -e "  ${BPurple}30.${NC} DDNS 脚本"

    echo -e "${BCyan}────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BRed}0.${NC} 退出脚本"
    echo ""
}

while true; do
    show_menu
    read -p " 请输入指令 [0-30]: " num
    case "$num" in
        1) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpsup.sh) ;;
        2) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpsx.sh) ;;
        3) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpsq.sh) ;;
        4) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/hostname.sh) ;;
        5) sudo passwd root ;;
        6) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpssshdk.sh) ;;
        7) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/BBR.sh) ;;
        8) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpsswap.sh) ;;
        9) sudo reboot ;;
        10) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/VPSDD.sh) ;;
        11) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/qhwl.sh) ;;
        12) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/opendk.sh) ;;
        13) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/DNS.sh) ;;
        14) wget -qO- https://raw.githubusercontent.com/akile-network/aktools/refs/heads/main/akdns.sh | bash ;;
        15) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/sshkey.sh) ;;
        16) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/Fail2Ban.sh) ;;
        17) wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh ;;
        18) bash <(curl -sL https://raw.githubusercontent.com/ceocok/c.cococ/refs/heads/main/easytier.sh) ;;
        19) bash <(curl -L -s https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh) ;;
        20) curl https://raw.githubusercontent.com/ludashi2020/backtrace/main/install.sh -sSf | sh ;;
        21) bash <(curl -sL https://run.NodeQuality.com) ;;
        22) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/agent.sh) ;;
        23) sed -i 's/disable_command_execute: false/disable_command_execute: true/' /opt/nezha/agent/config.yml && systemctl restart nezha-agent ;;
        24) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/3xui.sh) ;;
        25) wget -qO- https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh | sudo bash -s install ;;
        26) wget -O port-traffic-dog.sh https://raw.githubusercontent.com/zywe03/realm-xwPF/main/port-traffic-dog.sh && chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh ;;
        27) wget -O vless-server.sh https://raw.githubusercontent.com/Zyx0rx/vless-all-in-one/main/vless-server.sh && chmod +x vless-server.sh && ./vless-server.sh ;;
        28) bash <(curl -Ls https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh) ;;
        29) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/Embyfd.sh) ;;
        30) bash <(wget -qO- https://raw.githubusercontent.com/mocchen/cssmeihua/mochen/shell/ddns.sh) ;;
        0) exit 0 ;;
        *) echo -e "${BRed}无效输入${NC}" ;;
    esac
    read -p "按回车继续..."
done
EOF

chmod +x tools.sh
./tools.sh
