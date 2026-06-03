#!/bin/bash
# =========================================================================
# 字体与语言环境智能管理面板（多系统自动适配）
# =========================================================================

# 严格的 Root 权限检查
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31m❌ 错误：请使用 root 权限（或通过 sudo）运行此脚本！\033[0m"
    exit 1
fi

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 自动精确识别发行版
get_os_type() {
    if [ -f /etc/alpine-release ]; then
        echo "Alpine"
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu) echo "Ubuntu" ;;
            debian) echo "Debian" ;;
            centos|rhel|rocky|almalinux) echo "RedHat" ;;
            *) echo "Linux" ;;
        esac
    else
        echo "Linux"
    fi
}

OS=$(get_os_type)

# 动态获取当前系统的语言状态
get_current_locale() {
    echo "${LANG:-未设置}"
}

# 核心语言环境应用函数
apply_locale() {
    local target_lang=$1
    
    case "$OS" in
        Ubuntu|Debian)
            echo -e "${YELLOW}🔧 正在更新 apt 缓存并安装必要字体与语言包...${RESET}"
            apt-get update -y >/dev/null 2>&1
            apt-get install -y locales >/dev/null 2>&1
            
            if [ "$target_lang" = "zh_CN.UTF-8" ]; then
                apt-get install -y fonts-wqy-microhei fonts-wqy-zenhei >/dev/null 2>&1
            else
                apt-get install -y fonts-dejavu fonts-liberation >/dev/null 2>&1
            fi

            # 配置并生成 Locale（移除 set -e 规避 sed 报错引发挂科）
            echo -e "${YELLOW}🔄 正在生成语言环境: $target_lang...${RESET}"
            if [ -f /etc/locale.gen ]; then
                # 先取消注释，如果不存在则追加
                sed -i "s/^#\?\s*\($target_lang UTF-8\)/\1/" /etc/locale.gen 2>/dev/null
                if ! grep -q "$target_lang UTF-8" /etc/locale.gen; then
                    echo "$target_lang UTF-8" >> /etc/locale.gen
                fi
            fi
            locale-gen "$target_lang" >/dev/null 2>&1
            
            # 强制锁入环境配置
            if command -v update-locale >/dev/null 2>&1; then
                update-locale LANG="$target_lang" LC_ALL="$target_lang" >/dev/null 2>&1
            fi
            echo "LANG=$target_lang" > /etc/default/locale
            echo "LC_ALL=$target_lang" >> /etc/default/locale
            ;;
            
        Alpine)
            echo -e "${YELLOW}🔧 正在通过 apk 补全 Alpine 字体与 musl 本地化组件...${RESET}"
            # 关键补丁：Alpine 必须安装 musl-locales 才能真正支持 zh_CN 等非英语言环境
            apk add --no-cache musl-locales musl-locales-lang >/dev/null 2>&1
            
            if [ "$target_lang" = "zh_CN.UTF-8" ]; then
                # 从官方 testing 仓库拉取文泉驿中文字体
                apk add --no-cache ttf-dejavu font-wqy-zenhei --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing >/dev/null 2>&1
            else
                apk add --no-cache ttf-dejavu >/dev/null 2>&1
            fi
            
            # Alpine 的环境变量持久化机制
            echo -e "${YELLOW}🔄 正在写入系统全局环境变量...${RESET}"
            mkdir -p /etc/profile.d
            echo "export LANG=$target_lang" > /etc/profile.d/locale.sh
            echo "export LC_ALL=$target_lang" >> /etc/profile.d/locale.sh
            chmod +x /etc/profile.d/locale.sh
            ;;
            
        *)
            echo -e "${RED}⚠️ 当前系统 [${OS}] 未做深度定制，尝试通用变量写入...${RESET}"
            ;;
    esac

    # 立即污染并刷新当前临时 Shell 生效
    export LANG="$target_lang"
    export LC_ALL="$target_lang"
}

# 主循环面板
while true; do
    clear
    CURRENT_LANG=$(get_current_locale)
    
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}       ◈ 字体与语言环境管理面板 ◈      ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 检测到系统 : ${YELLOW}${OS}${RESET}"
    echo -e "${GREEN} 当前语言包 : ${YELLOW}${CURRENT_LANG}${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  1. 切换为【中文环境】${RESET}"
    echo -e "${GREEN}  2. 切换为【英文环境】${RESET}"
    echo -e "${GREEN}  0. 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    
    echo -ne "${GREEN} 请选择操作编号: ${RESET}"
    read choice

    case "$choice" in
        1)
            echo -e "\n${YELLOW}🚀 开始配置中文环境...${RESET}"
            apply_locale "zh_CN.UTF-8"
            echo -e "\n${GREEN}✅ 中文环境及支持字体配置完成！${RESET}"
            echo -e "${YELLOW}💡 提示：为了让 SSH 终端完整显示中文，请重新连接您的 SSH 会话。${RESET}"
            read -rp "按回车键返回菜单..."
            ;;
        2)
            echo -e "\n${YELLOW}🚀 开始配置英文环境...${RESET}"
            apply_locale "en_US.UTF-8"
            echo -e "\n${GREEN}✅ 英文环境配置完成！${RESET}"
            echo -e "${YELLOW}💡 提示：界面已重置，部分未刷新组件重新连接 SSH 后即可恢复纯英文。${RESET}"
            read -rp "按回车键返回菜单..."
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}❌ 输入错误，无此选项${RESET}"
            sleep 1
            ;;
    esac
done
