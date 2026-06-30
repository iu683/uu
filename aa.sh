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

# 动态定位 Quick-SSH 实际安装与数据路径
get_paths() {
    SSH_CONFIG="$HOME/.ssh/config"
    QSSHRC_FILE="$HOME/.qsshrc"
    # 优先寻找全局软链，其次寻找用户本地目录
    REAL_EXEC_PATH=$(command -v qssh 2>/dev/null)
    if [ -z "$REAL_EXEC_PATH" ] && [ -f "$HOME/.local/bin/qssh" ]; then
        REAL_EXEC_PATH="$HOME/.local/bin/qssh"
    fi
}

# 获取状态与版本信息
get_status() {
    get_paths
    if [ -n "$REAL_EXEC_PATH" ]; then
        status="${GREEN}已安装${RESET}"
        
        # 提取 qssh 版本号
        version_info=$($REAL_EXEC_PATH help 2>/dev/null | grep -i "qssh" | head -n 1 | awk '{print $2}')
        
        # 保底机制
        [ -z "$version_info" ] && version_info="1.1.11"
        qssh_version="${YELLOW}${version_info}${RESET}"
    else
        status="${RED}未安装${RESET}"
        qssh_version="${RED}-${RESET}"
    fi

    # 检查 SSH 配置文件中是否有连接配置
    if [ -f "$SSH_CONFIG" ] && grep -q -i "Host " "$SSH_CONFIG" 2>/dev/null; then
        config_status="${GREEN}已有连接${RESET}"
    else
        config_status="${YELLOW}暂无连接${RESET}"
    fi
}

# 菜单面板
show_menu() {
    clear
    get_status
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} ◈  Quick-SSH 终端连接管理面板 ◈ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}版本 :${RESET} $qssh_version"
    echo -e "${GREEN}连接 :${RESET} $config_status"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 自动安装/更新 (Linux x64)${RESET}"
    echo -e "${GREEN}2. 启动 TUI 交互界面${RESET}"
    echo -e "${GREEN}3. 快捷添加 SSH 连接${RESET}"
    echo -e "${GREEN}4. TUI 常用快捷键速查${RESET}"
    echo -e "${GREEN}5. 彻底卸载与净化${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
}

# 核心下载与软链接建立函数
download_latest_qssh() {
    echo -e "\n${YELLOW}正在从 GitHub 检索 Quick-SSH 最新版本信息...${RESET}"
    
    # 获取最新 release 标签
    LATEST_TAG=$(curl -s https://api.github.com/repos/CCE-Li/Quick-SSH/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -z "$LATEST_TAG" ]; then
        echo -e "${RED}❌ 无法获取最新版本信息，请检查网络（或 GitHub API 是否被限流）。${RESET}"
        return 1
    fi
    
    echo -e "${GREEN}发现最新版本: ${LATEST_TAG}${RESET}"
    
    # 构造 Linux x64 下载链接（根据您提供的信息，qssh 是单文件二进制，非压缩包）
    DOWNLOAD_URL="https://github.com/CCE-Li/Quick-SSH/releases/download/${LATEST_TAG}/qssh-linux-x64"
    
    TMP_DIR=$(mktemp -d)
    echo -e "${YELLOW}正在下载: ${DOWNLOAD_URL}${RESET}"
    
    if curl -L "$DOWNLOAD_URL" -o "${TMP_DIR}/qssh"; then
        echo -e "${GREEN}✔ 下载成功，正在建立全局系统调用...${RESET}"
        
        # 确保基础目录存在
        mkdir -p "$HOME/.local/bin"
        
        if [ -f "${TMP_DIR}/qssh" ]; then
            # 1. 移动原始二进制到用户目录
            mv "${TMP_DIR}/qssh" "$HOME/.local/bin/qssh"
            chmod +x "$HOME/.local/bin/qssh"
            
            # 2. 建立至全局 /usr/local/bin 的软链接，彻底解决 sh 不认 PATH 的问题
            if [ -w "/usr/local/bin" ]; then
                rm -f /usr/local/bin/qssh
                ln -s "$HOME/.local/bin/qssh" /usr/local/bin/qssh
                echo -e "${GREEN}✔ 全局软链接已指向: /usr/local/bin/qssh (任意 Shell 环境下均可直接运行)${RESET}"
            else
                echo -e "${YELLOW}⚠️ 由于当前非 root 权限，尝试使用 sudo 建立全局软链接...${RESET}"
                sudo rm -f /usr/local/bin/qssh
                sudo ln -s "$HOME/.local/bin/qssh" /usr/local/bin/qssh
            fi
            
            echo -e "${GREEN}✔ 最新版 Quick-SSH 成功安装！${RESET}"
        else
            echo -e "${RED}❌ 未找到 qssh 二进制文件。${RESET}"
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
install_qssh() {
    download_latest_qssh
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 2. 启动 TUI 界面
start_tui() {
    get_paths
    if [ -n "$REAL_EXEC_PATH" ]; then
        echo -e "\n${GREEN}正在调起 Quick-SSH TUI 交互界面...${RESET}"
        "$REAL_EXEC_PATH"
    else
        echo -e "\n${RED}未检测到 qssh 命令，请先执行选项 1 进行自动安装！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
    fi
}

# 3. 快捷添加连接
add_ssh_connection() {
    get_paths
    if [ -z "$REAL_EXEC_PATH" ]; then
        echo -e "\n${RED}未检测到已安装的 Quick-SSH。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
        return
    fi

    echo -e "\n${GREEN}[快捷添加 SSH 连接]${RESET}"
    echo -ne "${YELLOW}1. 请输入连接别名 (例如 my-server): ${RESET}"
    read -r alias_name
    [ -z "$alias_name" ] && echo -e "${RED}别名不能为空！${RESET}" && return

    echo -ne "${YELLOW}2. 请输入登录信息 (格式 root@192.168.1.100:22): ${RESET}"
    read -r login_info
    [ -z "$login_info" ] && echo -e "${RED}登录信息不能为空！${RESET}" && return

    echo -ne "${YELLOW}3. 请输入私钥路径 (直接回车默认使用 ~/.ssh/id_rsa): ${RESET}"
    read -r key_path
    [ -z "$key_path" ] && key_path="$HOME/.ssh/id_rsa"

    echo -e "\n${GREEN}正在写入连接配置...${RESET}"
    "$REAL_EXEC_PATH" add "$alias_name" "$login_info" --key "$key_path"
    
    echo -ne "\n${GREEN}添加成功！按回车键返回主菜单...${RESET}" && read -r
}

# 4. 快捷键指南面板
show_shortcuts() {
    clear
    echo -e "${YELLOW}======================================================${RESET}"
    echo -e "${YELLOW}               Quick-SSH TUI 常用键位速查             ${RESET}"
    echo -e "${YELLOW}======================================================${RESET}"
    echo -e "${GREEN}[基础控制]${RESET}"
    echo -e "  ↑ / ↓          : 移动光标选择不同的服务器连接"
    echo -e "  Enter          : 直接发起 SSH 会话连入选中服务器"
    echo -e "  Space (空格)   : 选择/取消选择当前连接（可用于批量操作）"
    echo -e "  d              : 删除当前光标连接；若多选则批量删除"
    echo -e "  P              : 批量检测已勾选连接延迟；未勾选则检测全部"
    echo -e "  q              : 退出当前界面"
    echo -e "\n${GREEN}[🔥 特色闪光点：高级拖拽上传]${RESET}"
    echo -e "  * 在会话连接中，直接把本地文件/目录拖进当前终端窗口。"
    echo -e "  * 软件会通过高级算法拦截路径，并自动打开新本地窗口利用 SFTP 上传。"
    echo -e "  * 并发数可在 ~/.qsshrc 中修改 UploadConcurrency 项进行控制。"
    echo -e "  * 不占用原 SSH 会话，上传过程完全在后台/新窗口独立运行。"
    echo -e "${YELLOW}======================================================${RESET}"
    echo -ne "${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 5. 清理与卸载
uninstall_qssh() {
    get_paths
    echo -e "\n${RED}警告：准备进入 Quick-SSH 卸载与程序清理流程...${RESET}"
    echo -e "${YELLOW}注意：标准 OpenSSH 配置文件 (~/.ssh/config) 会予以保留，防止您的核心数据丢失。${RESET}"
    echo -ne "${RED}确定要清除 qssh 二进制程序和全局调用配置吗？(y/n): ${RESET}"
    read -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        # 清理二进制与软链
        if [ -w "/usr/local/bin" ]; then
            rm -f /usr/local/bin/qssh
        else
            sudo rm -f /usr/local/bin/qssh
        fi
        
        if [ -n "$REAL_EXEC_PATH" ] && [ "$REAL_EXEC_PATH" != "/usr/local/bin/qssh" ]; then
            rm -f "$REAL_EXEC_PATH"
        fi
        rm -f "$HOME/.local/bin/qssh"
        rm -f "$QSSHRC_FILE"

        echo -e "${GREEN}✔ 全局软链、核心二进制及独立运行时配置文件已全部分离净化！${RESET}"
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
        1) install_qssh ;;
        2) start_tui ;;
        3) add_ssh_connection ;;
        4) show_shortcuts ;;
        5) uninstall_qssh ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择！${RESET}"; sleep 1 ;;
    esac
done
