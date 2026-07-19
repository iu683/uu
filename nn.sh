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
    echo -e "${RED} 请使用 root 用户运行！${PLAIN}"
    exit 1
fi

# 核心安装函数
install_hle() {
    echo -e "\n${YELLOW}========== 开始安装 Home-Location-Endpoint ==========${PLAIN}"
    echo -e "${YELLOW}正在从 GitHub 获取官方安装...${PLAIN}"
    
    curl -fsSL https://raw.githubusercontent.com/Loading886/Home-Location-Endpoint/main/install.sh | sudo bash

    if [ $? -eq 0 ]; then
        echo -e "${YELLOW} hle 安装成功！${PLAIN}"
        echo -e "${YELLOW}按回车键继续...${PLAIN}"
        read -r
        return 0
    else
        echo -e "${RED} 安装失败，请检查网络连接！${PLAIN}"
        exit 1
    fi
}

# 获取状态信息的函数
get_status_info() {
    # 1. 获取定位改写状态与城市（通过 hle status 解析）
    if command -v hle &> /dev/null; then
        HLE_RAW_STATUS=$(sudo hle status 2>/dev/null)
        # 简单提取状态，如果包含 paused 则为暂停
        if echo "$HLE_RAW_STATUS" | grep -q "paused"; then
            HLE_STATUS="${YELLOW}已暂停改写 (代理正常)${PLAIN}"
        else
            HLE_STATUS="${YELLOW}改写激活中${PLAIN}"
        fi
    else
        HLE_STATUS="${RED}未安装组件${PLAIN}"
    fi

    # 2. 获取 Telegram 控制器运行状态
    if systemctl is-active --quiet home-location-telegram-bot 2>/dev/null; then
        TG_BOT_STATUS="${YELLOW}运行中${PLAIN}"
    else
        TG_BOT_STATUS="${RED}已停止/未配置${PLAIN}"
    fi
}

# --- 脚本入口检查 ---
# 检查 hle 是否安装，如果没有则引导安装
if ! command -v hle &> /dev/null; then
    echo -e "${YELLOW}检测到系统未安装 Home-Location-Endpoint (hle)${PLAIN}"
    read -p "$(echo -e "${GREEN}是否现在开始安装？[y/n]: ${PLAIN}")" init_ins
    if [[ "$init_ins" == [yY] ]]; then
        install_hle
    else
        echo -e "${YELLOW} 已取消安装，退出。${PLAIN}"
        exit 0
    fi
fi

# 主循环菜单
while true; do
    clear
    get_status_info

    echo -e "${GREEN}=================================${PLAIN}"
    echo -e "${GREEN}   ◈  Apple 网络定位管理菜单  ◈   ${PLAIN}"
    echo -e "${GREEN}=================================${PLAIN}"
    echo -e "${GREEN}定位状态 :${PLAIN} ${HLE_STATUS}"
    echo -e "${GREEN}TG 机器人:${PLAIN} ${TG_BOT_STATUS}"
    echo -e "${GREEN}=================================${PLAIN}"
    echo -e "${GREEN} 1. 查看当前状态 (城市/坐标/运行)${PLAIN}"
    echo -e "${GREEN} 2. 暂停坐标改写 (返回原始定位)${PLAIN}"
    echo -e "${GREEN} 3. 恢复坐标改写 (无需重启)${PLAIN}"
    echo -e "${GREEN} 4. 本地完整性自检 (证书/权限/监听)${PLAIN}"
    echo -e "${GREEN} 5. 查看 Telegram 机器人系统状态${PLAIN}"
    echo -e "${GREEN} 6. 再次打印节点链接${PLAIN}"
    echo -e "${GREEN}---------------------------------${PLAIN}"
    echo -e "${YELLOW} 7. 打印 CA 描述文件路径${PLAIN}"
    echo -e "${YELLOW} 8. 手机下载描述文件 (生成二维码/令牌)${PLAIN}"
    echo -e "${RED} 9. 卸载定位修改工具${PLAIN}"
    echo -e "${GREEN}---------------------------------${PLAIN}"
    echo -e "${GREEN} 0. 退出${PLAIN}"
    echo -e "${GREEN}=================================${PLAIN}"
    read -p "$(echo -e "${GREEN} 请选择: ${PLAIN}")" choice
    
    case $choice in
        1)
            echo -e "\n${GREEN} [查看详细状态]${PLAIN}"
            sudo hle status
            ;;
        2)
            echo -e "\n${YELLOW} [暂停坐标改写] 保持代理正常并返回 Apple 原始定位...${PLAIN}"
            sudo hle pause
            ;;
        3)
            echo -e "\n${GREEN} [恢复坐标改写] 正在恢复修改...${PLAIN}"
            sudo hle resume
            ;;
        4)
            echo -e "\n${GREEN} [完整性自检] 正在检查证书、权限、监听和服务...${PLAIN}"
            sudo hle verify
            ;;
        5)
            echo -e "\n${GREEN} [检查 Telegram 控制器服务状态]${PLAIN}"
            sudo systemctl status home-location-telegram-bot
            ;;
        6)
            echo -e "\n${GREEN} [显示节点链接]${PLAIN}"
            sudo hle show-link
            ;;
        7)
            echo -e "\n${YELLOW} [CA 描述文件本地路径]${PLAIN}"
            sudo hle profile
            ;;
        8)
            echo -e "\n${YELLOW} [手机扫码下载] 生成一次性令牌链接与二维码（100分钟/1次有效）:${PLAIN}"
            sudo hle profile serve
            ;;
        9)
            echo -e "\n${RED} 确定要卸载 Apple 网络定位修改工具吗？这会清除所有数据和证书！${PLAIN}"
            read -p "$(echo -e " ${YELLOW}输入 'y' 确认卸载，输入其他任意键取消: ${PLAIN}")" confirm
            if [[ "$confirm" == [yY] ]]; then
                echo -e "${GREEN} 正在卸载并清理全部文件、证书与账户...${PLAIN}"
                sudo hle uninstall --yes
                echo -e "${GREEN} 卸载完成！${PLAIN}"
                exit 0
            else
                echo -e "${GREEN} 已取消卸载。${PLAIN}"
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
    
    echo -ne "\n${YELLOW}按回车键继续...${PLAIN}"
    read -r
done
