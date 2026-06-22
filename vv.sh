#!/bin/bash
# ========================================
# 宝塔面板 快捷管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

# 检查宝塔命令是否存在
check_cmd() {
    if ! command -v bt &>/dev/null; then
        echo -e "${RED}未检测到 bt 命令，请确认服务器已成功安装宝塔面板！若未安装，请选择选项 66${RESET}"
        return 1
    fi
    return 0
}

pause(){
    read -rp "按回车继续..."
}

menu(){
clear
echo -e "${GREEN}======================================${RESET}"
echo -e "${GREEN}     ◈  宝塔面板 开心版管理菜单  ◈    ${RESET}"
echo -e "${GREEN}======================================${RESET}"

# ----- 状态、版本、端口 强行直读 -----
if command -v bt &>/dev/null; then
    # 1. 服务状态检测
    if pgrep -f "BT-Panel" > /dev/null; then
        echo -e "${GREEN}服务状态  :${RESET} ${YELLOW}● 运行中${RESET}"
    else
        echo -e "${GREEN}服务状态  :${RESET} ${RED}○ 已停止${RESET}"
    fi

    # 2. 跨版本兼容强读版本号 (基于 11.8.0 真实内核提取)
    local ver_info=""
    
    # 优先从公共核心类库中提取最真实的硬编码版本号
    if [ -f "/www/server/panel/class/common.py" ]; then
        ver_info=$(grep -E "version\s*=\s*['\"]" /www/server/panel/class/common.py 2>/dev/null | awk -F"'" '{print $2}' | awk -F'"' '{print $1}' | tr -d ' \r\n')
    fi
    
    # 备用方案：读标准文件
    if [ -z "$ver_info" ] && [ -f "/www/server/panel/config/config.json" ]; then
        ver_info=$(grep -oE '"version": "[0-9.]+"' /www/server/panel/config/config.json 2>/dev/null | awk -F'"' '{print $4}' | head -n 1)
    fi
    
    # 最终洗白格式并输出
    if [ -n "$ver_info" ]; then
        [[ "$ver_info" =~ ^v ]] || ver_info="v$ver_info"
        echo -e "${GREEN}当前版本  :${RESET} ${YELLOW}${ver_info}${RESET}"
    else
        echo -e "${GREEN}当前版本  :${RESET} ${YELLOW}v11.8.0${RESET}"
    fi

    # 3. 读取端口
    local port=""
    if [ -f "/www/server/panel/data/port.pl" ]; then
        port=$(cat /www/server/panel/data/port.pl 2>/dev/null | tr -d ' \r\n')
    fi
    echo -e "${GREEN}面板端口  :${RESET} ${YELLOW}${port:-8888}${RESET}"
else
    echo -e "${GREEN}核心状态  :${RESET} ${RED}未安装${RESET}"
fi
echo -e "${GREEN}======================================${RESET}"

# ----- 菜单选项列表 (按功能逻辑顺序，完全对齐) -----
echo -e "${CYAN}[服务管理]${RESET}"
echo -e "${GREEN} 1.重启服务${RESET}           ${GREEN}|${RESET} ${GREEN} 2.停止服务${RESET}"
echo -e "${GREEN} 3.启动服务${RESET}           ${GREEN}|${RESET} ${GREEN} 4.重载面板${RESET}"
echo -e "${GREEN}--------------------------------------${RESET}"
echo -e "${CYAN}[账户与访问设置]${RESET}"
echo -e "${GREEN} 5.修改面板密码${RESET}       ${GREEN}|${RESET} ${GREEN} 6.修改面板用户名${RESET}"
echo -e "${GREEN} 7.修改MySQL密码${RESET}      ${GREEN}|${RESET} ${GREEN} 8.修改面板端口${RESET}"
echo -e "${GREEN}28.修改安全入口${RESET}       ${GREEN}|${RESET} ${GREEN}14.查看登录信息${RESET}"
echo -e "${GREEN}--------------------------------------${RESET}"
echo -e "${CYAN}[安全与限制解除]${RESET}"
echo -e "${GREEN}10.清除登录限制${RESET}       ${GREEN}|${RESET} ${GREEN}11.IP+UA双重验证${RESET}"
echo -e "${GREEN}12.取消域名绑定${RESET}       ${GREEN}|${RESET} ${GREEN}13.取消IP访问限制${RESET}"
echo -e "${GREEN}24.关闭两步验证${RESET}       ${GREEN}|${RESET} ${GREEN}26.关闭面板SSL(HTTPS)${RESET}"
echo -e "${GREEN}30.取消访问UA验证${RESET}     ${GREEN}|${RESET} ${GREEN}29.取消访问设备验证${RESET}"
echo -e "${GREEN}19.关闭BasicAuth认证${RESET}  ${GREEN}|${RESET} ${GREEN}23.关闭面板登录地区限制${RESET}"
echo -e "${GREEN}--------------------------------------${RESET}"
echo -e "${CYAN}[维护与清理修复]${RESET}"
echo -e "${GREEN} 9.清除面板缓存${RESET}       ${GREEN}|${RESET} ${GREEN}15.清理系统垃圾${RESET}"
echo -e "${GREEN}16.修复面板BUG${RESET}        ${GREEN}|${RESET} ${GREEN}22.查看错误日志${RESET}"
echo -e "${GREEN}36.磁盘清理工具${RESET}       ${GREEN}|${RESET} ${YELLOW}18.设置是否自动备份面板${RESET}"
echo -e "${YELLOW}35.btcli命令行工具${RESET}    ${GREEN}|${RESET} ${YELLOW}34.更新面板${RESET}"
echo -e "${GREEN}--------------------------------------${RESET}"
echo -e "${YELLOW}66.安装宝塔面板${RESET}       ${GREEN}|${RESET} ${RED}77.卸载宝塔面板${RESET}"
echo -e "${GREEN}--------------------------------------${RESET}"
echo -e "${GREEN} 0.退出${RESET}"

}

while true
do
    menu
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r num

    case "$num" in
    1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|22|23|24|26|28|29|30|35|36)
        if check_cmd; then
            echo -e "${YELLOW}正在执行 bt $num...${RESET}"
            bt $num
        fi
        pause
        ;;
    66)
        if command -v bt &>/dev/null; then
            echo -e "${YELLOW}检测到系统已安装宝塔面板，无需重复安装！${RESET}"
        else
            echo -e "${GREEN}正在安装开心版宝塔面板...${RESET}"
            if [ -f /usr/bin/curl ]; then
                curl -sSO https://io.bt.sb/install/install_panel.sh
            else
                wget -O install_panel.sh https://io.bt.sb/install/install_panel.sh
            fi
            bash install_panel.sh
        fi
        pause
        ;;
    77)
        if [ -f "/www/server/panel/bt-uninstall.sh" ] || command -v bt &>/dev/null; then
            echo -e "${RED}正在卸载宝塔面板...${RESET}"
            curl -o bt-uninstall.sh http://download.bt.cn/install/bt-uninstall.sh > /dev/null 2>&1
            chmod +x bt-uninstall.sh
            ./bt-uninstall.sh
            rm -f bt-uninstall.sh install_panel.sh
        else
            echo -e "${YELLOW}未检测到宝塔面板，无需卸载。${RESET}"
        fi
        pause
        ;;
    66)
        echo -e "${GREEN}正在安更新宝塔面板...${RESET}"
        curl https://io.bt.sb/install/update_panel.sh|bash
        pause
        ;;
    0) exit ;;
    *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
    esac
done
