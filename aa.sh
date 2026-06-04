#!/usr/bin/env bash
# 强制使用 bash 运行，Alpine 默认是 ash
set -e

CADDYFILE="/etc/caddy/Caddyfile"

# ==================== 智能动态证书路径适配 ====================
if [ -d "/root/.local/share/caddy" ]; then
    CADDY_DATA="/root/.local/share/caddy"
elif [ -d "/var/lib/caddy/.local/share/caddy" ]; then
    CADDY_DATA="/var/lib/caddy/.local/share/caddy"
else
    CADDY_DATA="$HOME/.local/share/caddy"
fi
# =============================================================

CADDY_CERTS_DIR="/etc/caddy/certs"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# ==================== 自动化环境检查与修复 ====================
if [ ! -f /etc/alpine-release ]; then
    echo -e "${RED}错误: 本脚本为 Alpine Linux 专属！${RESET}"
    exit 1
fi

INIT_DEPS=()
command -v sudo >/dev/null 2>&1 || INIT_DEPS+=("sudo")
command -v openssl >/dev/null 2>&1 || INIT_DEPS+=("openssl")
command -v curl >/dev/null 2>&1 || INIT_DEPS+=("curl")
command -v gawk >/dev/null 2>&1 || INIT_DEPS+=("gawk") 

if [ ${#INIT_DEPS[@]} -ne 0 ]; then
    echo -e "${YELLOW}正在自动安装必要依赖: ${INIT_DEPS[*]}...${RESET}"
    apk update -q && apk add -q "${INIT_DEPS[@]}"
fi

[ -f /usr/bin/gawk ] && ln -sf /usr/bin/gawk /usr/bin/awk 2>/dev/null || true

if [ ! -d "/etc/caddy" ]; then
    sudo mkdir -p /etc/caddy
fi

if [ ! -f "$CADDYFILE" ] || [ ! -s "$CADDYFILE" ]; then
    echo -e "${YELLOW}正在初始化空的 Caddyfile...${RESET}"
    sudo tee "$CADDYFILE" >/dev/null <<EOF
# Caddy Configuration File
# Managed by Alpine Caddy Panel
EOF
fi

[ ! -d "$CADDY_CERTS_DIR" ] && sudo mkdir -p $CADDY_CERTS_DIR && sudo chown -R root:root $CADDY_CERTS_DIR 2>/dev/null || true

pause() {
    echo -ne "${YELLOW}按回车返回菜单...${RESET}"
    read -r
}

get_all_domains() {
    [ ! -f "$CADDYFILE" ] && return
    grep -E '^[[:space:]]*([a-zA-Z0-9.-]+|:[0-9]+|http[s]?://[a-zA-Z0-9.-]+)' "$CADDYFILE" | \
    sed -E 's/https?:\/\///g' | \
    awk '{print $1}' | \
    awk -F: '{print $1}' | \
    grep -Ev '^(file_server|reverse_proxy|root|import|tls|header|encode|route|handle|handle_path|log|respond|rewrite|redir|try_files|{|}|\*)$' | \
    grep '\.' | sort -u
}

# ==================== 【同步增强】Alpine 原生自启与进程守护 ====================
setup_native_daemon() {
    # 方式1：针对非容器的标准 Alpine VPS，利用 Alpine 内置轻量 local 服务实现开机纯原生拉起
    if [ -d /etc/local.d ]; then
        echo -e "${CYAN}正在配置 Alpine 原生开机自启守护...${RESET}"
        sudo tee /etc/local.d/caddy_native.start >/dev/null <<EOF
#!/bin/sh
# Alpine Caddy Native Autostart
if ! pgrep -x caddy >/dev/null; then
    /usr/sbin/caddy start --config /etc/caddy/Caddyfile >/dev/null 2>&1
fi
EOF
        sudo chmod +x /etc/local.d/caddy_native.start
        sudo rc-update add local default >/dev/null 2>&1 || true
    fi

    # 方式2：利用 crontab 执行每分钟级的常驻保活（同时兼顾 Docker 容器环境与 VPS 挂掉重启）
    (crontab -l 2>/dev/null | grep -v "caddy start" || true; echo "* * * * * pgrep -x caddy >/dev/null || /usr/sbin/caddy start --config /etc/caddy/Caddyfile >/dev/null 2>&1") | crontab -
}

remove_native_daemon() {
    [ -f /etc/local.d/caddy_native.start ] && sudo rm -f /etc/local.d/caddy_native.start || true
    crontab -l 2>/dev/null | grep -v "caddy start" | crontab - || true
}

# ==================== 纯原生状态检测 ====================
get_system_status() {
    if ! command -v caddy >/dev/null 2>&1; then
        STATUS="${RED}未安装${RESET}"
        VERSION_SHOW="-"
        SITE_COUNT="0"
        return
    fi

    if pgrep -x caddy >/dev/null 2>&1; then
        STATUS="${GREEN}运行中${RESET}"
    else
        STATUS="${RED}已停止${RESET}"
    fi

    VERSION_SHOW=$(caddy version | awk '{print $1}')
    SITE_COUNT=$(get_all_domains | wc -l)
}

# ==================== 纯原生安装与原生拉起 ====================
install_caddy() {
    if command -v caddy >/dev/null 2>&1; then
        echo -e "${GREEN}Caddy 已安装${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}正在通过 apk 安装 Caddy...${RESET}"
    sudo apk update -q && sudo apk add -q caddy
    
    sudo rc-update del caddy default >/dev/null 2>&1 || true
    echo -e "${YELLOW}正在通过原生模式后台初始化 Caddy 服务...${RESET}"
    sudo caddy start --config "$CADDYFILE" >/dev/null 2>&1
    
    # 注入自启与保活守护
    setup_native_daemon

    sudo mkdir -p $CADDY_CERTS_DIR 2>/dev/null || true
    echo -e "${GREEN}Caddy 安装完成并已成功独立运行（已配置原生保活守护）！${RESET}"
    pause
}

update_caddy() {
    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${RED}Caddy 未安装，无法更新${RESET}"
        pause
        return
    fi
    echo -e "${GREEN}正在检查并更新 Caddy 固件...${RESET}"
    
    local was_running=0
    pgrep -x caddy >/dev/null 2>&1 && was_running=1
    
    sudo killall -9 caddy >/dev/null 2>&1 || true
    sudo apk update -q && sudo apk add -q --upgrade caddy
    
    if [ $was_running -eq 1 ]; then
        sudo caddy start --config "$CADDYFILE" >/dev/null 2>&1
    fi
    echo -e "${GREEN}Caddy 更新程序执行完毕${RESET}"
    pause
}

# ==================== 纯原生强力卸载 ====================
uninstall_caddy() {
    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${YELLOW}Caddy 未安装${RESET}"
        pause
        return
    fi
    echo -ne "${YELLOW}确定要彻底卸载 Caddy 吗？此操作不可逆！(y/n): ${RESET}"; read -r CONFIRM
    if [[ "$CONFIRM" != "y" ]]; then
        echo -e "${YELLOW}已取消卸载${RESET}"
        pause
        return
    fi
    echo -e "${GREEN}正在强制注销 Caddy 进程群...${RESET}"
    
    remove_native_daemon
    sudo killall -9 caddy >/dev/null 2>&1 || true
    sudo rc-update del caddy default >/dev/null 2>&1 || true
    sudo apk del caddy
    sudo rm -rf /etc/caddy /var/lib/caddy /var/log/caddy
    echo -e "${GREEN}Caddy 已从系统中完全原生抹除${RESET}"
    pause
}

# ==================== 纯原生秒级重载/复活控制流 ====================
validate_and_reload() {
    local BACKUP_FILE=$1
    echo -e "${YELLOW}正在对调整后的 Caddyfile 进行原生语法安全性检查...${RESET}"
    
    if local ERR_MSG=$(sudo caddy validate --config "$CADDYFILE" 2>&1); then
        echo -e "${GREEN}✔ 语法验证通过！正在应用配置...${RESET}"
        
        if pgrep -x caddy >/dev/null 2>&1; then
            if sudo caddy reload --config "$CADDYFILE" >/dev/null 2>&1; then
                echo -e "${GREEN}✔ Caddy 原生配置已完成零丢包热重载！${RESET}"
                return 0
            fi
        fi
        
        sudo killall -9 caddy >/dev/null 2>&1 || true
        if sudo caddy start --config "$CADDYFILE" >/dev/null 2>&1; then
            echo -e "${GREEN}✔ Caddy 独立主服务已强力冷启动，配置生效！${RESET}"
            return 0
        else
            echo -e "${RED}❌ 致命错误: 无法拉起原生 Caddy 二进制，请检查 80/443 端口是否被占用！${RESET}"
            return 1
        fi
    else
        echo -e "${RED}❌ 错误: Caddyfile 语法检查未通过！拒绝写入新配置。${RESET}"
        echo -e "${YELLOW}---------------- [Caddy 核心报错日志] ----------------${RESET}"
        echo -e "$ERR_MSG"
        echo -e "${YELLOW}------------------------------------------------------${RESET}"
        if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
            echo -e "${GREEN}🔄 系统检测到潜在崩溃风险，已自动秒级回滚。${RESET}"
            sudo cp -f "$BACKUP_FILE" "$CADDYFILE"
        fi
        return 1
    fi
}

# ==================== 纯原生菜单重载调用 ====================
reload_caddy() {
    if pgrep -x caddy >/dev/null 2>&1; then
        validate_and_reload ""
    else
        echo -e "${YELLOW}Caddy 当前未运行，正在尝试纯原生方式拉起服务...${RESET}"
        sudo killall -9 caddy >/dev/null 2>&1 || true
        if sudo caddy start --config "$CADDYFILE" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ 原生 Caddy 服务启动成功！${RESET}"
        else
            echo -e "${RED}❌ 启动失败，请检查端口占用。${RESET}"
        fi
    fi
    pause
}

remove_domain_block() {
    local tgt=$1
    sudo awk -v domain="$tgt" '
    BEGIN { inside = 0; brace_count = 0 }
    $0 ~ "^[[:space:]]*" domain "([[:space:],:{]|$)" {
        inside = 1
        if ($0 ~ "{") brace_count += gsub(/{/, "{")
        if ($0 ~ "}") brace_count -= gsub(/}/, "}")
        next
    }
    inside {
        if ($0 ~ "{") brace_count += gsub(/{/, "{")
        if ($0 ~ "}") brace_count -= gsub(/}/, "}")
        if (brace_count <= 0 && $0 ~ "}") {
            inside = 0
        }
        next
    }
    { print }
    ' "$CADDYFILE" > /tmp/caddyfile.tmp && sudo mv /tmp/caddyfile.tmp "$CADDYFILE"
}

add_site() {
    echo -ne "请输入域名 (例如: example.com)： "; read -r DOMAIN
    [ -z "$DOMAIN" ] && return
    echo -ne "是否需要 h2c/gRPC 代理？(y/n，回车默认 n)： "; read -r H2C
    H2C=${H2C:-n}
    
    local TS=$(date +%s 2>/dev/null || echo "bk")
    local BK_FILE="/tmp/caddyfile.bak.$TS"
    sudo cp "$CADDYFILE" "$BK_FILE"

    SITE_CONFIG="\n${DOMAIN} {\n"
    if [[ "$H2C" == "y" ]]; then
        echo -ne "请输入 h2c 代理路径 (例如 /proto.NezhaService/*)： "; read -r H2C_PATH
        echo -ne "请输入内网目标地址 (例如 127.0.0.1:8008)： "; read -r H2C_TARGET
        SITE_CONFIG+="    reverse_proxy ${H2C_PATH} h2c://${H2C_TARGET}\n"
    fi

    echo -ne "请输入普通 HTTP 代理目标 (例如 127.0.0.1:8008)： "; read -r HTTP_TARGET
    HTTP_TARGET=${HTTP_TARGET:-127.0.0.1:8008}
    SITE_CONFIG+="    reverse_proxy ${HTTP_TARGET}\n}\n"

    echo -e "$SITE_CONFIG" | sudo tee -a "$CADDYFILE" >/dev/null
    if validate_and_reload "$BK_FILE"; then
        echo -e "${GREEN}站点 ${DOMAIN} 添加成功${RESET}"
    fi
    rm -f "$BK_FILE"
    pause
}

check_domains_status() {
    clear
    echo -e "${YELLOW}========================================${RESET}"
    echo -e "${YELLOW}        ◈ 域名证书状态实时监控 ◈            ${RESET}"
    echo -e "${YELLOW}========================================${RESET}"

    DOMAINS=($(get_all_domains))
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${RED} ❌ 当前系统未检测到任何反代站点配置。${RESET}"
        echo -e "${YELLOW}----------------------------------------${RESET}"
        pause
        return
    fi

    for DOMAIN in "${DOMAINS[@]}"; do
        local CERT_PATH=""
        local TYPE="自动申请"

        if [ -d "$CADDY_DATA" ]; then
            CERT_PATH=$(sudo find "$CADDY_DATA" -type f -name "$DOMAIN.crt" 2>/dev/null | head -n 1)
        fi

        if [ -z "$CERT_PATH" ] && grep -A 5 "${DOMAIN}" "$CADDYFILE" | grep -q "tls "; then
            local CUSTOM_PATH=$(grep -A 5 "${DOMAIN}" "$CADDYFILE" | grep "tls " | awk '{print $2}' | tr -d '\r\n')
            if [ -e "$CUSTOM_PATH" ]; then
                CERT_PATH="$CUSTOM_PATH"
                TYPE="自定义证书 (软链接保持更新)"
            fi
        fi

        echo -e "${YELLOW}◈ 域名: ${RESET}${YELLOW}${DOMAIN}${RESET}"
        echo -e "  ├─ ${YELLOW}证书类型: ${RESET}${TYPE}"

        if [ -n "$CERT_PATH" ] && [ -e "$CERT_PATH" ]; then
            END_DATE=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
            if END_TS=$(date -d "$END_DATE" +%s 2>/dev/null) || END_TS=$(date -D "%b %d %T %Y %Z" -d "$END_DATE" +%s 2>/dev/null); then
                NOW_TS=$(date +%s)
                DAYS_LEFT=$(( (END_TS - NOW_TS) / 86400 ))
                
                if [ $DAYS_LEFT -ge 30 ]; then
                    STATUS_COLOR="${GREEN}"
                    STATUS_TEXT="正常有效"
                elif [ $DAYS_LEFT -ge 0 ]; then
                    STATUS_COLOR="${YELLOW}"
                    STATUS_TEXT="即将过期"
                else
                    STATUS_COLOR="${RED}"
                    STATUS_TEXT="已过期"
                fi
                echo -e "  ├─ ${YELLOW}到期时间: ${RESET}$(date -d "@$END_TS" +"%Y-%m-%d" 2>/dev/null || echo "$END_DATE")"
                echo -e "  ├─ ${YELLOW}剩余天数: ${RESET}${STATUS_COLOR}${DAYS_LEFT} 天${RESET}"
                echo -e "  └─ ${YELLOW}运行状态: ${RESET}${STATUS_COLOR}${STATUS_TEXT}${RESET}"
            else
                if openssl x509 -checkend 2592000 -in "$CERT_PATH" >/dev/null; then
                    echo -e "  └─ ${YELLOW}运行状态: ${RESET}${GREEN}正常有效 (剩余 > 30天)${RESET}"
                else
                    echo -e "  └─ ${YELLOW}运行状态: ${RESET}${YELLOW}即将过期或已过期${RESET}"
                fi
            fi
        else
            echo -e "  └─ ${YELLOW}运行状态: ${RESET}${RED}未找到证书或尚未签发成功${RESET}"
        fi
        echo -e "${YELLOW}----------------------------------------${RESET}"
    done
    pause
}

delete_site() {
    DOMAINS=($(get_all_domains))
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有可删除的域名${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}请选择要删除的域名编号（输入0返回菜单）:${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo "$((i+1))) ${DOMAINS[$i]}"
    done
    echo -ne "输入编号： "; read -r NUM
    if [[ "$NUM" == "0" || -z "$NUM" ]]; then return; fi

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效编号${RESET}"
        pause
        return
    fi

    DOMAIN="${DOMAINS[$((NUM-1))]}"
    local TS=$(date +%s 2>/dev/null || echo "bk")
    local BK_FILE="/tmp/caddyfile.bak.$TS"
    sudo cp "$CADDYFILE" "$BK_FILE"

    remove_domain_block "$DOMAIN"

    if validate_and_reload "$BK_FILE"; then
        echo -e "${GREEN}域名 ${DOMAIN} 已彻底从配置中移除！${RESET}"
        sudo rm -f "$CADDY_CERTS_DIR/${DOMAIN}"* "$CADDY_CERTS_DIR/emby_${DOMAIN}"*
    fi
    rm -f "$BK_FILE"
    pause
}

modify_site() {
    DOMAINS=($(get_all_domains))
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有可修改的域名${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}请选择要修改的域名编号（输入0返回菜单）:${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo "$((i+1))) ${DOMAINS[$i]}"
    done
    echo -ne "输入编号： "; read -r NUM
    if [[ "$NUM" == "0" || -z "$NUM" ]]; then return; fi

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效编号${RESET}"
        pause
        return
    fi

    DOMAIN="${DOMAINS[$((NUM-1))]}"
    local OLD_TLS_LINE=$(grep -A 5 "${DOMAIN}" "$CADDYFILE" | grep "tls " | head -n 1 | tr -d '\r')

    echo -ne "请输入普通 HTTP 代理目标 (例如 127.0.0.1:8008)： "; read -r HTTP_TARGET
    HTTP_TARGET=${HTTP_TARGET:-127.0.0.1:8008}

    echo -ne "是否需要 h2c/gRPC 代理？(y/n，回车默认 n)： "; read -r H2C
    H2C=${H2C:-n}
    H2C_CONFIG=""
    if [[ "$H2C" == "y" ]]; then
        echo -ne "请输入 h2c 代理路径 (例如 /proto.NezhaService/*)： "; read -r H2C_PATH
        echo -ne "请输入内网目标地址 (例如 127.0.0.1:8008)： "; read -r H2C_TARGET
        H2C_CONFIG="    reverse_proxy ${H2C_PATH} h2c://${H2C_TARGET}\n"
    fi

    local TS=$(date +%s 2>/dev/null || echo "bk")
    local BK_FILE="/tmp/caddyfile.bak.$TS"
    sudo cp "$CADDYFILE" "$BK_FILE"

    remove_domain_block "$DOMAIN"
    
    NEW_CONFIG="\n${DOMAIN} {\n"
    if [ -n "$OLD_TLS_LINE" ]; then
        NEW_CONFIG+="${OLD_TLS_LINE}\n"
    fi
    NEW_CONFIG+="${H2C_CONFIG}    reverse_proxy ${HTTP_TARGET}\n}\n"
    
    echo -e "$NEW_CONFIG" | sudo tee -a "$CADDYFILE" >/dev/null
    if validate_and_reload "$BK_FILE"; then
        echo -e "${GREEN}域名 ${DOMAIN} 配置已成功修改！${RESET}"
    fi
    rm -f "$BK_FILE"
    pause
}

link_and_fix_permissions() {
    local src_file=$1
    local symlink_dst=$2

    if [ ! -f "$src_file" ]; then
        echo -e "${RED}❌ 错误: 源证书/密钥文件 [${src_file}] 实际不存在，请检查输入路径！${RESET}"
        return 1
    fi

    sudo chmod 644 "$src_file" 2>/dev/null || true

    # 【修复重点】Alpine 下的路径追溯：递归修改父级目录执行权限，跳过根目录防止死循环
    local dir_path=$(dirname "$src_file")
    while [ "$dir_path" != "/" ] && [ "$dir_path" != "." ] && [ -n "$dir_path" ]; do
        if [[ "$dir_path" == /root* ]]; then
            echo -e "${RED}❌ 拒绝: 检测到源证书位于 /root 极度隐秘目录下。${RESET}"
            echo -e "${YELLOW}💡 强烈建议: 请将 acme 证书导出路径改为 /etc/ssl/ 或 /etc/caddy/certs/ 等公共非 root 目录下！${RESET}"
            return 1
        fi
        sudo chmod +x "$dir_path" 2>/dev/null || true
        dir_path=$(dirname "$dir_path")
    done

    sudo rm -f "$symlink_dst"
    sudo ln -sf "$src_file" "$symlink_dst"
    return 0
}

add_site_with_cert() {
    echo -ne "请输入域名 (example.com)： "; read -r DOMAIN
    [ -z "$DOMAIN" ] && return
    echo -ne "是否需要 h2c/gRPC 代理？(y/n，回车默认 n)： "; read -r H2C
    H2C=${H2C:-n}

    echo -ne "请输入【源证书文件】绝对路径 (.pem/.crt)： "; read -r RAW_CERT_PATH
    echo -ne "请输入【源私钥文件】绝对路径 (.key)： "; read -r RAW_KEY_PATH

    local LINK_CERT="$CADDY_CERTS_DIR/${DOMAIN}.fullchain.pem"
    local LINK_KEY="$CADDY_CERTS_DIR/${DOMAIN}.privkey.key"

    echo -e "${YELLOW}正在智能打通父目录权限并建立不占空间的软链接...${RESET}"
    if ! link_and_fix_permissions "$RAW_CERT_PATH" "$LINK_CERT"; then pause; return; fi
    if ! link_and_fix_permissions "$RAW_KEY_PATH" "$LINK_KEY"; then pause; return; fi

    local TS=$(date +%s 2>/dev/null || echo "bk")
    local BK_FILE="/tmp/caddyfile.bak.$TS"
    sudo cp "$CADDYFILE" "$BK_FILE"

    SITE_CONFIG="\n${DOMAIN} {\n"
    SITE_CONFIG+="    tls ${LINK_CERT} ${LINK_KEY}\n"

    if [[ "$H2C" == "y" ]]; then
        echo -ne "请输入 h2c 代理路径 (例如 /proto.NezhaService/*)： "; read -r H2C_PATH
        echo -ne "请输入内网目标地址 (例如 127.0.0.1:8008)： "; read -r H2C_TARGET
        SITE_CONFIG+="    reverse_proxy ${H2C_PATH} h2c://${H2C_TARGET}\n"
    fi

    echo -ne "请输入普通 HTTP 代理目标 (例如 127.0.0.1:8008)： "; read -r HTTP_TARGET
    HTTP_TARGET=${HTTP_TARGET:-127.0.0.1:8008}
    SITE_CONFIG+="    reverse_proxy ${HTTP_TARGET}\n}\n"

    echo -e "$SITE_CONFIG" | sudo tee -a "$CADDYFILE" >/dev/null

    if validate_and_reload "$BK_FILE"; then
        echo -e "${GREEN}站点 ${DOMAIN} (动态软链证书模式) 添加成功！${RESET}"
        echo -e "${GREEN}今后源证书文件更新时，Caddy 将会自动同步加载最新的凭证。${RESET}"
    fi
    rm -f "$BK_FILE"
    pause
}

add_emby_site_caddy() {
    echo -ne "${GREEN}请输入您的域名 (例: emby.example.com): ${RESET}"; read -r DOMAIN
    [ -z "$DOMAIN" ] && return
    echo -ne "${GREEN}请输入 Emby 目标地址 (例: http://127.0.0.1:8096): ${RESET}"; read -r TARGET
    
    local TARGET_HOST=$(echo "$TARGET" | awk -F[/:] '{print $4}')
    local TS=$(date +%s 2>/dev/null || echo "bk")
    local BK_FILE="/tmp/caddyfile.bak.$TS"
    sudo cp "$CADDYFILE" "$BK_FILE"

    sudo tee -a "$CADDYFILE" >/dev/null <<EOF

$DOMAIN {
    encode gzip
    reverse_proxy $TARGET {
        flush_interval -1
        header_up Host {upstream_hostport}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
EOF

    if [[ "$TARGET" == https* ]]; then
        sudo tee -a "$CADDYFILE" >/dev/null <<EOF
        header_up Host $TARGET_HOST
        transport http {
            tls_server_name $TARGET_HOST
        }
EOF
    fi

    sudo tee -a "$CADDYFILE" >/dev/null <<EOF
    }
    header {
        Access-Control-Allow-Origin *
        Access-Control-Allow-Methods "GET, POST, OPTIONS, DELETE, PUT"
        Access-Control-Allow-Headers "X-Emby-Authorization, Content-Type, Authorization, X-Requested-With"
    }
}
EOF
    if validate_and_reload "$BK_FILE"; then
        echo -e "${GREEN}配置已生成！访问地址: https://${DOMAIN}${RESET}"
    fi
    rm -f "$BK_FILE"
    pause
}

add_emby_split_site_caddy() {
    echo -ne "${GREEN}请输入您的域名(例: emby.example.com): ${RESET}"; read -r DOMAIN
    [ -z "$DOMAIN" ] && return
    echo -ne "${GREEN}请输入 Emby 主站地址: ${RESET}"; read -r T_MAIN
    echo -ne "${GREEN}请输入推流后端地址: ${RESET}"; read -r T_STREAM

    local STREAM_HOST=$(echo "$T_STREAM" | awk -F[/:] '{print $4}')
    local TS=$(date +%s 2>/dev/null || echo "bk")
    local BK_FILE="/tmp/caddyfile.bak.$TS"
    sudo cp "$CADDYFILE" "$BK_FILE"

    sudo tee -a "$CADDYFILE" >/dev/null <<EOF

$DOMAIN {
    handle_path /s1/* {
        reverse_proxy $T_STREAM {
            flush_interval -1
            header_up Host $STREAM_HOST
            header_up X-Real-IP ""
            header_up X-Forwarded-For ""
        }
    }
    handle {
        reverse_proxy $T_MAIN {
            flush_interval -1
            header_up Host {upstream_hostport}
            header_up X-Real-IP ""
            header_up X-Forwarded-For ""
        }
    }
}
EOF
    if validate_and_reload "$BK_FILE"; then
        echo -e "${GREEN}访问地址: https://${DOMAIN}${RESET}"
    fi
    rm -f "$BK_FILE"
    pause
}

add_emby_custom_cert_caddy() {
    echo -ne "${GREEN}请输入您的域名 (例: emby.example.com): ${RESET}"; read -r DOMAIN
    [ -z "$DOMAIN" ] && return
    echo -ne "${GREEN}请输入源证书绝对路径 (.pem/.crt): ${RESET}"; read -r RAW_CERT_PATH
    echo -ne "${GREEN}请输入源私钥绝对路径 (.key): ${RESET}"; read -r RAW_KEY_PATH

    local LINK_CERT="$CADDY_CERTS_DIR/emby_${DOMAIN}.fullchain.pem"
    local LINK_KEY="$CADDY_CERTS_DIR/emby_${DOMAIN}.privkey.key"

    if ! link_and_fix_permissions "$RAW_CERT_PATH" "$LINK_CERT"; then pause; return; fi
    if ! link_and_fix_permissions "$RAW_KEY_PATH" "$LINK_KEY"; then pause; return; fi

    echo -ne "${GREEN}请输入 Emby 目标地址 (例: http://127.0.0.1:8096): ${RESET}"; read -r TARGET
    local TARGET_HOST=$(echo "$TARGET" | awk -F[/:] '{print $4}')
    
    local TS=$(date +%s 2>/dev/null || echo "bk")
    local BK_FILE="/tmp/caddyfile.bak.$TS"
    sudo cp "$CADDYFILE" "$BK_FILE"

    sudo tee -a "$CADDYFILE" >/dev/null <<EOF

$DOMAIN {
    tls $LINK_CERT $LINK_KEY
    encode gzip
    reverse_proxy $TARGET {
        flush_interval -1
        header_up Host {upstream_hostport}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
EOF

    if [[ "$TARGET" == https* ]]; then
        sudo tee -a "$CADDYFILE" >/dev/null <<EOF
        header_up Host $TARGET_HOST
        transport http {
            tls_server_name $TARGET_HOST
        }
EOF
    fi

    sudo tee -a "$CADDYFILE" >/dev/null <<EOF
    }
    header {
        Access-Control-Allow-Origin *
        Access-Control-Allow-Methods "GET, POST, OPTIONS, DELETE, PUT"
        Access-Control-Allow-Headers "X-Emby-Authorization, Content-Type, Authorization, X-Requested-With"
    }
}
EOF
    if validate_and_reload "$BK_FILE"; then
        echo -e "${GREEN}自定义软链证书 Emby 配置已成功生成！${RESET}"
    fi
    rm -f "$BK_FILE"
    pause
}

emby_proxy_menu() {
    while true; do
        clear
        echo -e "${GREEN}==== Emby 反代管理 ====${RESET}"
        echo -e "${GREEN}1. 普通反代(自动申请证书)${RESET}"
        echo -e "${GREEN}2. 主站+推流重定向(自动申请证书)${RESET}"
        echo -e "${GREEN}3. 普通反代(使用自定义软链证书)${RESET}"
        echo -e "${0}. 返回主菜单${RESET}"
        echo -ne "${GREEN}请选择: ${RESET}" 
        read -r emby_choice
        case $emby_choice in
            1) add_emby_site_caddy; break ;;
            2) add_emby_split_site_caddy; break ;;
            3) add_emby_custom_cert_caddy; break ;;
            0) return ;;
            *) echo -e "${RED}无效选项${RESET}"; pause ;;
        esac
    done
}

view_sites() {
    DOMAINS=($(get_all_domains))
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有已配置的域名${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}请选择要查看证书信息的域名编号（输入0返回菜单）:${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo "$((i+1))) ${DOMAINS[$i]}"
    done

    echo -ne "输入编号： "; read -r NUM
    if [[ "$NUM" == "0" || -z "$NUM" ]]; then return; fi

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效编号${RESET}"
        pause
        return
    fi

    DOMAIN="${DOMAINS[$((NUM-1))]}"
    local CERT_FILE=""
    if [ -d "$CADDY_DATA" ]; then
        CERT_FILE=$(sudo find "$CADDY_DATA" -type f -name "$DOMAIN.crt" 2>/dev/null | head -n 1)
    fi
    if [ -z "$CERT_FILE" ] && [ -e "$CADDY_CERTS_DIR/${DOMAIN}.fullchain.pem" ]; then
        CERT_FILE="$CADDY_CERTS_DIR/${DOMAIN}.fullchain.pem"
    fi
    if [ -z "$CERT_FILE" ] && [ -e "$CADDY_CERTS_DIR/emby_${DOMAIN}.fullchain.pem" ]; then
        CERT_FILE="$CADDY_CERTS_DIR/emby_${DOMAIN}.fullchain.pem"
    fi

    if [ -n "$CERT_FILE" ] && [ -e "$CERT_FILE" ]; then
        echo -e "${GREEN}证书路径：${RESET}${CERT_FILE}"
        echo -e "${GREEN}证书信息：${RESET}"
        openssl x509 -in "$CERT_FILE" -noout -text | awk '/Subject:/ || /Issuer:/ || /Not Before:/ || /Not After :/ {print}'
    else
        echo -e "${YELLOW}${DOMAIN} - 未在系统默认路径找到证书${RESET}"
    fi
    pause
}

# ==================== 纯原生语法安全性诊断（无需服务运行） ====================
view_caddy_logs() {
    clear
    if ! pgrep -x caddy >/dev/null 2>&1; then
        echo -e "${RED}⚠️ 检测到 Caddy 服务当前【未运行 / 已停止】！${RESET}"
        echo -e "${YELLOW}正在强行为您执行底层的 Caddy 核心配置文件语法安全性诊断...${RESET}"
        echo -e "${GREEN}执行命令: caddy validate --config /etc/caddy/Caddyfile${RESET}"
        echo -e "${YELLOW}------------------- [诊断输出开始] -------------------${RESET}"
        echo ""
        if sudo caddy validate --config /etc/caddy/Caddyfile 2>&1; then
            echo ""
            echo -e "${GREEN}✔ 核心诊断结论: 您的 Caddyfile 语法本身完全正确！${RESET}"
        else
            echo ""
            echo -e "${RED}❌ 核心诊断结论: 您的 Caddyfile 存在语法错误或路径死链！请根据上方报错修改。${RESET}"
        fi
        echo -e "${YELLOW}------------------- [诊断输出结束] -------------------${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${GREEN}           ◈ 正在实时捕获 Caddy 运行日志 ◈             ${RESET}"
    echo -e "${YELLOW}   >> 提示: 键盘按下 Ctrl + C 即可随时退出日志流 <<  ${RESET}"
    echo -e "${GREEN}======================================================${RESET}"
    echo ""
    
    if [ -f /var/log/caddy.log ]; then
        sudo tail -n 50 -f /var/log/caddy.log
    elif [ -f /var/log/messages ]; then
        sudo grep -i caddy /var/log/messages | tail -n 50
        sudo tail -f /var/log/messages | grep --line-buffered -i caddy || true
    else
        echo -e "${YELLOW}未找到独立日志文件，正在执行 caddy 原生运行流实时检测(前台诊断，按 Ctrl+C 退出)...${RESET}"
        sudo caddy run --config "$CADDYFILE" 2>&1 | tail -n 50
    fi
    pause
}

menu() {
    while true; do
        clear
        get_system_status
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}        Caddy  管理面板          ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}状态   :${RESET} $STATUS"
        echo -e "${GREEN}版本   :${RESET} ${YELLOW}$VERSION_SHOW${RESET}"
        echo -e "${GREEN}站点   :${RESET} ${YELLOW}$SITE_COUNT 个${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 1. 安装Caddy${RESET}"
        echo -e "${GREEN} 2. 添加站点(自动申请)${RESET}"
        echo -e "${GREEN} 3. 修改配置${RESET}"
        echo -e "${GREEN} 4. 添加站点(自定义证书)${RESET}"
        echo -e "${GREEN} 5. 删除站点${RESET}"
        echo -e "${GREEN} 6. 查看证书信息${RESET}"
        echo -e "${GREEN} 7. Emby反代管理${RESET}"
        echo -e "${GREEN} 8. 查看证书状态${RESET}"
        echo -e "${GREEN} 9. 重载Caddy配置${RESET}"
        echo -e "${GREEN}10. 查看Caddy日志${RESET}"
        echo -e "${GREEN}11. 更新Caddy${RESET}"
        echo -e "${GREEN}12. 卸载Caddy${RESET}"
        echo -e "${0}. 退出${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -ne "${GREEN} 请选择: ${RESET}"
        read choice

        case $choice in
            1) install_caddy ;;
            2) add_site ;;
            3) modify_site ;;
            4) add_site_with_cert ;;
            5) delete_site ;;
            6) view_sites ;;
            7) emby_proxy_menu ;;
            8) check_domains_status ;;
            9) reload_caddy ;;
            10) view_caddy_logs ;;
            11) update_caddy ;;
            12) uninstall_caddy ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${RESET}"; pause ;;
        esac
    done
}

menu
