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
    # 如果目录不存在（如首次安装），则自动创建
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}目录 $INSTALL_DIR 不存在，正在自动创建...${RESET}"
        mkdir -p "$INSTALL_DIR"
    fi
    # 自动切换到目标目录
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

# ================== 检查服务状态 ==================
check_status() {
    if [ ! -f "bin" ]; then
        echo -e "${RED}服务状态: 未安装 (请选择 1 进行系统安装)${RESET}"
        return
    fi
    # 检查前台安装程序 index.php 或常规服务是否在运行
    STATUS=$(ps aux | grep -v grep | grep -E "bin index.php|mcy service")
    if [ -n "$STATUS" ]; then
        echo -e "${GREEN}服务状态: 运行中 (或正在进行前台安装)${RESET}"
    else
        echo -e "${YELLOW}服务状态: 未启动${RESET}"
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

    echo -e "${GREEN}设置程序权限...${RESET}"
    chmod 777 "bin" "console.sh"
    chmod +x "bin"

    echo -e "${GREEN}进入安装程序目录...${RESET}"
    cd "$INSTALL_DIR" || return 1

    echo -e "${YELLOW}==================================================${RESET}"
    echo -e "${YELLOW} 🚀 正在前台启动安装程序...${RESET}"
    echo -e "${YELLOW} 请保持此 SSH 窗口打开！${RESET}"
    echo -e "${YELLOW} 请立即用浏览器访问：http://服务器IP:端口 完成网页端安装。${RESET}"
    echo -e "${YELLOW} 安装完成后，若程序未自动退出，可按 Ctrl + C 结束并返回菜单。${RESET}"
    echo -e "${YELLOW}==================================================${RESET}"
    sleep 2

    # 执行前台安装，脚本会在此处阻塞停止
    ./bin index.php

    # 当网页端安装完程序退出，或用户 Ctrl+C 后，才会继续向下走
    echo -e "\n${GREEN}✔ 前台安装程序已关闭。${RESET}"
}

# ================== 环境检查中间件 ==================
ensure_installed() {
    if [ ! -f "bin" ]; then
        echo -e "${RED}错误: 检测到程序尚未安装，请先选择选项 1 进行安装！${RESET}"
        return 1
    fi
    return 0
}

# ================== 菜单函数 ==================
show_menu() {
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}         MCY 管理菜单         ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    check_status
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${YELLOW}1.  安装服务${RESET}"
    echo -e "${GREEN}2.  启动服务${RESET}"
    echo -e "${GREEN}3.  停止服务${RESET}"
    echo -e "${GREEN}4.  重启服务${RESET}"
    echo -e "${GREEN}5.  卸载服务${RESET}"
    echo -e "${GREEN}6.  更新系统${RESET}"
    echo -e "${GREEN}7.  生成数据库模型${RESET}"
    echo -e "${GREEN}8.  创建语言包${RESET}"
    echo -e "${GREEN}9.  删除语言包${RESET}"
    echo -e "${GREEN}10. 批量删除语言包${RESET}"
    echo -e "${GREEN}11. 查看语言代码${RESET}"
    echo -e "${GREEN}12. 压缩 JS${RESET}"
    echo -e "${GREEN}13. 压缩 CSS${RESET}"
    echo -e "${GREEN}14. 压缩 JS+CSS${RESET}"
    echo -e "${GREEN}15. 停止插件${RESET}"
    echo -e "${GREEN}16. 查看运行插件${RESET}"
    echo -e "${GREEN}17. 重置超级管理员密码${RESET}"
    echo -e "${GREEN}18. 添加 Composer依赖${RESET}"
    echo -e "${GREEN}19. 删除 Composer依赖${RESET}"
    echo -e "${GREEN}20. 导入异次元 V3用户数据${RESET}"
    echo -e "${GREEN}0.  退出${RESET}"
    echo "--------------------------------"
    echo -ne "${GREEN}请选择操作: ${RESET}"
}

# ================== 主循环 ==================
while true; do
    show_menu
    read -r choice
    case $choice in
        1)
            mcy_install
            ;;
        2)
            ensure_installed && cd "$INSTALL_DIR" && ./mcy service.start
            ;;
        3)
            ensure_installed && cd "$INSTALL_DIR" && ./mcy service.stop
            ;;
        4)
            ensure_installed && cd "$INSTALL_DIR" && ./mcy service.restart
            ;;
        5)
            ensure_installed && cd "$INSTALL_DIR" && ./mcy service.uninstall
            ;;
        6)
            ensure_installed && cd "$INSTALL_DIR" && ./mcy kit.update
            ;;
        7)
            ensure_installed && {
                echo -ne "请输入表名（空格隔开）: "
                read -r tables
                cd "$INSTALL_DIR" && ./mcy database.model.create $tables
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
                cd "$INSTALL_DIR" && ./mcy language.create "$original" "$translation" "$lang"
            }
            ;;
        9)
            ensure_installed && {
                echo -ne "请输入原文: "
                read -r original
                echo -ne "请输入语言代码: "
                read -r lang
                cd "$INSTALL_DIR" && ./mcy language.del "$original" "$lang"
            }
            ;;
        10)
            ensure_installed && {
                echo -ne "请输入要删除的原文（空格隔开，如有空格请用双引号包裹）: "
                read -r originals
                cd "$INSTALL_DIR" && ./mcy language.all.del "$originals"
            }
            ;;
        11)
            ensure_installed && cd "$INSTALL_DIR" && ./mcy language.code
            ;;
        12)
            ensure_installed && cd "$INSTALL_DIR" && ./mcy compress.js.merge
            ;;
        13)
            ensure_installed && cd "$INSTALL_DIR" && ./mcy compress.css.merge
            ;;
        14)
            ensure_installed && cd "$INSTALL_DIR" && ./mcy compress.all
            ;;
        15)
            ensure_installed && {
                echo -ne "请输入插件标识: "
                read -r plugin
                echo -ne "请输入用户ID（可留空代表主站插件）: "
                read -r userid
                cd "$INSTALL_DIR" && ./mcy plugin.stop "$plugin" "$userid"
            }
            ;;
        16)
            ensure_installed && {
                echo -ne "请输入用户ID（可留空代表主站插件）: "
                read -r userid
                cd "$INSTALL_DIR" && ./mcy plugin.startups "$userid"
            }
            ;;
        17)
            ensure_installed && {
                echo -ne "请输入新密码: "
                read -r newpass
                cd "$INSTALL_DIR" && ./mcy kit.reset "$newpass"
            }
            ;;
        18)
            ensure_installed && {
                echo -ne "请输入 Composer 包名: "
                read -r package
                cd "$INSTALL_DIR" && ./mcy composer.require "$package"
            }
            ;;
        19)
            ensure_installed && {
                echo -ne "请输入要删除的 Composer 包名: "
                read -r package
                cd "$INSTALL_DIR" && ./mcy composer.remove "$package"
            }
            ;;
        20)
            ensure_installed && {
                echo -ne "请输入 .sql 文件名（放在根目录下）: "
                read -r sqlfile
                cd "$INSTALL_DIR" && ./mcy migration.v3.user "$sqlfile"
            }
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重新输入${RESET}"
            ;;
    esac
    echo -e "\n${GREEN}操作完成，按回车键返回菜单...${RESET}"
    read -r
done
