#!/bin/bash
# =================================================================
# Twilight 影音工具箱 Docker Compose 运维管理面板（修复版）
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/twilight"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if ! command -v git &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Git，请先安装 Git 依赖！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态
get_status_info() {
    if [ "$(docker ps -q -f name=twilight-webui)" ] || [ "$(docker ps -q -f name=twilight-backend)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=twilight-webui)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=twilight-webui)" ]; then
        if [ -f "$BASE_DIR/.env" ]; then
            webui_port=$(grep "^WEBUI_PORT=" "$BASE_DIR/.env" | cut -d'=' -f2)
        fi
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "twilight-webui" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3000"
    else
        webui_port="N/A"
    fi
}

# 获取公网 IP (兼容双栈环境)
get_public_ip() {
    local mode=${1:-"auto"}
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1" && return 0
}


# 部署 Twilight
install_utils() {
    check_dependencies
    
    # 1. 克隆或更新项目源码
    if [ -d "$BASE_DIR/.git" ]; then
        echo -e "${YELLOW}检测到项目目录已存在，正在同步最新源码...${RESET}"
        cd "$BASE_DIR" && git pull
    else
        echo -e "${YELLOW}正在克隆 Twilight 项目源码到 $BASE_DIR ...${RESET}"
        git clone https://github.com/Prejudice-Studio/Twilight.git "$BASE_DIR"
        cd "$BASE_DIR"
    fi

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入前端对外访问端口 [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"

    echo -ne "${YELLOW}请输入 Emby 服务器地址 (例如 http://192.168.1.100:8096): ${RESET}"
    read -r emby_url

    echo -ne "${YELLOW}请输入 Emby API Token: ${RESET}"
    read -r emby_token

    echo -ne "${YELLOW}请输入管理员用户名 [默认: admin]: ${RESET}"
    read -r admin_user
    [[ -z "$admin_user" ]] && admin_user="admin"

    echo -ne "${YELLOW}请输入 PostgreSQL 数据库密码 [默认: twilight_pwd]: ${RESET}"
    read -r db_pwd
    [[ -z "$db_pwd" ]] && db_pwd="twilight_pwd"

    # 自动生成强随机的安全密钥
    generated_secret=$(date +%s | sha256sum | base64 | head -c 32)

    # 2. 生成满足 Docker 覆盖要求的全局 .env 配置文件
    echo -e "${YELLOW}正在生成满足 Docker 覆盖要求的全局 .env 配置文件...${RESET}"
    cat <<EOF > .env
# Twilight 部署级核心环境变量
TWILIGHT_API_HOST=0.0.0.0
TWILIGHT_API_PORT=5000
SITE_NAME=Twilight

# 映射给 Compose 内置服务的核心密钥与端口
POSTGRES_PASSWORD=${db_pwd}
ADMIN_USERNAMES=${admin_user}
BOT_INTERNAL_SECRET=${generated_secret}
WEBUI_PORT=${custom_port}
EOF

    # 3. 释放基础主的 config.toml
    echo -e "${YELLOW}正在生成基础主配置源 config.toml...${RESET}"
    cat <<EOF > config.toml
[Global]
server_name = "Twilight"
server_icon = ""
log_level = "info"
runtime_log_limit = 5000
redis_url = "redis://redis:6379/0"
telegram_mode = true
force_bind_telegram = false
tmdb_api_key = ""
tmdb_api_url = "https://api.themoviedb.org/3"
tmdb_image_url = "https://image.tmdb.org/t/p"
bangumi_token = ""
bangumi_api_url = "https://api.bgm.tv/v0"
auth_background_url = ""

[Admin]
usernames = ["${admin_user}"]

[Database]
driver = "postgres"
postgres_host = "postgres"
postgres_port = 5432
postgres_user = "twilight"
postgres_password = "${db_pwd}"
postgres_database = "twilight"
postgres_sslmode = "disable"
postgres_max_open_conns = 16
postgres_max_idle_conns = 8
state_file = "db/twilight_go_state.json"
backup_dir = "db/backups"
migration_panel_enabled = false

[Emby]
emby_url = "${emby_url}"
emby_token = ""
emby_username = ""
emby_password = ""
emby_url_list = []
emby_url_list_for_whitelist = []

[Telegram]
bot_token = ""
admin_id = []
group_id = []
channel_id = []
force_bind_group = false
force_bind_channel = false
require_group_membership = false
ban_on_leave = false
auto_enable_rejoined = false
enable_tg_panel = true

[SAR]
register_mode = false
register_code_limit = false
allow_pending_register = false
emby_direct_register_enabled = false
emby_direct_register_days = 30
user_limit = -1
emby_user_limit = -1
regcode_format = "TW-{type}-{random}"
regcode_random_algorithm = "base32-20"
invite_code_format = "INV{random}"
invite_code_random_algorithm = "hex10"
regcode_decoy_action = "log_only"
media_request_enabled = true
max_concurrent_requests_per_user = 3
max_concurrent_requests_global = -1
invite_enabled = true
invite_limit = 10
invite_root_user_limit = -1
invite_max_depth = 3
invite_require_emby = false
invite_code_default_days = 30
permanent_invite_max_days = 365
auto_cleanup_no_emby = false
auto_cleanup_no_emby_days = 7
auto_cleanup_pending_emby = false
auto_cleanup_pending_emby_days = 7
signin_enabled = true
currency_name = "星币"
daily_min = 5
daily_max = 20
streak_bonus_enabled = true
streak_bonus_days = [3, 7, 14, 30]
streak_bonus_points = [10, 50, 100, 300]
reset_after_miss = true
signin_renewal_enabled = false
signin_renewal_cost = 100
signin_renewal_days = 30

[DeviceLimit]
device_limit_enabled = false
max_devices = 5
max_streams = 2

[API]
host = "0.0.0.0"
port = 5000
cors_origins = ["http://localhost:3000"]
upload_folder = "uploads"
max_upload_size = 5242880
session_cookie_name = "twilight_session"
session_cookie_secure = true
session_cookie_samesite = "lax"
session_cookie_domain = ""
trust_proxy_headers = false
trusted_proxy_cidrs = ["127.0.0.0/8", "::1/128"]

[Security]
forgot_password_enabled = true
forgot_password_emby_enabled = true
forgot_password_email_enabled = true
bot_internal_secret = ""

[RateLimit]
enabled = true
global_per_minute = 1200
login_per_minute = 60
login_user_per_5m = 10
register_per_10m = 30
forgot_password_ip_per_10m = 20
forgot_password_user_per_30m = 10
email_code_ip_per_10m = 20
email_code_addr_per_10m = 5
email_code_uid_per_10m = 10
upload_per_minute = 60
admin_icon_per_minute = 20
api_key_default_per_minute = 300

[Scheduler]
enabled = true
tick_interval_seconds = 30
expired_check_time = "03:00"
expiring_check_time = "09:00"
daily_stats_time = "00:05"
session_cleanup_interval = 6
cleanup_no_emby_time = "03:30"
cleanup_pending_emby_time = "03:45"
cleanup_unused_uploads_time = "02:20"
cleanup_audit_logs_time = "04:30"

[SystemUpdate]
auto_update_enabled = false
repo_url = "https://github.com/Prejudice-Studio/Twilight.git"
branch = "main"
restart_services = false

[Notification]
enabled = true
expiry_remind_days = 3

[BangumiSync]
enabled = false
webhook_secret = ""

[Ticket]
enabled = false
types = ["all"]

[AuditLog]
enabled = true
auto_cleanup_enabled = false
retention_days = 90
max_entries = 10000
preserve_admin = true
cleanup_check_time = "04:30"

[Email]
enabled = false
smtp_host = ""
smtp_port = 587
smtp_username = ""
smtp_password = ""
smtp_encryption = "starttls"
smtp_from_address = ""
smtp_from_name = ""
smtp_timeout_seconds = 10
force_bind = false
code_length = 6
code_type = "numeric"
code_ttl_minutes = 10
box_resend_cooldown_seconds = 60
max_attempts = 5
subject_template = "{site} 邮箱验证码"
body_template = """您正在 {site} 进行邮箱验证。\n\n验证码：{code}\n\n验证码 {ttl} 分钟内有效，请勿向任何人泄露。如非本人操作，请忽略本邮件。"""
EOF

    # 4. 生成私密覆盖配置 config.local.toml
    echo -e "${YELLOW}正在生成私密覆盖配置 config.local.toml...${RESET}"
    cat <<EOF > config.local.toml
# Twilight Local Private Configuration (Overrides config.toml)

[Database]
postgres_password = "${db_pwd}"

[Emby]
emby_token = "${emby_token}"

[Security]
bot_internal_secret = "${generated_secret}"
EOF

    # 5. 生成前端环境变量 webui/.env
    echo -e "${YELLOW}正在生成前端环境变量...${RESET}"
    if [ -f "webui/.env.example" ]; then
        cp webui/.env.example webui/.env
    else
        cat <<EOF > webui/.env
VITE_API_BASE_URL=/api/v1
NEXT_PUBLIC_SITE_NAME=Twilight
EOF
    fi

    # 📌 【核心修复代码】：通过 sed 移去 Dockerfile 中导致报错的 pnpm 严格锁定校验
    if [ -f "webui/Dockerfile" ]; then
        echo -e "${YELLOW}正在优化前端 Dockerfile 以规避 pnpm 锁文件冲突...${RESET}"
        sed -i 's/pnpm install --frozen-lockfile/pnpm install/g' webui/Dockerfile
    fi

    # 6. 构建并运行服务
    echo -e "${YELLOW}正在构建镜像并启动 Twilight 容器组 (首次编译较慢)...${RESET}"
    docker compose up -d --build

    echo -e "${YELLOW}等待服务健康检查完成...${RESET}"
    sleep 5

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN}          Twilight 影音工具箱部署成功！         ${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${YELLOW}前端访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}管理用户名     : ${admin_user}${RESET}"
    echo -e "${RED}⚠️  注意: 首次打开网页注册的第一个账号，名字必须叫: ${admin_user}${RESET}"
    echo -e "${GREEN}================================================${RESET}"
}

# 更新 Twilight
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到项目，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端同步最新源码并重新打包...${RESET}"
    cd "$BASE_DIR" && git pull
    # 更新源码后，同样需要做防冲突处理
    if [ -f "webui/Dockerfile" ]; then
        sed -i 's/pnpm install --frozen-lockfile/pnpm install/g' webui/Dockerfile
    fi
    docker compose up -d --build --remove-orphans
    echo -e "${GREEN}更新并构建完成！${RESET}"
}

# 卸载 Twilight
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 Twilight 容器组吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -d "$BASE_DIR" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器及卷已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地源码、数据库和所有配置文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}数据目录已彻底清理。${RESET}"
            fi
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }

# 细化日志查询选项
logs_utils() {
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}         查看运行日志           ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 查看 后端 Go API 日志${RESET}"
    echo -e "${GREEN}2. 查看 前端 WebUI 日志${RESET}"
    echo -e "${GREEN}3. 查看 数据库 Postgres 日志${RESET}"
    echo -e "${GREEN}4. 查看 缓存 Redis 日志${RESET}"
    echo -e "${GREEN}5. 查看 容器组全部混合日志${RESET}"
    echo -e "${GREEN}0. 返回主菜单${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请选择要查看的日志组件: ${RESET}"
    read -r log_choice
    cd "$BASE_DIR" || return
    case "$log_choice" in
        1) docker compose logs -f twilight ;;
        2) docker compose logs -f webui ;;
        3) docker compose logs -f postgres ;;
        4) docker compose logs -f redis ;;
        5) docker compose logs -f ;;
        0) return ;;
        *) echo -e "${RED}无效参数${RESET}" ;;
    esac
}

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}主配置文件路径 : $BASE_DIR/config.toml"
    echo -e "${YELLOW}秘密配置文件路径: $BASE_DIR/config.local.toml${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  Twilight 核心面板  ◈     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 源码部署与构建${RESET}"
    echo -e "${GREEN}2. 拉取源码并更新${RESET}"
    echo -e "${GREEN}3. 卸载清除服务${RESET}"
    echo -e "${GREEN}4. 启动所有容器${RESET}"
    echo -e "${GREEN}5. 停止所有容器${RESET}"
    echo -e "${GREEN}6. 重启所有容器${RESET}"
    echo -e "${GREEN}7. 查看运行日志${RESET}"
    echo -e "${GREEN}8. 查看基本信息${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
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
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
