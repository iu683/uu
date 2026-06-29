#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
PLAIN='\033[0m'

# 工作目录
WORK_DIR="/opt/reality_checker"

# 架构检测
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        SCANNER_ARCH="linux-amd64"
        CHECKER_ARCH="linux-amd64"
        ;;
    aarch64)
        SCANNER_ARCH="linux-arm64"
        CHECKER_ARCH="linux-arm64"
        ;;
    *)
        echo -e "${RED}暂不支持当前系统架构: ${ARCH}${PLAIN}"
        exit 1
        ;;
esac

# 检查根权限
if [ "$EUID" -ne 0 ]; then
   echo -e "${RED}错误: 请使用 root 用户或 sudo 运行此脚本！${PLAIN}"
   exit 1
fi

# 状态检测函数
check_status() {
    if [ -f "$WORK_DIR/RealiTLScanner" ] && [ -f "$WORK_DIR/reality-checker-bin" ] && [ -f "$WORK_DIR/Country.mmdb" ]; then
        STATUS_DEPLOY="环境部署: 已安装"
    else
        STATUS_DEPLOY="环境部署: 未安装"
    fi

    if [ -f "$WORK_DIR/file.csv" ] && [ -s "$WORK_DIR/file.csv" ]; then
        STATUS_SCAN="扫描数据: 已生成结果"
    else
        STATUS_SCAN="扫描数据: 无扫描数据"
    fi
}

# 菜单函数
show_menu() {
    clear
    check_status
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "${GREEN}    REALITY 扫描与检测一键菜单脚本${PLAIN}"
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "${GREEN} [状态] $STATUS_DEPLOY | $STATUS_SCAN${PLAIN}"
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "${GREEN} 1. 一键部署环境${PLAIN}"
    echo -e "${GREEN} 2. 启动本地扫描${PLAIN}"
    echo -e "${GREEN} 3. 分析过滤数据${PLAIN}"
    echo -e "${GREEN} 4. 卸载清理环境${PLAIN}"
    echo -e "${GREEN} 0. 退出脚本${PLAIN}"
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e -n "${GREEN}请选择操作 [0-4]: ${PLAIN}"
}

# 1. 部署函数
deploy_env() {
    echo -e "${GREEN}[*] 开始部署环境...${PLAIN}"
    
    # 安装必要工具
    if ! command -v wget &> /dev/null || ! command -v unzip &> /dev/null; then
        echo -e "${GREEN}[*] 正在安装依赖包 wget / unzip...${PLAIN}"
        if command -v apt &> /dev/null; then
            apt update && apt install -y wget unzip
        elif command -v yum &> /dev/null; then
            yum install -y wget unzip
        fi
    fi

    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR" || exit

    # 下载 reality-checker
    echo -e "${GREEN}[*] 正在下载 reality-checker...${PLAIN}"
    wget -q --show-progress "https://github.com/V2RaySSR/RealityChecker/releases/latest/download/reality-checker-${CHECKER_ARCH}.zip" -O checker.zip
    unzip -q -o checker.zip
    mv "reality-checker" "reality-checker-bin" 2>/dev/null || true
    rm -f checker.zip

    # 下载 RealiTLScanner
    echo -e "${GREEN}[*] 正在下载 RealiTLScanner...${PLAIN}"
    LATEST_SCANNER_VER=$(wget -qO- "https://api.github.com/repos/XTLS/RealiTLScanner/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_SCANNER_VER" ]; then LATEST_SCANNER_VER="v0.2.3"; fi
    wget -q --show-progress "https://github.com/XTLS/RealiTLScanner/releases/download/${LATEST_SCANNER_VER}/RealiTLScanner-${SCANNER_ARCH}" -O RealiTLScanner
    
    # 下载 GeoIP 数据库
    echo -e "${GREEN}[*] 正在下载 GeoIP 数据库...${PLAIN}"
    wget -q --show-progress "https://github.com/Loyalsoldier/geoip/releases/latest/download/Country.mmdb" -O Country.mmdb

    # 赋予权限
    chmod +x reality-checker-bin RealiTLScanner 2>/dev/null

    echo -e "${GREEN}[✓] 环境部署成功！所有程序已保存在: $WORK_DIR${PLAIN}"
    echo -e -n "${GREEN}按任意键返回菜单...${PLAIN}"
    read -n 1 -s -r
}

# 2. 扫描函数
start_scan() {
    if [ ! -f "$WORK_DIR/RealiTLScanner" ]; then
        echo -e "${GREEN}[X] 错误: 未检测到运行环境，请先执行选项 1 进行部署。${PLAIN}"
        echo -e -n "${GREEN}按任意键返回菜单...${PLAIN}"
        read -n 1 -s -r
        return
    fi

    cd "$WORK_DIR" || exit
    LOCAL_IP=$(wget -qO- -t 1 -T 2 ipinfo.io/ip || wget -qO- -t 1 -T 2 ifconfig.me)
    
    echo -e "${GREEN}--- 启动 RealiTLScanner 扫描 ---${PLAIN}"
    echo -e -n "${GREEN}请输入目标 VPS IP (默认: $LOCAL_IP): ${PLAIN}"
    read vpsip
    vpsip=${vpsip:-$LOCAL_IP}
    
    echo -e -n "${GREEN}请输入扫描线程数 (默认 100): ${PLAIN}"
    read thread
    thread=${thread:-100}
    
    echo -e -n "${GREEN}请输入超时时间(秒) (默认 5): ${PLAIN}"
    read timeout
    timeout=${timeout:-5}

    echo -e "${GREEN}[*] 开始扫描，请耐心等待进度条完成...${PLAIN}"
    ./RealiTLScanner -addr "$vpsip" -port 443 -thread "$thread" -timeout "$timeout" -show -out file.csv

    if [ -f "file.csv" ] && [ -s "file.csv" ]; then
        echo -e "${GREEN}[✓] 扫描完成！初始结果已保存至 $WORK_DIR/file.csv${PLAIN}"
    else
        echo -e "${GREEN}[X] 扫描结束，但未成功生成有效数据。${PLAIN}"
    fi
    echo -e -n "${GREEN}按任意键返回菜单...${PLAIN}"
    read -n 1 -s -r
}

# 3. 检查函数
start_check() {
    if [ ! -f "$WORK_DIR/reality-checker-bin" ] || [ ! -f "$WORK_DIR/file.csv" ]; then
        echo -e "${GREEN}[X] 错误: 缺少必要组件或 file.csv 扫描文件，请先执行选项 1 和 2。${PLAIN}"
        echo -e -n "${GREEN}按任意键返回菜单...${PLAIN}"
        read -n 1 -s -r
        return
    fi

    cd "$WORK_DIR" || exit
    echo -e "${GREEN}--- 启动 reality-checker 过滤分析 ---${PLAIN}"
    ./reality-checker-bin csv file.csv

    echo -e "\n${GREEN}[✓] 分析完成。请从上方输出中挑选适合的 REALITY 域名！${PLAIN}"
    echo -e -n "${GREEN}按任意键返回菜单...${PLAIN}"
    read -n 1 -s -r
}

# 4. 卸载函数
uninstall_all() {
    echo -e -n "${RED}确定要彻底卸载并删除所有工具与数据吗？(y/n): ${PLAIN}"
    read choice
    if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
        rm -rf "$WORK_DIR"
        rm -f "$0"
        echo -e "${GREEN}[✓] 卸载完成！已彻底清理环境并退出。${PLAIN}"
        exit 0
    else
        echo -e "${GREEN}已取消卸载。${PLAIN}"
        echo -e -n "${GREEN}按任意键返回菜单...${PLAIN}"
        read -n 1 -s -r
    fi
}

# 主循环
while true; do
    show_menu
    read choice
    case "$choice" in
        1) deploy_env ;;
        2) start_scan ;;
        3) start_check ;;
        4) uninstall_all ;;
        0) clear; exit 0 ;;
        *) echo -e "${GREEN}请输入正确的选项 [0-4]${PLAIN}" && sleep 1 ;;
    esac
done
