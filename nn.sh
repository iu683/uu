#!/bin/bash
# =================================================================
# 名称: 全能网络工具箱 (纯绿面板版)
# 适配: Debian / Ubuntu / CentOS / Rocky Linux / Alpine Linux
# =================================================================

set -e

GREEN="\033[32m"
RESET="\033[0m"
RED="\033[31m"

# 默认配置参数
IPERF_PORT=5201
IPERF_TIME=15
IPERF_PARALLEL=1
IPERF_UDP_BW="100M"
MTR_PROTO="icmp"
MTR_SHOW_AS="true"

trap "echo -e '${RESET}'; exit" INT TERM

# ==========================================
# 工具状态动态探测
# ==========================================
get_status() {
    if command -v "$1" >/dev/null 2>&1; then
        echo "已安装"
    else
        echo "未安装"
    fi
}

# ==========================================
# 自动化安装引擎
# ==========================================
check_and_install() {
    local tool=$1
    if command -v "$tool" >/dev/null 2>&1; then return; fi

    echo -e "${GREEN}正在安装必要依赖与工具: $tool ...${RESET}"
    
    if ! command -v curl >/dev/null 2>&1 || ! command -v wget >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
        if [ -f /etc/alpine-release ]; then apk add --no-cache curl wget tar bash grep awk
        elif command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y curl wget tar grep gawk
        elif command -v dnf >/dev/null 2>&1; then dnf install -y curl wget tar grep gawk
        elif command -v yum >/dev/null 2>&1; then yum install -y curl wget tar grep gawk
        fi
    fi

    case "$tool" in
        speedtest)
            if [ -f /etc/alpine-release ]; then
                apk add --no-cache speedtest-cli
                [ ! -f /usr/bin/speedtest ] && ln -sf "$(command -v speedtest-cli)" /usr/bin/speedtest || true
            else
                local arch=$(uname -m)
                local url=""
                [ "$arch" = "x86_64" ] && url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
                [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ] && url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
                if [ -n "$url" ]; then
                    cd /tmp && wget -q "$url" -O speedtest.tgz && tar -xzf speedtest.tgz
                    mv -f speedtest /usr/local/bin/ && rm -f speedtest.tgz speedtest.md LICENSE.md speedtest.5
                fi
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
# 1) Speedtest 模块
# ==========================================
run_speedtest() {
    clear
    check_and_install speedtest
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Speedtest 网速测试        ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    if speedtest --help 2>&1 | grep -q "accept-license"; then
        echo "YES" | speedtest --accept-license --accept-gdpr --force || true
    else
        speedtest || speedtest-cli || true
    fi
    echo -e "${GREEN}================================${RESET}"
    read -p "测试完成，按回车返回面板..." dummy
}

# ==========================================
# 2) NextTrace 模块
# ==========================================
run_nexttrace() {
    clear
    check_and_install nexttrace
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      NextTrace 路由追踪        ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    read -p "请输入目标IP或域名: " target
    if [ -z "$target" ]; then return; fi
    echo -e "--------------------------------"
    nexttrace "$target" || true
    echo -e "${GREEN}================================${RESET}"
    read -p "追踪完成，按回车返回面板..." dummy
}

# ==========================================
# 3) iperf3 面板模块
# ==========================================
run_iperf3() {
    check_and_install iperf3
    while true; do
        clear
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}      iperf3 吞吐量压测         ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}当前端口 :${RESET} ${IPERF_PORT}"
        echo -e "${GREEN}当前时长的:${RESET} ${IPERF_TIME}s"
        echo -e "${GREEN}当前线程 :${RESET} ${IPERF_PARALLEL}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 1) 启动服务端${RESET}"
        echo -e "${GREEN}--------------------------------${RESET}"
        echo -e "${GREEN} 2) TCP 客户端测试${RESET}"
        echo -e "${GREEN} 3) UDP 客户端测试${RESET}"
        echo -e "${GREEN}--------------------------------${RESET}"
        echo -e "${GREEN} 4) 修改测试参数${RESET}"
        echo -e "${GREEN} 0) 返回上级菜单${RESET}"
        echo -e "${GREEN}================================${RESET}"
        read -p " 请选择: " choice
        
        case "$choice" in
            1)
                clear
                echo -e "${GREEN}服务端已启动，监听端口 $IPERF_PORT。测速完成后按 Ctrl+C 返回。${RESET}\n"
                (trap 'echo -e "\n${GREEN}服务端已关闭。${RESET}"; exit 0' INT; iperf3 -s -i 5 -p "$IPERF_PORT")
                read -p "按回车继续..." dummy
                ;;
            2|3)
                read -p "请输入远端服务器IP: " s_ip
                if [ -z "$s_ip" ]; then continue; fi
                echo -e "--------------------------------"
                if [ "$choice" = "2" ]; then
                    iperf3 -c "$s_ip" -P "$IPERF_PARALLEL" -t "$IPERF_TIME" -p "$IPERF_PORT" || true
                else
                    iperf3 -c "$s_ip" -u -b "$IPERF_UDP_BW" -t "$IPERF_TIME" -P "$IPERF_PARALLEL" -p "$IPERF_PORT" || true
                fi
                echo -e "--------------------------------"
                read -p "测试完成，按回车继续..." dummy
                ;;
            4)
                read -p "修改端口 (当前 $IPERF_PORT): " in_p; IPERF_PORT=${in_p:-$IPERF_PORT}
                read -p "修改时长 (当前 $IPERF_TIME): " in_t; IPERF_TIME=${in_t:-$IPERF_TIME}
                read -p "修改线程 (当前 $IPERF_PARALLEL): " in_pa; IPERF_PARALLEL=${in_pa:-$IPERF_PARALLEL}
                read -p "修改UDP带宽 (当前 $IPERF_UDP_BW): " in_b; IPERF_UDP_BW=${in_b:-$IPERF_UDP_BW}
                ;;
            0) break ;;
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
        echo -e "${GREEN}       MTR 链路诊断面板         ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}探测协议 :${RESET} ${MTR_PROTO^^}"
        echo -e "${GREEN}AS号展示 :${RESET} $([ "$MTR_SHOW_AS" = "true" ] && echo "开启" || echo "关闭")"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 1) 实时动态检测${RESET}"
        echo -e "${GREEN} 2) 静态报告模式${RESET}"
        echo -e "${GREEN} 0) 返回上级菜单${RESET}"
        echo -e "${GREEN}================================${RESET}"
        read -p " 请选择: " choice
        
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
            0) break ;;
        esac
    done
}

# ==========================================
# 5) 大小包面板模块 (含三网全测逻辑)
# ==========================================
extract_route() { grep -E '^[0-9]+ ' | awk '{print $1, $2}'; }

core_packet_test() {
    local name=$1
    local ip=$2
    echo -e "\n${GREEN}开始对 [${name}] 进行大小包差异分析...${RESET}"
    
    local raw_big=$(nexttrace --tcp --psize 1400 --backbone "$ip" -p 80 2>/dev/null || true)
    local route_big=$(echo "$raw_big" | extract_route)
    
    local raw_small=$(nexttrace --tcp --psize 40 --backbone "$ip" -p 80 2>/dev/null || true)
    local route_small=$(echo "$raw_small" | extract_route)

    if [ -z "$route_big" ] || [ -z "$route_small" ]; then
        echo -e " 结果: 测试超时，未能获取到完整路由。"
    elif [ "$route_big" = "$route_small" ]; then
        echo -e " 结果: 大小包路由完全一致 ✅"
    else
        echo -e " 结果: 大小包路由不一致 ❌"
        diff -u <(echo "$route_big") <(echo "$route_small") | grep -E '^[-+][^-+]' || true
    fi
}

run_packet_size_test() {
    check_and_install nexttrace
    while true; do
        clear
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}     大小包策略路由检测面板     ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 1) 设置测试 深圳移动${RESET}"
        echo -e "${GREEN} 2) 设置测试 广州联通${RESET}"
        echo -e "${GREEN} 3) 设置测试 广州电信${RESET}"
        echo -e "${GREEN}--------------------------------${RESET}"
        echo -e "${GREEN} 4) 启动三网大小包全测${RESET}"
        echo -e "${GREEN} 0) 返回上级菜单${RESET}"
        echo -e "${GREEN}================================${RESET}"
        read -p " 请选择: " choice
        case "$choice" in
            1) core_packet_test "深圳移动" "120.233.18.250"; read -p "按回车继续..." dummy ;;
            2) core_packet_test "广州联通" "157.148.58.29"; read -p "按回车继续..." dummy ;;
            3) core_packet_test "广州电信" "14.116.225.60"; read -p "按回车继续..." dummy ;;
            4)
                clear
                echo -e "${GREEN}正在执行三网策略路由一键联合测验...${RESET}"
                core_packet_test "深圳移动" "120.233.18.250"
                echo -e "\n--------------------------------"
                core_packet_test "广州联通" "157.148.58.29"
                echo -e "\n--------------------------------"
                core_packet_test "广州电信" "14.116.225.60"
                echo -e "\n--------------------------------"
                read -p "全测结束，按回车返回..." dummy
                ;;
            0) break ;;
        esac
    done
}

# ==========================================
# 工具箱主面板循环
# ==========================================
while true; do
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      网络管理 综合面板         ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}Speedtest :${RESET} $(get_status speedtest)"
    echo -e "${GREEN}NextTrace :${RESET} $(get_status nexttrace)"
    echo -e "${GREEN}iperf3    :${RESET} $(get_status iperf3)"
    echo -e "${GREEN}MTR       :${RESET} $(get_status mtr)"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1) 运行 Speedtest 网速测试${RESET}"
    echo -e "${GREEN} 2) 运行 NextTrace 路由追踪${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "${GREEN} 3) 运行 iperf3 吞吐量压测${RESET}"
    echo -e "${GREEN} 4) 运行 MTR 多协议链路诊断${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "${GREEN} 5) 运行 大小包策略路由检测${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    read -p $'\033[32m 请选择: \033[0m' choice

    case "$choice" in
        1) run_speedtest ;;
        2) run_nexttrace ;;
        3) run_iperf3 ;;
        4) run_mtr ;;
        5) run_packet_size_test ;;
        0) echo -e "${GREEN}工具箱已关闭。${RESET}"; exit 0 ;;
        *) echo -e "${RED}输入错误。${RESET}"; sleep 1 ;;
    esac
done
