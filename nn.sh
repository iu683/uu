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
CURRENT_LOCAL_VERSION="v1.4.0" # 当前固定的本地脚本对应版本

# 动态定位 Riptide 实际安装路径
get_paths() {
    REAL_EXEC_PATH=$(command -v riptide 2>/dev/null)
    if [ -z "$REAL_EXEC_PATH" ] && [ -f "$HOME/.local/bin/riptide" ]; then
        REAL_EXEC_PATH="$HOME/.local/bin/riptide"
    fi
}

# 获取状态、版本及远程更新提示
get_status() {
    get_paths
    if [ -n "$REAL_EXEC_PATH" ]; then
        status="${GREEN}已安装${RESET}"
        riptide_version="${YELLOW}${CURRENT_LOCAL_VERSION}${RESET}"
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
    echo -e "${GREEN} 1. 一键安装 / 检查更新 Riptide${RESET}"
    echo -e "${GREEN} 2. 标准模式启动 (主菜单)${RESET}"
    echo -e "${GREEN} 3. 紧凑模式启动 (跳过大Logo)${RESET}"
    echo -e "${GREEN} 4. 自定义色彩主题启动${RESET}"
    echo -e "${GREEN} 5. 测速历史数据库路径查看${RESET}"
    echo -e "${GREEN} 6. 重置本地数据库 (清空历史)${RESET}"
    echo -e "${GREEN} 7. TUI 界面快捷键指南${RESET}"
    echo -e "${GREEN} 8. 卸载 Riptide 二进制${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
}

# 1. 动态获取最新版并智能解压安装
download_and_install() {
    echo -e "\n${YELLOW}[正在从 GitHub 检索 Riptide 最新发布版本...]${RESET}"
    
    # 自动请求 GitHub API 获取最新的 tag_name
    LATEST_TAG=$(curl -s "$GITHUB_API" | grep -o '"tag_name": "[^"]*' | grep -o '[^"]*$')
    
    if [ -z "$LATEST_TAG" ]; then
        LATEST_TAG="v1.4.0"
    fi
    echo -e "${GREEN}最新发布版本: ${LATEST_TAG}${RESET}"

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
    echo -e "${GREEN}准备下载目标资源: ${FILENAME}${RESET}"
    
    TMP_DIR=$(mktemp -d)
    if curl -L "$DOWNLOAD_URL" -o "${TMP_DIR}/${FILENAME}"; then
        echo -e "${YELLOW}下载成功，正在解压处理...${RESET}"
        
        # 解压二进制文件到隔离的临时目录
        tar -xzf "${TMP_DIR}/${FILENAME}" -C "$TMP_DIR"
        
        # 💡 核心修复：剔除压缩包本身，仅查找名为 riptide 或包含 riptide 的“普通文件(-type f)”
        # 这样能有效避免由于重名文件夹或压缩包本身引发的 mv 判定失效
        FOUND_EXEC=$(find "$TMP_DIR" -type f ! -name "*.tar.gz" -name "*riptide*" | head -n 1)
        
        if [ -n "$FOUND_EXEC" ]; then
            mkdir -p "$HOME/.local/bin"
            
            # 清理历史残余，防止覆盖失败
            rm -f "$HOME/.local/bin/riptide"
            
            # 移动并强制规范命名为标准的 riptide
            mv "$FOUND_EXEC" "$HOME/.local/bin/riptide"
            chmod +x "$HOME/.local/bin/riptide"
            
            # 创建或刷新全局软链接
            if [ -w "/usr/local/bin" ]; then
                rm -f /usr/local/bin/riptide
                ln -s "$HOME/.local/bin/riptide" /usr/local/bin/riptide
            else
                sudo rm -f /usr/local/bin/riptide
                sudo ln -s "$HOME/.local/bin/riptide" /usr/local/bin/riptide
            fi
            echo -e "${GREEN}✔ Riptide (${LATEST_TAG}) 安装/自更新成功！${RESET}"
            echo -e "${GREEN}👉 快捷指令: riptide${RESET}"
        else
            echo -e "${RED}❌ 错误：解压后未在包内探测到有效的 riptide 可执行文件。${RESET}"
            echo -e "${YELLOW}当前包内结构树如下，请检查官方打包格式是否有变：${RESET}"
            ls -la "$TMP_DIR"
        fi
    else
        echo -e "${RED}❌ 下载失败，请检查网络是否能够顺畅访问 GitHub 节点。${RESET}"
        echo -e "${RED}失败资源链接: ${DOWNLOAD_URL}${RESET}"
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
    echo -e "\n${GREEN}【v1.4.0 新增及经典主题列表（共 20 种）】${RESET}"
    echo -e "${YELLOW}经典氛围:${RESET} default, ocean, midnight, sunset, forest, rose, nord, arctic, cyber, ember"
    echo -e "${YELLOW}高端复古:${RESET} gruvbox, tokyo, catppuccin, solarized, rosepine, monokai, onedark, github, everforest"
    echo -ne "\n${GREEN}请输入你想使用的主题名称 (直接回车默认 default): ${RESET}"
    read -r target_theme
    if [ -z "$target_theme" ]; then
        target_theme="default"
    fi
    echo -e "${YELLOW}正在以 [${target_theme}] 主题启动 Riptide 并将其写入本地偏好...${RESET}"
    "$REAL_EXEC_PATH" --theme "$target_theme"
}

# 5. 查看配置与数据库实际路径
show_config_details() {
    echo -e "\n${YELLOW}------------------------------------------------${RESET}"
    echo -e "${GREEN}【SQLite 历史跑网数据库绝对路径】:${RESET}"
    echo -e " $DB_PATH"
    echo -e "${GREEN}【当前文件详情与占用体积】:${RESET}"
    if [ -f "$DB_PATH" ]; then
        ls -lh "$DB_PATH"
    else
        echo -e " 暂无本地数据库文件，运行一次网络测速后将自动生成该文件。"
    fi
    echo -e "${YELLOW}------------------------------------------------${RESET}"
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 6. 重置本地数据库
reset_database() {
    if [ -f "$DB_PATH" ]; then
        echo -e "\n${RED}⚠️ 警告：准备重置本地 SQLite 数据库...${RESET}"
        echo -ne "${RED}此操作将永久清空所有测速历史数据（但会保留您选择的主题偏好）！确定执行？(y/n): ${RESET}"
        read -r ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            rm -f "$DB_PATH"
            echo -e "${GREEN}✔ 历史数据库已成功重置，历史跑网记录已清空。${RESET}"
        else
            echo -e "${GREEN}操作已取消。${RESET}"
        fi
    else
        echo -e "\n${YELLOW}提示：本地尚无历史数据库文件，无需清空。${RESET}"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 7. 快捷键面板 (基于 v1.4.0 QoL 版本同步更新)
show_shortcuts() {
    clear
    echo -e "${YELLOW}==================================================================${RESET}"
    echo -e "${YELLOW}             Riptide TUI (v1.4.0) 终端界面快捷操作指南            ${RESET}"
    echo -e "${YELLOW}==================================================================${RESET}"
    echo -e "  ${GREEN}【常规导航与交互】${RESET}"
    echo -e "   ← → ↑ ↓ / h j k l  : 菜单选项移动 / 主题实时浏览切换"
    echo -e "   Enter              : 确认选中当前项 / 应用并保存选中的主题"
    echo -e "   Tab                : 在设置界面切换到下一组配置节"
    echo -e "   1, 2, 3, 4         : 快捷跳转 (1:测速 / 2:带宽 / 3:设置 / 4:退出)"
    echo -e "   Esc / m            : 立即返回主菜单"
    echo -e "   ?                  : 全局打开帮助遮罩层"
    echo -e "   g                  : 实时在外部浏览器中打开 GitHub 项目主页"
    echo -e "   b                  : 【在设置-关于页面】打开请作者喝杯咖啡链接"
    echo -e "  ${GREEN}【测速面板 (Speed Test)】${RESET}"
    echo -e "   s                  : 测速过程中或结束后 — 保存 / 用自定义名称重命名记录"
    echo -e "   y                  : 复制本次测速结果到系统剪贴板 (格式: ↓248 ↑19 12ms)"
    echo -e "   c                  : 实时切换网速/流量显示单位"
    echo -e "   r                  : 强制重新启动网络测速"
    echo -e "   t                  : 实时切换显示/隐藏紧凑型标语与大 Logo"
    echo -e "  ${GREEN}【带宽监控面板 (Bandwidth)】${RESET}"
    echo -e "   p                  : 暂停 / 继续当前的实时流量监控"
    echo -e "   a                  : 开启/切换活跃应用网络面板 (跨平台，零门槛免 Root)"
    echo -e "  ${GREEN}【全局退出】${RESET}"
    echo -e "   q / Ctrl+C         : 立即退出 Riptide"
    echo -e "${YELLOW}==================================================================${RESET}"
    echo -ne "${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 8. 卸载功能
uninstall_riptide() {
    get_paths
    echo -e "\n${RED}⚠️ 警告：准备进入 Riptide 二进制文件卸载流程...${RESET}"
    echo -ne "${RED}确认要删除系统中的 riptide 程序及全局调用软链接吗？(y/n): ${RESET}"
    read -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        # 移除软链接
        if [ -w "/usr/local/bin" ]; then rm -f /usr/local/bin/riptide; else sudo rm -f /usr/local/bin/riptide; fi
        # 移除本地用户目录的二进制
        [ -n "$REAL_EXEC_PATH" ] && [ "$REAL_EXEC_PATH" != "/usr/local/bin/riptide" ] && rm -f "$REAL_EXEC_PATH"
        rm -f "$HOME/.local/bin/riptide"
        
        echo -e "${GREEN}✔ 核心二进制程序已完全清理。${RESET}"
        echo -e "${YELLOW}💡 提示：为保护您的资产，SQLite 测速历史仍保留在 $DB_PATH。${RESET}"
        echo -e "   如需彻底不留痕迹，请再次运行本脚本并选择 [选项 6] 清理数据库。${RESET}"
    else
        echo -e "${GREEN}已取消卸载流程。${RESET}"
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
