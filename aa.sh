#!/bin/bash

# 标准 ANSI 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
RESET='\033[0m'

# 动态定位 Node.js / npx 状态
get_status() {
    if command -v node &> /dev/null; then
        node_status="${YELLOW}已就绪 ($(node -v))${RESET}"
    else
        node_status="${RED}未检测到${RESET}"
    fi
}

# 菜单面板
show_menu() {
    clear
    get_status
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN}     ◈ Torlnk 磁力搜索管理 ◈      ${RESET}"
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN}Node.js 环境 :${RESET} $node_status"
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN} 1. 检测安装 Node.js 环境${RESET}"
    echo -e "${GREEN} 2. 启动 Torlnk 搜索栏${RESET}"
    echo -e "${GREEN} 3. 查看操作与快捷键指南${RESET}"
    echo -e "${GREEN} 4. 卸载${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}=================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
}

# 1. 自动化检测与安装 Node.js 环境
check_and_install_node() {
    echo -e "\n${YELLOW}[1/3] 正在检测 Node.js 环境...${RESET}"
    if ! command -v node &> /dev/null; then
        echo -e "${YELLOW}未检测到 Node.js，正在通过 NodeSource 配置 Node.js v24 源...${RESET}"
        
        # 确保系统有 curl
        if ! command -v curl &> /dev/null; then
            echo -e "${YELLOW}检测到缺少 curl，正在尝试安装...${RESET}"
            if command -v apt-get &> /dev/null; then
                apt-get update && apt-get install -y curl
            elif command -v dnf &> /dev/null; then
                dnf install -y curl
            elif command -v yum &> /dev/null; then
                yum install -y curl
            fi
        fi

        # 执行 NodeSource v24 脚本
        curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
        
        # 根据包管理器执行安装
        if command -v apt-get &> /dev/null; then
            echo -e "${YELLOW}正在通过 apt 安装 nodejs...${RESET}"
            apt-get install -y nodejs
        elif command -v dnf &> /dev/null; then
            echo -e "${YELLOW}正在通过 dnf 安装 nodejs...${RESET}"
            dnf install -y nodejs
        elif command -v yum &> /dev/null; then
            echo -e "${YELLOW}正在通过 yum 安装 nodejs...${RESET}"
            yum install -y nodejs
        else
            echo -e "${RED}❌ 未能识别系统包管理器，请手动运行：apt/dnf install -y nodejs${RESET}"
            echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
            return 1
        fi
    fi
    
    # 再次确认 Node 版本
    if command -v node &> /dev/null; then
        echo -e "${GREEN}✔ Node.js 已就绪，版本: $(node --version)${RESET}"
        echo -e "${GREEN}✔ npm 版本: $(npm --version)${RESET}"
        echo -ne "\n${GREEN}环境检测通过！按回车键返回主菜单...${RESET}" && read -r
        return 0
    else
        echo -e "${RED}❌ Node.js 安装失败，请检查网络或系统权限。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
        return 1
    fi
}

# 2 启动 Torlnk (带环境强置检查)
start_torlnk() {
    if ! command -v npx &>/dev/null; then
        echo -e "${RED}❌ 启动失败：未检测到 'npx' 环境，正在尝试为你激活...${RESET}"
        check_and_install_node
        # 如果激活安装流依然失败，则退出
        ! command -v npx &>/dev/null && return
    fi

    echo -e "\n${YELLOW}[正在通过 npx 启动 Torlnk...]${RESET}"
    npx torlnk
}

# 4. 快捷键指南
show_guide() {
    clear
    echo -e "${YELLOW}======================================================${RESET}"
    echo -e "${YELLOW}               Torlnk 终端操作与快捷键速查              ${RESET}"
    echo -e "${YELLOW}======================================================${RESET}"
    echo -e "${GREEN}【搜索阶段】:${RESET}"
    echo -e "  输入关键字 + 回车  : 全网搜索你想要的内容"
    echo -e "  直接粘贴磁力/Hash : 直接识别并导入任务"
    echo -e "  不输入直接回车     : 浏览精选资源库"
    echo -e ""
    echo -e "${GREEN}【结果筛选】:${RESET}"
    echo -e "  ↑ / ↓ (方向键)   : 在结果列表中上下移动光标"
    echo -e "  大小/分享人数标签 : 观察 Seeders 数量，人数太少的内容容易断种"
    echo -e ""
    echo -e "${GREEN}【下载保存】:${RESET}"
    echo -e "  d                  : 用箭头指向想要的内容后，按 ${YELLOW}d${RESET} 键保存下载"
    echo -e ""
    echo -e "${YELLOW}======================================================${RESET}"
    echo -ne "${GREEN}按回车键返回主菜单...${RESET}" && read -r
}


#4. 卸载 Torlnk 核心逻辑
uninstall_torlnk() {
    echo -e "\n${RED}警告：准备清理 Torlnk 所有相关的二进制包和本地运行缓存...${RESET}"
    echo -ne "${RED}确定要执行卸载吗？(y/n): ${RESET}"
    read -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        # 1. 检查并移除全局 npm 安装的 torlnk
        if command -v npm &>/dev/null; then
            echo -e "${YELLOW}[1/2] 正在检查并卸载全局 npm 安装包...${RESET}"
            npm uninstall -g torlnk &>/dev/null
        fi

        # 2. 清理 npx 本地产生的残留快照和缓存目录
        echo -e "${YELLOW}[2/2] 正在强制抹除本地 npx 运行缓存...${RESET}"
        rm -rf "$HOME/.npm/_npx" 2>/dev/null
        # 针对新版 npm 缓存机制补充清理
        npx --yes clear-npx-cache &>/dev/null

        echo -e "${GREEN}✔ Torlnk 清理完成！(Node.js 环境已保留，仅移除了工具本身)${RESET}"
    else
        echo -e "${GREEN}已取消卸载。${RESET}"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 主循环
while true; do
    show_menu
    read -r choice
    case $choice in
        1)
            check_and_install_node
            ;;
        2) 
            start_torlnk 
            ;;
        3) 
            show_guide 
            ;;
        4) 
            uninstall_torlnk
            ;;
        0) 
            clear
            exit 0 
            ;;
        *) 
            echo -e "${RED}无效选项，请重新选择！${RESET}"
            sleep 1 
            ;;
    esac
done
