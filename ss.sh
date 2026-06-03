#!/bin/bash
# =========================================================================
# 字体与语言环境智能管理面板
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

            # 配置并生成 Locale
            echo -e "${YELLOW}🔄 正在生成语言环境: $target_lang...${RESET}"
            if [ -f /etc/locale.gen ]; then
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
            # 1. 补齐多语言底层包与 GNU coreutils 工具链（彻底解决 Busybox 无法解析中文国际化的问题）
            apk add --no-cache musl-locales musl-locales-lang coreutils >/dev/null 2>&1
            
            if [ "$target_lang" = "zh_CN.UTF-8" ]; then
                # 从官方 testing 仓库拉取标准的文泉驿中文字体，防止终端看中文全是 [?] 方块
                apk add --no-cache ttf-dejavu font-wqy-zenhei --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing >/dev/null 2>&1
            else
                apk add --no-cache ttf-dejavu >/dev/null 2>&1
            fi
            
            # 2. 【核心修复】清理所有可能导致干扰的历史语言变量
            rm -f /etc/profile.d/locale.sh
            if [ -f /etc/profile ]; then
                sed -i '/LANG=/d' /etc/profile
                sed -i '/LANGUAGE=/d' /etc/profile
                sed -i '/LC_ALL=/d' /etc/profile
                sed -i '/zh_CN/d' /etc/profile
                sed -i '/en_US/d' /etc/profile
            fi
            
            # 3. 【降维打击】直接强制把变量锁死在全局 /etc/profile 的最底部
            # 这样无论 SSH 工具怎么强推本地英文变量，在进系统的最后一刻都会被强制洗成目标语言
            echo -e "\n🔄 正在向系统全局写入环境配置..."
            cat >> /etc/profile <<EOF

export LANG=$target_lang
export LANGUAGE=$(echo "$target_lang" | cut -d'.' -f1):$(echo "$target_lang" | cut -d'_' -f1)
export LC_ALL=$target_lang
EOF
            ;;
            
        *)
            echo -e "${RED}⚠️ 当前系统 [${OS}] 未做深度定制，尝试通用变量写入...${RESET}"
            ;;
    esac
}

# 主循环面板
while true; do
    clear
    CURRENT_LANG=$(get_current_locale)
    
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}       ◈ 字体与语言环境管理面板 ◈    ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 检测到系统 : ${YELLOW}${OS}${RESET}"
    echo -e "${GREEN} 当前语言包 : ${YELLOW}${CURRENT_LANG}${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  1) 切换为【中文环境】${RESET}"
    echo -e "${GREEN}  2) 切换为【英文环境】${RESET}"
    echo -e "${GREEN}  0) 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    
    echo -ne "${GREEN} 请选择操作编号: ${RESET}"
    read choice

    case "$choice" in
        1)
            echo -e "\n${YELLOW}🚀 开始配置中文环境...${RESET}"
            apply_locale "zh_CN.UTF-8"
            echo -e "\n${GREEN}✅ 中文环境及支持字体配置完成！${RESET}"
            echo -e "${YELLOW}💡 提示：系统底层已修改，请【彻底断开并重新连接 SSH】查看中文效果。${RESET}"
            read -rp "按回车键返回菜单..."
            ;;
        2)
            echo -e "\n${YELLOW}🚀 开始配置英文环境...${RESET}"
            apply_locale "en_US.UTF-8"
            echo -e "\n${GREEN}✅ 英文环境配置完成！${RESET}"
            echo -e "${YELLOW}💡 提示：系统底层已修改，请【彻底断开并重新连接 SSH】查看英文效果。${RESET}"
            read -rp "按回车键返回菜单..."
            ;;
        0)
            echo -e "${YELLOW}退出脚本，祝你今天过得愉快！${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ 输入错误，无此选项${RESET}"
            sleep 1
            ;;
    esac
done
