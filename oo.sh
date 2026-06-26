#!/bin/bash

# 颜色定义
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
BLUE='\033[34m'
PURPLE='\033[35m'
PLAIN='\033[0m'

# 提示信息
INFO="[${GREEN}INFO${PLAIN}]"
WARN="[${YELLOW}WARN${PLAIN}]"
ERROR="[${RED}ERROR${PLAIN}]"

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${ERROR} 请使用 root 用户运行！"
    exit 1
fi

# 核心安装函数
install_xbctl() {
    echo -e "\n${BLUE}========== 开始安装 xboard-node ==========${PLAIN}"
    
    # 1. 选择模式
    read -p "请选择安装模式 [1) Node 模式 | 2) Machine 模式, 默认1]: " install_mode_choice
    if [ "$install_mode_choice" = "2" ]; then
        INSTALL_MODE="machine"
        ID_TYPE="machine-id"
    else
        INSTALL_MODE="node"
        ID_TYPE="node-id"
    fi

    # 2. 输入面板 URL
    read -p "请输入面板 URL (例如 https://panel.example.com): " ins_url
    if [ -z "$ins_url" ]; then
        echo -e "${ERROR} 面板 URL 不能为空！"
        return 1
    fi

    # 3. 输入 Token
    read -p "请输入通讯 Token: " ins_token
    if [ -z "$ins_token" ]; then
        echo -e "${ERROR} Token 不能为空！"
        return 1
    fi

    # 4. 输入 ID
    read -p "请输入对应的 ID (${INSTALL_MODE} ID): " ins_id
    if [ -z "$ins_id" ]; then
        echo -e "${ERROR} ID 不能为空！"
        return 1
    fi

    # 5. 执行官方在线安装命令
    echo -e "\n${INFO} 开始安装..."
    curl -fsSL https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh | \
      sudo bash -s -- --mode "$INSTALL_MODE" --panel "$ins_url" --token "$ins_token" --$ID_TYPE "$ins_id"

    if [ $? -eq 0 ]; then
        echo -e "${INFO} xboard-node 安装成功！"
        echo -e "${YELLOW}按回车键继续...${PLAIN}"
        read -r
        return 0
    else
        echo -e "${ERROR} 安装失败，请检查网络或参数是否正确！"
        exit 1
    fi
}

# 获取状态信息的函数
get_status_info() {
    # 1. 获取版本
    CURRENT_VER=$(xbctl version 2>/dev/null | awk '{print $NF}')
    if [ -z "$CURRENT_VER" ]; then
        CURRENT_VER="${RED}未检测到组件（未安装）${PLAIN}"
    fi

    # 2. 获取运行状态
    if systemctl is-active --quiet xbctl 2>/dev/null || xbctl status 2>/dev/null | grep -q "running"; then
        RUN_STATUS="${GREEN}运行中${PLAIN}"
    else
        RUN_STATUS="${RED}已停止${PLAIN}"
    fi

    # 3. 获取绑定的 Instance ID
    INSTANCE_ID=$(xbctl instance list --output text 2>/dev/null | awk 'NR>1 {print $1}' | head -n 1)
    [ -z "$INSTANCE_ID" ] && INSTANCE_ID="${YELLOW}未绑定或无实例${PLAIN}"
}

# 修改/初始化配置函数
modify_config() {
    echo -e "\n${BLUE}========== 修改/初始化配置 ==========${PLAIN}"
    
    # 1. 选择模式
    read -p "请选择绑定模式 [1) Node 模式 | 2) Machine 模式, 默认1]: " mode_choice
    if [ "$mode_choice" = "2" ]; then
        MODE="machine"
        SHORTCUT_CMD="bind-machine"
        ID_FLAG="--machine-id"
    else
        MODE="node"
        SHORTCUT_CMD="bind-node"
        ID_FLAG="--node-id"
    fi

    # 2. 输入面板 URL
    read -p "请输入面板 URL (例如 https://panel.com): " input_url
    if [ -z "$input_url" ]; then
        echo -e "${ERROR} 面板 URL 不能为空！"
        return
    fi

    # 3. 输入 Token
    read -p "请输入通讯 Token: " input_token
    if [ -z "$input_token" ]; then
        echo -e "${ERROR} Token 不能为空！"
        return
    fi

    # 4. 输入 ID
    read -p "请输入对应的 ID ($MODE ID): " input_id
    if [ -z "$input_id" ]; then
        echo -e "${ERROR} ID 不能为空！"
        return
    fi

    # 5. 选择内核
    read -p "请选择核心内核 [1) xray | 2) singbox, 默认1]: " kernel_choice
    if [ "$kernel_choice" = "2" ]; then
        KERNEL="singbox"
    else
        KERNEL="xray"
    fi

    # 执行绑定配置
    echo -e "\n${INFO} 正在执行配置绑定，请稍候..."
    echo -e "执行命令: xbctl $SHORTCUT_CMD --panel-url $input_url --token [HIDDEN] $ID_FLAG $input_id --kernel $KERNEL"
    
    xbctl $SHORTCUT_CMD --panel-url "$input_url" --token "$input_token" $ID_FLAG "$input_id" --kernel "$KERNEL"
    
    if [ $? -eq 0 ]; then
        echo -e "${INFO} 配置修改并绑定成功！正在重启服务..."
        xbctl restart
    else
        echo -e "${ERROR} 绑定失败，请检查配置信息是否正确。"
    fi
}

# --- 脚本入口检查 ---
# 检查xbctl是否安装，如果没有则引导安装
if ! command -v xbctl &> /dev/null; then
    echo -e "${YELLOW}检测到系统未安装 xboard-node${PLAIN}"
    read -p " 是否现在开始安装？[y/n]: " init_ins
    if [[ "$init_ins" == [yY] ]]; then
        install_xbctl
    else
        echo -e "${INFO} 已取消安装，退出。"
        exit 0
    fi
fi

# 主循环菜单
while true; do
    clear
    get_status_info

    echo -e "${GREEN}=================================${PLAIN}"
    echo -e "${GREEN}   ◈  Xboard-node  管理菜单 ◈   ${PLAIN}"
    echo -e "${GREEN}=================================${PLAIN}"
    echo -e "${GREEN}运行状态:${PLAIN} $RUN_STATUS"
    echo -e "${GREEN}实例 ID :${PLAIN} $INSTANCE_ID"
    echo -e "${GREEN}=================================${PLAIN}"
    echo -e "${GREEN} 1. 查看状态${PLAIN}"
    echo -e "${GREEN} 2. 启动服务${PLAIN}"
    echo -e "${GREEN} 3. 停止服务${PLAIN}"
    echo -e "${GREEN} 4. 重启服务${PLAIN}"
    echo -e "${GREEN} 5. 查看日志${PLAIN}"
    echo -e "${GREEN} 6. 检查健康${PLAIN}"
    echo -e "${GREEN}---------------------------------${PLAIN}"
    echo -e "${YELLOW} 7. 修改配置${PLAIN}"
    echo -e "${GREEN} 8. 更新节点${PLAIN}"
    echo -e "${RED} 9. 卸载节点${PLAIN}"
    echo -e "${GREEN}---------------------------------${PLAIN}"
    echo -e "${GREEN} 0. 退出${PLAIN}"
    echo -e "${GREEN}=================================${PLAIN}"
    read -p "$(echo -e " ${GREEN}请输入数字选择操作: ${PLAIN}")" choice
    
    case $choice in
        1)
            echo -e "\n${GREEN} 正在查看服务状态...${PLAIN}"
            xbctl status
            ;;
        2)
            echo -e "\n${GREEN} 正在启动服务...${PLAIN}"
            xbctl start
            ;;
        3)
            echo -e "\n${GREEN} 正在停止服务...${PLAIN}"
            xbctl stop
            ;;
        4)
            echo -e "\n${GREEN} 正在重启服务...${PLAIN}"
            xbctl restart
            ;;
        5)
            echo -e "\n${GREEN} 正在查看实时日志（按 Ctrl+C 退出日志查看）...${PLAIN}"
            xbctl logs
            ;;
        6)
            echo -e "\n${GREEN} 正在检查健康状态...${PLAIN}"
            xbctl health
            ;;
        7)
            modify_config
            ;;
        8)
            echo -e "\n${GREEN} 正在更新节点 xbctl...${PLAIN}"
            xbctl upgrade
            ;;
        9)
            echo -e "\n${RED} 确定要完全卸载节点 吗？这会清除所有数据！${PLAIN}"
            read -p " 输入 'y' 确认卸载，输入其他任意键取消: " confirm
            if [[ "$confirm" == [yY] ]]; then
                echo -e "${INFO} 正在完全卸载..."
                xbctl uninstall --purge --yes
                echo -e "${INFO} 卸载完成"
                exit 0
            else
                echo -e "${INFO} 已取消卸载。"
            fi
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "\n${RED} 无效的选择，请重新输入！${PLAIN}"
            sleep 1
            continue
            ;;
    esac
    
    echo -ne "\033[A\n${YELLOW}按回车键继续...${PLAIN}"
    read -r
done
