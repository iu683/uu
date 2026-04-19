cat << 'EOF' > tools.sh
#!/bin/bash

# 颜色定义
BGreen='\033[1;32m'
BRed='\033[1;31m'
BYellow='\033[1;33m'
BBlue='\033[1;34m'
BPurple='\033[1;35m'
BCyan='\033[1;36m'
NC='\033[0m' # No Color

get_info() {
    IP=$(curl -s --max-time 2 https://api64.ipify.org || echo "未知")
    OS=$(hostnamectl | grep "Operating System" | cut -d ' ' -f3-)
    ARCH=$(uname -m)
}

show_menu() {
    get_info
    clear
    echo -e "${BCyan}┌──────────────────────────────────────────────────────┐${NC}"
    echo -e "${BCyan}│${NC}             ${BYellow}🚀 VPS 极致管理工具箱${NC}             ${BCyan}│${NC}"
    echo -e "${BCyan}├──────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${BGreen}机器信息:${NC}  ${NC}$OS | $ARCH | $IP${NC}"
    echo -e "${BCyan}└──────────────────────────────────────────────────────┘${NC}"

    echo -e " ${BBlue}【 系统维护 】${NC}"
    echo -e "  ${BGreen}01.${NC} 更新系统         ${BGreen}02.${NC} 系统信息查询"
    echo -e "  ${BGreen}03.${NC} 系统清理         ${BGreen}04.${NC} 修改主机名"
    echo -e "  ${BGreen}05.${NC} 修改Root密码     ${BGreen}06.${NC} 修改SSH端口"
    echo -e "  ${BGreen}07.${NC} 开启BBR加速      ${BGreen}08.${NC} 设置SWAP内存"
    echo -e "  ${BGreen}09.${NC} 系统重启         ${BGreen}10.${NC} 重装系统(DD)"

    echo -e "\n ${BBlue}【 网络安全 】${NC}"
    echo -e "  ${BYellow}11.${NC} 切换v4/v6        ${BYellow}12.${NC} 开放所有端口"
    echo -e "  ${BYellow}13.${NC} DNS 设置         ${BYellow}14.${NC} Akile DNS"
    echo -e "  ${BYellow}15.${NC} SSH密钥登录      ${BYellow}16.${NC} Fail2Ban防刷"
    echo -e "  ${BYellow}17.${NC} CF WARP          ${BYellow}18.${NC} EasyTier组网"

    echo -e "\n ${BBlue}【 测试监控 】${NC}"
    echo -e "  ${BCyan}19.${NC} 流媒体解锁       ${BCyan}20.${NC} 回程线路测试"
    echo -e "  ${BCyan}21.${NC} 节点质量测速     ${BCyan}22.${NC} 卸载哪吒探针"
    echo -e "  ${BCyan}23.${NC} 关闭哪吒V1指令"

    echo -e "\n ${BBlue}【 应用转发 】${NC}"
    echo -e "  ${BPurple}24.${NC} 3x-ui 面板       ${BPurple}25.${NC} Realm 转发"
    echo -e "  ${BPurple}26.${NC} 流量监控(狗)     ${BPurple}27.${NC} VLESS AIO"
    echo -e "  ${BPurple}28.${NC} SS-Xray-2go      ${BPurple}29.${NC} Emby反代配置"
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
