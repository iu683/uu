#!/bin/bash
# =================================================================
# 名称: 全能网络工具箱 (纯绿面板极致兼容稳定版)
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
trap "echo -e '${RESET}'; exit 0" INT TERM

# ==========================================
# 工具状态动态探测
# ==========================================
get_status() {
    if command -v "$1" >/dev/null 2>&1; then
        echo -e "${GREEN}已安装${RESET}"
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
    
    if [ -f /etc/alpine-release ]; then
        apk add --no-cache curl wget tar bash grep gawk openssl diffutils
    elif ! command -v curl >/dev/null 2>&1 || ! command -v wget >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y curl wget tar grep gawk diffutils
        elif command -v dnf >/dev/null 2>&1; then dnf install -y curl wget tar grep gawk diffutils
        elif command -v yum >/dev/null 2>&1; then yum install -y epel-release 2>/dev/null || true; yum install -y curl wget tar grep gawk diffutils
        fi
    fi

    case "$tool" in
        speedtest)
            if [ -f /etc/alpine-release ]; then
                echo -e "${YELLOW}📦 检测到 Alpine 系统，正在通过 apk 官方源安装...${RESET}"
                apk add --no-cache speedtest-cli
                if [ ! -f /usr/local/bin/speedtest ] && [ ! -f /usr/bin/speedtest ]; then
                    ln -sf "$(command -v speedtest-cli)" /usr/bin/speedtest 2>/dev/null || true
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
                mv -f speedtest /usr/local/bin/ 2>/dev/null || mv -f speedtest /usr/bin/ && \
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
# 1) Speedtest 模块
# ==========================================
run_speedtest() {
    clear
    check_and_install speedtest
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}        Speedtest 网速测试        ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}🚀 开始测速...${RESET}"
    echo "-------------------------------------"
    if command -v speedtest >/dev/null 2>&1; then
        if speedtest --help 2>&1 | grep -q "accept-license"; then
            echo "YES" | speedtest --accept-license --accept-gdpr --force || true
        else
            speedtest || speedtest-cli || true
        fi
    else
        speedtest-cli || echo -e "${RED}❌ 未检测到可用的测速程序${RESET}"
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
    echo -e "${GREEN}        NextTrace 路由追踪        ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    read -p "请输入目标IP或域名: " target
    if [ -z "$target" ]; then return; fi
    echo -e "--------------------------------"
    nexttrace "$target" || true
    echo -e "${GREEN}================================${RESET}"
    read -p "追踪完成，按回车返回面板..." dummy
}

# ==========================================
# 3) iperf3 模块
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
        echo -e "${ORANGE}===================================${RESET}"
        echo -e "${ORANGE}          iperf3 测速管理          ${RESET}"
        echo -e "${ORANGE}===================================${RESET}"
        echo -e " ${BLUE}当前参数: 端口=$IPERF_PORT | 时长=${IPERF_TIME}s | 线程=$IPERF_PARALLEL | UDP带宽=$IPERF_UDP_BW${RESET}"
        echo -e "${ORANGE}-----------------------------------${RESET}"
        echo -e " ${GREEN}1)${RESET} 启动 iperf3 本地服务端"
        echo -e " -----------------------------------"
        echo -e " ${GREEN}2)${RESET} 发起 TCP 下载 (↓) 测试"
        echo -e " ${GREEN}3)${RESET} 发起 TCP 上传 (↑) 测试"
        echo -e " -----------------------------------"
        echo -e " ${GREEN}4)${RESET} 发起 UDP 下载 (↓) 测试"
        echo -e " ${GREEN}5)${RESET} 发起 UDP 上传 (↑) 测试"
        echo -e " -----------------------------------"
        echo -e " ${GREEN}6)${RESET} 修改测试核心参数"
        echo -e " ${RED}0)${RESET} 返回上级工具箱菜单"
        echo -e "${ORANGE}===================================${RESET}"
        echo -ne "${GREEN} 请选择: ${RESET}"
        read -r choice
        
        case "$choice" in
            1)
                clear
                echo -e "${ORANGE}===================================${RESET}"
                echo -e "${GREEN}  iperf3 服务器已启动 (监听端口: $IPERF_PORT)${RESET}"
                echo -e "${YELLOW}  👉 提示: 测速完毕后，按 Ctrl+C 可安全返回菜单${RESET}"
                echo -e "${ORANGE}===================================${RESET}\n"
                (trap 'exit 0' INT; iperf3 -s -i 10 -p "$IPERF_PORT")
                echo -e "\n${YELLOW}ℹ 服务端已安全关闭。${RESET}"
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
                clear
                echo -e "${YELLOW}>>> 修改 iperf3 临时参数 <<<${RESET}"
                read -p "修改端口 (当前 $IPERF_PORT): " in_p; IPERF_PORT=${in_p:-$IPERF_PORT}
                read -p "修改时长 (当前 $IPERF_TIME): " in_t; IPERF_TIME=${in_t:-$IPERF_TIME}
                read -p "修改线程 (当前 $IPERF_PARALLEL): " in_pa; IPERF_PARALLEL=${in_pa:-$IPERF_PARALLEL}
                read -p "修改UDP带宽 (当前 $IPERF_UDP_BW): " in_b; IPERF_UDP_BW=${in_b:-$IPERF_UDP_BW}
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 4) MTR 模块
# ==========================================
run_mtr() {
    check_and_install mtr
    while true; do
        clear
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}        MTR 链路诊断面板         ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}探测协议 :${RESET} $(echo "$MTR_PROTO" | tr 'a-z' 'A-Z')"
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
# 5) 大小包面板模块（高兼容稳定融合版）
# ==========================================
core_packet_test() {
    local provider=$1
    local ip=$2
    local is_batch=$3  # 批处理标识，防read冲突
    clear
    echo -e "\n${YELLOW}=== 测试 ${provider} (${ip}) ===${RESET}"

    # 大小包字节安全边界设定（1450字节大包，64字节小包）
    echo -ne "大包测试（1450 Bytes）："
    local raw_big=$(nexttrace --tcp --psize 1450 --backbone --timeout 2s --max-hops 30 "$ip" -p 80 2>/dev/null)
    local route_big=$(echo "$raw_big" | grep -E '^[0-9]+' | awk '{print $1,$2,$3}' | grep -v "^\s*$" || true)
    if [ -n "$route_big" ]; then echo -e "${GREEN}完成${RESET}"; else echo -e "${RED}超时/失败${RESET}"; fi
    
    echo -ne "小包测试（64 Bytes）："
    local raw_small=$(nexttrace --tcp --psize 64 --backbone --timeout 2s --max-hops 30 "$ip" -p 80 2>/dev/null)
    local route_small=$(echo "$raw_small" | grep -E '^[0-9]+' | awk '{print $1,$2,$3}' | grep -v "^\s*$" || true)
    if [ -n "$route_small" ]; then echo -e "${GREEN}完成${RESET}"; else echo -e "${RED}超时/失败${RESET}"; fi

    echo -e "\n${YELLOW}=== 路由对比 ===${RESET}"
    
    local file_big="/tmp/route_big_$$.txt"
    local file_small="/tmp/route_small_$$.txt"
    echo "$route_big" > "$file_big"
    echo "$route_small" > "$file_small"
    
    if [ ! -s "$file_big" ] && [ ! -s "$file_small" ]; then
        echo -e "${RED}❌ 探测失败：双向节点均响应超时，请确认是否以 sudo/root 运行。${RESET}"
    elif diff "$file_big" "$file_small" >/dev/null 2>&1; then
        echo -e "${GREEN}大小包路由一致 ✅${RESET}"
    else
        echo -e "${RED}大小包路由不一致 ❌ (检测到策略分流)${RESET}"
        echo -e "\n${BLUE}>>> 轨迹分流差异对比 (-大包 / +小包) <<<\n${RESET}"
        diff "$file_big" "$file_small" | grep -E '^[-+][^-+]' || true
    fi

    rm -f "$file_big" "$file_small"
    
    # 如果是全测模式，不单独阻塞，留到最后统一卡住
    if [ "$is_batch" != "true" ]; then
        read -rp $'\n\033[33m按回车返回菜单...\033[0m'
    fi
}

run_packet_size_test() {
    check_and_install nexttrace
    while true; do
        clear
        echo -e "${GREEN}==== 大小包测试====${RESET}"
        echo -e " 1) 移动 (深圳)"
        echo -e " 2) 联通 (广州)"
        echo -e " 3) 电信 (广州)"
        echo -e " 4) 全测"
        echo -e " 0) 返回主菜单"
        echo -e "${GREEN}====================${RESET}"
        read -rp $'\033[32m请选择测试节点: \033[0m' choice

        case $choice in
            1) core_packet_test "深圳移动" "120.233.18.250" "false" ;;
            2) core_packet_test "广州联通" "157.148.58.29" "false" ;;
            3) core_packet_test "广州电信" "14.116.225.60" "false" ;;
            4)
                core_packet_test "深圳移动" "120.233.18.250" "true"
                core_packet_test "广州联通" "157.148.58.29" "true"
                core_packet_test "广州电信" "14.116.225.60" "true"
                read -rp $'\n\033[33m所有节点测试完毕，按回车返回菜单...\033[0m'
                ;;
            0) break ;;
            *) echo -e "${RED}无效选择，请重新输入${RESET}"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 工具箱主面板循环
# ==========================================
while true; do
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}        网络管理 综合面板        ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}Speedtest :${RESET} $(get_status speedtest)"
    echo -e "${GREEN}NextTrace :${RESET} $(get_status nexttrace)"
    echo -e "${GREEN}iperf3    :${RESET} $(get_status iperf3)"
    echo -e "${GREEN}MTR       :${RESET} $(get_status mtr)"
    echo -e "${GREEN}================================${RESET}"
    echo -e " ${GREEN}1)${RESET} 运行 Speedtest 网速测试"
    echo -e " ${GREEN}2)${RESET} 运行 NextTrace 路由追踪"
    echo -e " --------------------------------"
    echo -e " ${GREEN}3)${RESET} 运行 iperf3 进阶测速管理箱"
    echo -e " ${GREEN}4)${RESET} 运行 MTR 多协议链路诊断"
    echo -e " --------------------------------"
    echo -e " ${GREEN}5)${RESET} 运行 大小包策略路由检测"
    echo -e " ${RED}0)${RESET} 退出"
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
