#!/bin/bash

# ========================================
# Croc 文件传输一键安装与使用脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 初始化本地配置文件路径
CONF_FILE="/opt/Croc/.croc_env.conf"
mkdir -p /opt/Croc 2>/dev/null

# 默认下载/输出目录
DEFAULT_OUT_DIR="."

# 读取持久化配置
load_config() {
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    fi
    OUT_DIR="${OUT_DIR:-$DEFAULT_OUT_DIR}"
}

# 保存持久化配置
save_config() {
cat > "$CONF_FILE" <<EOF
OUT_DIR="$OUT_DIR"
EOF
}

# 联网动态获取 GitHub 官方最新 Tag 版本的函数
fetch_latest_version_tag() {
    local lat_ver
    # 通过 API 获取最新 tag_name，加入超时与重试保障直连稳定性
    lat_ver=$(curl -fsSL --connect-timeout 8 --retry 3 https://api.github.com/repos/schollz/croc/releases/latest 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    # 如果由于网络极端原因获取失败，则采用最新已知的稳定版作为兜底
    if [ -z "$lat_ver" ]; then
        lat_ver="v10.4.4"
    fi
    echo "$lat_ver"
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
        CROC_STATUS="${GREEN}已安装${RESET} ${YELLOW}(${CURRENT_VERSION})${RESET}"
    else
        CROC_STATUS="${RED}未安装${RESET}"
    fi
}

# 1) 快速全新安装 (动态获取最新版本)
install_croc() {
    echo -e "${YELLOW}➔ 正在检测并配置系统安装环境...${RESET}"
    
    # 【Alpine 分支】：执行依赖安装与官方一键托管脚本流（其内部自动拉取最新）
    if [ -f /etc/alpine-release ]; then
        echo -e "${YELLOW}➔ 检测到 Alpine Linux，正在安装官方必要依赖 (bash / coreutils)...${RESET}"
        apk update && apk add bash coreutils wget >/dev/null 2>&1
        
        echo -e "${GREEN}➔ 正在通过官方一键流获取并安装最新版 Croc...${RESET}"
        wget -qO- https://getcroc.schollz.com | bash

    # 【其他系统分支】：动态抓取最新版本号，直连下载静态二进制包
    elif [[ "$OSTYPE" == "linux-gnu"* ]] || [ -f /etc/debian_version ] || [[ "$OSTYPE" == "freebsd"* ]]; then
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

        echo -e "${YELLOW}➔ 确保依赖正常...${RESET}"
        [ -f /etc/debian_version ] && (apt-get update && apt-get install -y curl tar >/dev/null 2>&1)

        # 核心改动：动态获取云端最新版本
        echo -e "${YELLOW}➔ 正在检索 GitHub 官方最新 Release 版本号...${RESET}"
        LATEST_VERSION=$(fetch_latest_version_tag)
        echo -e "${GREEN}➔ 检测到当前官方最新版本为: ${YELLOW}${LATEST_VERSION}${RESET}"

        echo -e "${YELLOW}➔ 正在下载静态编译包 [${SYS_TYPE} ${ARCH_TAG}]...${RESET}"
        
        TMP_DIR=$(mktemp -d)
        cd "$TMP_DIR" || return
        
        DOWNLOAD_URL="https://github.com/schollz/croc/releases/download/${LATEST_VERSION}/croc_${LATEST_VERSION}_${SYS_TYPE}-${ARCH_TAG}.tar.gz"
        
        curl -fsSL --connect-timeout 15 --retry 5 --retry-delay 3 "$DOWNLOAD_URL" -o croc.tar.gz
        
        if [ $? -eq 0 ] && [ -s croc.tar.gz ]; then
            tar -xzf croc.tar.gz croc 2>/dev/null
            if [ -f croc ]; then
                chmod +x croc
                mv -f croc /usr/local/bin/
            fi
        fi
        cd - >/dev/null && rm -rf "$TMP_DIR"
    else
        echo -e "${RED}❌ 暂不支持的系统架构。${RESET}"
        read -r -p "按回车返回..." ; return
    fi

    # 最终验证
    if command -v croc &>/dev/null || [ -f /usr/local/bin/croc ]; then
        echo -e "${GREEN}🟢 Croc 核心传输组件最新版安装/覆盖成功！${RESET}"
    else
        echo -e "${RED}🔴 Croc 安装失败，请检查网络直连环境。${RESET}"
    fi
    read -r -p "按回车返回主菜单..."
}

# 5) 独立在线检查并安全更新
update_croc() {
    echo -e "${YELLOW}➔ 正在向 GitHub 发起版本合规性检查...${RESET}"
    if ! command -v croc &>/dev/null; then
        echo -e "${RED}❌ 错误：检测到系统尚未安装 Croc，请先选择选项 1 进行全新安装。${RESET}"
        read -r -p "按回车返回..." ; return
    fi

    # 动态抓取云端最新版本
    CLOUD_VERSION=$(fetch_latest_version_tag)
    LOCAL_VERSION=$(croc --version 2>/dev/null | awk '{print $3}')
    
    echo -e "${GREEN}➔ 当前本地版本: ${YELLOW}${LOCAL_VERSION}${RESET}"
    echo -e "${GREEN}➔ 官方云端版本: ${YELLOW}${CLOUD_VERSION}${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"

    if [ "$LOCAL_VERSION" = "$CLOUD_VERSION" ]; then
        echo -e "${GREEN}🟢 检测完毕：您当前已是官方最新版本，无需更新。${RESET}"
    else
        echo -e "${YELLOW}➔ 发现新版本！准备为您在线无缝升级组件...${RESET}"
        if [ -f /etc/alpine-release ]; then
            # Alpine 继续走官方最新流
            wget -qO- https://getcroc.schollz.com | bash
        else
            # 其它系统继续走纯二进制直连覆盖（精准套用动态云端版本）
            ARCH=$(uname -m)
            SYS_TYPE="Linux"
            [[ "$OSTYPE" == "freebsd"* ]] && SYS_TYPE="FreeBSD"
            case "$ARCH" in
                x86_64) ARCH_TAG="64bit" ;; aarch64|arm64) ARCH_TAG="ARM64" ;; *) ARCH_TAG="64bit" ;;
            esac
            
            TMP_DIR=$(mktemp -d)
            cd "$TMP_DIR" || return
            DOWNLOAD_URL="https://github.com/schollz/croc/releases/download/${CLOUD_VERSION}/croc_${CLOUD_VERSION}_${SYS_TYPE}-${ARCH_TAG}.tar.gz"
            curl -fsSL --connect-timeout 15 --retry 3 "$DOWNLOAD_URL" -o croc.tar.gz
            if [ -f croc.tar.gz ]; then
                tar -xzf croc.tar.gz croc 2>/dev/null
                [ -f croc ] && chmod +x croc && mv -f croc /usr/local/bin/
            fi
            cd - >/dev/null && rm -rf "$TMP_DIR"
        fi
        echo -e "${GREEN}🟢 Croc 组件更新程序执行完毕。${RESET}"
    fi
    read -r -p "按回车返回主菜单..."
}

# 7) 自定义设置输出文件夹
set_output_dir() {
    echo -e "${GREEN}当前设定的文件下载保存目录为: ${YELLOW}${OUT_DIR}${RESET}"
    read -r -p "请输入新的保存路径 (支持绝对路径或 ~，留空回车取消修改): " input_path
    
    if [ -n "$input_path" ]; then
        eval expanded_path="$input_path"
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

# 2) 从当前系统深度卸载 Croc
uninstall_croc() {
    echo -e "${YELLOW}➔ 正在卸载 Croc...${RESET}"
    if command -v croc &>/dev/null || [ -f /usr/local/bin/croc ] || [ -f /usr/bin/croc ]; then
        rm -f /usr/local/bin/croc /usr/bin/croc 2>/dev/null
        local croc_path
        croc_path=$(command -v croc 2>/dev/null)
        [ -n "$croc_path" ] && rm -f "$croc_path"
        echo -e "${GREEN}🟢 Croc 已从当前系统成功卸载。${RESET}"
    else
        echo -e "${YELLOW}⚠️  系统中未发现已安装的 Croc。${RESET}"
    fi
    read -r -p "按回车返回主菜单..."
}

# 3) 安全发送本地文件/目录 (完美适配新版 CROC_SECRET 规范)
send_file() {
    if ! command -v croc &>/dev/null; then
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
        # 【核心修正】：完美适配新版本规范，通过注入环境变量传递密码，移除了被禁用的 --code 参数
        CROC_SECRET="$code" croc send "${valid_paths[@]}"
    fi

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}🟢 文件/目录传输任务执行完毕。${RESET}"
    else
        echo -e "${RED}🔴 传输中断或发送失败。${RESET}"
    fi
    read -r -p "按回车返回主菜单..."
}

# 4) 📥 接收远端文件/目录
receive_file() {
    if ! command -v croc &>/dev/null; then
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
    echo -e "${GREEN}     ◈  Croc 点对点安全传输面板  ◈      ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 当前系统环境 : ${YELLOW}${OS}${RESET}"
    echo -e "${GREEN} 传输组件状态 : ${CROC_STATUS}${RESET}"
    echo -e "${GREEN} 当前接收目录 : ${YELLOW}${OUT_DIR}${RESET}"
    echo -e "${GREEN} 加密传输协议 : ${YELLOW}PAKE (端到端全密文)${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  1) 安装 Croc${RESET}"
    echo -e "${GREEN}  2) 更新 Croc${RESET}"
    echo -e "${GREEN}  3) 卸载 Croc${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  4) 安全发送本地文件/目录 (多选)${RESET}"
    echo -e "${GREEN}  5) 接收远端文件/目录 (凭码提取)${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  6) 设置文下载文件夹${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  0) 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}"

    echo -ne "${GREEN} 请选择操作编号: ${RESET}"
    read -r choice

    case $choice in
        1) install_croc ;;
        2) update_croc ;;
        3) uninstall_croc ;;
        4) send_file ;;
        5) receive_file ;;
        6) set_output_dir ;;
        0) exit 0 ;;
        *) echo -e "${RED}❌ 无效选项，请输入正确的编号！${RESET}" ; read -r -p "按回车继续..." ;;
    esac
done
