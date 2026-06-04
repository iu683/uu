#!/bin/bash
# =========================================================================
#       ◈ Tmux 虚拟化工作区通用多端管理面板 ◈
# =========================================================================

# 设置颜色
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
SKYBLUE="\033[36m"
RESET="\033[0m"

# ================== 自动化多平台安装组件 ==================
install_tmux() {
    if ! command -v tmux >/dev/null 2>&1; then
        echo -e "${YELLOW}⚙️ 正在检测宿主系统包管理器并自动部署 Tmux...${RESET}"
        
        # 智能判定包管理器，免去手工 sudo 的尴尬
        local cmd_prefix=""
        if command -v sudo >/dev/null 2>&1; then cmd_prefix="sudo"; fi

        if command -v apk >/dev/null 2>&1; then
            $cmd_prefix apk add --no-cache tmux >/dev/null 2>&1
        elif command -v apt-get >/dev/null 2>&1; then
            $cmd_prefix apt-get update -y >/dev/null 2>&1
            $cmd_prefix apt-get install -y tmux >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            $cmd_prefix dnf install -y tmux >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            $cmd_prefix yum install -y tmux >/dev/null 2>&1
        else
            echo -e "${RED}❌ 错误: 无法识别当前系统架构，请手动安装 tmux 后重试。${RESET}"
            read -r -p "按 [回车键] 返回菜单..." dummy
            return 1
        fi
    fi

    if command -v tmux >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Tmux 虚拟化核心组件已完美就绪！${RESET}"
    else
        echo -e "${RED}❌ Tmux 安装失败，请检查网络源。${RESET}"
    fi
    read -r -p "按 [回车键] 返回菜单..." dummy
}

# ================== 卸载组件 ==================
remove_tmux() {
    if command -v tmux >/dev/null 2>&1; then
        echo -e "${YELLOW}⚡ 正在清空宿主机中的 Tmux 组件...${RESET}"
        local cmd_prefix=""
        if command -v sudo >/dev/null 2>&1; then cmd_prefix="sudo"; fi

        case "$cmd_prefix" in
            *)
                if command -v apk >/dev/null 2>&1; then $cmd_prefix apk del tmux >/dev/null 2>&1;
                elif command -v apt-get >/dev/null 2>&1; then $cmd_prefix apt-get remove -y tmux >/dev/null 2>&1;
                elif command -v dnf >/dev/null 2>&1; then $cmd_prefix dnf remove -y tmux >/dev/null 2>&1;
                elif command -v yum >/dev/null 2>&1; then $cmd_prefix yum remove -y tmux >/dev/null 2>&1; fi
                ;;
        esac
        echo -e "${GREEN}✓ Tmux 已安全卸载。${RESET}"
    else
        echo -e "${YELLOW}提示: 系统中未检测到 Tmux 环境，无需御载。${RESET}"
    fi
    read -r -p "按 [回车键] 返回菜单..." dummy
}

# ================== 智能开启/直连虚拟工作区 ==================
open_workspace() {
    local SESSION_NAME="$1"
    
    # 前置拦截：确保组件存在
    if ! command -v tmux >/dev/null 2>&1; then
        echo -e "${RED}❌ 错误：未检测到 Tmux 环境！请先选 [a] 安装工作区环境。${RESET}"
        read -r -p "按 [回车键] 返回菜单..." dummy
        return 1
    fi

    # 检测当前是否已经在其他的 Tmux 会话里嵌套（防止无限套娃报错）
    if [ -n "$TMUX" ]; then
        echo -e "${RED}⚠️  您当前已经身处一个 Tmux 会话中了！不能在内部再次嵌套连接。${RESET}"
        read -r -p "按 [回车键] 返回主菜单..." dummy
        return 1
    fi

    # 检查工作区是否存在
    tmux has-session -t "$SESSION_NAME" 2>/dev/null
    if [ $? -ne 0 ]; then
        # 后台静默创建会话
        tmux new-session -s "$SESSION_NAME" -d
        echo -e "${GREEN}🚀 工作区 [ ${SESSION_NAME} ] 初始化成功并移至后台运行。${RESET}"
    fi

    # 温馨温馨交互视觉
    echo -e "\n${SKYBLUE}==================================================${RESET}"
    echo -e " ⚡ 正在全速切入工作区 : ${GREEN}${SESSION_NAME}${RESET}"
    echo -e " 📌 温馨逃脱小贴士 :"
    echo -e "    若稍后想要【挂起并退出】该工作区，请在键盘上依次按下："
    echo -e "    ${YELLOW}Ctrl + B${RESET}  然后松开，再单按一次键盘上的  ${YELLOW}D${RESET}"
    echo -e "${SKYBLUE}==================================================${RESET}"
    echo ""
    read -r -p "👉 准备好了？按 [回车键] 立即进入..." dummy

    # 直连接入会话
    tmux attach-session -t "$SESSION_NAME"
}

# ================== 强制销毁指定工作区 ==================
delete_workspace() {
    if ! command -v tmux >/dev/null 2>&1; then
        echo -e "${RED}❌ 错误：未检测到已安装的 Tmux 组件。${RESET}"
        read -r -p "按 [回车键] 返回菜单..." dummy
        return 1
    fi

    # 打印当前正在运行的，方便用户看
    if tmux list-sessions >/dev/null 2>&1; then
        echo -e "${YELLOW}当前存活的工作区列表：${RESET}"
        tmux list-sessions | awk -F: '{print "  • " $1}'
        echo ""
    else
        echo -e "${YELLOW}当前暂无任何活跃的工作区。${RESET}"
    fi

    read -r -p "$(echo -e ${RED}请输入要彻底强杀的工作区名称: ${RESET})" del_name
    if [ -z "$del_name" ]; then
        echo -e "${YELLOW}输入为空，已放弃操作。${RESET}"
    else
        tmux kill-session -t "$del_name" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ 工作区 [ ${del_name} ] 及其内部的所有后台程序已被安全强制销毁。${RESET}"
        else
            echo -e "${RED}❌ 销毁失败：未找到名为 [ ${del_name} ] 的工作区。${RESET}"
        fi
    fi
    read -r -p "按 [回车键] 返回菜单..." dummy
}

# ================== 全局状态快照面板 ==================
show_status() {
    if ! command -v tmux >/dev/null 2>&1; then
        echo -e "${RED}❌ 未安装 Tmux，无法获取虚拟化工作区状态。${RESET}"
    else
        if tmux list-sessions >/dev/null 2>&1; then
            echo -e "${GREEN}📋 当前后台挂载运行的工作区状态清单:${RESET}"
            echo -e "${SKYBLUE}--------------------------------------------------${RESET}"
            tmux list-sessions
            echo -e "${SKYBLUE}--------------------------------------------------${RESET}"
        else
            echo -e "${YELLOW}🍃 干净如初：当前暂无任何用户自定义的后台工作区。${RESET}"
        fi
    fi
    read -r -p "按 [回车键] 重回主菜单..." dummy
}

# ================== 核心可交互大主菜单 ==================
while true; do
    clear
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}     ◈ 智控虚拟化多端工作区管理面板 ◈  ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${YELLOW} a) 安装虚拟工作区环境 (Tmux)${RESET}"
    echo -e "${YELLOW} b) 卸载 Tmux 环境${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN} 1) 切入 / 开启 [ 2号工作区 (work2) ]"
    echo -e "${GREEN} 2) 切入 / 开启 [ 2号工作区 (work2) ]"
    echo -e "${GREEN} 3) 切入 / 开启 [ 3号工作区 (work3) ]"
    echo -e "${GREEN} 4) 切入 / 开启 [ 4号工作区 (work4) ]"
    echo -e "${GREEN} 5) 切入 / 开启 [ 5号工作区 (work5) ]"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN} 6) 强制销毁并清除指定后台工作区${RESET}"
    echo -e "${GREEN} 7) 实时检索当前存活的工作区快照${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN} 0) 退出"
    echo -e "${GREEN}=======================================${RESET}"
    
    echo -ne "${GREEN}请输入操作指令选项: ${RESET}"
    read -r sub_choice

    case "$sub_choice" in
        a|[Aa]) install_tmux ;;
        b|[Bb]) remove_tmux ;;
        1) open_workspace "work1" ;;
        2) open_workspace "work2" ;;
        3) open_workspace "work3" ;;
        4) open_workspace "work4" ;;
        5) open_workspace "work5" ;;
        6) delete_workspace ;;
        7) show_status ;;
        0) echo -e "${YELLOW}已安全退出工作区控制台，您的后台任务仍在安全运行！${RESET}"; exit 0 ;;
        *) echo -e "${RED}❌ 无效指令，请重新输入！${RESET}"; sleep 1 ;;
    esac
done
