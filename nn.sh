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

# 动态定位 Quick-SSH 实际安装与数据路径
get_paths() {
    SSH_CONFIG="$HOME/.ssh/config"
    QSSHRC_FILE="$HOME/.qsshrc"
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
        version_info=$($REAL_EXEC_PATH help 2>/dev/null | grep -i "qssh" | head -n 1 | awk '{print $2}')
        [ -z "$version_info" ] && version_info="1.1.11"
        qssh_version="${YELLOW}${version_info}${RESET}"
    else
        status="${RED}未安装${RESET}"
        qssh_version="${RED}-${RESET}"
    fi

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
    echo -e "${YELLOW}5. 🛠️ 一键修复 ~/.ssh 密钥权限${RESET}"
    echo -e "${GREEN}6. 彻底卸载与净化${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
}

# 1. 安装
install_qssh() {
    echo -e "\n${YELLOW}正在从 GitHub 检索 Quick-SSH 最新版本信息...${RESET}"
    LATEST_TAG=$(curl -s https://api.github.com/repos/CCE-Li/Quick-SSH/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_TAG" ]; then
        echo -e "${RED}❌ 无法获取最新版本信息，请检查网络。${RESET}"
        return 1
    fi
    echo -e "${GREEN}发现最新版本: ${LATEST_TAG}${RESET}"
    DOWNLOAD_URL="https://github.com/CCE-Li/Quick-SSH/releases/download/${LATEST_TAG}/qssh-linux-x64"
    TMP_DIR=$(mktemp -d)
    if curl -L "$DOWNLOAD_URL" -o "${TMP_DIR}/qssh"; then
        mkdir -p "$HOME/.local/bin"
        mv "${TMP_DIR}/qssh" "$HOME/.local/bin/qssh"
        chmod +x "$HOME/.local/bin/qssh"
        if [ -w "/usr/local/bin" ]; then
            rm -f /usr/local/bin/qssh
            ln -s "$HOME/.local/bin/qssh" /usr/local/bin/qssh
        else
            sudo rm -f /usr/local/bin/qssh
            sudo ln -s "$HOME/.local/bin/qssh" /usr/local/bin/qssh
        fi
        echo -e "${GREEN}✔ 最新版 Quick-SSH 成功安装！${RESET}"
    else
        echo -e "${RED}❌ 下载失败。${RESET}"
    fi
    rm -rf "$TMP_DIR"
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 2. 启动 TUI 界面
start_tui() {
    get_paths
    if [ -n "$REAL_EXEC_PATH" ]; then
        "$REAL_EXEC_PATH"
    else
        echo -e "\n${RED}未检测到 qssh 命令，请先执行选项 1！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
    fi
}

# 3. 快捷添加连接 (拆分输入项版)
add_ssh_connection() {
    get_paths
    if [ -z "$REAL_EXEC_PATH" ]; then
        echo -e "\n${RED}未检测到已安装的 Quick-SSH。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
        return
    fi
    echo -e "\n${GREEN}[快捷添加 SSH 连接]${RESET}"
    
    # 1. 别名
    echo -ne "${YELLOW}1. 请输入连接别名 (例如 my-server): ${RESET}"
    read -r alias_name
    [ -z "$alias_name" ] && echo -e "${RED}❌ 别名不能为空！${RESET}" && sleep 1 && return

    # 2. 用户名
    echo -ne "${YELLOW}2. 请输入用户名 (例如 root): ${RESET}"
    read -r ssh_user
    [ -z "$ssh_user" ] && echo -e "${RED}❌ 用户名不能为空！${RESET}" && sleep 1 && return

    # 3. 连接地址
    echo -ne "${YELLOW}3. 请输入连接地址/IP (例如 192.168.1.100): ${RESET}"
    read -r ssh_host
    [ -z "$ssh_host" ] && echo -e "${RED}❌ 连接地址不能为空！${RESET}" && sleep 1 && return

    # 4. 端口（带默认值 22）
    echo -ne "${YELLOW}4. 请输入端口号 (回车默认 22): ${RESET}"
    read -r ssh_port
    [ -z "$ssh_port" ] && ssh_port="22"

    # 5. 私钥路径（带默认值 ~/.ssh/id_rsa）
    echo -ne "${YELLOW}5. 请输入私钥路径 (回车默认 ~/.ssh/id_rsa): ${RESET}"
    read -r key_path
    [ -z "$key_path" ] && key_path="$HOME/.ssh/id_rsa"

    # 拼接为 qssh 所需的标准格式: user@host:port
    login_info="${ssh_user}@${ssh_host}:${ssh_port}"

    echo -e "\n${GREEN}正在将 [${alias_name}] (${login_info}) 写入连接配置...${RESET}"
    "$REAL_EXEC_PATH" add "$alias_name" "$login_info" --key "$key_path"
    
    echo -ne "\n${GREEN}添加成功！按回车键返回主菜单...${RESET}" && read -r
}

# 4. 快捷键指南面板
show_shortcuts() {
    clear
    echo -e "${YELLOW}======================================================${RESET}"
    echo -e "${YELLOW}               Quick-SSH TUI 常用键位速查             ${RESET}"
    echo -e "${YELLOW}======================================================${RESET}"
    echo -e "  ↑ / ↓          : 移动光标选择服务器连接"
    echo -e "  Enter          : 一键发起 SSH 会话连入服务器"
    echo -e "  Space (空格)   : 选择/取消选择（用于批量操作）"
    echo -e "  d              : 删除当前/批量删除连接"
    echo -e "  P              : 批量检测连接延迟状态"
    echo -e "  q              : 退出当前界面"
    echo -e "\n${GREEN}[🔥 特色闪光点：高级拖拽上传]${RESET}"
    echo -e "  * 会话连接中，直接把本地文件/目录拖进当前终端窗口。"
    echo -e "  * 软件自动打开新本地窗口利用 SFTP 后台并发上传。"
    echo -e "${YELLOW}======================================================${RESET}"
    echo -ne "${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 5. 🔥 一键修复权限功能
fix_ssh_permissions() {
    echo -e "\n${YELLOW}正在检查并严格标准化修复本地 SSH 目录及文件的权限...${RESET}"
    
    if [ -d "$HOME/.ssh" ]; then
        # 1. 修复目录
        chmod 700 "$HOME/.ssh"
        echo -e "${GREEN}✔ 已将 ~/.ssh 目录权限修正为 700 (drwx------)${RESET}"
        
        # 2. 修复常见私钥文件
        for keyfile in id_rsa id_ecdsa id_ed25519 id_dsa; do
            if [ -f "$HOME/.ssh/$keyfile" ]; then
                chmod 600 "$HOME/.ssh/$keyfile"
                echo -e "${GREEN}✔ 已将私钥 $keyfile 权限修正为 600 (-rw-------)${RESET}"
            fi
        done
        
        # 3. 修复常见公钥及配置文件
        [ -f "$HOME/.ssh/id_rsa.pub" ] && chmod 644 "$HOME/.ssh/id_rsa.pub" && echo -e "${GREEN}✔ 已将公钥 id_rsa.pub 权限修正为 644${RESET}"
        [ -f "$HOME/.ssh/authorized_keys" ] && chmod 600 "$HOME/.ssh/authorized_keys" && echo -e "${GREEN}✔ 已将授权列表 authorized_keys 权限修正为 600${RESET}"
        [ -f "$HOME/.ssh/config" ] && chmod 644 "$HOME/.ssh/config" && echo -e "${GREEN}✔ 已将配置文件 config 权限修正为 644${RESET}"
        
        echo -e "\n${GREEN}🎉 权限修复成功！现已满足 OpenSSH 严格安全指标，可正常使用密匙连入。${RESET}"
    else
        echo -e "${RED}❌ 未在当前用户家目录下找到 .ssh 文件夹，无需修复。${RESET}"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read -r
}

# 6. 清理与卸载
uninstall_qssh() {
    get_paths
    echo -e "\n${RED}警告：准备进入 Quick-SSH 卸载流程... (保留 ~/.ssh/config 数据)${RESET}"
    echo -ne "${RED}确定要清除 qssh 二进制程序和全局调用配置吗？(y/n): ${RESET}"
    read -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        if [ -w "/usr/local/bin" ]; then rm -f /usr/local/bin/qssh; else sudo rm -f /usr/local/bin/qssh; fi
        [ -n "$REAL_EXEC_PATH" ] && [ "$REAL_EXEC_PATH" != "/usr/local/bin/qssh" ] && rm -f "$REAL_EXEC_PATH"
        rm -f "$HOME/.local/bin/qssh" "$QSSHRC_FILE"
        echo -e "${GREEN}✔ 全局清理完成！${RESET}"
    else
        echo "已取消卸载。"
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
        5) fix_ssh_permissions ;;
        6) uninstall_qssh ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择！${RESET}"; sleep 1 ;;
    esac
done
