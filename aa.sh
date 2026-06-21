#!/bin/bash
# =================================================================
# Rhex 论坛系统 Docker Compose 独立管理面板 (生产级备份与升级增强版)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_WEB="rhex-web"
BASE_DIR="/opt/rhex"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取核心容器状态与映射端口
get_status_info() {
    if [ "$(docker ps -q -f name=^/web$)" ] || [ "$(docker ps -q -f name=^/rhex-web$)" ]; then
        status="${GREEN}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/web$)" ] || [ "$(docker ps -aq -f name=^/rhex-web$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    local active_id=$(docker ps -aq -f name=^/web$ || docker ps -aq -f name=^/rhex-web$)
    if [ -n "$active_id" ]; then
        webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{(index $conf 0).HostPort}}{{end}}' "$active_id" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3000"
        port_display="${webui_port}"
    else
        port_display="N/A"
    fi
}

# 获取公网 IP
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://4.ip.sb"; do
        ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
    done
    echo "127.0.0.1" && return 0
}

# 部署 Rhex
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 持久化数据与附件目录初始化 ======${RESET}"
    echo -e "${YELLOW}正在自动创建官方标准挂载目录 (uploads / addons / backups)...${RESET}"
    mkdir -p "$BASE_DIR/uploads" "$BASE_DIR/addons" "$BASE_DIR/backups"
    chmod -R 777 "$BASE_DIR/uploads" "$BASE_DIR/addons" "$BASE_DIR/backups"
    echo -e "${GREEN}宿主机各数据目录初始化完成。${RESET}"

    echo -e "\n${CYAN}====== 2. 网络端口与站点配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Rhex 论坛前端宿主机访问端口 [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"

    echo -ne "${YELLOW}请输入您的站点公网 URL (例如 https://bbs.rhex.im，可选，没有直接回车): ${RESET}"
    read -r site_url

    echo -e "\n${CYAN}====== 3. 管理员初始化配置 (仅首次生效) ======${RESET}"
    echo -ne "${YELLOW}请输入管理员用户名 [默认: admin]: ${RESET}"
    read -r admin_user
    [[ -z "$admin_user" ]] && admin_user="admin"

    echo -ne "${YELLOW}请输入管理员密码 [默认: ChangeMe_123456]: ${RESET}"
    read -r admin_pass
    [[ -z "$admin_pass" ]] && admin_pass="ChangeMe_123456"

    echo -ne "${YELLOW}请输入管理员邮箱 [默认: admin@rhex.im]: ${RESET}"
    read -r admin_email
    [[ -z "$admin_email" ]] && admin_email="admin@rhex.im"

    echo -ne "${YELLOW}请输入管理员昵称 [默认: 秦始皇]: ${RESET}"
    read -r admin_nick
    [[ -z "$admin_nick" ]] && admin_nick="秦始皇"

    local rand_session=$(date +%s | sha256sum | base64 | head -c 32)
    local rand_captcha=$(date +%s%N | sha256sum | base64 | head -c 32)
    local rand_redis_pass=$(date +%s%N | sha256sum | head -c 16)

    echo -e "${YELLOW}正在生成核心安全环境配置文件 .env...${RESET}"
    cat <<EOF > "$ENV_FILE"
PORT=${custom_port}
TZ=Asia/Shanghai
SESSION_SECRET="${rand_session}"
CAPTCHA_SECRET_KEY="${rand_captcha}"
POSTGRES_DB=bbs
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_PORT=5432
REDIS_PORT=6379
REDIS_PASSWORD="${rand_redis_pass}"
REDIS_DB=0
REDIS_KEY_PREFIX=rhex
SEED_ADMIN_USERNAME="${admin_user}"
SEED_ADMIN_PASSWORD="${admin_pass}"
SEED_ADMIN_EMAIL="${admin_email}"
SEED_ADMIN_NICKNAME="${admin_nick}"
BACKGROUND_JOB_WEB_RUNTIME=worker-only
BACKGROUND_JOB_CONCURRENCY=10
BACKGROUND_JOB_MAX_ATTEMPTS=3
BACKGROUND_JOB_RETRY_BASE_MS=5000
BACKGROUND_JOB_RETRY_MAX_MS=300000
EOF

    if [[ -n "$site_url" ]]; then
        cat <<EOF >> "$ENV_FILE"
SITE_URL="${site_url}"
APP_URL="${site_url}"
EOF
    fi

    echo -e "${YELLOW}正在生成官方标准带锚点版 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
x-app-environment: &app-environment
  DATABASE_URL: postgresql://\${POSTGRES_USER:-postgres}:\${POSTGRES_PASSWORD:-postgres}@postgres:5432/\${POSTGRES_DB:-bbs}?schema=public
  REDIS_URL: redis://redis:6379
  REDIS_PASSWORD: \${REDIS_PASSWORD:-}
  REDIS_DB: \${REDIS_DB:-}

x-app-service: &app-service
  image: ghcr.io/lovedevpanda/rhex:latest
  pull_policy: always
  init: true
  env_file:
    - .env
  volumes:
    - ./uploads:/app/uploads
    - ./addons:/app/addons

services:
  postgres:
    image: postgres:18
    container_name: rhex-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: \${POSTGRES_DB:-bbs}
      POSTGRES_USER: \${POSTGRES_USER:-postgres}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:-postgres}
      TZ: \${TZ:-Asia/Shanghai}
    ports:
      - "127.0.0.1:\${POSTGRES_PORT:-5432}:5432"
    volumes:
      - postgres_data:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -U \${POSTGRES_USER:-postgres} -d \${POSTGRES_DB:-bbs}"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 10s

  redis:
    image: redis:latest
    container_name: rhex-redis
    restart: unless-stopped
    command:
      - sh
      - -c
      - |
        set -eu
        if [ -n "\$\${REDIS_PASSWORD:-}" ]; then
          exec redis-server --appendonly yes --requirepass "\$\${REDIS_PASSWORD}"
        fi
        exec redis-server --appendonly yes
    environment:
      REDIS_PASSWORD: \${REDIS_PASSWORD:-}
    ports:
      - "127.0.0.1:\${REDIS_PORT:-6379}:6379"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD-SHELL", "if [ -n \"\$\${REDIS_PASSWORD:-}\" ]; then redis-cli -a \"\$\${REDIS_PASSWORD}\" --no-auth-warning ping; else redis-cli ping; fi"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 5s

  setup:
    <<: *app-service
    container_name: rhex-setup
    restart: on-failure
    environment: *app-environment
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    command: ["pnpm", "run", "setup:prod"]

  postgres-backup:
    image: postgres:18
    container_name: rhex-backup
    profiles:
      - backup
    restart: "no"
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      POSTGRES_DB: \${POSTGRES_DB:-bbs}
      POSTGRES_USER: \${POSTGRES_USER:-postgres}
      PGPASSWORD: \${POSTGRES_PASSWORD:-postgres}
      TZ: \${TZ:-Asia/Shanghai}
    volumes:
      - ./backups:/backups
    command:
      - sh
      - -c
      - |
        set -eu
        mkdir -p /backups
        pg_dump -h postgres -U "\$\${POSTGRES_USER:-postgres}" -d "\$\${POSTGRES_DB:-bbs}" -Fc -f "/backups/rhex-\$\$(date +%Y%m%d-%H%M%S).dump"

  web:
    <<: *app-service
    container_name: rhex-web
    restart: unless-stopped
    stop_grace_period: 30s
    environment:
      <<: *app-environment
      HOSTNAME: \${HOSTNAME:-0.0.0.0}
      PORT: \${PORT:-3000}
    depends_on:
      postgres:
        condition: service_healthy
        restart: true
      redis:
        condition: service_healthy
        restart: true
      setup:
        condition: service_completed_successfully
    ports:
      - "\${PORT:-3000}:\${PORT:-3000}"
    command: ["pnpm", "run", "start"]

  worker:
    <<: *app-service
    container_name: rhex-worker
    restart: unless-stopped
    stop_grace_period: 30s
    environment:
      <<: *app-environment
      INTERNAL_REVALIDATION_ORIGIN: \${INTERNAL_REVALIDATION_ORIGIN:-http://web:\${PORT:-3000}}
    depends_on:
      postgres:
        condition: service_healthy
        restart: true
      redis:
        condition: service_healthy
        restart: true
      setup:
        condition: service_completed_successfully
    command: ["pnpm", "run", "worker"]

volumes:
  postgres_data:
  redis_data:
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动官方全集成拓扑结构...${RESET}"
    cd "$BASE_DIR" && docker compose up -d

    echo -e "${YELLOW}同步等待健康检查握手与初始化迁移 (约 10 秒)...${RESET}"
    sleep 10

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}         Rhex 官方全集成架构 部署成功！              ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}论坛访问地址     : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}初始管理员账号   : ${admin_user}${RESET}"
    echo -e "${YELLOW}初始管理员密码   : ${admin_pass}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 升级镜像与清理孤儿容器
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在执行生产级升级序列...${RESET}"
    cd "$BASE_DIR"
    
    echo -e "${CYAN}1. 正在拉取远端最新镜像库 (docker compose pull)...${RESET}"
    docker compose pull
    
    echo -e "${CYAN}2. 正在平滑应用新镜像并裁撤孤儿容器 (up -d --remove-orphans)...${RESET}"
    docker compose up -d --remove-orphans
    
    echo -e "${GREEN}升级完成！集群各模块已处于最新状态。${RESET}"
}

# 复合全量数据备份
trigger_backup() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在启动生产级全链路备份双熔断机制...${RESET}"
    cd "$BASE_DIR"

    # 1. 触发数据库 profile 备份
    echo -e "${CYAN}[步骤 1/2] 调起 profile 备份容器导出数据库 .dump 文件...${RESET}"
    docker compose --profile backup run --rm postgres-backup

    # 2. 触发核心物理结构打包压缩
    echo -e "${CYAN}[步骤 2/2] 打包物理文件归档 (uploads/addons/.env/compose)...${RESET}"
    local file_name="backups/rhex-files-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$file_name" uploads addons .env docker-compose.yml

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}               核心资产打包快照成功！                ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}打包归档位置 : $BASE_DIR/$file_name${RESET}"
    echo -e "${YELLOW}全量备份目录 : $BASE_DIR/backups/${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

uninstall_utils() {
    echo -e "${RED}警告: 卸载如果清理数据，将永久粉碎论坛所有的持久化物理券和用户附件！${RESET}"
    echo -ne "${YELLOW}确定要卸载并删除所有容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            echo -e "${GREEN}所有运行容器及 Docker 内置卷已彻底移除。${RESET}"
            echo -ne "${RED}【超高风险】是否连同宿主机上的附件(uploads)与备份(backups)一并碎裂删除？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}宿主机本地 Rhex 核心资产已全部销毁。${RESET}"
            fi
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}所有服务已激活${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}所有服务已挂起${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}所有服务已重启${RESET}"; }
logs_utils() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}Web端运行状态  : $status"
    echo -e "${YELLOW}当前前端活动端口 : ${port_display}${RESET}"
    echo -e "--------------------------------"
    echo -e "${CYAN}当前拓扑及健康检查报告:${RESET}"
    docker ps --format "table {{.Names}}\t{{.Status}}" | grep "rhex"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}   ◈  Rhex 官方生产级集群管理面板 ◈   ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}前端状态 :${RESET} $status"
    echo -e "${GREEN}活动端口 :${RESET} ${YELLOW}${port_display}${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}1. 部署启动 (全新导入)${RESET}"
    echo -e "${GREEN}2. 更新镜像 (拉取并剔除孤儿容器)${RESET}"
    echo -e "${GREEN}3. 卸载面板 (清理资产)${RESET}"
    echo -e "${GREEN}4. 激活集群服务${RESET}"
    echo -e "${GREEN}5. 挂起集群服务${RESET}"
    echo -e "${GREEN}6. 重启集群服务${RESET}"
    echo -e "${GREEN}7. 查看拓扑联动日志${RESET}"
    echo -e "${GREEN}8. 查看健康状态报告${RESET}"
    echo -e "${GREEN}9. 触发复合全量备份 (Dump + 物理Tar打包)${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_utils ;;
        2) update_utils ;;
        3) uninstall_utils ;;
        4) start_utils ;;
        5) stop_utils ;;
        6) restart_utils ;;
        7) logs_utils ;;
        8) show_info ;;
        9) trigger_backup ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
