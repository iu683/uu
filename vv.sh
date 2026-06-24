#!/bin/bash

# 标准 ANSI 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

# 载入环境变量并增强 PATH 搜索（加入全局标准路径 /usr/local/bin）
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc" 2>/dev/null
[ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc" 2>/dev/null
export PATH="/usr/local/bin:$HOME/.local/bin:/root/.local/bin:$PATH"

# 动态定位 ReadCLI 实际安装与数据路径
get_paths() {
    READCLI_DATA_DIR="${READCLI_DATA_DIR:-$HOME/.readcli}"
    CONFIG_FILE="$READCLI_DATA_DIR/config.json"
    BOOKSHELF_FILE="$READCLI_DATA_DIR/bookshelf.json"
    # 优先寻找全局软链，其次寻找用户本地目录
    REAL_EXEC_PATH=$(command -v readcli 2>/dev/null)
    if [ -z "$REAL_EXEC_PATH" ] && [ -f "$HOME/.local/bin/readcli" ]; then
        REAL_EXEC_PATH="$HOME/.local/bin/readcli"
    fi
}

# 获取状态与版本信息
get_status() {
    get_paths
    if [ -n "$REAL_EXEC_PATH" ]; then
        status="${GREEN}已安装 ($REAL_EXEC_PATH)${RESET}"
        version_info=$($REAL_EXEC_PATH -v 2>/dev/null | head -n 1)
        [ -z "$version_info" ] && version_info="v0.3.5 (或最新)"
        readcli_version="${YELLOW}${version_info}${RESET}"
    else
        status="${RED}未安装${RESET}"
        readcli_version="${RED}-${RESET}"
    fi

    # 检查书架内是否有书
    if [ -f "$BOOKSHELF_FILE" ] && grep -q '"path"' "$BOOKSHELF_FILE" 2>/dev/null; then
        bookshelf_status="${GREEN}已有藏书${RESET}"
    else
        bookshelf_status="${YELLOW}书架空空${RESET}"
    fi

    # 检查是否有自定义配置
    if [ -f "$CONFIG_FILE" ]; then
        config_status="${YELLOW}自定义配置${RESET}"
    else
        config_status="${GREEN}官方默认${RESET}"
    fi
}

# 菜单面板
show_menu() {
    clear
    get_status
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  ReadCLI 终端阅读管理面板 ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}版本 :${RESET} $readcli_version"
    echo -e "${GREEN}书架 :${RESET} $bookshelf_status"
    echo -e "${GREEN}配置 :${RESET} $config_status"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装${RESET}"
    echo -e "${GREEN}2. 打开书架${RESET}"
    echo -e "${GREEN}3. 浏览并打开指定书籍 (TXT/EPUB)${RESET}"
    echo -e "${GREEN}4. 快速配置BossKey(老板键)${RESET}"
    echo -e "${GREEN}5. 查看系统常用快捷键指南${RESET}"
    echo -e "${GREEN}6. 更新${RESET}"
    echo -e "${GREEN}7. 卸载${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
}

# 核心下载与软链接建立函数
download_latest_readcli() {
    echo -e "\n${YELLOW}正在从 GitHub 检索 ReadCLI 最新版本信息...${RESET}"
    
    # 获取最新 release 标签
    LATEST_TAG=$(curl -s https://api.github.com/repos/lvshp/ReadCLI/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -z "$LATEST_TAG" ]; then
        echo -e "${RED}❌ 无法获取最新版本信息，请检查网络（或 GitHub API 是否被限流）。${RESET}"
        return 1
    fi
    
    echo -e "${GREEN}发现最新版本: ${LATEST_TAG}${RESET}"
    
    # 构造下载链接
    VERSION_NUM=$(echo "$LATEST_TAG" | sed 's/^v//')
    DOWNLOAD_URL="https://github.com/lvshp/ReadCLI/releases/download/${LATEST_TAG}/readcli-linux-amd64-v${VERSION_NUM}.tar.gz"
    
    TMP_DIR=$(mktemp -d)
    echo -e "${YELLOW}正在下载: ${DOWNLOAD_URL}${RESET}"
    
    if curl -L "$DOWNLOAD_URL" -o "${TMP_DIR}/readcli.tar.gz"; then
        echo -e "${GREEN}✔ 下载成功，正在解压并建立全局系统调用...${RESET}"
        tar -zxf "${TMP_DIR}/readcli.tar.gz" -C "$TMP_DIR"
        
        # 确保基础目录存在
        mkdir -p "$HOME/.local/bin"
        mkdir -p "/usr/local/bin"
        
        if [ -f "${TMP_DIR}/readcli" ]; then
            # 1. 移动原始二进制到用户目录
            mv "${TMP_DIR}/readcli" "$HOME/.local/bin/readcli"
            chmod +x "$HOME/.local/bin/readcli"
            
            # 2. 🌟 核心修复：建立至全局 /usr/local/bin 的软链接，彻底解决 sh 不认 PATH 的问题
            rm -f /usr/local/bin/readcli
            ln -s "$HOME/.local/bin/readcli" /usr/local/bin/readcli
            
            echo -e "${GREEN}✔ 最新版 ReadCLI 成功安装！${RESET}"
            echo -e "${GREEN}✔ 全局软链接已指向: /usr/local/bin/readcli (任意 Shell 环境下均可直接运行)${RESET}"
        else
            echo -e "${RED}❌ 解压文件中未找到 readcli 二进制文件。${RESET}"
            rm -rf "$TMP_DIR"
            return 1
        fi
    else
        echo -e "${RED}❌ 下载失败，请检查网络连接。${RESET}"
        rm -rf "$TMP_DIR"
        return 1
    fi
    rm -rf "$TMP_DIR"

    # 兼容性写入环境变量（备用）
    if [ -f "$HOME/.zshrc" ] && ! grep -q "local/bin" "$HOME/.zshrc"; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
    fi
    if [ -f "$HOME/.bashrc" ] && ! grep -q "local/bin" "$HOME/.bashrc"; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    fi
}

# 1. 安装
install_readcli() {
    download_latest_readcli
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 2. 打开书架
start_bookshelf() {
    get_paths
    if [ -n "$REAL_EXEC_PATH" ]; then
        echo -e "\n${GREEN}正在调起 ReadCLI 书架...${RESET}"
        "$REAL_EXEC_PATH"
    else
        echo -e "\n${RED}未检测到 readcli 命令，请先执行选项 1 进行自动安装！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
    fi
}

# 3. 指定路径启动
start_with_book() {
    get_paths
    if [ -z "$REAL_EXEC_PATH" ]; then
        echo -e "\n${RED}未检测到已安装的 ReadCLI。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
        return
    fi

    echo -ne "\n${GREEN}请输入书籍文件的绝对或相对路径 (支持 .txt / .epub): ${RESET}"
    read -r book_path
    if [ -f "$book_path" ]; then
        echo -ne "${YELLOW}请输入阅读时的每页显示行数 (直接回车使用系统默认设置): ${RESET}"
        read -r line_num
        if [ -n "$line_num" ]; then
            "$REAL_EXEC_PATH" -n "$line_num" "$book_path"
        else
            "$REAL_EXEC_PATH" "$book_path"
        fi
    else
        echo -e "${RED}文件不存在，请检查路径！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
    fi
}

# 4. 快速配置 Boss Key
config_boss_key() {
    get_paths
    mkdir -p "$READCLI_DATA_DIR"
    
    echo -e "\n${GREEN}================================${RESET}"
    echo -e "${GREEN}  ReadCLI 老板键 (Boss Key) 配置 ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "在阅读时按下 ${YELLOW}'b'${RESET} 键将立刻触发此伪装指令。"
    
    echo -ne "${YELLOW}请输入你想触发的外部命令 (例如: genact): ${RESET}"
    read -r boss_cmd
    
    if [ -z "$boss_cmd" ]; then
        echo -e "${RED}输入为空，取消配置。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
        return
    fi

    cat <<EOF > "$CONFIG_FILE"
{
  "\$schema": "https://raw.githubusercontent.com/lvshp/ReadCLI/main/config.schema.json",
  "boss_key_command": "$boss_cmd"
}
EOF

    echo -e "\n${GREEN}✔ 老板键伪装指令已成功写入配置文件！${RESET}"
    echo -e "保存路径: $CONFIG_FILE"
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 5. 快捷键指南面板
show_shortcuts() {
    clear
    echo -e "${YELLOW}======================================================${RESET}"
    echo -e "${YELLOW}               ReadCLI 终端快捷键速查表                  ${RESET}"
    echo -e "${YELLOW}======================================================${RESET}"
    echo -e "${GREEN}[书架首页]${RESET}"
    echo -e "  j / k 或 ↑ / ↓  : 移动光标"
    echo -e "  Enter 或 →      : 打开选中的书籍"
    echo -e "  i               : 导入本地书籍 (支持路径补全/拖拽/Ctrl+r递归)"
    echo -e "  o / r           : 书籍排序与过滤"
    echo -e "  x               : 从书架移除书籍"
    echo -e "\n${GREEN}[阅读界面]${RESET}"
    echo -e "  j / k 或 ↑ / ↓  : 向上/向下翻页"
    echo -e "  [ / ] 或 ← / →  : 切换到 上一章/下一章"
    echo -e "  /               : 唤起正文搜索 (n/N 跳转结果)"
    echo -e "  m               : 打开书籍目录 (支持数字跳章)"
    echo -e "  s / B           : 添加或查看书签"
    echo -e "  , (逗号)        : 打开阅读样式个性化设置面板"
    echo -e "  c / T           : 快速切换正文颜色预设 / 切换主题"
    echo -e "  z               : 一键切换 [精简模式] 与 [全信息模式]"
    echo -e "  t               : 开启 / 关闭自动翻页"
    echo -e "  + / -           : 动态增减每页显示的正文行数"
    echo -e "  b               : 瞬间触发 Boss Key (老板键) 伪装"
    echo -e "  f / p           : 开关外边框 / 查看当前精确阅读进度"
    echo -e "  q               : 返回书架或退出"
    echo -e "${YELLOW}======================================================${RESET}"
    echo -ne "${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 6. 更新功能
update_readcli() {
    echo -e "\n${YELLOW}开始检查并强行覆盖更新至最新版...${RESET}"
    readcli u
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 7. 清理与卸载
uninstall_readcli() {
    get_paths
    echo -e "\n${RED}警告：准备进入 ReadCLI 卸载与数据清理流程...${RESET}"
    echo -ne "${RED}是否要清除包括二进制程序、书架、阅读进度在内的所有数据？(y/n): ${RESET}"
    read -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        # 清理二进制与软链
        rm -f /usr/local/bin/readcli
        if [ -n "$REAL_EXEC_PATH" ] && [ "$REAL_EXEC_PATH" != "/usr/local/bin/readcli" ]; then
            rm -f "$REAL_EXEC_PATH"
        fi
        rm -f "$HOME/.local/bin/readcli"
        
        # 清理数据目录
        if [ -d "$READCLI_DATA_DIR" ]; then
            rm -rf "$READCLI_DATA_DIR"
        fi
        echo -e "${GREEN}✔ 全局软链、核心程序及本地数据已全部净化！${RESET}"
    else
        echo "已取消卸载操作。"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 主循环
while true; do
    show_menu
    read -r choice
    case $choice in
        1) install_readcli ;;
        2) start_bookshelf ;;
        3) start_with_book ;;
        4) config_boss_key ;;
        5) show_shortcuts ;;
        6) update_readcli ;;
        7) uninstall_readcli ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择！${RESET}"; sleep 1 ;;
    esac
done
