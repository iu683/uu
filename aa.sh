cat << 'EOF' > tools.sh
#!/bin/bash

# 定义颜色与格式
BIWhite='\033[1;97m'
BIRed='\033[1;91m'
BIGreen='\033[1;92m'
BIBlue='\033[1;94m'
BIYellow='\033[1;93m'
BIPurple='\033[1;95m'
Cyan='\033[0;36m'
Plain='\033[0m'

# 获取系统简单信息
get_sys_info() {
    IP=$(curl -s https://ipapi.co/ip)
    ARCH=$(uname -m)
    OS=$(hostnamectl | grep "Operating System" | cut -d ' ' -f3-)
}

# 绘制分割线
draw_line() {
    echo -e "${BIBlue}---------------------------------------------------------${Plain}"
}

show_menu() {
    get_sys_info
    clear
    echo -e "${BIPurple}┌───────────────────────────────────────────────────────┐${Plain}"
    echo -e "${BIPurple}│${Plain}                ${BIWhite}🚀 VPS 交互式管理工具箱${Plain}               ${BIPurple}│${Plain}"
    echo -e "${BIPurple}└───────────────────────────────────────────────────────┘${Plain}"
    echo -e "${Cyan} 系统架构: ${BIWhite}$ARCH${Plain}  | ${Cyan}操作系统: ${BIWhite}$OS${Plain}"
    echo -e "${Cyan} 公网地址: ${BIYellow}$IP${Plain}"
    draw_line
    
    echo -e "  ${BIGreen}1.${Plain} 更新系统        ${BIGreen}2.${Plain} 系统信息查询    ${BIGreen}3.${Plain} 系统清理"
    echo -e "  ${BIGreen}4.${Plain} 修改主机名      ${BIGreen}5.${Plain} 修改Root密码    ${BIGreen}6.${Plain} 修改SSH端口"
    echo -e "  ${BIGreen}7.${Plain} 开启BBR加速     ${BIGreen}8.${Plain} 设置SWAP内存    ${BIGreen}9.${Plain} 重装/重启"
    
    echo -e "${BIBlue} [ 网络与安全 ]${Plain}"
    echo -e "  ${BIYellow}10.${Plain} 切换v4/v6      ${BIYellow}11.${Plain} 开放所有端口    ${BIYellow}12.${Plain} DNS 设置"
    echo -e "  ${BIYellow}13.${Plain} 配置SSH密钥    ${BIYellow}14.${Plain} Fail2Ban防刷    ${BIYellow}15.${Plain} CF WARP"
    echo -e "  ${BIYellow}16.${Plain} EasyTier组网   ${BIYellow}17.${Plain} Akile DNS"
    
    echo -e "${BIBlue} [ 测试与监控 ]${Plain}"
    echo -e "  ${BIWhite}18.${Plain} 流媒体解锁      ${BIWhite}19.${Plain} 回程线路测试    ${BIWhite}20.${Plain} 节点测速"
    echo -e "  ${BIWhite}21.${Plain} 卸载探针        ${BIWhite}22.${Plain} 关闭V1指令执行"
    
    echo -e "${BIBlue} [ 代理与转发 ]${Plain}"
    echo -e "  ${BIPurple}23.${Plain} 3x-ui 面板     ${BIPurple}24.${Plain} Realm 转发      ${BIPurple}25.${Plain} 流量狗"
    echo -e "  ${BIPurple}26.${Plain} VLESS AIO       ${BIPurple}27.${Plain} SS-Xray-2go     ${BIPurple}28.${Plain} Emby反代"
    echo -e "  ${BIPurple}29.${Plain} DDNS 脚本"
    
    draw_line
    echo -e "  ${BIRed}0.${Plain} 退出脚本"
    echo ""
}

while true; do
    show_menu
    echo -n -e "${BIWhite}请输入指令 [0-29]: ${Plain}"
    read num
    case "$num" in
        1) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpsup.sh) ;;
        2) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpsx.sh) ;;
        3) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpsq.sh) ;;
        4) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/hostname.sh) ;;
        5) sudo passwd root ;;
        6) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpssshdk.sh) ;;
        7) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/BBR.sh) ;;
        8) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/vpsswap.sh) ;;
        9) echo -e "${BIRed}1. 重启  2. 重装系统 (DD)${Plain}"
           read -p "选择: " sub; [[ $sub == 1 ]] && sudo reboot || bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/VPSDD.sh) ;;
        10) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/qhwl.sh) ;;
        11) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/opendk.sh) ;;
        12) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/DNS.sh) ;;
        13) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/sshkey.sh) ;;
        14) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/Fail2Ban.sh) ;;
        15) wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh ;;
        16) bash <(curl -sL https://raw.githubusercontent.com/ceocok/c.cococ/refs/heads/main/easytier.sh) ;;
        17) wget -qO- https://raw.githubusercontent.com/akile-network/aktools/refs/heads/main/akdns.sh | bash ;;
        18) bash <(curl -L -s https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh) ;;
        19) curl https://raw.githubusercontent.com/ludashi2020/backtrace/main/install.sh -sSf | sh ;;
        20) bash <(curl -sL https://run.NodeQuality.com) ;;
        21) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/agent.sh) ;;
        22) sed -i 's/disable_command_execute: false/disable_command_execute: true/' /opt/nezha/agent/config.yml && systemctl restart nezha-agent ;;
        23) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/3xui.sh) ;;
        24) wget -qO- https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh | sudo bash -s install ;;
        25) wget -O port-traffic-dog.sh https://raw.githubusercontent.com/zywe03/realm-xwPF/main/port-traffic-dog.sh && chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh ;;
        26) wget -O vless-server.sh https://raw.githubusercontent.com/Zyx0rx/vless-all-in-one/main/vless-server.sh && chmod +x vless-server.sh && ./vless-server.sh ;;
        27) bash <(curl -Ls https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh) ;;
        28) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/Embyfd.sh) ;;
        29) bash <(wget -qO- https://raw.githubusercontent.com/mocchen/cssmeihua/mochen/shell/ddns.sh) ;;
        0) echo -e "${BIGreen}下次再见！${Plain}"; exit 0 ;;
        *) echo -e "${BIRed}无效输入，请重新选择${Plain}" ;;
    esac
    echo -e "${BIYellow}任务执行完毕。${Plain}"
    read -p "按回车键返回主菜单..."
done
EOF

chmod +x tools.sh
./tools.sh
