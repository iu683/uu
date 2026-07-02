#!/bin/bash

# 标准 ANSI 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

# 载入环境变量并增强 PATH 搜索
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc" 2>/dev/null
[ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc" 2>/dev/null
export PATH="/usr/local/bin:$HOME/.local/bin:/root/.local/bin:$PATH"

# 基础配置
GITEA_API="https://gitea.bytevibe.dev/api/v1/repos/gary/ktui/releases/latest"
GITEA_DOWNLOAD_BASE="https://gitea.bytevibe.dev/gary/ktui/releases/download"

# 动态定位 KTUI 实际安装路径
get_paths() {
    REAL_EXEC_PATH=$(command -v ktui 2>/dev/null)
    if [ -z "$REAL_EXEC_PATH" ] && [ -f "$HOME/.local/bin/ktui" ]; then
        REAL_EXEC_PATH="$HOME/.local/bin/ktui"
    fi
}

# 获取状态、版本及当前配置信息
get_status() {
    get_paths
    if [ -n "$REAL_EXEC_PATH" ]; then
        status="${GREEN}已安装${RESET}"
        # 💡 优化点：使用 head -n 1 只精准抓取第一行的版本号，防止 Hash 和时间刷屏
        version_info=$($REAL_EXEC_PATH version 2>/dev/null | head -n 1 | awk '{print $2}')
        [ -z "$version_info" ] && version_info="0.1.1"
        ktui_version="${YELLOW}${version_info}${RESET}"
    else
        status="${RED}未安装${RESET}"
        ktui_version="${RED}-${RESET}"
    fi

    # 获取当前配置的 URL
    if [ -n "$REAL_EXEC_PATH" ]; then
        current_url=$($REAL_EXEC_PATH config show 2>/dev/null | grep -i "url" | awk -F'"' '{print $4}')
        if [ -z "$current_url" ] || [ "$current_url" == "null" ]; then
            config_status="${YELLOW}未配置 URL${RESET}"
        else
            config_status="${GREEN}${current_url}${RESET}"
        fi
    else
        config_status="${RED}-${RESET}"
    fi
}

# 菜单面板
show_menu() {
    clear
    get_status
    echo -e "${GREEN}============================${RESET}"
    echo -e "${GREEN}     ◈ KTUI 监控管理 ◈     ${RESET}"
    echo -e "${GREEN}============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}版本 :${RESET} $ktui_version"
    echo -e "${GREEN}后端 :${RESET} $config_status"
    echo -e "${GREEN}============================${RESET}"
    echo -e "${GREEN} 1. 安装${RESET}"
    echo -e "${GREEN} 2. 更新${RESET}"
    echo -e "${GREEN} 3. 卡片视图${RESET}"
    echo -e "${GREEN} 4. 列表视图${RESET}"
    echo -e "${GREEN} 5. 配置后端${RESET}"
    echo -e "${GREEN} 6. 设置APIKey${RESET}"
    echo -e "${GREEN} 7. 查看配置与路${RESET}"
    echo -e "${GREEN} 8. 启动ASCII${RESET}"
    echo -e "${GREEN} 9. 快捷键指南${RESET}"
    echo -e "${GREEN}10. 卸载${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}============================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
}

# 1. 动态获取最新版并下载安装
download_and_install() {
    echo -e "\n${YELLOW}[正在从 Gitea 检索 KTUI 最新版本信息...]${RESET}"
    
    # 1. 自动请求 Gitea API 获取最新的 tag_name
    LATEST_TAG=$(curl -s "$GITEA_API" | grep -o '"tag_name":"[^"]*' | grep -o '[^"]*$')
    
    if [ -z "$LATEST_TAG" ]; then
        # 备用方案：如果 API 限制或失效，尝试从网页流抓取
        LATEST_TAG=$(curl -sL "https://gitea.bytevibe.dev/gary/ktui/releases" | grep -o 'releases/tag/v[0-9.]*' | head -n 1 | awk -F'/' '{print $3}')
    fi

    if [ -z "$LATEST_TAG" ]; then
        echo -e "${RED}❌ 错误：无法获取最新版本号，请检查网络是否能够访问 gitea.bytevibe.dev。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
        return 1
    fi

    # 去掉 tag 里面的 'v' 方便纯版本号拼接（如 v0.1.1 -> 0.1.1）
    PURE_VER=$(echo "$LATEST_TAG" | sed 's/^v//')
    echo -e "${GREEN}发现最新版本: ${LATEST_TAG}${RESET}"

    # 2. 识别系统架构
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            FILENAME="ktui_${PURE_VER}_linux_amd64.tar.gz"
            ;;
        aarch64|arm64)
            FILENAME="ktui_${PURE_VER}_linux_arm64.tar.gz"
            ;;
        *)
            echo -e "${RED}❌ 抱歉，暂不支持当前系统架构: $ARCH${RESET}"
            echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
            return 1
            ;;
    esac

    # 3. 拼接动态下载链接
    DOWNLOAD_URL="${GITEA_DOWNLOAD_BASE}/${LATEST_TAG}/${FILENAME}"
    echo -e "${GREEN}准备下载: ${FILENAME}${RESET}"
    
    TMP_DIR=$(mktemp -d)
    if curl -L "$DOWNLOAD_URL" -o "${TMP_DIR}/${FILENAME}"; then
        echo -e "${YELLOW}下载成功，正在解压并配置路径...${RESET}"
        
        # 解压 tar.gz
        tar -xzf "${TMP_DIR}/${FILENAME}" -C "$TMP_DIR"
        
        if [ -f "${TMP_DIR}/ktui" ]; then
            mkdir -p "$HOME/.local/bin"
            mv "${TMP_DIR}/ktui" "$HOME/.local/bin/ktui"
            chmod +x "$HOME/.local/bin/ktui"
            
            # 创建全局软链接
            if [ -w "/usr/local/bin" ]; then
                rm -f /usr/local/bin/ktui
                ln -s "$HOME/.local/bin/ktui" /usr/local/bin/ktui
            else
                sudo rm -f /usr/local/bin/ktui
                sudo ln -s "$HOME/.local/bin/ktui" /usr/local/bin/ktui
            fi
            echo -e "${GREEN}✔ KTUI (${LATEST_TAG}) 成功安装到系统路径！快捷指令: ktui${RESET}"
        else
            echo -e "${RED}❌ 解压文件中未找到可执行文件 ktui。${RESET}"
        fi
    else
        echo -e "${RED}❌ 下载失败，请检查下载地址是否正确或 Gitea 仓储中是否有对应的架构包。${RESET}"
        echo -e "${RED}失败链接: ${DOWNLOAD_URL}${RESET}"
    fi
    rm -rf "$TMP_DIR"
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 2. 纯粹的自更新逻辑
check_and_update() {
    get_paths
    if [ -z "$REAL_EXEC_PATH" ]; then
        echo -e "\n${RED}❌ 未检测到已安装的 KTUI，无法执行更新流，请先选择选项 1 安装。${RESET}"
    else
        echo -e "\n${YELLOW}[触发官方内置自更新流程]${RESET}"
        "$REAL_EXEC_PATH" update --check
        echo -ne "${YELLOW}是否执行更新替换？(y/n): ${RESET}"
        read -r ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            "$REAL_EXEC_PATH" update
            echo -e "${GREEN}✔ 更新指令执行完毕。${RESET}"
        else
            echo -e "${GREEN}已取消更新。${RESET}"
        fi
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 3 & 4. 启动 TUI
start_tui() {
    get_paths
    if [ -z "$REAL_EXEC_PATH" ]; then
        echo -e "\n${RED}未检测到 ktui 命令，请先执行选项 1 进行安装！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
        return
    fi
    if [ "$1" == "sheet" ]; then
        "$REAL_EXEC_PATH" --sheet
    else
        "$REAL_EXEC_PATH" --line
    fi
}

# 5. 初始化与设置 URL
init_config_url() {
    get_paths
    if [ -z "$REAL_EXEC_PATH" ]; then
        echo -e "\n${RED}未检测到已安装的 KTUI。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
        return
    fi
    echo -e "\n${GREEN}[初始化与设置后端 URL]${RESET}"
    "$REAL_EXEC_PATH" config init 2>/dev/null
    
    echo -ne "${YELLOW}请输入 Komari 后端地址 (例如 https://komari.example.com): ${RESET}"
    read -r komari_url
    if [ -n "$komari_url" ]; then
        "$REAL_EXEC_PATH" config set url "$komari_url"
        echo -e "${GREEN}✔ URL 设置成功！${RESET}"
    else
        echo -e "${RED}❌ 输入不能为空。${RESET}"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 6. 快捷设置其他常用项
set_extra_config() {
    get_paths
    if [ -z "$REAL_EXEC_PATH" ]; then
        echo -e "\n${RED}未检测到已安装的 KTUI。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
        return
    fi
    echo -e "\n${GREEN}[快捷设置核心配置]${RESET}"
    
    echo -ne "${YELLOW}1. 请输入 API Key (留空跳过): ${RESET}"
    read -r api_key
    [ -n "$api_key" ] && "$REAL_EXEC_PATH" config set api-key "$api_key"

    echo -ne "${YELLOW}2. 请输入默认视图模式 (sheet/line, 回车跳过): ${RESET}"
    read -r view_mode
    [[ "$view_mode" == "sheet" || "$view_mode" == "line" ]] && "$REAL_EXEC_PATH" config set mode "$view_mode"

    echo -e "${GREEN}✔ 配置项更新完成！${RESET}"
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 7. 查看配置与实际路径
show_config_details() {
    get_paths
    if [ -z "$REAL_EXEC_PATH" ]; then
        echo -e "\n${RED}未检测到已安装的 KTUI。${RESET}"
    else
        echo -e "\n${YELLOW}--------------------------------------${RESET}"
        echo -e "${GREEN}【配置文件当前实际绝对路径】:${RESET}"
        "$REAL_EXEC_PATH" config path
        echo -e "${GREEN}【配置文件当前内容展示】:${RESET}"
        "$REAL_EXEC_PATH" config show
        echo -e "${YELLOW}--------------------------------------${RESET}"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 8. 启动 ASCII 兼容模式
start_ascii_mode() {
    get_paths
    if [ -n "$REAL_EXEC_PATH" ]; then
        echo -e "\n${YELLOW}正在使用 ASCII 兼容无色模式启动，解决乱码问题...${RESET}"
        "$REAL_EXEC_PATH" --ascii --no-color
    else
        echo -e "\n${RED}未检测到已安装的 KTUI。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
    fi
}

# 9. 快捷键面板
show_shortcuts() {
    clear
    echo -e "${YELLOW}======================================================${RESET}"
    echo -e "${YELLOW}               KTUI TUI 界面快捷键交互速查             ${RESET}"
    echo -e "${YELLOW}======================================================${RESET}"
    echo -e "  ↑ / k          : 列表页选择上一个节点；详情页向上滚动"
    echo -e "  ↓ / j          : 列表页选择下一个节点；详情页向下滚动"
    echo -e "  PgUp / PgDn    : 快速向上 / 向下翻页滚动"
    echo -e "  Enter / o      : 打开选中节点的【详情页】"
    echo -e "  Esc / b / q    : 从详情页【返回】列表页"
    echo -e "  h / l、1-5、Tab : 切换详情页内部的【标签页(Tabs)】"
    echo -e "  [ / ]          : 切换详情页的【时间窗口范围】"
    echo -e "  m              : 在列表页无缝切换 sheet / line 模式"
    echo -e "  r              : 立即强制刷新当前数据"
    echo -e "  d              : 打开或重新加载选中节点的详情数据"
    echo -e "  a              : 实时切换 ASCII 兼容模式"
    echo -e "  q / Ctrl-C     : 在列表页退出程序"
    echo -e "${YELLOW}======================================================${RESET}"
    echo -ne "${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 10. 卸载功能
uninstall_ktui() {
    get_paths
    echo -e "\n${RED}警告：准备进入 KTUI 卸载流程... (保留用户配置文件)${RESET}"
    echo -ne "${RED}确定要清除 ktui 二进制程序和全局调用配置吗？(y/n): ${RESET}"
    read -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        if [ -w "/usr/local/bin" ]; then rm -f /usr/local/bin/ktui; else sudo rm -f /usr/local/bin/ktui; fi
        [ -n "$REAL_EXEC_PATH" ] && [ "$REAL_EXEC_PATH" != "/usr/local/bin/ktui" ] && rm -f "$REAL_EXEC_PATH"
        rm -f "$HOME/.local/bin/ktui"
        echo -e "${GREEN}✔ 全局清理完成！配置保留在系统 XDG 目录中。${RESET}"
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
        1) download_and_install ;;
        2) check_and_update ;;
        3) start_tui "sheet" ;;
        4) start_tui "line" ;;
        5) init_config_url ;;
        6) set_extra_config ;;
        7) show_config_details ;;
        8) start_ascii_mode ;;
        9) show_shortcuts ;;
        10) uninstall_ktui ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择！${RESET}"; sleep 1 ;;
    esac
done
