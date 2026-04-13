#!/bin/bash
# ========================================
# VFaka 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="vfaka"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.local.toml"
TOKENPAY_CONFIG="$APP_DIR/config/tokenpay/appsettings.json"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2，请升级 Docker${RESET}"
        exit 1
    fi
}

check_git() {
    if ! command -v git &>/dev/null; then
        echo -e "${YELLOW}未检测到 git，正在安装...${RESET}"
        apt-get update && apt-get install -y git || yum install -y git || exit 1
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== VFaka 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {
    check_docker
    check_git
    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
        rm -rf "$APP_DIR"
        mkdir -p "$APP_DIR"
    fi

    echo -e "${GREEN}开始下载 VFaka...${RESET}"
    git clone --recursive https://github.com/Viloze/VFaka.git "$APP_DIR" || {
        echo -e "${RED}git clone 失败，请检查网络或依赖${RESET}"
        read -p "按回车返回菜单..."
        return
    }

    cp "$APP_DIR/config.toml" "$CONFIG_FILE"

    read -p "配置监听 host [默认:127.0.0.1]: " input_host
    HOST=${input_host:-127.0.0.1}

    read -p "配置端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}

    read -p "设置 admin 用户名 [默认:admin]: " input_admin_user
    ADMIN_USER=${input_admin_user:-admin}

    read -p "设置 admin 密码: " ADMIN_PASS
    if [ -z "$ADMIN_PASS" ]; then
        echo -e "${RED}管理员密码不能为空${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    read -p "设置 JWT secret (可留空自动生成随机密钥): " INPUT_JWT_SECRET
    JWT_SECRET=${INPUT_JWT_SECRET:-$(openssl rand -hex 32)}


    read -p "是否配置 public_base_url (用于生产环境) [留空则不设置]: " PUBLIC_BASE_URL
    if [ -n "$PUBLIC_BASE_URL" ]; then
        read -p "是否配置 allowed_origins (逗号分隔) [留空使用默认]: " ALLOWED_ORIGINS
    fi

    cat > "$CONFIG_FILE" <<EOF
[server]
host = "${HOST}"
port = ${PORT}
EOF

    if [ -n "$PUBLIC_BASE_URL" ]; then
        echo "public_base_url = \"${PUBLIC_BASE_URL}\"" >> "$CONFIG_FILE"
        if [ -n "$ALLOWED_ORIGINS" ]; then
            echo "allowed_origins = [$(echo "$ALLOWED_ORIGINS" | sed 's/, */", "/g' | sed 's/^/"/; s/$/"/')]" >> "$CONFIG_FILE"
        fi
    fi

    cat >> "$CONFIG_FILE" <<EOF

[database]
url = "sqlite:./aff_shop.db?mode=rwc"

[jwt]
secret = "${JWT_SECRET}"
expiration_hours = 24

[admin]
username = "${ADMIN_USER}"
password = "${ADMIN_PASS}"
EOF

    read -p "是否配置 TokenPay (y/n) [默认:n]: " enable_tokenpay
    if [[ "$enable_tokenpay" == "y" || "$enable_tokenpay" == "Y" ]]; then
        cp "$APP_DIR/config/tokenpay/appsettings.json.example" "$TOKENPAY_CONFIG"

        read -p "请输入 TRONGRID API KEY: " TRON_API_KEY
        read -p "请输入 BaseCurrency [默认:CNY]: " input_base_currency
        BASE_CURRENCY=${input_base_currency:-CNY}

        read -p "是否启用动态地址 UseDynamicAddress? [true/false，默认:false]: " input_dynamic
        USE_DYNAMIC=${input_dynamic:-false}

        read -p "请输入 TRON 收款地址（多个逗号隔开）: " TRON_ADDRESSES
        read -p "设置 ApiToken (用于 TokenPay 回调鉴权): " API_TOKEN
        read -p "设置 TokenPay WebSiteUrl [默认:http://localhost:5000]: " input_website
        WEB_SITE_URL=${input_website:-http://localhost:5000}

        jq ".\"TRON-PRO-API-KEY\" = \"${TRON_API_KEY}\" |
            .BaseCurrency = \"${BASE_CURRENCY}\" |
            .UseDynamicAddress = ${USE_DYNAMIC,,} |
            .Address.TRON = [$(echo "$TRON_ADDRESSES" | sed 's/, */","/g' | sed 's/^/"/; s/$/"/')] |
            .ApiToken = \"${API_TOKEN}\" |
            .WebSiteUrl = \"${WEB_SITE_URL}\"" "$TOKENPAY_CONFIG" > "$TOKENPAY_CONFIG.tmp" && mv "$TOKENPAY_CONFIG.tmp" "$TOKENPAY_CONFIG"
    fi

    mkdir -p "$APP_DIR/data/uploads"

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ VFaka 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    [ -n "$PUBLIC_BASE_URL" ] && echo -e "${YELLOW}🔗 Public URL: ${PUBLIC_BASE_URL}${RESET}"
    echo -e "${GREEN}📂 配置文件: ${CONFIG_FILE}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    if [ ! -d "$APP_DIR/.git" ]; then
        echo -e "${RED}未检测到安装目录或 git 仓库，无法更新${RESET}"
        read -p "按回车返回菜单..."
        return
    fi
    cd "$APP_DIR" || return
    git pull --recurse-submodules
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ VFaka 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    cd "$APP_DIR" || return
    docker compose restart
    echo -e "${GREEN}✅ VFaka 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    cd "$APP_DIR" || return
    docker compose logs -f
}

check_status() {
    cd "$APP_DIR" || return
    docker compose ps
    read -p "按回车返回菜单..."
}

uninstall_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}未检测到安装目录，无需卸载${RESET}"
        read -p "按回车返回菜单..."
        return
    fi
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ VFaka 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
