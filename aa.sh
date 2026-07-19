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
GITHUB_API="https://api.github.com/repos/Foxemsx/riptide/releases/latest"
DB_PATH="$HOME/.config/riptide/riptide.db"

# 动态定位 Riptide 实际安装路径
get_paths() {
    REAL_EXEC_PATH=$(command -v riptide 2>/dev/null)
    if [ -z "$REAL_EXEC_PATH" ] && [ -f "$HOME/.local/bin/riptide" ]; then
        REAL_EXEC_PATH="$HOME/.local/bin/riptide"
    fi
}

# 获取状态、版本及数据库信息
get_status() {
    get_paths
    if [ -n "$REAL_EXEC_PATH" ]; then
        status="${GREEN}已安装${RESET}"
        # 获取当前版本信息
        version_info="v1.4.0" # 默认为当前版本，若程序支持 --version 可在此解析
        riptide_version="${YELLOW}${version_info}${RESET}"
    else
        status="${RED}未安装${RESET}"
        riptide_version="${RED}-${RESET}"
    fi

    # 检测本地数据库状态
    if [ -f "$DB_PATH" ]; then
        db_status="${GREEN}已建立 (已记录历史数据)${RESET}"
    else
        db_status="${YELLOW}未初始化 (首次运行测速后生成)${RESET}"
    fi
}

# 菜单面板
show_menu() {
    clear
    get_status
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}      ◈ Riptide 网络监控管理 ◈       ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}版本 :${RESET} $riptide_version"
    echo -e "${GREEN}数据 :${RESET} $db_status"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN} 1. 安装 / 更新 Riptide${RESET}"
    echo -e "${GREEN} 2. 标准模式启动 (主菜单)${RESET}"
    echo -e "${GREEN} 3. 紧凑模式启动 (跳过大Logo)${RESET}"
    echo -e "${GREEN} 4. 自定义色彩主题启动${RESET}"
    echo -e "${GREEN} 5. 测速历史数据库路径查看${RESET}"
    echo -e "${GREEN} 6. 重置本地数据库 (清空历史)${RESET}"
    echo -e "${GREEN} 7. TUI 界面快捷键指南${RESET}"
    echo -e "${GREEN} 8. 卸载 Riptide${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
}

# 1. 动态获取最新版并下载安装/更新
download_and_install() {
    echo -e "\n${YELLOW}[正在从 GitHub 检索 Riptide 最新发布版本...]${RESET}"
    
    # 自动请求 GitHub API 获取最新的 tag_name
    LATEST_TAG=$(curl -s "$GITHUB_API" | grep -o '"tag_name": "[^"]*' | grep -o '[^"]*$')
    
    if [ -z "$LATEST_TAG" ]; then
        # 兜底默认版本
        LATEST_TAG="v1.4.0"
    fi
    echo -e "${GREEN}目标安装版本: ${LATEST_TAG}${RESET}"

    # 识别系统架构
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            FILENAME="riptide-linux-amd64.tar.gz"
            ;;
        aarch64|arm64)
            FILENAME="riptide-linux-arm64.tar.gz"
            ;;
        *)
            echo -e "${RED}❌ 抱歉，暂不支持当前系统架构: $ARCH${RESET}"
            echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
            return 1
            ;;
    esac

    # 拼接官方 GitHub Release 下载链接
    DOWNLOAD_URL="https://github.com/Foxemsx/riptide/releases/download/${LATEST_TAG}/${FILENAME}"
    echo -e "${GREEN}准备下载: ${FILENAME}${RESET}"
    
    TMP_DIR=$(mktemp -d)
    if curl -L "$DOWNLOAD_URL" -o "${TMP_DIR}/${FILENAME}"; then
        echo -e "${YELLOW}下载成功，正在解压并配置路径...${RESET}"
        
        # 解压二进制文件
        tar -xzf "${TMP_DIR}/${FILENAME}" -C "$TMP_DIR"
        
        if [ -f "${TMP_DIR}/riptide" ]; then
            mkdir -p "$HOME/.local/bin"
            mv "${TMP_DIR}/riptide" "$HOME/.local/bin/riptide"
            chmod +x "$HOME/.local/bin/riptide"
            
            # 创建全局软链接
            if [ -w "/usr/local/bin" ]; then
                rm -f /usr/local/bin/riptide
                ln -s "$HOME/.local/bin/riptide" /usr/local/bin/riptide
            else
                sudo rm -f /usr/local/bin/riptide
                sudo ln -s "$HOME/.local/bin/riptide" /usr/local/bin/riptide
            fi
            echo -e "${GREEN}✔ Riptide (${LATEST_TAG}) 成功安装/更新！快捷指令: riptide${RESET}"
        else
            echo -e "${RED}❌ 解压文件中未找到可执行文件 riptide。${RESET}"
        fi
    else
        echo -e "${RED}❌ 下载失败，请检查网络是否能正常访问 GitHub Release。${RESET}"
        echo -e "${RED}失败链接: ${DOWNLOAD_URL}${RESET}"
    fi
    rm -rf "$TMP_DIR"
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 2 & 3. 启动 TUI 界面
start_tui() {
    get_paths
    if [ -z "$REAL_EXEC_PATH" ]; then
        echo -e "\n${RED}未检测到 riptide 命令，请先执行选项 1 进行安装！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
        return
    fi
    if [ "$1" == "compact" ]; then
        "$REAL_EXEC_PATH" --compact
    else
        "$REAL_EXEC_PATH"
    fi
}

# 4. 指定主题启动并保存偏好
start_with_theme() {
    get_paths
    if [ -z "$REAL_EXEC_PATH" ]; then
        echo -e "\n${RED}未检测到已安装的 Riptide。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
        return
    fi
    echo -e "\n${GREEN}[可用主题推荐]${RESET}: ocean, midnight, sunset, forest, dracula, cyber, nord, gruvbox, tokyo"
    echo -ne "${YELLOW}请输入你想使用的主题名称 (直接回车默认 default): ${RESET}"
    read -r target_theme
    if [ -z "$target_theme" ]; then
        target_theme="default"
    fi
    echo -e "${YELLOW}正在以 [${target_theme}] 主题启动 Riptide...${RESET}"
    "$REAL_EXEC_PATH" --theme "$target_theme"
}

# 5. 查看配置与数据库实际路径
show_config_details() {
    echo -e "\n${YELLOW}------------------------------------------------${RESET}"
    echo -e "${GREEN}【SQLite 数据库实际绝对路径】:${RESET}"
    echo -e " $DB_PATH"
    echo -e "${GREEN}【当前数据库状态】:${RESET}"
    if [ -f "$DB_PATH" ]; then
        ls -lh "$DB_PATH"
    else
        echo -e " 暂无本地数据库文件，运行一次网络测速后将自动创建。"
    fi
    echo -e "${YELLOW}------------------------------------------------${RESET}"
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 6. 重置本地数据库
reset_database() {
    if [ -f "$DB_PATH" ]; then
        echo -e "\n${RED}警告：准备重置本地 SQLite 数据库...${RESET}"
        echo -ne "${RED}此操作将永久清空所有测速历史数据！确定要执行吗？(y/n): ${RESET}"
        read -r ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            rm -f "$DB_PATH"
            echo -e "${GREEN}✔ 历史数据库已成功重置并清理。${RESET}"
        else
            echo -e "${GREEN}操作已取消。${RESET}"
        fi
    else
        echo -e "\n${YELLOW}提示：本地尚无历史数据库文件，无需重置。${RESET}"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 7. 快捷键面板
show_shortcuts() {
    clear
    echo -e "${YELLOW}==================================================================${RESET}"
    echo -e "${YELLOW}                Riptide TUI 终端界面快捷操作指南                  ${RESET}"
    echo -e "${YELLOW}==================================================================${RESET}"
    echo -e "  ${GREEN}【常规导航】${RESET}"
    echo -e "   ← → ↑ ↓ / h j k l  : 菜单选项移动"
    echo -e "   Enter              : 确认选中当前项"
    echo -e "   1, 2, 3, 4         : 快捷跳转 (1:测速 / 2:带宽 / 3:设置 / 4:退出)"
    echo -e "   Esc / m            : 返回主菜单"
    echo -e "   ?                  : 打开帮助遮罩层"
    echo -e "   g                  : 在浏览器中打开官方 GitHub 项目"
    echo -e "  ${GREEN}【测速/监控面板】${RESET}"
    echo -e "   s                  : 测速面板 — 保存 / 重命名当前测速运行记录"
    echo -e "   y                  : 测速面板 — 复制结果到剪贴板 (↓248 ↑19 12ms)"
    echo -e "   c                  : 切换流量/速度显示单位"
    echo -e "   r                  : 重新启动当前测试或网络监控"
    echo -e "   p                  : 暂停 / 继续当前监控 (仅限带宽视图)"
    echo -e "   a                  : 切换应用 (仅限带宽面板使用)"
    echo -e "   t                  : 实时切换显示紧凑型/大 Logo 标志"
    echo -e "  ${GREEN}【全局退出】${RESET}"
    echo -e "   q / Ctrl+C         : 立即退出 Riptide 监控"
    echo -e "${YELLOW}==================================================================${RESET}"
    echo -ne "${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 8. 卸载功能
uninstall_riptide() {
    get_paths
    echo -e "\n${RED}警告：准备进入 Riptide 卸载流程...${RESET}"
    echo -ne "${RED}确定要卸载二进制程序并清理全局快捷调用吗？(y/n): ${RESET}"
    read -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        # 清除全局软链接
        if [ -w "/usr/local/bin" ]; then rm -f /usr/local/bin/riptide; else sudo rm -f /usr/local/bin/riptide; fi
        # 清除局部路径
        [ -n "$REAL_EXEC_PATH" ] && [ "$REAL_EXEC_PATH" != "/usr/local/bin/riptide" ] && rm -f "$REAL_EXEC_PATH"
        rm -f "$HOME/.local/bin/riptide"
        
        echo -e "${GREEN}✔ 二进制程序清理完成。${RESET}"
        echo -e "${YELLOW}💡 提示：本地测速历史仍保留在 $DB_PATH。如需彻底清除，请在菜单中选择选项 6。${RESET}"
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
        2) start_tui "standard" ;;
        3) start_tui "compact" ;;
        4) start_with_theme ;;
        5) show_config_details ;;
        6) reset_database ;;
        7) show_shortcuts ;;
        8) uninstall_riptide ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择！${RESET}"; sleep 1 ;;
    esac
done
