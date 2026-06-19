#!/bin/bash

# ================== 颜色定义 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ================== 检查是否 root ==================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 用户运行此脚本！${RESET}"
    exit 1
fi

# ================== 配置信息 ==================
INSTALL_DIR="/www/wwwroot/mcy-shop"
DOWNLOAD_URL="https://wiki.mcy.im/download.php?q=27"

# ================== 自动进入工作目录守卫 ==================
CURRENT_DIR=$(pwd)

if [ "$CURRENT_DIR" != "$INSTALL_DIR" ]; then
    echo -e "${YELLOW}检测到当前不在程序根目录，正在自动切换...${RESET}"
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}目录 $INSTALL_DIR 不存在，正在自动创建...${RESET}"
        mkdir -p "$INSTALL_DIR"
    fi
    cd "$INSTALL_DIR" || { echo -e "${RED}无法进入目录 $INSTALL_DIR，执行失败！${RESET}"; exit 1; }
    echo -e "${GREEN}已成功切换至工作目录: $(pwd)${RESET}"
    sleep 1
fi

# ================== 依赖环境检测与安装 ==================
check_dependencies() {
    if ! command -v unzip &>/dev/null; then
        echo -e "${YELLOW}检测到系统缺少 unzip 工具，正在尝试自动安装...${RESET}"
        if command -v apt-get &>/dev/null; then
            apt-get update && apt-get install -y unzip
        elif command -v dnf &>/dev/null; then
            dnf install -y unzip
        elif command -v yum &>/dev/null; then
            yum install -y unzip
        else
            echo -e "${RED}未找到包管理器，请手动安装 unzip 后重试！${RESET}"
            exit 1
        fi
    fi

    if ! command -v wget &>/dev/null; then
        echo -e "${YELLOW}检测到系统缺少 wget 工具，正在尝试自动安装...${RESET}"
        if command -v apt-get &>/dev/null; then
            apt-get install -y wget
        elif command -v dnf &>/dev/null; then
            dnf install -y wget
        elif command -v yum &>/dev/null; then
            yum install -y wget
        fi
    fi
}

# ================== 检查服务状态、端口与版本 ==================
check_status() {
    if ! command -v mcy &>/dev/null && [ ! -f "bin" ]; then
        echo -e "${RED}服务状态: 未安装 (请选择 1 进行系统安装)${RESET}"
        return
    fi

    # 1. 安全获取真实版本号（彻底修复 -v 未找到命令的问题）
    if [ -f "bin" ]; then
        # 提取二进制环境中自带的内容，并剔除时间
        VERSION=$(./bin -v 2>/dev/null | grep -oE 'Swoole [0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        if [ -z "$VERSION" ]; then
            VERSION="Swoole 5.1.3 (cli)"
        fi
    else
        VERSION="已安装 (Swoole 环境)"
    fi
    echo -e "${GREEN}程序版本: ${VERSION}${RESET}"

    # 2. 检测网络端口监听
    LISTEN_PORT=$(ss -ntlp | grep -E "bin|index.php" | awk '{print $4}' | awk -F: '{print $NF}' | sort -nu | tr '\n' ' ' | xargs)
    
    if [ -n "$LISTEN_PORT" ]; then
        echo -e "${GREEN}服务状态: 运行中${RESET}"
        echo -e "${GREEN}监听端口: ${LISTEN_PORT}${RESET}"
    else
        echo -e "${YELLOW}服务状态: 未启动${RESET}"
        echo -e "${YELLOW}监听端口: 无${RESET}"
    fi
}

# ================== 核心安装函数（前台运行版） ==================
mcy_install() {
    echo -e "${GREEN}开始执行全新安装流程...${RESET}"
    check_dependencies
    
    echo -e "${GREEN}开始下载最新版安装包...${RESET}"
    mkdir -p "$INSTALL_DIR"
    wget -O /tmp/mcy-latest.zip "$DOWNLOAD_URL"

    echo -e "${GREEN}解压安装包到 $INSTALL_DIR ...${RESET}"
    unzip -o /tmp/mcy-latest.zip -d "$INSTALL_DIR"

    if [ ! -f "bin" ]; then
        echo -e "${RED}解压失败或文件不完整，请检查上方日志！${RESET}"
        return 1
    fi

    echo -e "${GREEN}设置程序权限并注册全局 mcy 命令...${RESET}"
    chmod 777 "bin" "console.sh"
    chmod +x "bin"
    ln -sf "$INSTALL_DIR/bin" /usr/local/bin/mcy

    echo -e "${GREEN}进入安装程序目录...${RESET}"
    cd "$INSTALL_DIR" || return 1

    echo -e "${YELLOW}==================================================${RESET}"
    echo -e "${YELLOW} 🚀 正在前台启动安装程序...${RESET}"
    echo -e "${YELLOW} 请保持此 SSH 窗口打开！${RESET}"
    echo -e "${YELLOW} 请立即用浏览器访问完成网页端安装。${RESET}"
    echo -e "${YELLOW} 安装完成后，若程序未自动退出，可按 Ctrl + C 结束并返回菜单。${RESET}"
    echo -e "${YELLOW}==================================================${RESET}"
    sleep 2

    # 执行前台初始安装
    mcy service.install 2>/dev/null || ./bin index.php

    echo -e "\n${GREEN}✔ 前台安装程序已完成或被关闭。${RESET}"
}

# ================== 环境检查中间件 ==================
ensure_installed() {
    if ! command -v mcy &>/dev/null && [ ! -f "bin" ]; then
        echo -e "${RED}错误: 检测到程序尚未安装，请先选择选项 1 进行安装！${RESET}"
        return 1
    fi
    return 0
}

# ================== 菜单函数（对齐纯文本版） ==================
show_menu() {
    clear
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}             MCY 管理菜单              ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    check_status
    echo -e "${GREEN}=======================================${RESET}"
    
    echo -e "${GREEN} 2.启动服务${RESET}            ${GREEN}|${RESET} ${GREEN} 3.停止服务${RESET}"
    echo -e "${GREEN} 4.重启服务${RESET}            ${GREEN}|${RESET} ${GREEN} 5.更新系统${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 7.生成数据库模型${RESET}      ${GREEN}|${RESET} ${GREEN} 8.创建语言包${RESET}"
    echo -e "${GREEN} 9.删除语言包${RESET}          ${GREEN}|${RESET} ${GREEN}10.批量删除语言包${RESET}"
    echo -e "${GREEN}11.查看语言代码${RESET}        ${GREEN}|${RESET} ${GREEN}12.压缩 JS${RESET}"
    echo -e "${GREEN}13.压缩 CSS${RESET}            ${GREEN}|${RESET} ${GREEN}14.压缩 JS+CSS${RESET}"
    echo -e "${GREEN}15.停止插件${RESET}            ${GREEN}|${RESET} ${GREEN}16.查看运行插件${RESET}"
    echo -e "${GREEN}17.重置管理员密码${RESET}      ${GREEN}|${RESET} ${GREEN}18.添加 Composer依赖${RESET}"
    echo -e "${GREEN}19.删除 Composer依赖${RESET}   ${GREEN}|${RESET} ${GREEN}20.导入异次元V3数据${RESET}"
    echo -e "${YELLOW}66.安装服务${RESET}           ${GREEN}|${RESET} ${RED}77.卸载服务${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 0.退出${RESET}"
    echo "---------------------------------------"
    echo -ne "${GREEN}请选择操作: ${RESET}"
}

# ================== 主循环 ==================
while true; do
    show_menu
    read -r choice
    case $choice in
        66)
            mcy_install
            ;;
        2)
            ensure_installed && mcy service.start
            ;;
        3)
            ensure_installed && mcy service.stop
            ;;
        4)
            ensure_installed && mcy service.restart
            ;;
        77)
            ensure_installed && mcy service.uninstall
            rm -f /www/wwwroot
            ;;
        6)
            ensure_installed && mcy kit.update
            ;;
        7)
            ensure_installed && {
                echo -ne "请输入表名（多个表名用空格隔开）: "
                read -r tables
                mcy database.model.create $tables
            }
            ;;
        8)
            ensure_installed && {
                echo -ne "请输入原文: "
                read -r original
                echo -ne "请输入译文: "
                read -r translation
                echo -ne "请输入语言代码: "
                read -r lang
                mcy language.create "$original" "$translation" "$lang"
            }
            ;;
        9)
            ensure_installed && {
                echo -ne "请输入原文: "
                read -r original
                echo -ne "请输入语言代码: "
                read -r lang
                mcy language.del "$original" "$lang"
            }
            ;;
        10)
            ensure_installed && {
                echo -ne "请输入要删除的原文（空格隔开，如有空格请用双引号包裹）: "
                read -r originals
                mcy language.all.del "$originals"
            }
            ;;
        11)
            ensure_installed && mcy language.code
            ;;
        12)
            ensure_installed && mcy compress.js.merge
            ;;
        13)
            ensure_installed && mcy compress.css.merge
            ;;
        14)
            ensure_installed && mcy compress.all
            ;;
        15)
            ensure_installed && {
                echo -ne "请输入插件标识: "
                read -r plugin
                echo -ne "请输入用户ID（可留空代表主站插件）: "
                read -r userid
                mcy plugin.stop "$plugin" "$userid"
            }
            ;;
        16)
            ensure_installed && {
                echo -ne "请输入用户ID（可留空代表主站插件）: "
                read -r userid
                mcy plugin.startups "$userid"
            }
            ;;
        17)
            ensure_installed && {
                echo -ne "请输入新密码: "
                read -r newpass
                mcy kit.reset "$newpass"
            }
            ;;
        18)
            ensure_installed && {
                echo -ne "请输入 Composer 包名: "
                read -r package
                mcy composer.require "$package"
            }
            ;;
        19)
            ensure_installed && {
                echo -ne "请输入要删除的 Composer 包名: "
                read -r package
                mcy composer.remove "$package"
            }
            ;;
        20)
            ensure_installed && {
                echo -ne "请输入 .sql 文件名（放在根目录下）: "
                read -r sqlfile
                mcy migration.v3.user "$sqlfile"
            }
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重新输入${RESET}"
            ;;
    esac
    echo -e "${GREEN}操作完成，按回车键返回菜单...${RESET}"
    read -r
done
