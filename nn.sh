#!/bin/bash

# ========================================
# Croc 文件传输一键安装与使用脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 初始化本地配置文件路径
CONF_FILE="/opt/vpsbackup/.croc_env.conf"
mkdir -p /opt/vpsbackup

# 默认下载/输出目录（如果配置文件不存在则采用当前目录）
DEFAULT_OUT_DIR="."

# 读取持久化配置
load_config() {
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    fi
    # 确保变量有默认值
    OUT_DIR="${OUT_DIR:-$DEFAULT_OUT_DIR}"
}

# 保存持久化配置
save_config() {
cat > "$CONF_FILE" <<EOF
OUT_DIR="$OUT_DIR"
EOF
}

# 获取系统与Croc状态信息
get_system_env() {
    load_config
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
    else
        OS=$(uname -s)
    fi

    if command -v croc &>/dev/null; then
        CURRENT_VERSION=$(croc --version 2>/dev/null | awk '{print $3}')
        CROC_STATUS="${GREEN}已安装 (${RESET}${CURRENT_VERSION}${GREEN})${RESET}"
    else
        CROC_STATUS="${RED}未安装${RESET}"
    fi
}

# 核心下载与提取逻辑 (内部复用)
download_and_extract() {
    local target_version="$1"
    
    if [ -f /etc/alpine-release ]; then
        echo -e "${YELLOW}➔ 检测到 Alpine Linux，自动安装基础组件...${RESET}"
        apk update && apk add curl tar coreutils >/dev/null 2>&1
    elif [ -f /etc/debian_version ]; then
        echo -e "${YELLOW}➔ 检测到 Ubuntu/Debian/Debian系，确保 curl 和 tar 正常...${RESET}"
        apt-get update && apt-get install -y curl tar >/dev/null 2>&1
    fi

    if [[ "$OSTYPE" == "linux-gnu"* ]] || [ -f /etc/alpine-release ] || [[ "$OSTYPE" == "freebsd"* ]]; then
        ARCH=$(uname -m)
        SYS_TYPE="Linux"
        [[ "$OSTYPE" == "freebsd"* ]] && SYS_TYPE="FreeBSD"

        case "$ARCH" in
            x86_64)       ARCH_TAG="64bit" ;;
            i386|i686)    ARCH_TAG="32bit" ;;
            aarch64|arm64) ARCH_TAG="ARM64" ;;
            armv5*)       ARCH_TAG="ARMv5" ;;
            arm*)         ARCH_TAG="ARM" ;;
            riscv64)      ARCH_TAG="RISCV64" ;;
            *)            ARCH_TAG="64bit" ;;
        esac

        echo -e "${YELLOW}➔ 正在直连 GitHub 下载静态编译包 [${SYS_TYPE} ${ARCH_TAG}]...${RESET}"
        
        TMP_DIR=$(mktemp -d)
        cd "$TMP_DIR" || return
        
        DOWNLOAD_URL="https://github.com/schollz/croc/releases/download/${target_version}/croc_${target_version}_${SYS_TYPE}-${ARCH_TAG}.tar.gz"
        curl -fsSL "$DOWNLOAD_URL" -o croc.tar.gz
        
        if [ $? -eq 0 ] && [ -s croc.tar.gz ]; then
            tar -xzf croc.tar.gz croc 2>/dev/null
            if [ -f croc ]; then
                chmod +x croc
                mv -f croc /usr/local/bin/
                DOWNLOAD_SUCCESS=0
            else
                DOWNLOAD_SUCCESS=1
            fi
        else
            DOWNLOAD_SUCCESS=1
        fi
        
        cd - >/dev/null && rm -rf "$TMP_DIR"
        return $DOWNLOAD_SUCCESS

    elif [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &>/dev/null; then
            brew install croc
            return 0
        else
            echo -e "${RED}❌ 未检测到 Homebrew，请先安装 Homebrew 再重试。${RESET}"
            return 1
        fi
    else
        echo -e "${RED}❌ 不支持的系统架构: $OSTYPE${RESET}"
        return 1
    fi
}

# 1) 纯净全新安装
install_croc() {
    echo -e "${YELLOW}➔ 正在启动全新安装程序...${RESET}"
    if command -v croc &>/dev/null; then
        echo -e "${YELLOW}⚠️  系统已存在 Croc 组件，继续操作将覆盖现有版本。${RESET}"
    fi

    # 锁定当前已知稳定版
    LATEST_VERSION="v10.4.4"
    download_and_extract "$LATEST_VERSION"
    
    if [ $? -eq 0 ] && (command -v /usr/local/bin/croc &>/dev/null || command -v croc &>/dev/null); then
        echo -e "${GREEN}🟢 Croc 核心传输组件全新安装成功！${RESET}"
    else
        echo -e "${RED}🔴 Croc 安装失败，请检查网络是否能正常直连 github.com。${RESET}"
    fi
    read -r -p "按回车返回主菜单..."
}

# 5) 独立在线检查更新
update_croc() {
    echo -e "${YELLOW}➔ 正在向 GitHub 发起版本合规性检查...${RESET}"
    if ! command -v croc &>/dev/null; then
        echo -e "${RED}❌ 错误：检测到系统尚未安装 Croc，请先选择选项 1 进行全新安装。${RESET}"
        read -r -p "按回车返回..." ; return
    fi

    # 获取云端最新 Tag
    CLOUD_VERSION=$(curl -s https://api.github.com/repos/schollz/croc/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$CLOUD_VERSION" ]; then
        echo -e "${YELLOW}⚠️  在线获取最新版本失败，尝试强制拉取同步 v10.4.4 稳定版...${RESET}"
        CLOUD_VERSION="v10.4.4"
    fi

    LOCAL_VERSION=$(croc --version 2>/dev/null | awk '{print $3}')
    
    echo -e "${GREEN}➔ 当前本地版本: ${YELLOW}${LOCAL_VERSION}${RESET}"
    echo -e "${GREEN}➔ 官方云端版本: ${YELLOW}${CLOUD_VERSION}${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"

    if [ "$LOCAL_VERSION" = "$CLOUD_VERSION" ]; then
        echo -e "${GREEN}🟢 检测完毕：您当前已是官方最新版本，无需更新。${RESET}"
    else
        echo -e "${YELLOW}➔ 发现新版本！准备为您在线无感升级...${RESET}"
        download_and_extract "$CLOUD_VERSION"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}🟢 Croc 成功升级至最新版本: ${YELLOW}${CLOUD_VERSION}${RESET}"
        else
            echo -e "${RED}🔴 升级失败，请检查网络直连环境。${RESET}"
        fi
    fi
    read -r -p "按回车返回主菜单..."
}

# 7) 自定义设置输出文件夹
set_output_dir() {
    echo -e "${GREEN}当前设定的文件下载保存目录为: ${YELLOW}${OUT_DIR}${RESET}"
    read -r -p "请输入新的保存路径 (支持绝对路径或 ~，留空回车取消修改): " input_path
    
    if [ -n "$input_path" ]; then
        # 解析波浪号 ~ 为当前用户真实的家目录路径
        eval expanded_path="$input_path"
        
        # 尝试创建该目录（如果是相对路径 `.` 或当前目录则无需处理）
        if [ "$expanded_path" != "." ]; then
            mkdir -p "$expanded_path" 2>/dev/null
            if [ $? -ne 0 ]; then
                echo -e "${RED}❌ 路径创建失败：请检查权限或路径输入是否正确！${RESET}"
                read -r -p "按回车返回..." ; return
            fi
        fi
        
        OUT_DIR="$input_path"
        save_config
        echo -e "${GREEN}🟢 成功！文件接收保存路径已修改为: ${YELLOW}${OUT_DIR}${RESET}"
    else
        echo -e "${YELLOW}未做任何修改。${RESET}"
    fi
    read -r -p "按回车返回主菜单..."
}

# 卸载 Croc
uninstall_croc() {
    echo -e "${YELLOW}➔ 正在卸载 Croc...${RESET}"
    if [[ "$OSTYPE" == "linux-gnu"* ]] || [ -f /etc/alpine-release ]; then
        if command -v croc &>/dev/null || [ -f /usr/local/bin/croc ]; then
            rm -f /usr/local/bin/croc 2>/dev/null
            local croc_path
            croc_path=$(command -v croc 2>/dev/null)
            [ -n "$croc_path" ] && rm -f "$croc_path"
            echo -e "${GREEN}🟢 Croc 已从系统成功卸载。${RESET}"
        else
            echo -e "${YELLOW}⚠️  系统中未发现已安装的 Croc。${RESET}"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        brew uninstall croc 2>/dev/null
        echo -e "${GREEN}🟢 Croc 已从 macOS 卸载。${RESET}"
    else
        echo -e "${RED}❌ 不支持的系统架构: $OSTYPE${RESET}"
    fi
    read -r -p "按回车返回主菜单..."
}

# 发送文件/目录
send_file() {
    if ! command -v croc &>/dev/null && [ ! -f /usr/local/bin/croc ]; then
        echo -e "${RED}❌ 错误：请先选择选项 1 安装 Croc 核心传输组件。${RESET}"
        read -r -p "按回车返回..." ; return
    fi

    echo -e "${YELLOW}请输入要发送的文件或目录路径 (多个路径请用 空格 分隔):${RESET}"
    read -r -a paths
    
    if [ ${#paths[@]} -eq 0 ]; then
        echo -e "${YELLOW}操作已取消。${RESET}"
        read -r -p "按回车返回主菜单..." ; return
    fi

    valid_paths=()
    for p in "${paths[@]}"; do
        if [[ -e "$p" ]]; then
            valid_paths+=("$p")
        else
            echo -e "${RED}❌ 路径不存在，已自动忽略: $p${RESET}"
        fi
    done

    if [[ ${#valid_paths[@]} -eq 0 ]]; then
        echo -e "${RED}🔴 没有找到任何有效路径，返回主菜单。${RESET}"
        read -r -p "按回车返回..." ; return
    fi

    echo -e "${GREEN}---------------------------------------${RESET}"
    read -r -p "请输入自定义接收代码 (直接回车则随机生成): " code
    echo -e "${GREEN}---------------------------------------${RESET}"

    if [[ -z "$code" ]]; then
        echo -e "${YELLOW}➔ 正在建立加密信道并自动生成代码...${RESET}"
        croc send "${valid_paths[@]}"
    else
        echo -e "${YELLOW}➔ 正在建立加密信道，使用自定义代码: ${YELLOW}$code${RESET}"
        croc send --code "$code" "${valid_paths[@]}"
    fi

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}🟢 文件/目录传输任务执行完毕。${RESET}"
    else
        echo -e "${RED}🔴 传输中断或发送失败。${RESET}"
    fi
    read -r -p "按回车返回主菜单..."
}

# 接收文件/目录 (核心级完美集成 --out 输出路径)
receive_file() {
    if ! command -v croc &>/dev/null && [ ! -f /usr/local/bin/croc ]; then
        echo -e "${RED}❌ 错误：请先选择选项 1 安装 Croc 核心传输组件。${RESET}"
        read -r -p "按回车返回..." ; return
    fi

    read -r -p "请输入接收连接代码 (Code): " code
    if [[ -z "$code" ]]; then
        echo -e "${RED}❌ 接收连接代码不能为空！${RESET}"
        read -r -p "按回车返回主菜单..." ; return
    fi

    echo -e "${YELLOW}➔ 正在通过安全通道连接远端传输中继...${RESET}"
    echo -e "${YELLOW}➔ 文件将被安全保存至: ${OUT_DIR}${RESET}"
    
    # 注入临时环境变量运行，并携带高度自定义的 --out 变量路径
    CROC_SECRET="$code" croc --out "$OUT_DIR"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}🟢 文件/目录安全接收完成！${RESET}"
    else
        echo -e "${RED}🔴 接收失败：连接超时、代码错误或信道断开。${RESET}"
    fi
    read -r -p "按回车返回主菜单..."
}

# 主菜单循环
while true; do
    clear
    get_system_env
    
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}      ◈  Croc 点对点安全传输面板  ◈      ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 当前系统环境 : ${YELLOW}${OS}${RESET}"
    echo -e "${GREEN} 传输组件状态 : ${CROC_STATUS}${RESET}"
    echo -e "${GREEN} 当前接收目录 : ${YELLOW}${OUT_DIR}${RESET}"
    echo -e "${GREEN} 加密传输协议 : ${YELLOW}PAKE (端到端全密文)${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  1) 安装 Croc${RESET}"
    echo -e "${GREEN}  2) 卸载 Croc${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  3) 安全发送本地文件/目录 (多选)${RESET}"
    echo -e "${GREEN}  4) 接收远端文件/目录 (凭码提取)${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  5) 升级至最新版${RESET}"
    echo -e "${GREEN}  7) 自定义设置下载文件夹${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  0) 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}"

    echo -ne "${GREEN} 请选择操作编号: ${RESET}"
    read -r choice

    case $choice in
        1) install_croc ;;
        2) uninstall_croc ;;
        3) send_file ;;
        4) receive_file ;;
        5) update_croc ;;
        7) set_output_dir ;;
        0) exit 0 ;;
        *) echo -e "${RED}❌ 无效选项，请输入正确的编号！${RESET}" ; read -r -p "按回车继续..." ;;
    esac
done
