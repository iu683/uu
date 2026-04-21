#!/bin/bash

# 定义颜色变量
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
ORANGE='\033[38;5;214m'
RESET='\033[0m'

# 工作目录定义 (用于 Argo 等模块)
work_dir="/etc/argo" 

status_check() {
    echo -e "${ORANGE}╔══════════════════════════╗${RESET}"
    echo -e "${ORANGE}       核心状态检测          ${RESET}"
    echo -e "${ORANGE}╚══════════════════════════╝${RESET}"
    echo ""

    format_status() {
        case "$1" in
            active) echo -e "${GREEN}运行中${RESET}" ;;
            inactive|failed) echo -e "${YELLOW}未运行${RESET}" ;;
            *) echo -e "${RED}未安装${RESET}" ;;
        esac
    }

    get_ports() {
        ss -tulnp 2>/dev/null | grep -E "$1" | awk '{print $5}' | awk -F: '{print $NF}' | sort -u
    }

    # =============================
    # Xray
    # =============================
    echo -e "${YELLOW}▶ Xray${RESET}"
    if command -v xray &>/dev/null || pgrep -f xray &>/dev/null; then
        status=$(systemctl is-active xray 2>/dev/null)
        [[ "$status" != "active" && $(pgrep -f xray) ]] && status="active"
        echo -e "状态: $(format_status "$status")"
        if command -v xray &>/dev/null; then
            ver=$(xray version 2>/dev/null | head -n1 | awk '{print $2}')
        else
            ver=$(ps -ef | grep xray | grep -v grep | grep -oE 'v[0-9.]+' | head -n1)
        fi
        echo -e "版本: ${ver:-运行中(内置)}"
        ports=$(get_ports xray)
        [[ -n "$ports" ]] && echo -e "端口: $(echo $ports | tr ' ' ', ')" || echo -e "${YELLOW}端口: 无${RESET}"
    else
        echo -e "状态: ${RED}未安装${RESET}"
    fi
    echo ""

    # =============================
    # Sing-box
    # =============================
    echo -e "${YELLOW}▶ Sing-box${RESET}"
    if command -v sing-box &>/dev/null || pgrep -f sing-box &>/dev/null; then
        status=$(systemctl is-active sing-box 2>/dev/null)
        [[ "$status" != "active" && $(pgrep -f sing-box) ]] && status="active"
        echo -e "状态: $(format_status "$status")"
        if command -v sing-box &>/dev/null; then
            ver=$(sing-box version 2>/dev/null | head -n1 | awk '{print $3}')
        else
            ver=$(ps -ef | grep sing-box | grep -v grep | grep -oE 'v[0-9.]+' | head -n1)
        fi
        echo -e "版本: ${ver:-运行中(内置)}"
        ports=$(get_ports sing-box)
        [[ -n "$ports" ]] && echo -e "端口: $(echo $ports | tr ' ' ', ')" || echo -e "${YELLOW}端口: 无${RESET}"
    else
        echo -e "状态: ${RED}未安装${RESET}"
    fi
    echo ""

    # =============================
    # Mihomo (Clash Meta)
    # =============================
    echo -e "${YELLOW}▶ Mihomo/Clash${RESET}"
    mihomo_found=0
    mi_ports=""
    if command -v docker &>/dev/null; then
        mi_containers=$(docker ps -a --format "{{.Names}}" | grep -iE "mihomo|clash")
    fi
    if command -v mihomo &>/dev/null || pgrep -iE "mihomo|clash" &>/dev/null || [[ -n "$mi_containers" ]]; then
        mihomo_found=1
        status=$(systemctl is-active mihomo 2>/dev/null || systemctl is-active clash 2>/dev/null)
        if [[ "$status" != "active" ]]; then
            if pgrep -iE "mihomo|clash" &>/dev/null; then status="active"
            elif [[ -n "$mi_containers" ]]; then
                for name in $mi_containers; do
                    [[ $(docker inspect -f '{{.State.Status}}' "$name") == "running" ]] && status="active" && break
                done
            fi
        fi
        echo -e "状态: $(format_status "$status")"
        local raw_ver=""
        if command -v mihomo &>/dev/null; then
            raw_ver=$(mihomo -v 2>/dev/null)
        elif [[ -n "$mi_containers" ]]; then
            first_c=$(echo "$mi_containers" | head -n1)
            raw_ver=$(docker exec "$first_c" mihomo -v 2>/dev/null)
        fi
        if [[ -n "$raw_ver" ]]; then
            ver_num=$(echo "$raw_ver" | grep -iE "Mihomo|Clash" | awk '{print $3}' | head -n1)
            [[ "$raw_ver" == *"gvisor"* ]] && ver_num="${ver_num} (gVisor)"
            echo -e "版本: ${ver_num:-未知}"
        else
            echo -e "版本: 运行中(内置)"
        fi
        mi_ports=$(get_ports mihomo; get_ports clash)
        if [[ -n "$mi_containers" ]]; then
            d_ports=$(docker container inspect $(echo "$mi_containers") --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}} {{end}}{{end}}' | tr -s ' ' '\n' | grep -v '^$')
            mi_ports="$mi_ports $d_ports"
        fi
        final_mi_ports=$(echo $mi_ports | tr ' ' '\n' | sort -un | tr '\n' ',' | sed 's/,$//')
        [[ -n "$final_mi_ports" ]] && echo -e "端口: ${GREEN}${final_mi_ports}${RESET}" || echo -e "端口: ${YELLOW}无${RESET}"
        if [[ -n "$mi_containers" ]]; then
            for name in $mi_containers; do
                raw_s=$(docker inspect -f '{{.State.Status}}' "$name")
                [[ "$raw_s" == "running" ]] && c_s="active" || c_s="$raw_s"
                echo -e "容器: ${CYAN}${name}${RESET} | 状态: $(format_status "$c_s")"
            done
        fi
    else
        echo -e "状态: ${RED}未安装${RESET}"
    fi
    echo ""

    # =============================
    # Realm
    # =============================
    echo -e "${YELLOW}▶ Realm${RESET}"
    realm_containers=""
    if command -v docker &>/dev/null; then
        realm_containers=$(docker ps -a --format "{{.Names}}" | grep -i "realm")
    fi
    if command -v realm &>/dev/null || pgrep -f realm &>/dev/null || [[ -n "$realm_containers" ]]; then
        status=$(systemctl is-active realm 2>/dev/null)
        if [[ "$status" != "active" ]]; then
            if pgrep -f realm &>/dev/null; then status="active"
            elif [[ -n "$realm_containers" ]]; then
                for name in $realm_containers; do
                    [[ $(docker inspect -f '{{.State.Status}}' "$name") == "running" ]] && status="active" && break
                done
            fi
        fi
        echo -e "状态: $(format_status "$status")"
        if command -v realm &>/dev/null; then
            ver=$(realm --version 2>/dev/null | awk '{print $2}')
        elif [[ -n "$realm_containers" ]]; then
            first_c=$(echo "$realm_containers" | head -n1)
            ver=$(docker exec "$first_c" realm --version 2>/dev/null | awk '{print $2}')
        fi
        echo -e "版本: ${ver:-运行中(内置)}"
        ports=$(get_ports realm)
        [[ -n "$ports" ]] && echo -e "端口: $(echo $ports | tr ' ' ', ')" || echo -e "${YELLOW}端口: 无${RESET}"
        if [[ -n "$realm_containers" ]]; then
            for name in $realm_containers; do
                raw_s=$(docker inspect -f '{{.State.Status}}' "$name")
                [[ "$raw_s" == "running" ]] && c_s="active" || c_s="$raw_s"
                echo -e "容器: ${CYAN}${name}${RESET} | 状态: $(format_status "$c_s")"
            done
        fi
    else
        echo -e "状态: ${RED}未安装${RESET}"
    fi
    echo ""

    # =============================
    # Gost
    # =============================
    echo -e "${YELLOW}▶ Gost${RESET}"
    gost_containers=""
    if command -v docker &>/dev/null; then
        gost_containers=$(docker ps -a --format "{{.Names}}" | grep -i "gost")
    fi
    if command -v gost &>/dev/null || pgrep -f gost &>/dev/null || [[ -n "$gost_containers" ]]; then
        status="inactive"
        if systemctl is-active gost &>/dev/null; then status="active"
        elif pgrep -f gost &>/dev/null; then status="active"
        elif [[ -n "$gost_containers" ]]; then
            for name in $gost_containers; do
                [[ $(docker inspect -f '{{.State.Status}}' "$name") == "running" ]] && status="active" && break
            done
        fi
        echo -e "状态: $(format_status "$status")"
        ver=""
        if command -v gost &>/dev/null; then
            ver=$(gost -V 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
        fi
        if [[ -z "$ver" && -n "$gost_containers" ]]; then
            first_c=$(echo "$gost_containers" | head -n1)
            ver=$(docker exec "$first_c" gost -V 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
            [[ -z "$ver" ]] && ver=$(docker exec "$first_c" /bin/gost -V 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
        fi
        echo -e "版本: ${ver:-运行中(内置)}"
        ports=$(get_ports gost)
        if [[ -n "$gost_containers" ]]; then
            d_ports=$(docker container inspect $gost_containers --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}} {{end}}{{end}}' | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ',' | sed 's/^,//;s/,$//')
            if [[ -n "$d_ports" ]]; then
                [[ -n "$ports" ]] && ports="${ports},${d_ports}" || ports="$d_ports"
            fi
        fi
        final_ports=$(echo "$ports" | tr ' ' '\n' | tr ',' '\n' | sed '/^$/d' | sort -u | tr '\n' ',' | sed 's/,$//')
        [[ -n "$final_ports" ]] && echo -e "端口: ${CYAN}${final_ports}${RESET}" || echo -e "${YELLOW}端口: 无${RESET}"
        if [[ -n "$gost_containers" ]]; then
            for name in $gost_containers; do
                raw_s=$(docker inspect -f '{{.State.Status}}' "$name")
                [[ "$raw_s" == "running" ]] && c_s="active" || c_s="$raw_s"
                echo -e "容器: ${CYAN}${name}${RESET} | 状态: $(format_status "$c_s")"
            done
        fi
    else
        echo -e "状态: ${RED}未安装${RESET}"
    fi
    echo ""

    # =============================
    # FRP (frpc/frps)
    # =============================
    echo -e "${YELLOW}▶ FRP${RESET}"
    frp_containers=""
    if command -v docker &>/dev/null; then
        frp_containers=$(docker ps -a --format "{{.Names}}" | grep -i "frp")
    fi
    if command -v frpc &>/dev/null || command -v frps &>/dev/null || pgrep -x frpc &>/dev/null || pgrep -x frps &>/dev/null || [[ -n "$frp_containers" ]]; then
        status=$(systemctl is-active frpc 2>/dev/null || systemctl is-active frps 2>/dev/null)
        if [[ "$status" != "active" ]]; then
            if pgrep -x frpc &>/dev/null || pgrep -x frps &>/dev/null; then status="active"
            elif [[ -n "$frp_containers" ]]; then
                for name in $frp_containers; do
                    [[ $(docker inspect -f '{{.State.Status}}' "$name") == "running" ]] && status="active" && break
                done
            fi
        fi
        echo -e "状态: $(format_status "$status")"
        if command -v frpc &>/dev/null; then ver=$(frpc -v 2>/dev/null)
        elif command -v frps &>/dev/null; then ver=$(frps -v 2>/dev/null)
        elif [[ -n "$frp_containers" ]]; then
            first_c=$(echo "$frp_containers" | head -n1)
            ver=$(docker exec "$first_c" frpc -v 2>/dev/null || docker exec "$first_c" frps -v 2>/dev/null)
        fi
        echo -e "版本: ${ver:-运行中(内置)}"
        ports=$( (get_ports frpc; get_ports frps) | sort -u )
        [[ -n "$ports" ]] && echo -e "端口: $(echo $ports | tr ' ' ', ')" || echo -e "${YELLOW}端口: 无${RESET}"
        if [[ -n "$frp_containers" ]]; then
            for name in $frp_containers; do
                raw_s=$(docker inspect -f '{{.State.Status}}' "$name")
                [[ "$raw_s" == "running" ]] && c_s="active" || c_s="$raw_s"
                echo -e "容器: ${CYAN}${name}${RESET} | 状态: $(format_status "$c_s")"
            done
        fi
    else
        echo -e "状态: ${RED}未安装${RESET}"
    fi
    echo ""

    # =============================
    # Nginx
    # =============================
    echo -e "${YELLOW}▶ Nginx${RESET}"
    nginx_found=0
    all_ports=""
    if command -v nginx &>/dev/null; then
        nginx_found=1
        status=$(systemctl is-active nginx 2>/dev/null)
        [[ "$status" != "active" ]] && pgrep -x nginx &>/dev/null && status="active"
        echo -e "状态: $(format_status "$status")"
        ver=$(nginx -v 2>&1 | awk -F/ '{print $2}')
        echo -e "版本: ${ver:-内置}"
        all_ports=$(get_ports nginx)
    fi
    if command -v docker &>/dev/null; then
        nginx_containers=$(docker ps -a --format "{{.Names}}" | grep -iE "nginx|npm")
        if [[ -n "$nginx_containers" ]]; then
            [[ $nginx_found -eq 0 ]] && echo -e "状态: ${GREEN}Docker 运行中${RESET}"
            nginx_found=1
            for name in $nginx_containers; do
                raw_s=$(docker inspect -f '{{.State.Status}}' "$name")
                [[ "$raw_s" == "running" ]] && c_s="active" || c_s="$raw_s"
                echo -e "容器: ${CYAN}${name}${RESET} | 状态: $(format_status "$c_s")"
                d_ports=$(docker container inspect "$name" --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}} {{end}}{{end}}' | tr -s ' ' '\n' | grep -v '^$')
                all_ports="$all_ports $d_ports"
            done
        fi
    fi
    if [[ $nginx_found -eq 1 ]]; then
        final_ports=$(echo $all_ports | tr ' ' '\n' | grep -v '^$' | sort -un | tr '\n' ',' | sed 's/,$//')
        [[ -n "$final_ports" ]] && echo -e "端口: ${GREEN}${final_ports}${RESET}" || echo -e "端口: ${YELLOW}未发现映射端口${RESET}"
    else
        echo -e "状态: ${RED}未安装${RESET}"
    fi
    echo ""

    # =============================
    # Caddy
    # =============================
    echo -e "${YELLOW}▶ Caddy${RESET}"
    caddy_containers=""
    if command -v docker &>/dev/null; then
        caddy_containers=$(docker ps -a --format "{{.Names}}" | grep -i "caddy")
    fi
    if command -v caddy &>/dev/null || pgrep -x caddy &>/dev/null || [[ -n "$caddy_containers" ]]; then
        status=$(systemctl is-active caddy 2>/dev/null)
        if [[ "$status" != "active" ]]; then
            if pgrep -x caddy &>/dev/null; then status="active"
            elif [[ -n "$caddy_containers" ]]; then
                for name in $caddy_containers; do
                    [[ $(docker inspect -f '{{.State.Status}}' "$name") == "running" ]] && status="active" && break
                done
            fi
        fi
        echo -e "状态: $(format_status "$status")"
        if command -v caddy &>/dev/null; then
            ver=$(caddy version 2>/dev/null | awk '{print $1}')
        elif [[ -n "$caddy_containers" ]]; then
            first_c=$(echo "$caddy_containers" | head -n1)
            ver=$(docker exec "$first_c" caddy version 2>/dev/null | awk '{print $1}')
        fi
        echo -e "版本: ${ver:-运行中(内置)}"
        ports=$(get_ports caddy)
        [[ -n "$ports" ]] && echo -e "端口: $(echo $ports | tr ' ' ', ')" || echo -e "${YELLOW}端口: 无${RESET}"
        if [[ -n "$caddy_containers" ]]; then
            for name in $caddy_containers; do
                raw_s=$(docker inspect -f '{{.State.Status}}' "$name")
                [[ "$raw_s" == "running" ]] && c_s="active" || c_s="$raw_s"
                echo -e "容器: ${CYAN}${name}${RESET} | 状态: $(format_status "$c_s")"
            done
        fi
    else
        echo -e "状态: ${RED}未安装${RESET}"
    fi
    echo ""

    # =============================
    # ACME
    # =============================
    echo -e "${YELLOW}▶ ACME${RESET}"
    if command -v acme.sh &>/dev/null || [[ -f ~/.acme.sh/acme.sh ]] || (command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' | grep -qi "acme"); then
        if command -v acme.sh &>/dev/null || [[ -f ~/.acme.sh/acme.sh ]]; then echo -e "状态: ${GREEN}已安装${RESET}"
        else echo -e "状态: ${GREEN}已安装(Docker)${RESET}"; fi
        if command -v acme.sh &>/dev/null; then ver=$(acme.sh --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        elif [[ -f ~/.acme.sh/acme.sh ]]; then ver=$(~/.acme.sh/acme.sh --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        elif command -v docker &>/dev/null; then
            container_id=$(docker ps -a --format "{{.Names}}" | grep -i "acme" | head -n1)
            ver=$(docker exec "$container_id" acme.sh --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        fi
        echo -e "版本: ${ver:-内置}"
    else
        echo -e "状态: ${RED}未安装${RESET}"
    fi
    echo ""

    # =============================
    # CF WARP
    # =============================
    echo -e "${YELLOW}▶ Cloudflare WARP${RESET}"
    warp_found=0
    if command -v warp-cli &>/dev/null; then
        warp_found=1
        if warp-cli status 2>/dev/null | grep -qi 'Connected'; then echo -e "状态: ${GREEN}已连接${RESET}"
        else echo -e "状态: ${YELLOW}已安装(未连接)${RESET}"; fi
    fi
    if command -v warp-go &>/dev/null || command -v warpgo &>/dev/null; then warp_found=1; echo -e "状态: ${GREEN}WarpGo已安装${RESET}"; fi
    if systemctl list-unit-files 2>/dev/null | grep -q warp-go; then
        warp_found=1
        if systemctl is-active warp-go &>/dev/null; then echo -e "状态: ${GREEN}WarpGo服务运行中${RESET}"
        else echo -e "状态: ${YELLOW}WarpGo已安装(未运行)${RESET}"; fi
    fi
    if command -v wgcf &>/dev/null || ip a 2>/dev/null | grep -q 'wgcf'; then warp_found=1; echo -e "状态: ${GREEN}WGCF已安装${RESET}"; fi
    if systemctl list-unit-files 2>/dev/null | grep -q warp-svc; then
        warp_found=1
        if systemctl is-active warp-svc &>/dev/null; then echo -e "状态: ${GREEN}服务运行中${RESET}"
        else echo -e "状态: ${YELLOW}服务已安装${RESET}"; fi
    fi
    if command -v warp &>/dev/null; then
        warp_found=1
        if warp status 2>/dev/null | grep -q "WARP 网络接口已开启"; then echo -e "状态: ${GREEN}已开启${RESET}"
        else echo -e "状态: ${YELLOW}已安装${RESET}"; fi
    fi
    if command -v docker &>/dev/null; then
        warp_containers=$(docker ps -a --format "{{.Names}}" | grep -i "warp")
        if [[ -n "$warp_containers" ]]; then
            warp_found=1
            for name in $warp_containers; do
                raw_status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)
                [[ "$raw_status" == "running" ]] && c_status="active" || c_status="$raw_status"
                echo -e "容器: ${CYAN}${name}${RESET} | 状态: $(format_status "$c_status")"
            done
        fi
    fi
    if [[ $warp_found -eq 0 ]]; then echo -e "状态: ${RED}未安装${RESET}"
    else
        trace=$(curl -s --max-time 2 https://www.cloudflare.com/cdn-cgi/trace)
        if echo "$trace" | grep -q "warp=on"; then echo -e "模式: ${GREEN}WARP中${RESET}"
        elif echo "$trace" | grep -q "warp=plus"; then echo -e "模式: ${GREEN}WARP+${RESET}"
        else echo -e "模式: ${YELLOW}普通网络${RESET}"; fi
    fi
    echo ""

    # =============================
    # CF Tunnel (Argo)
    # =============================
    local argo_path="${work_dir}/argo"
    echo -e "${YELLOW}▶ Cloudflare Tunnel${RESET}"
    cf_containers=""
    if command -v docker &>/dev/null; then
        cf_containers=$(docker ps -a --format "{{.Names}}" | grep -iE "cloudflared|tunnel|argo")
    fi
    if [[ -f "$argo_path" ]] || command -v cloudflared &>/dev/null || pgrep -f "argo|cloudflared" &>/dev/null || [[ -n "$cf_containers" ]]; then
        status=$(systemctl is-active cloudflared 2>/dev/null || systemctl is-active argo 2>/dev/null)
        if [[ "$status" != "active" ]]; then
            if pgrep -f "$argo_path" &>/dev/null || pgrep -f "cloudflared" &>/dev/null; then status="active"
            elif [[ -n "$cf_containers" ]]; then
                for name in $cf_containers; do
                    [[ $(docker inspect -f '{{.State.Status}}' "$name") == "running" ]] && status="active" && break
                done
            fi
        fi
        echo -e "状态: $(format_status "$status")"
        if [[ -f "$argo_path" ]]; then ver=$("$argo_path" --version 2>/dev/null | awk '{print $3}')
        elif command -v cloudflared &>/dev/null; then ver=$(cloudflared --version 2>/dev/null | awk '{print $3}')
        elif [[ -n "$cf_containers" ]]; then
            first_c=$(echo "$cf_containers" | head -n1)
            ver=$(docker exec "$first_c" cloudflared --version 2>/dev/null | awk '{print $3}')
        fi
        echo -e "版本: ${ver:-运行中(内置)}"
        if [[ -n "$cf_containers" ]]; then
            for name in $cf_containers; do
                raw_s=$(docker inspect -f '{{.State.Status}}' "$name")
                [[ "$raw_s" == "running" ]] && c_s="active" || c_s="$raw_s"
                echo -e "容器: ${CYAN}${name}${RESET} | 状态: $(format_status "$c_s")"
            done
        fi
    else
        echo -e "状态: ${RED}未安装${RESET}"
    fi
    echo ""

    # =============================
    # Docker
    # =============================
    echo -e "${YELLOW}▶ Docker${RESET}"
    if command -v docker &>/dev/null; then
        containers=$(docker ps --format "{{.Names}}" | grep -Ei 'xray|sing|hysteria|tuic|snell|3xui_app|AnyTLSD|MTProto|shadowsocks|sshadow-tls|shadow-tls|Singbox-AnyReality|Singbox-AnyTLS|Singbox-TUICv5|Xray-Reality|Xray-Realityxhttp|xray-socks5|xray-vmess|xray-vmesstls|clash|mihomo|warp|glash|conflux|heki|microwarp|nodepassdash|ppanel|wg-easy|wireguard|gostpanel|vite-frontend|xboard|xtrafficdash|lumina-client|freegfw|Mihomo')
        if [[ -n "$containers" ]]; then
            echo -e "状态: ${GREEN}运行中${RESET}"
            echo -e "${YELLOW}容器:${RESET} $(echo "$containers" | tr '\n' ' ')"
        else echo -e "状态: ${GREEN}已安装${RESET}"; fi
    else echo -e "状态: ${RED}未安装${RESET}"; fi
    echo ""

    # =============================
    # BBR
    # =============================
    echo -e "${YELLOW}▶ BBR${RESET}"
    actual_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
    if [[ "$actual_cc" == "bbr" ]]; then echo -e "状态: ${GREEN}已启用 BBR${RESET}"
    else echo -e "状态: ${RED}未启用 BBR${RESET}"; fi
    echo ""

    # =============================
    # 网络出口
    # =============================
    echo -e "${YELLOW}▶ 网络出口${RESET}"
    ipv4=$(curl -4 -s --max-time 3 ip.sb 2>/dev/null || curl -4 -s --max-time 3 ifconfig.me 2>/dev/null)
    ipv6=$(curl -6 -s --max-time 3 ip.sb 2>/dev/null)
    get_country_cn() {
        local ip="$1"
        local res=$(curl -s --max-time 3 "http://ip-api.com/json/$ip?lang=zh-CN")
        local name=$(echo "$res" | grep -oP '"country":"\K[^"]+')
        echo "${name:-未知}"
    }
    if [[ -n "$ipv4" ]]; then
        country4=$(get_country_cn "$ipv4")
        echo -e "IPv4: ${GREEN}$ipv4${RESET}         国家: ${GREEN}$country4${RESET}"
    else echo -e "IPv4: ${RED}获取失败${RESET}"; fi
    if [[ -n "$ipv6" ]]; then
        country6=$(get_country_cn "$ipv6")
        echo -e "IPv6: ${GREEN}$ipv6${RESET}  国家: ${GREEN}$country6${RESET}"
    fi
    echo ""

  
    # =============================
    # DNS 检测
    # =============================
    echo -e "${YELLOW}▶ DNS 信息检测${RESET}"

    # 确保工具存在
    [[ ! $(command -v dig) ]] && apk add --no-cache bind-tools >/dev/null 2>&1

    # 提取 DNS 列表
    dns_all=$(grep "nameserver" /etc/resolv.conf | awk '{print $2}')
    dns_v4=$(echo "$dns_all" | grep -v ":" | tr '\n' ' ')
    dns_v6=$(echo "$dns_all" | grep ":" | tr '\n' ' ')

    # --- IPv4 部分 ---
    if [[ -n "$dns_v4" ]]; then
        echo -e "DNSv4: ${CYAN}${dns_v4}${RESET}"
        first_dns=$(echo $dns_v4 | awk '{print $1}')
        test_v4=$(dig +short +time=2 +tries=1 google.com @$first_dns >/dev/null 2>&1 && echo "ok" || echo "fail")
        [[ "$test_v4" == "ok" ]] && echo -e "解析: ${GREEN}IPv4 正常${RESET}" || echo -e "解析: ${RED}IPv4 失败${RESET}"
    else
        echo -e "DNSv4: ${RED}无${RESET}"
    fi

    # --- IPv6 部分  ---
    if [[ -n "$dns_v6" ]]; then
        echo -e "DNSv6: ${CYAN}${dns_v6}${RESET}"
        first_dns6=$(echo $dns_v6 | awk '{print $1}')
        # 测试 AAAA 记录解析
        test_v6=$(dig +short +time=2 +tries=1 google.com AAAA @$first_dns6 >/dev/null 2>&1 && echo "ok" || echo "fail")
        
        if [[ "$test_v6" == "ok" ]]; then
            echo -e "解析: ${GREEN}IPv6 正常${RESET}"
        else
            echo -e "解析: ${RED}IPv6 失败${RESET}"
        fi
    else
        echo -e "DNSv6: ${RED}无配置${RESET}"
    fi


}

# 运行检测
status_check
