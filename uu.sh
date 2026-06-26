#!/bin/bash

# 颜色定义
GREEN='\033;32m'
RED='\033;31m'
YELLOW='\033;33m'
BLUE='\033;34m'
PURPLE='\033;35m'
PLAIN='\033[0m'

# 提示信息
INFO="[${GREEN}INFO${PLAIN}]"
WARN="[${YELLOW}WARN${PLAIN}]"
ERROR="[${RED}ERROR${PLAIN}]"

# 检查是否为 root 用户
if [ $(id -u) -ne 0 ]; then
    echo -e "${ERROR} 请使用 root 用户运行！"
    exit 1
fi

# 获取状态信息的函数
get_status_info() {
    # 1. 获取版本
    CURRENT_VER=$(xbctl version 2>/dev/null | awk '{print $NF}')
    [ -z "$CURRENT_VER" ] && CURRENT_VER="未检测到"

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
    echo -e "请选择绑定模式:"
    echo -e " 1) Node 模式 (节点)"
    echo -e " 2) Machine 模式 (机器)"
    echo -n "请选择 [1-2, 默认1]: "
    read mode_choice
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
    echo -n "请输入面板 URL (例如 https://panel.com): "
    read input_url
    if [ -z "$input_url" ]; then
        echo -e "${ERROR} 面板 URL 不能为空！"
        return
    fi

    # 3. 输入 Token
    echo -n "请输入通讯 Token: "
    read input_token
    if [ -z "$input_token" ]; then
        echo -e "${ERROR} Token 不能为空！"
        return
    fi

    # 4. 输入 ID
    echo -n "请输入对应的 ID ($MODE ID): "
    read input_id
    if [ -z "$input_id" ]; then
        echo -e "${ERROR} ID 不能为空！"
        return
    fi

    # 5. 选择内核
    echo -e "请选择核心内核 (Kernel):"
    echo -e " 1) xray"
    echo -e " 2) singbox"
    echo -n "请选择 [1-2, 默认1]: "
    read kernel_choice
    if [ "$kernel_choice" = "2" ]; then
        KERNEL="singbox"
    else
        KERNEL="xray"
    fi

    # 执行绑定配置
    echo -e "\n${INFO} 正在执行配置绑定，请稍候..."
    echo -e "执行命令: xbctl $SHORTCUT_CMD --panel-url $input_url --token $input_token $ID_FLAG $input_id --kernel $KERNEL"
    
    xbctl $SHORTCUT_CMD --panel-url "$input_url" --token "$input_token" $ID_FLAG "$input_id" --kernel "$KERNEL"
    
    if [ $? -eq 0 ]; then
        echo -e "${INFO} 配置修改并绑定成功！正在重启服务..."
        xbctl restart
    else
        echo -e "${ERROR} 绑定失败，请检查配置信息是否正确。"
    fi
}

# 主菜单函数
main_menu() {
    clear
    get_status_info

    echo -e "${GREEN}=================================${PLAIN}"
    echo -e "${GREEN}     xboard-node  管理菜单        ${PLAIN}"
    echo -e "${GREEN}=================================${PLAIN}"
    echo -e "${GREEN}组件版本:${PLAIN} $CURRENT_VER"
    echo -e "${GREEN}运行状态:${PLAIN} $RUN_STATUS"
    echo -e "${GREEN}实例 ID :${PLAIN} $INSTANCE_ID"
    echo -e "${GREEN}=================================${PLAIN}"
    echo -e "${GREEN}1.查看状态${PLAIN}"
    echo -e "${GREEN}2.启动服务${PLAIN}"
    echo -e "${GREEN}3.停止服务${PLAIN}"
    echo -e "${GREEN}4.重启服务${PLAIN}"
    echo -e "${GREEN}5.查看日志${PLAIN}"
    echo -e "${GREEN}6.检查健康${PLAIN}"
    echo -e "${GREEN}---------------------------------${PLAIN}"
    echo -e "${YELLOW}7.修改配置${PLAIN}"
    echo -e "${GREEN}8.更新节点"
    echo -e "${RED}9.卸载节点${PLAIN}"
    echo -e "${GREEN}---------------------------------${PLAIN}"
    echo -e "${GREEN}0.退出${PLAIN}"
    echo -e "${GREEN}=================================${PLAIN}"
    echo -e -n " ${GREEN}请输入数字选择操作 [0-9]: ${PLAIN}"
    read choice
    
    case $choice in
        1)
            echo -e "\n${INFO} 正在查看服务状态..."
            xbctl status
            ;;
        2)
            echo -e "\n${INFO} 正在启动服务..."
            xbctl start
            ;;
        3)
            echo -e "\n${INFO} 正在停止服务..."
            xbctl stop
            ;;
        4)
            echo -e "\n${INFO} 正在重启服务..."
            xbctl restart
            ;;
        5)
            echo -e "\n${INFO} 正在查看实时日志（按 Ctrl+C 退出日志查看）..."
            xbctl logs
            ;;
        6)
            echo -e "\n${INFO} 正在检查健康状态..."
            xbctl health
            ;;
        7)
            modify_config
            ;;
        8)
            echo -e "\n${INFO} 正在尝试更新 xbctl..."
            xbctl upgrade
            ;;
        9)
            echo -e "\n${WARN} 确定要完全卸载 xbctl 吗？这会清除所有数据！"
            echo -n " 输入 'y' 确认卸载，输入其他任意键取消: "
            read confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                echo -e "${INFO} 正在完全卸载..."
                xbctl uninstall --purge --yes
                exit 0
            else
                echo -e "${INFO} 已取消卸载。"
            fi
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "\n${ERROR} 无效的选择，请重新输入！"
            sleep 1
            main_menu
            ;;
    esac
    
    echo -e "\n${YELLOW}按任意键返回主菜单...${PLAIN}"
    read -n 1
    main_menu
}

# 运行主菜单
main_menu
