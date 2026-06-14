#!/bin/bash
# =================================================================
# 名称: 全能网络工具箱 
# 适配: Debian / Ubuntu / CentOS / Rocky Linux / Alpine Linux
# =================================================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"
ORANGE='\033[38;5;208m'

# 默认配置参数
IPERF_PORT=5201
IPERF_TIME=30
IPERF_PARALLEL=1
IPERF_UDP_BW="1G"
MTR_PROTO="ICMP"
MTR_SHOW_AS="true"

# 全局安全退出捕获
trap "echo -e '${RESET}'; exit" INT TERM

# ==========================================
# 工具状态动态探测
# ==========================================
get_status() {
    if command -v "$1" >/dev/null 2>&1; then
        echo -e "${YELLOW}已安装${RESET}"
    else
        echo -e "${RED}未安装${RESET}"
    fi
}

# ==========================================
# 自动化安装引擎
# ==========================================
check_and_install() {
    local tool=$1
    if command -v "$tool" >/dev/null 2>&1; then return; fi

    echo -e "${YELLOW}📦 正在安装必要依赖与工具: $tool ...${RESET}"
    
    # 基础依赖环境前置检查与修复
    if [ -f /etc/alpine-release ]; then
        apk add --no-cache curl wget tar bash grep gawk openssl
    elif ! command -v curl >/dev/null 2>&1 || ! command -v wget >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y curl wget tar grep gawk
        elif command -v dnf >/dev/null 2>&1; then dnf install -y curl wget tar grep gawk
        elif command -v yum >/dev/null 2>&1; then yum install -y curl wget tar grep gawk
        fi
    fi

    case "$tool" in
        speedtest)
            if [ -f /etc/alpine-release ]; then
                echo -e "${YELLOW}📦 检测到 Alpine 系统，正在通过 apk 官方源安装...${RESET}"
                apk add --no-cache speedtest-cli
                if [ ! -f /usr/local/bin/speedtest ] && [ ! -f /usr/bin/speedtest ]; then
                    ln -sf "$(command -v speedtest-cli)" /usr/bin/speedtest
                fi
            else
                echo -e "${YELLOW}📦 正在通过二进制包快速安装 Ookla Speedtest...${RESET}"
                local cpu_arch=$(uname -m)
                local download_url=""
                case "$cpu_arch" in
                    x86_64) download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz" ;;
                    aarch64|arm64) download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz" ;;
                    *) echo -e "${RED}❌ 错误: 不支持的架构 ${cpu_arch}${RESET}" >&2; exit 1 ;;
                esac
                cd /tmp
                wget -q "$download_url" -O speedtest.tgz && \
                tar -xzf speedtest.tgz && \
                mv -f speedtest /usr/local/bin/ && \
                rm -f speedtest.tgz speedtest.5 speedtest.md LICENSE.md
            fi
            mkdir -p "$HOME/.ookla"
            echo '{"license_accepted": true, "gdpr_accepted": true}' > "$HOME/.ookla/speedtest-cli.json" 2>/dev/null || true
            ;;
        nexttrace)
            curl -fsSL nxtrace.org/nt | bash || true
            ;;
        iperf3)
            if [ -f /etc/alpine-release ]; then apk add --no-cache iperf3
            elif command -v apt-get >/dev/null 2>&1; then apt-get install -y iperf3
            elif command -v dnf >/dev/null 2>&1; then dnf install -y epel-release 2>/dev/null || true; dnf install -y iperf3
            elif command -v yum >/dev/null 2>&1; then yum install -y epel-release 2>/dev/null || true; yum install -y iperf3
            fi
            ;;
        mtr)
            if [ -f /etc/alpine-release ]; then apk add --no-cache mtr
            elif command -v apt-get >/dev/null 2>&1; then apt-get install -y mtr-tiny || apt-get install -y mtr
            elif command -v dnf >/dev/null 2>&1; then dnf install -y mtr
            elif command -v yum >/dev/null 2>&1; then yum install -y mtr
            fi
            ;;
    esac
    hash -r 2>/dev/null
}

# ==========================================
# 1) Speedtest 模块 (双保险免提示版)
# ==========================================
run_speedtest() {
    clear
    check_and_install speedtest
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈   Speedtest 网速测试   ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}🚀 开始测速...${RESET}"
    echo "-------------------------------------"
    if speedtest --help 2>&1 | grep -q "accept-license"; then
        echo "YES" | speedtest --accept-license --accept-gdpr --force || true
    else
        speedtest || speedtest-cli || true
    fi
    echo "-------------------------------------"
    read -p "测试完成，按回车返回面板..." dummy
}

# ==========================================
# 2) NextTrace 模块
# ==========================================
run_nexttrace() {
    clear
    check_and_install nexttrace
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈   NextTrace 路由追踪   ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    read -p "请输入目标IP或域名: " target
    if [ -z "$target" ]; then return; fi
    echo -e "--------------------------------"
    nexttrace "$target" || true
    echo -e "${GREEN}================================${RESET}"
    read -p "追踪完成，按回车返回面板..." dummy
}

# ==========================================
# 3) iperf3 
# ==========================================
get_iperf_ip() {
    read -p "请输入远端服务器 IP/域名: " SERVER_IP
    if [ -z "$SERVER_IP" ]; then
        echo -e "${RED}❌ 未输入有效 IP，操作取消。${RESET}"
        sleep 1.5
        return 1
    fi
    return 0
}

run_iperf3() {
    check_and_install iperf3
    while true; do
        clear
        echo -e "${GREEN}===================================${RESET}"
        echo -e "${GREEN}     ◈   iperf3 测速管理   ◈      ${RESET}"
        echo -e "${GREEN}===================================${RESET}"
        echo -e "${YELLOW}端口=$IPERF_PORT  | 时长=${IPERF_TIME}s ${RESET}"
        echo -e "${YELLOW}线程=$IPERF_PARALLEL     | UDP带宽=$IPERF_UDP_BW${RESET}"
        echo -e "${GREEN}-----------------------------------${RESET}"
        echo -e " ${GREEN}1) 启动 iperf3 本地服务端"
        echo -e "${GREEN}-----------------------------------${RESET}"
        echo -e " ${GREEN}2) 发起 TCP 下载 (↓) 测试${RESET}"
        echo -e " ${GREEN}3) 发起 TCP 上传 (↑) 测试${RESET}"
        echo -e " ${GREEN}-----------------------------------${RESET}"
        echo -e " ${GREEN}4) 发起 UDP 下载 (↓) 测试${RESET}"
        echo -e " ${GREEN}5) 发起 UDP 上传 (↑) 测试${RESET}"
        echo -e "${GREEN}-----------------------------------${RESET}"
        echo -e " ${GREEN}6) 修改测试核心参数${RESET}"
        echo -e " ${GREEN}0) 退出${RESET}"
        echo -e "${GREEN}===================================${RESET}"
        echo -ne "${GREEN} 请选择: ${RESET}"
        read -r choice
        
        case "$choice" in
            1)
                clear
                echo -e "${ORANGE}===================================${RESET}"
                echo -e "${GREEN}  iperf3 服务器已启动 (监听端口: $IPERF_PORT)${RESET}"
                echo -e "${YELLOW}  👉 提示: 测速完毕后，按 Ctrl+C 可安全返回菜单${RESET}"
                echo -e "${ORANGE}===================================${RESET}\n"
                (trap 'echo -e "${YELLOW}服务端已安全关闭。${RESET}"; exit 0' INT; iperf3 -s -i 10 -p "$IPERF_PORT")
                echo "-----------------------------------"
                read -p "按回车继续..." dummy
                ;;
            2)
                clear; get_iperf_ip || continue
                echo -e "\n${GREEN}🚀 TCP 下载 (↓) 测试中...${RESET}"
                iperf3 -c "$SERVER_IP" -R -P "$IPERF_PARALLEL" -t "$IPERF_TIME" -p "$IPERF_PORT" || true
                read -p "测试完成，按回车继续..." dummy
                ;;
            3)
                clear; get_iperf_ip || continue
                echo -e "\n${GREEN}🚀 TCP 上传 (↑) 测试中...${RESET}"
                iperf3 -c "$SERVER_IP" -P "$IPERF_PARALLEL" -t "$IPERF_TIME" -p "$IPERF_PORT" || true
                read -p "测试完成，按回车继续..." dummy
                ;;
            4)
                clear; get_iperf_ip || continue
                echo -e "\n${GREEN}🚀 UDP 下载 (↓) 测试中...${RESET}"
                iperf3 -c "$SERVER_IP" -u -b "$IPERF_UDP_BW" -t "$IPERF_TIME" -R -P "$IPERF_PARALLEL" -p "$IPERF_PORT" || true
                read -p "测试完成，按回车继续..." dummy
                ;;
            5)
                clear; get_iperf_ip || continue
                echo -e "\n${GREEN}🚀 UDP 上传 (↑) 测试中...${RESET}"
                iperf3 -c "$SERVER_IP" -u -b "$IPERF_UDP_BW" -t "$IPERF_TIME" -P "$IPERF_PARALLEL" -p "$IPERF_PORT" || true
                read -p "测试完成，按回车继续..." dummy
                ;;
            6)
                echo -e "${YELLOW}>>> 修改 iperf3 临时参数 <<<${RESET}"
                read -p "修改端口 (当前 $IPERF_PORT): " in_p; IPERF_PORT=${in_p:-$IPERF_PORT}
                read -p "修改时长 (当前 $IPERF_TIME): " in_t; IPERF_TIME=${in_t:-$IPERF_TIME}
                read -p "修改线程 (当前 $IPERF_PARALLEL): " in_pa; IPERF_PARALLEL=${in_pa:-$IPERF_PARALLEL}
                read -p "修改UDP带宽 (当前 $IPERF_UDP_BW): " in_b; IPERF_UDP_BW=${in_b:-$IPERF_UDP_BW}
                ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 4) MTR 面板模块
# ==========================================
run_mtr() {
    check_and_install mtr
    while true; do
        clear
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}    ◈   MTR 链路诊断面板   ◈    ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}探测协议 :${RESET} ${YELLOW}$(echo "$MTR_PROTO" | tr 'a-z' 'A-Z')${RESET}"
        echo -e "${GREEN}AS号展示 :${RESET} ${YELLOW}$([ "$MTR_SHOW_AS" = "true" ] && echo "开启" || echo "关闭")${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 1) 实时动态检测${RESET}"
        echo -e "${GREEN} 2) 静态报告模式${RESET}"
        echo -e "${GREEN} 0) 退出${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -ne "${GREEN} 请选择: ${RESET}"
        read -r choice
        
        local args=""
        [ "$MTR_SHOW_AS" = "true" ] && args="$args -z"

        case "$choice" in
            1)
                read -p "请输入目标IP/域名: " target
                if [ -z "$target" ]; then continue; fi
                echo -e "--------------------------------"
                mtr $args "$target" || true
                echo -e "--------------------------------"
                read -p "检测结束，按回车返回..." dummy
                ;;
            2)
                read -p "请输入目标IP/域名: " target
                if [ -z "$target" ]; then continue; fi
                clear
                echo -e "${GREEN}报告生成中(发送100个包)...${RESET}\n"
                mtr -r -c 100 $args "$target" || true
                echo -e "--------------------------------"
                read -p "分析结束，按回车返回..." dummy
                ;;
            0) exit 0 ;;
        esac
    done
}


# ==========================================
# 工具箱主面板循环
# ==========================================
while true; do
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈   网络管理 综合面板   ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}Speedtest :${RESET} $(get_status speedtest)"
    echo -e "${GREEN}NextTrace :${RESET} $(get_status nexttrace)"
    echo -e "${GREEN}iperf3    :${RESET} $(get_status iperf3)"
    echo -e "${GREEN}MTR       :${RESET} $(get_status mtr)"
    echo -e "${GREEN}================================${RESET}"
    echo -e " ${GREEN}1) 运行 Speedtest 网速测试${RESET}"
    echo -e " ${GREEN}2) 运行 NextTrace 路由追踪${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e " ${GREEN}3) 运行 iperf3 测速${RESET}"
    echo -e " ${GREEN}4) 运行 MTR 链路诊断${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e " ${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    read -p $'\033[32m 请选择: \033[0m' choice

    case "$choice" in
        1) run_speedtest ;;
        2) run_nexttrace ;;
        3) run_iperf3 ;;
        4) run_mtr ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误。${RESET}"; sleep 1 ;;
    esac
done
