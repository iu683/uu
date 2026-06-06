#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色

# 脚本路径与代理定义
GH_PROXY="https://v6.gh-proxy.org/"
INSTALL_DIR="$HOME/gproxy-tool"
CONFIG_FILE="$HOME/.config/gproxy/config.env"
TUNNEL_SCRIPT="/usr/lib/gproxy/lib/tunnel.sh"

# 检查是否安装了 gproxy
check_status() {
    if command -v gproxy &> /dev/null; then
        echo -e "${GREEN}[已安装]${NC}"
    else
        echo -e "${RED}[未安装]${NC}"
    fi
}

# 获取当前本地端口
get_current_port() {
    if [ -f "$TUNNEL_SCRIPT" ]; then
        grep -E '^LOCAL_PORT=' "$TUNNEL_SCRIPT" | cut -d'=' -f2
    else
        echo "19527"
    fi
}

# 菜单头部
show_header() {
    clear
    echo -e " ${GREEN}===============================${NC}"
    echo -e " ${GREEN}  GProxy -SSH 隧道网络加速工具  ${NC}"
    echo -e " ${GREEN}===============================${NC}"
    echo -e "${GREEN}当前状态:${NC} $(check_status)"
    echo -e "${GREEN}代理端口:${NC} ${YELLOW}$(get_current_port)${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "当前配置 VPS: ${BLUE}$(grep 'VPS_IP' $CONFIG_FILE 2>/dev/null | cut -d'=' -f2 || echo '已配置')${NC}"
    fi
    echo -e " ${GREEN}===============================${NC}"
}

# 安装准备（生成并配置 SSH 密钥）
prepare_ssh_key() {
    echo -e "${YELLOW}[步骤 1/3] 正在国内服务器生成 SSH 密钥对...${NC}"
    if [ -f "$HOME/.ssh/vps_key" ]; then
        echo -e "${PURPLE}提示: 发现已存在密钥文件 ~/.ssh/vps_key，跳过生成。${NC}"
    else
        ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/vps_key" -N ""
        echo -e "${GREEN}成功生成密钥: ~/.ssh/vps_key${NC}"
    fi

    echo -e "\n${YELLOW}[步骤 2/3] 将公钥复制到海外 VPS (请按提示操作)...${NC}"
    read -p "请输入海外 VPS 的 IP 地址: " vps_ip
    read -p "请输入海外 VPS 的 SSH 用户名 (默认 root): " vps_user
    vps_user=${vps_user:-root}
    read -p "请输入海外 VPS 的 SSH 端口 (默认 22): " vps_port
    vps_port=${vps_port:-22}

    echo -e "${BLUE}正在执行 ssh-copy-id，接下来请输入海外 VPS 的密码...${NC}"
    ssh-copy-id -p "$vps_port" -i "$HOME/.ssh/vps_key.pub" "$vps_user@$vps_ip"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[OK] 公钥复制成功！${NC}"
        echo -e "\n${YELLOW}[步骤 3/3] 正在测试免密登录...${NC}"
        echo -e "${BLUE}尝试不输入密码登录海外 VPS 并执行 'echo 连接成功'：${NC}"
        ssh -p "$vps_port" -i "$HOME/.ssh/vps_key" -o PasswordAuthentication=no -o StrictHostKeyChecking=no "$vps_user@$vps_ip" "echo '🎉 [OK] 成功连接到海外 VPS，免密配置完美！'"
    else
        echo -e "${RED}[ERROR] 公钥复制失败，请检查网络或海外密码是否正确。${NC}"
    fi

    read -p "按回车键返回主菜单..." dummy
}

# 1. 下载并安装 (已集成 gh-proxy 代理)
install_gproxy() {
    echo -e "${YELLOW}[1/3] 正在通过 gh-proxy 代理克隆仓库...${NC}"
    echo -e "${BLUE}代理节点: ${GH_PROXY}${NC}"
    
    if [ -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}目录 $INSTALL_DIR 已存在，正在尝试更新...${NC}"
        cd "$INSTALL_DIR" || exit
        # 移除可能存在的旧代理，并重新设置代理源更新
        git remote set-url origin "${GH_PROXY}https://github.com/xtianowner/gproxy-tool.git"
        git pull
    else
        # 使用 gh-proxy 代理前缀进行克隆
        git clone "${GH_PROXY}https://github.com/xtianowner/gproxy-tool.git" "$INSTALL_DIR"
    fi

    cd "$INSTALL_DIR" || exit

    echo -e "\n${YELLOW}[2/3] 正在检查免密私钥...${NC}"
    key_path="$HOME/.ssh/vps_key"
    if [ -f "$key_path" ]; then
        mkdir -p config
        cp "$key_path" config/
        echo -e "${GREEN}自动发现并复制私钥 $key_path 到 config/ 目录${NC}"
    else
        read -p "未找到默认私钥，请手动输入私钥路径 (直接回车跳过): " custom_key
        if [ -f "$custom_key" ]; then
            mkdir -p config
            cp "$custom_key" config/
            echo -e "${GREEN}成功复制私钥 $custom_key 到 config/ 目录${NC}"
        else
            echo -e "${YELLOW}提示: 未放入私钥，稍后可在交互配置中手动指定。${NC}"
        fi
    fi

    echo -e "\n${YELLOW}[3/3] 开始安装（需要 sudo 权限）...${NC}"
    sudo sh install.sh
    
    echo -e "${GREEN}安装程序执行完毕！${NC}"
    read -p "按回车键返回主菜单..." dummy
}

# 2. 首次运行 / 测试配置
test_config() {
    if ! command -v gproxy &> /dev/null; then
        echo -e "${RED}错误: GProxy 未安装，请先执行安装！${NC}"
    else
        echo -e "${YELLOW}正在触发 GProxy 配置/测试命令...${NC}"
        gproxy curl -I https://www.google.com
    fi
    read -p "按回车键返回主菜单..." dummy
}

# 3. 重新配置服务器
reconfig_vps() {
    if ! command -v gproxy &> /dev/null; then
        echo -e "${RED}错误: GProxy 未安装！${NC}"
    else
        gproxy --config
    fi
    read -p "按回车键返回主菜单..." dummy
}

# 4. 修改本地代理端口
change_port() {
    if [ ! -f "$TUNNEL_SCRIPT" ]; then
        echo -e "${RED}错误: 未找到 $TUNNEL_SCRIPT，请确认是否成功安装。${NC}"
    else
        current_port=$(get_current_port)
        echo -e "${YELLOW}当前本地代理端口为: ${GREEN}$current_port${NC}"
        read -p "请输入新的端口号 (1024-65353): " new_port
        if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65353 ]; then
            sudo sed -i "s/^LOCAL_PORT=.*/LOCAL_PORT=$new_port/" "$TUNNEL_SCRIPT"
            echo -e "${GREEN}端口已成功修改为 $new_port !${NC}"
        else
            echo -e "${RED}输入无效，未做任何修改。${NC}"
        fi
    fi
    read -p "按回车键返回主菜单..." dummy
}

# 5. 编辑配置文件
edit_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}即将打开 $CONFIG_FILE ...${NC}"
        nano "$CONFIG_FILE" || vim "$CONFIG_FILE" || vi "$CONFIG_FILE"
    else
        echo -e "${RED}配置文件不存在，请先运行一次配置。${NC}"
    fi
    read -p "按回车键返回主菜单..." dummy
}

# 6. 常用命令快捷查阅
show_usage() {
    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${GREEN}            GProxy 常用命令速查手册               ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${YELLOW}1. Git 加速:${NC}        gproxy git clone https://github.com/... "
    echo -e "${YELLOW}2. Docker 加速:${NC}     gproxy docker pull alpine:latest"
    echo -e "${YELLOW}3. Python pip:${NC}     gproxy pip install torch"
    echo -e "${YELLOW}4. Node.js npm:${NC}    gproxy npm install"
    echo -e "${YELLOW}5. 系统更新:${NC}        gproxy bash -c \"apt update && apt install -y vim\""
    echo -e "${YELLOW}6. 下载文件:${NC}        gproxy wget https://... 或 gproxy curl -O ..."
    echo -e "${YELLOW}7. 复合安装脚本:${NC}    gproxy bash -c \"bash <(curl -sL https://...)\""
    echo -e "${CYAN}--------------------------------------------------${NC}"
    read -p "按回车键返回主菜单..." dummy
}

# 7. 卸载
uninstall_gproxy() {
    echo -e "${RED}警告: 您确定要卸载 GProxy 吗？(y/n)${NC}"
    read -p "> " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -d "$INSTALL_DIR" ]; then
            sudo sh "$INSTALL_DIR/uninstall.sh"
        elif [ -f "/usr/lib/gproxy/uninstall.sh" ]; then
            sudo sh /usr/lib/gproxy/uninstall.sh
        else
            sh /path/to/gproxy-tool/uninstall.sh 2>/dev/null || echo -e "${RED}未找到卸载脚本，请手动执行卸载。${NC}"
        fi
    else
        echo -e "${GREEN}已取消卸载。${NC}"
    fi
    read -p "按回车键返回主菜单..." dummy
}

# 主循环
while true; do
    show_header
    echo -e " ${GREEN}1. 安装准备生成SSH密钥并打通免密${NC}"
    echo -e " ${GREEN}2. 安装GProxy${NC}"
    echo -e " ${GREEN}3. 首次配置/测试Google连通性${NC}"
    echo -e " ${GREEN}4. 重新配置服务器信息${NC}"
    echo -e " ${GREEN}5. 修改本地代理端口${NC}"
    echo -e " ${GREEN}6. 手动编辑配置文件(多VPS切换)${NC}"
    echo -e " ${GREEN}7. 查看常用命令使用示例"
    echo -e " ${GREEN}8. 卸载 GProxy${NC}"
    echo -e " ${GREEN}0. 退出${NC}"
    echo -e " ${GREEN}===============================${NC}"
    read -p "$(echo -e "${GREEN}请输入数字选择操作: ${NC}")" choice

    case $choice in
        1) prepare_ssh_key ;;
        2) install_gproxy ;;
        3) test_config ;;
        4) reconfig_vps ;;
        5) change_port ;;
        6) edit_config ;;
        7) show_usage ;;
        8) uninstall_gproxy ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效输入，请重新选择！${NC}"; sleep 1 ;;
    esac
done
