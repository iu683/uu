#!/bin/bash
# ========================================
# ACME.sh 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="acme"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
SSL_DIR="/opt/$APP_NAME/ssl"

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

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== ACME 证书管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新 ACME${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 卸载${RESET}"
        echo -e "${GREEN}6) 申请证书${RESET}"
        echo -e "${GREEN}7) 删除证书${RESET}"
        echo -e "${GREEN}8) 查看已配置域名${RESET}"
        echo -e "${GREEN}9) 查看证书状态${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"

        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) uninstall_app ;;
            6) issue_cert ;;
            7) remove_cert ;;
            8) list_domains ;;
            9) cert_status ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {

    check_docker
    mkdir -p "$APP_DIR"
    mkdir -p "$SSL_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入 CF_Token: " CF_Token
    read -p "请输入 CF_Account_ID: " CF_Account_ID
    read -p "请输入 CF_Zone_ID: " CF_Zone_ID

    cat > "$COMPOSE_FILE" <<EOF
services:
  acme:
    image: neilpang/acme.sh
    container_name: acme
    restart: always
    command: daemon
    environment:
      CF_Token: ${CF_Token}
      CF_Account_ID: ${CF_Account_ID}
      CF_Zone_ID: ${CF_Zone_ID}
    volumes:
      - ${APP_DIR}/data:/root/.acme.sh
    network_mode: bridge
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}等待容器启动...${RESET}"
    sleep 3

    # =========================
    # ① 强制 Let’s Encrypt
    # =========================
    docker exec acme --set-default-ca --server letsencrypt >/dev/null 2>&1

    # =========================
    # ② 随机邮箱注册
    # =========================
    random_email() {
        echo "acme-$(date +%s%N | md5sum | head -c 8)@example.com"
    }

    email=$(random_email)

    echo -e "${GREEN}注册 ACME 账户: ${email}${RESET}"

    docker exec acme --register-account -m "$email" || {
        echo -e "${YELLOW}⚠️ 账户可能已存在或已注册，跳过注册${RESET}"
    }

    # =========================
    # ③ 更新 ACME
    # =========================
    docker exec acme --upgrade --auto-upgrade >/dev/null 2>&1 || true

    # =========================
    # ④ 定时任务
    # =========================
    (crontab -l 2>/dev/null; echo "10 0 * * * docker exec acme --cron > /dev/null") | crontab -

    echo
    echo -e "${GREEN}✅ ACME 初始化完成${RESET}"
    echo -e "${GREEN}✔ CA: Let's Encrypt${RESET}"
    echo -e "${GREEN}✔ Account: $email${RESET}"
    echo -e "${GREEN}✔ Storage: $APP_DIR/data${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {

    echo -e "${GREEN}开始更新 ACME 容器...${RESET}"

    # =========================
    # ① 拉取最新镜像
    # =========================
    docker pull neilpang/acme.sh

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 镜像拉取失败${RESET}"
        read -p "按回车返回..."
        return
    fi

    # =========================
    # ② 重新创建容器（无损更新）
    # =========================
    cd "$APP_DIR" || return

    docker compose up -d

    # =========================
    # ③ 更新 acme.sh 程序
    # =========================
    docker exec acme --upgrade --auto-upgrade || {
        echo -e "${YELLOW}⚠️ acme.sh 更新失败或已是最新${RESET}"
    }

    # =========================
    # ④ 确认状态
    # =========================
    sleep 2

    if docker ps | grep -q acme; then
        echo -e "${GREEN}✅ ACME 容器更新完成并运行中${RESET}"
    else
        echo -e "${RED}❌ 容器未正常运行，请检查日志${RESET}"
    fi

    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart acme
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f acme
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已卸载 ACME${RESET}"
    read -p "按回车返回菜单..."
}

issue_cert() {

    read -p "请输入主域名 (如 example.com): " domain

    echo -e "${GREEN}开始申请证书...${RESET}"

    docker exec acme --issue --dns dns_cf -d "$domain" -d "*.$domain" --ecc

    mkdir -p "$SSL_DIR/$domain"

    docker exec acme --install-cert -d "$domain" \
    --ecc \
    --key-file "$SSL_DIR/$domain/key.pem" \
    --fullchain-file "$SSL_DIR/$domain/fullchain.pem" \
    --reloadcmd "nginx -s reload"

    echo -e "${GREEN}✅ 证书申请完成${RESET}"
    read -p "按回车返回菜单..."
}

remove_cert() {

    mapfile -t domains < <(docker exec acme --list | awk 'NR>1 && NF{print $1}')

    if [ ${#domains[@]} -eq 0 ]; then
        echo -e "${YELLOW}暂无证书可删除${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    echo -e "${RED}选择要删除的证书:${RESET}"
    for i in "${!domains[@]}"; do
        echo -e "${GREEN}$((i+1))) ${domains[$i]}${RESET}"
    done

    read -p "请输入编号: " num

    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#domains[@]}" ]; then
        echo -e "${RED}无效选择${RESET}"
        read -p "按回车返回..."
        return
    fi

    domain="${domains[$((num-1))]}"

    echo -e "${YELLOW}正在删除: $domain${RESET}"

    docker exec acme --remove -d "$domain" --ecc || true
    rm -rf "$SSL_DIR/$domain"

    echo -e "${RED}✅ 删除完成: $domain${RESET}"
    read -p "按回车返回菜单..."
}

list_domains() {
    echo -e "${GREEN}正在获取证书列表...${RESET}"

    mapfile -t domains < <(docker exec acme --list | awk 'NR>1 && NF{print $1}')

    if [ ${#domains[@]} -eq 0 ]; then
        echo -e "${YELLOW}暂无证书${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    echo -e "${GREEN}已签发证书:${RESET}"
    for i in "${!domains[@]}"; do
        echo -e "${GREEN}$((i+1))) ${domains[$i]}${RESET}"
    done

    read -p "按回车返回菜单..."
}

cert_status() {

    mapfile -t domains < <(docker exec acme --list | awk 'NR>1 && NF{print $1}')

    if [ ${#domains[@]} -eq 0 ]; then
        echo -e "${YELLOW}暂无证书${RESET}"
        read -p "按回车返回..."
        return
    fi

    echo -e "${GREEN}选择查看证书状态:${RESET}"
    for i in "${!domains[@]}"; do
        echo -e "${GREEN}$((i+1))) ${domains[$i]}${RESET}"
    done

    read -p "请输入编号: " num

    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        return
    fi

    domain="${domains[$((num-1))]}"
    docker exec acme --info -d "$domain"

    read -p "按回车返回菜单..."
}

menu
