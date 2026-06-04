#!/bin/sh
# =========================================================================
#       ◈ 多系统通用运维工具箱一键部署面板 (POSIX Shell 完美兼容版)
# =========================================================================

# 权限校验
if [ "$(id -u)" -ne 0 ]; then
    echo "\033[31m❌ 错误：请使用 root 权限或 sudo 运行此脚本！\033[0m"
    exit 1
fi

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ================== 精准系统检测 ==================
detect_os() {
    if [ -f /etc/os-release ]; then
        os_name=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    else
        os_name="unknown"
    fi
    
    # 规范化家族名称
    case "$os_name" in
        fedora|rocky|alma|centos) os_family="rhel" ;;
        ubuntu|debian|kali|linuxmint) os_family="debian" ;;
        alpine) os_family="alpine" ;;
        amzn) os_family="amazon" ;;
        *) os_family="unknown" ;;
    esac
}

# ================== 核心通用安装引擎 ==================
install_tool_core() {
    local tool="$1"
    local sys_mode="$2"
    
    echo -e "${YELLOW}⚙️ 正在为您在 ${os_name} 系统上配置 ${tool} ...${RESET}"
    
    # 针对特定系统工具做特殊分支处理
    if [ "$sys_mode" = "sys" ]; then
        case "$os_family" in
            rhel)
                yum install epel-release -y >/dev/null 2>&1
                yum install -y "$tool"
                return $?
                ;;
            amazon)
                amazon-linux-extras install epel -y >/dev/null 2>&1 || yum install epel-release -y >/dev/null 2>&1
                yum install -y "$tool"
                return $?
                ;;
            debian)
                if [ "$tool" = "mtr" ]; then
                    apt-get update -y && apt-get install -y mtr-tiny
                    return $?
                fi
                ;;
        esac
    fi

    # 标准通用安装路由
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 && apt-get install -y "$tool"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$tool"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$tool"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$tool"
    else
        echo -e "${RED}❌ 错误：无法识别此系统的包管理器！${RESET}"
        return 1
    fi
}

# 检查是否安装
check_installed() {
    command -v "$1" >/dev/null 2>&1
}

# ================== 工具元数据驱动器 (代替容易闪退的关联数组) ==================
# 格式化存储明细： 编号 | 工具名称 | 运行测试模式 | 系统专属限制 (留空代表通用)
get_tool_data() {
    case "$1" in
        1)  echo "curl:help:" ;;
        2)  echo "wget:help:" ;;
        3)  echo "sudo:help:" ;;
        4)  echo "socat:help:" ;;
        5)  echo "htop:run:" ;;
        6)  echo "iftop:run:" ;;
        7)  echo "unzip:help:" ;;
        8)  echo "tar:help:" ;;
        9)  echo "tmux:help:" ;;
        10) echo "ffmpeg:help:" ;;
        11) echo "btop:run:" ;;
        12) echo "ranger:run_root:" ;;
        13) echo "ncdu:run_root:" ;;
        14) echo "fzf:run_root:" ;;
        15) echo "vim:help_root:" ;;
        16) echo "nano:help_root:" ;;
        17) echo "git:help_root:" ;;
        18) echo "screen:sys:centos,rocky,amzn" ;;
        19) echo "masscan:sys:centos,rocky,amzn" ;;
        20) echo "iperf3:sys:" ;;
        21) echo "mtr:sys:" ;;
        *)  echo "NONE" ;;
    esac
}

# ================== 智能动态菜单渲染 ==================
show_menu() {
    clear
    echo -e "${GREEN}=====================================${RESET}"
    echo -e "${GREEN}     ◈ 运维必备全能工具箱面板 ◈      ${RESET}"
    echo -e "${GREEN}=====================================${RESET}"
    echo -e "${GREEN} 宿主系统:${RESET} ${YELLOW}$os_name${RESET}"
    echo -e "${GREEN} 核心架构:${RESET} ${YELLOW}$(uname -m)${RESET}"
    echo -e "${GREEN}------------------------------------=${RESET}"
    
    local i=1
    while [ $i -le 21 ]; do
        local data=$(get_tool_data $i)
        IFS=":" read -r tool mode support_os _ <<EOF
$data
EOF
        # 校验系统特定的软件展示限制
        if [ -n "$support_os" ]; then
            echo ",$support_os," | grep -q ",$os_name,"
            if [ $? -ne 0 ]; then
                i=$((i+1))
                continue
            fi
        fi

        # 状态标色
        if check_installed "$tool"; then
            status="${GREEN}✔ 已安装${RESET}"
        else
            status="${RED}✖ 未安装${RESET}"
        fi

        # 优雅的对齐格式化输出
        printf "${GREEN} [%02d] %-12s${RESET} %b\n" "$i" "$tool" "$status"
        i=$((i+1))
    done
    
    echo -e "${GREEN}------------------------------------=${RESET}"
    echo -e "${YELLOW} [99] 批量/单个多选工具卸载${RESET}"
    echo -e "${RED} [00] 退出${RESET}"
    echo -e "${GREEN}=====================================${RESET}"
}

# ================== 动作调度核心执行器 ==================
execute_action() {
    local tool="$1"
    local mode="$2"

    if ! check_installed "$tool"; then
        install_tool_core "$tool" "$mode"
        if [ $? -ne 0 ] || ! check_installed "$tool"; then
            echo -e "${RED}❌ $tool 安装失败，请检查软件源仓库配置。${RESET}"
            return 1
        fi
        echo -e "${GREEN}✅ $tool 成功部署就绪！${RESET}"
    else
        echo -e "${GREEN}💡 检测到 $tool 已经安装在系统环境中。${RESET}"
    fi

    # 引导运行或调出帮助信息
    echo -e "${YELLOW}-------------------------------------${RESET}"
    case "$mode" in
        help)      echo -e "即将调取帮助快照: $tool --help"; sleep 1; "$tool" --help ;;
        run)       echo -e "即将立刻进入并运行工具: $tool"; sleep 1; "$tool" ;;
        run_root)  echo -e "即将切入根路径运行工具: $tool"; sleep 1; cd / && "$tool"; cd ~ ;;
        help_root) echo -e "即将切入根路径调取帮助: $tool -h"; sleep 1; cd / && "$tool" -h; cd ~ ;;
        sys)       echo -e "环境包部署完成，您现在可以直接在全局键入 [ ${tool} ] 使用它。" ;;
    esac
}

# ================== 智能多选御载引擎 ==================
uninstall_mode() {
    clear
    echo -e "${RED}=====================================${RESET}"
    echo -e "${RED}      ◈ 软件卸载清洗中心 ◈          ${RESET}"
    echo -e "${RED}=====================================${RESET}"
    
    # 动态扫描已存在的工具
    local count=0
    local i=1
    while [ $i -le 21 ]; do
        local data=$(get_tool_data $i)
        IFS=":" read -r tool _ <<EOF
$data
EOF
        if check_installed "$tool"; then
            count=$((count+1))
            eval "inst_tool_$count=\"$tool\""
            echo -e "${GREEN}  $count) $tool${RESET}"
        fi
        i=$((i+1))
    done

    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}🍃 系统非常洁净，没有发现可供卸载的工具组件。${RESET}"
        read -r -p "按 [回车键] 返回菜单..." dummy
        return
    fi

    echo ""
    echo -ne "${YELLOW}请输入需要清洗的软件编号 (支持以空格或逗号多选, 如 1 3 5): ${RESET}"
    read -r choices
    
    # 兼容处理用户输入的逗号
    choices=$(echo "$choices" | tr ',' ' ')
    
    for choice in $choices; do
        # 验证数字合法性
        echo "$choice" | grep -q '^[0-9]\+$' || continue
        if [ "$choice" -ge 1 ] && [ "$choice" -le $count ]; then
            eval "target_tool=\$inst_tool_$choice"
            echo -e "${YELLOW}⚡ 正在全盘清洗组件: $target_tool ...${RESET}"
            
            # 移除静默输出，允许打印错误信息，以便排查基础固件无法卸载的问题
            if command -v apt-get >/dev/null 2>&1; then
                # 使用 purge 彻底清理核心配置
                apt-get purge -y "$target_tool"
            elif command -v dnf >/dev/null 2>&1; then
                dnf remove -y "$target_tool"
            elif command -v yum >/dev/null 2>&1; then
                yum remove -y "$target_tool"
            elif command -v apk >/dev/null 2>&1; then
                apk del "$target_tool"
            fi
            
            # 重新检查是否真的被卸载了
            if check_installed "$target_tool"; then
                echo -e "${RED}❌ $target_tool 移除失败！可能该组件是系统核心依赖，被包管理器保护。${RESET}"
            else
                echo -e "${GREEN}✓ $target_tool 已安全移除！${RESET}"
            fi
        else
            echo -e "${RED}❌ 无效的选择序列号: $choice${RESET}"
        fi
    done
    read -r -p "操作完成，按 [回车键] 返回主菜单..." dummy
}
# ================== 主循环入口 ==================
detect_os

while true; do
    show_menu
    echo -ne "${GREEN}请输入您的首选操作编号: ${RESET}"
    read -r sub_choice

    # 兼容非标数字格式输入
    if [ "$sub_choice" = "0" ] || [ "$sub_choice" = "00" ]; then
        echo -e "${YELLOW}感谢使用，控制台脚本已安全退出。${RESET}"
        exit 0
    fi

    if [ "$sub_choice" = "99" ]; then
        uninstall_mode
        continue
    fi

    # 判断输入合法性与范围
    echo "$sub_choice" | grep -q '^[0-9]\+$'
    if [ $? -ne 0 ] || [ "$sub_choice" -lt 1 ] || [ "$sub_choice" -gt 21 ]; then
        echo -e "${RED}❌ 警告：请输入有效的菜单指令数字！${RESET}"
        sleep 1
        continue
    fi

    # 获取选定的配置行
    tool_raw_data=$(get_tool_data "$sub_choice")
    if [ "$tool_raw_data" != "NONE" ]; then
        IFS=":" read -r target_tool target_mode _ <<EOF
$tool_raw_data
EOF
        execute_action "$target_tool" "$target_mode"
        echo ""
        read -r -p "👉 任务完毕，按 [回车键] 重回主菜单..." dummy
    fi
done
