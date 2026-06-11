#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色

# 脚本路径定义
INSTALL_DIR="$HOME/gproxy-tool"
CONFIG_FILE="$HOME/.config/gproxy/config.env"

# GITHUB 代理自动轮询列表（最后一个为空代表直连）
GITHUB_PROXY=(
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
    ''
)

# 动态获取 tunnel.sh 路径
get_tunnel_path() {
    if [ -f "/usr/lib/gproxy/lib/tunnel.sh" ]; then
        echo "/usr/lib/gproxy/lib/tunnel.sh"
    elif [ -f "$INSTALL_DIR/lib/tunnel.sh" ]; then
        echo "$INSTALL_DIR/lib/tunnel.sh"
    else
        echo ""
    fi
}

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
    local tunnel_path=$(get_tunnel_path)
    if [ -n "$tunnel_path" ] && [ -f "$tunnel_path" ]; then
        grep -E '^LOCAL_PORT=' "$tunnel_path" | cut -d'=' -f2
    else
        echo "19527"
    fi
}

# 检查并自动安装 Git 依赖
check_git_dependency() {
    if ! command -v git &> /dev/null; then
        echo -e "${YELLOW}检测到系统未安装 Git，正在尝试自动安装...${NC}"
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y git
        elif command -v yum &> /dev/null; then
            sudo yum install -y git
        elif command -v apk &> /dev/null; then
            sudo apk add git
        else
            echo -e "${RED}错误: 未找到系统包管理器，请手动安装 git 后再运行。${NC}"
            return 1
        fi
    fi
    return 0
}

# 检查并导入私钥
handle_ssh_key_import() {
    echo -e "\n${YELLOW}正在检查免密私钥...${NC}"
    local key_path="$HOME/.ssh/vps_key"
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
}

# 菜单头部
show_header() {
    clear
    echo -e " ${GREEN}=======================================${NC}"
    echo -e " ${GREEN}  ◈ GProxy - SSH 隧道网络加速工具 ◈    ${NC}"
    echo -e " ${GREEN}=======================================${NC}"
    echo -e " ${GREEN}当前状态:${NC} $(check_status)"
    echo -e " ${GREEN}代理端口:${NC} ${YELLOW}($(get_current_port))${NC}"
    echo -e " ${GREEN}=======================================${NC}"
}

# 1. 生成SSH密钥并打通免密
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
        echo -e "${YELLOW}[OK] 私钥文件路径:/root/.ssh/vps_key${NC}"
        echo -e "\n${YELLOW}[步骤 3/3] 正在测试免密登录...${NC}"
        echo -e "${GREEN}尝试不输入密码登录海外 VPS 并执行 'echo 连接成功'：${NC}"
        ssh -p "$vps_port" -i "$HOME/.ssh/vps_key" -o PasswordAuthentication=no -o StrictHostKeyChecking=no "$vps_user@$vps_ip" "echo '🎉 [OK] 成功连接到海外 VPS，免密配置完美！'"
    else
        echo -e "${RED}[ERROR] 公钥复制失败，请检查网络或海外密码是否正确。${NC}"
    fi

    read -p "按回车键返回主菜单..." dummy
}

# 2. 全新下载并安装 (核心：多代理逐个尝试)
install_gproxy() {
    check_git_dependency || { read -p "按回车键返回主菜单..." dummy; return 1; }

    if [ -d "$INSTALL_DIR" ]; then
        echo -e "${RED}提示: 检测到目录 $INSTALL_DIR 已存在。${NC}"
        echo -e "${YELLOW}全新安装需要清空该目录。如果您想保留配置并更新，请选择菜单中的 [更新] 选项。${NC}"
        read -p "确定要清空该目录并重新安装吗？(y/n): " clean_confirm
        if [[ "$clean_confirm" =~ ^[Yy]$ ]]; then
            rm -rf "$INSTALL_DIR"
        else
            echo -e "${GREEN}已取消安装。${NC}"
            read -p "按回车键返回主菜单..." dummy
            return 0
        fi
    fi

    local success=false
    for url in "${GITHUB_PROXY[@]}"; do
        if [ -z "$url" ]; then
            echo -e "${YELLOW}正在尝试以 [直连模式] 克隆仓库...${NC}"
        else
            echo -e "${YELLOW}正在尝试通过代理 [ ${url} ] 克隆仓库...${NC}"
        fi

        if git clone "${url}https://github.com/xtianowner/gproxy-tool.git" "$INSTALL_DIR"; then
            success=true
            echo -e "${GREEN}✅ 克隆成功！${NC}"
            break
        else
            echo -e "${RED}❌ 当前节点连接失败，正在尝试下一个...${NC}"
            rm -rf "$INSTALL_DIR" 2>/dev/null
        fi
    done

    if [ "$success" = false ]; then
        echo -e "${RED}❌ 抱歉，尝试了所有 GitHub 代理节点以及直连，均无法连接服务器。请检查您的网络设置！${NC}"
        read -p "按回车键返回主菜单..." dummy
        return 1
    fi

    cd "$INSTALL_DIR" || exit
    handle_ssh_key_import

    echo -e "\n${YELLOW}开始执行安装程序...${NC}"
    sudo sh install.sh
    
    echo -e "${GREEN}🎉 GProxy 安装程序执行完毕！${NC}"
    echo -e "${GREEN}🎉 首次运行请选择 4 配置${NC}"
    read -p "按回车键返回主菜单..." dummy
}

# 3. 独立更新函数 (核心：多代理逐个尝试)
update_gproxy() {
    check_git_dependency || { read -p "按回车键返回主菜单..." dummy; return 1; }

    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${RED}错误: 未找到克隆目录 $INSTALL_DIR，无法进行更新，请先执行全新安装！${NC}"
        read -p "按回车键返回主菜单..." dummy
        return 1
    fi

    cd "$INSTALL_DIR" || exit
    local success=false

    for url in "${GITHUB_PROXY[@]}"; do
        if [ -z "$url" ]; then
            echo -e "${YELLOW}正在尝试以 [直连模式] 获取更新...${NC}"
        else
            echo -e "${YELLOW}正在尝试通过代理 [ ${url} ] 获取更新...${NC}"
        fi

        # 动态修改远程仓库地址，防止旧节点卡死
        git remote set-url origin "${url}https://github.com/xtianowner/gproxy-tool.git"
        
        # 尝试拉取更新（设置15秒超时防止原生 git pull 无限挂起）
        if git pull; then
            success=true
            echo -e "${GREEN}✅ 成功同步最新源码！${NC}"
            break
        else
            echo -e "${RED}❌ 当前节点更新失败，正在尝试下一个...${NC}"
        fi
    done

    if [ "$success" = false ]; then
        echo -e "${RED}❌ 抱歉，所有代理节点更新失败，请稍后再试。${NC}"
        read -p "按回车键返回主菜单..." dummy
        return 1
    fi

    echo -e "\n${YELLOW}正在重新执行安装脚本以应用更新...${NC}"
    sudo sh install.sh
    
    echo -e "${GREEN}🎉 GProxy 更新覆盖完毕！${NC}"
    read -p "按回车键返回主菜单..." dummy
}

# 4. 首次运行 / 测试配置
test_config() {
    if ! command -v gproxy &> /dev/null; then
        echo -e "${RED}错误: GProxy 未安装，请先执行安装！${NC}"
    else
        echo -e "${YELLOW}正在触发 GProxy 配置/测试命令...${NC}"
        gproxy curl -I https://www.google.com
    fi
    read -p "按回车键返回主菜单..." dummy
}

# 5. 重新配置服务器
reconfig_vps() {
    if ! command -v gproxy &> /dev/null; then
        echo -e "${RED}错误: GProxy 未安装！${NC}"
    else
        gproxy --config
    fi
    read -p "按回车键返回主菜单..." dummy
}

# 6. 修改本地代理端口
change_port() {
    local tunnel_path=$(get_tunnel_path)
    if [ -z "$tunnel_path" ]; then
        echo -e "${RED}错误: 未找到 tunnel.sh 脚本！请确保已执行安装。${NC}"
    else
        current_port=$(get_current_port)
        echo -e "${YELLOW}目标文件: $tunnel_path${NC}"
        echo -e "${YELLOW}当前本地代理端口为: ${GREEN}$current_port${NC}"
        read -p "请输入新的端口号 (1024-65353): " new_port
        if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65353 ]; then
            if [ -w "$tunnel_path" ]; then
                sed -i "s/^LOCAL_PORT=.*/LOCAL_PORT=$new_port/" "$tunnel_path"
            else
                sudo sed -i "s/^LOCAL_PORT=.*/LOCAL_PORT=$new_port/" "$tunnel_path"
            fi
            echo -e "${GREEN}端口已成功修改为 $new_port !${NC}"
        else
            echo -e "${RED}输入无效，未做任何修改。${NC}"
        fi
    fi
    read -p "按回车键返回主菜单..." dummy
}

# 7. 编辑配置文件
edit_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}即将打开 $CONFIG_FILE ...${NC}"
        nano "$CONFIG_FILE" || vim "$CONFIG_FILE" || vi "$CONFIG_FILE"
    else
        echo -e "${RED}配置文件不存在，请先运行一次配置。${NC}"
    fi
    read -p "按回车键返回主菜单..." dummy
}

# 8. 常用命令快捷查阅
show_usage() {
    clear
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}            GProxy 常用命令速查手册            ${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${YELLOW}1.Git加速   :${NC} gproxy git clone https://github.com/... "
    echo -e "${YELLOW}2.Docker加速:${NC} gproxy docker pull alpine:latest"
    echo -e "${YELLOW}3.Python pip:${NC} gproxy pip install torch"
    echo -e "${YELLOW}4.Node.js npm:${NC}gproxy npm install"
    echo -e "${YELLOW}5.系统更新    :${NC}gproxy bash -c \"apt update && apt install -y vim\""
    echo -e "${YELLOW}6.下载文件    :${NC}gproxy wget https://... 或 gproxy curl -O ..."
    echo -e "${YELLOW}7.安装脚本    :${NC}gproxy bash -c \"bash <(curl -sL https://...)\""
    echo -e "${GREEN}==============================================${NC}"
    read -p "按回车键返回主菜单..." dummy
}

# 9. 卸载
uninstall_gproxy() {
    echo -e "${RED}警告: 您确定要卸载 GProxy 吗？(y/n)${NC}"
    read -p "> " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$INSTALL_DIR/uninstall.sh" ]; then
            echo -e "${YELLOW}正在执行源码目录中的卸载程序...${NC}"
            sudo sh "$INSTALL_DIR/uninstall.sh"
        elif [ -f "/usr/lib/gproxy/uninstall.sh" ]; then
            echo -e "${YELLOW}正在执行系统目录中的卸载程序...${NC}"
            sudo sh /usr/lib/gproxy/uninstall.sh
        else
            echo -e "${YELLOW}未检测到标准的卸载脚本，尝试直接清理核心命令...${NC}"
            sudo rm -f /usr/local/bin/gproxy /usr/bin/gproxy 2>/dev/null
        fi

        if [ -d "$INSTALL_DIR" ]; then
            echo -e "${YELLOW}正在清理克隆目录: $INSTALL_DIR ...${NC}"
            rm -rf "$INSTALL_DIR"
            echo -e "${GREEN}源码目录清理完毕！${NC}"
        fi
        
        echo -e "${GREEN}卸载流程执行完毕！${NC}"
    else
        echo -e "${GREEN}已取消卸载。${NC}"
    fi
    read -p "按回车键返回主菜单..." dummy
}

# 主循环
while true; do
    show_header
    echo -e " ${GREEN}1. 生成SSH密钥并打通免密(可选)${NC}"
    echo -e " ${GREEN}2. 全新安装GProxy${NC}"
    echo -e " ${GREEN}3. 检查并同步更新GProxy${NC}"
    echo -e " ${GREEN}4. 首次配置/测试Google连通性${NC}"
    echo -e " ${GREEN}5. 重新配置服务器信息${NC}"
    echo -e " ${GREEN}6. 修改本地代理端口${NC}"
    echo -e " ${GREEN}7. 手动编辑配置文件(多VPS切换)${NC}"
    echo -e " ${GREEN}8. 查看常用命令使用示例${NC}"
    echo -e " ${GREEN}9. 卸载 GProxy${NC}"
    echo -e " ${GREEN}0. 退出${NC}"
    echo -e " ${GREEN}=======================================${NC}"
    read -p "$(echo -e "${GREEN}请输入数字选择操作: ${NC}")" choice

    case $choice in
        1) prepare_ssh_key ;;
        2) install_gproxy ;;
        3) update_gproxy ;;
        4) test_config ;;
        5) reconfig_vps ;;
        6) change_port ;;
        7) edit_config ;;
        8) show_usage ;;
        9) uninstall_gproxy ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效输入，请重新选择！${NC}"; sleep 1 ;;
    esac
done
