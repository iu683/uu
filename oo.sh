#!/bin/bash
# ========================================
# Redis 容器管理面板 (Docker Compose) 
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
CYAN="\033[36m"
APP_NAME="redis"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"
BACKUP_DIR="$APP_DIR/backup"

# 自动适配 docker compose 语法
if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

# 随机密码生成函数
gen_pass() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP"
}

get_local_ip() {
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-127.0.0.1}"
}

pause() {
    read -p $'\e[32m按回车返回菜单...\e[0m'
}

# 获取容器动态状态及内存使用量
get_sys_status() {
    if [ ! -f "$CONFIG_FILE" ]; then
        status="${RED}未安装${RESET}"
        version="${RED}无${RESET}"
        port_show="${RED}无${RESET}"
        mem_show="${RED}0B${RESET}"
    else
        source "$CONFIG_FILE"
        version="7.2 (Alpine)"
        port_show="$PORT"
        
        if [ "$(docker ps -q -f name=^redis$)" ]; then
            status="${GREEN}运行中${RESET}"
            # 通过 redis-cli 实时获取已用内存
            local raw_mem=$(docker exec -i redis redis-cli -a "$REDIS_PASSWORD" info memory 2>/dev/null | grep "used_memory_human" | cut -d':' -f2)
            mem_show="${YELLOW}${raw_mem//[[:space:]]/}${RESET}"
        elif [ "$(docker ps -a -q -f name=^redis$)" ]; then
            status="${YELLOW}已停止${RESET}"
            mem_show="${YELLOW}未知 (请先启动容器)${RESET}"
        else
            status="${RED}未启动 (容器不存在)${RESET}"
            mem_show="${RED}0B${RESET}"
        fi
    fi
}

# ==================== 菜单 ====================
function menu() {
    clear
    get_sys_status
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈    Redis 管理面板    ◈     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态       :${RESET} $status"
    echo -e "${GREEN}版本       :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口       :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}内存占用   :${RESET} $mem_show"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 Redis${RESET}"
    echo -e "${GREEN} 2. 更新 Redis${RESET}"
    echo -e "${GREEN} 3. 卸载 Redis${RESET}"
    echo -e "${GREEN} 4. 启动 Redis${RESET}"
    echo -e "${GREEN} 5. 停止 Redis${RESET}"
    echo -e "${GREEN} 6. 重启 Redis${RESET}"
    echo -e "${GREEN} 7. 查看 日志${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "${GREEN} 8. 运行信息 (INFO)${RESET}"
    echo -e "${GREEN} 9. 连入命令行 (CLI)${RESET}"
    echo -e "${GREEN}10. 清空当前库 (FLUSHDB)${RESET}"
    echo -e "${GREEN}11. 清空所有库 (FLUSHALL)${RESET}"
    echo -e "${GREEN}12. 修改连接密码${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "${GREEN}13. 备份快照 (SAVE)${RESET}"
    echo -e "${GREEN}14. 恢复快照 (RESTORE)${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    
    read -p $'\e[32m请输入数字: \e[0m' num
    case "$num" in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) start_rd ;;
        5) stop_rd ;;
        6) restart_rd ;;
        7) view_logs ;;
        8) show_info ;;
        9) enter_cli ;;
        10) flush_db ;;
        11) flush_all ;;
        12) change_password ;;
        13) backup_db ;;
        14) restore_db ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

# ==================== 功能实现 ====================

function install_app() {
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${RED}检测到已经安装过 Redis。${RESET}"
        pause; menu
    fi
    
    read -p "请输入 Redis 端口 [默认 6379]: " input_port
    PORT=${input_port:-6379}
    
    echo -e "\n请选择网络绑定策略 (IP Binding):"
    echo -e "  [1] 允许公网/局域网访问 (绑定 0.0.0.0) [默认]"
    echo -e "  [2] 仅允许本地访问     (绑定 127.0.0.1)"
    read -p "请输入数字 [1-2, 2]: " bind_choice
    bind_choice=${bind_choice:-1}
    
    local compose_port_mapping
    local bind_status_text
    if [ "$bind_choice" = "2" ]; then
        compose_port_mapping="127.0.0.1:${PORT}:6379"
        bind_status_text="仅限本地 (127.0.0.1)"
    else
        compose_port_mapping="${PORT}:6379"
        bind_status_text="开放公网 (0.0.0.0)"
    fi

    read -p "请输入 Redis 连接密码 [留空自动生成]: " input_pass
    REDIS_PASSWORD=${input_pass:-$(gen_pass)}

    mkdir -p "$APP_DIR/data" "$BACKUP_DIR"
    
    cat > "$COMPOSE_FILE" <<EOF
services:
  redis-cache:
    container_name: redis
    image: redis:7.2-alpine
    restart: always
    ports:
      - "${compose_port_mapping}"
    command: redis-server --requirepass "${REDIS_PASSWORD}" --appendonly yes
    environment:
      TZ: Asia/Shanghai
    volumes:
      - ./data:/data
EOF

    cat > "$CONFIG_FILE" <<EOF
PORT=$PORT
REDIS_PASSWORD=$REDIS_PASSWORD
BIND_STRATEGY=$bind_choice
EOF

    cd "$APP_DIR" && $COMPOSE_CMD up -d
    
    local public_ip=$(get_public_ip)
    local local_ip=$(get_local_ip)
    
    echo -e "\n${GREEN}================================================${RESET}"
    echo -e "${GREEN}🎉 Redis 安全认证版安装启动成功！运行连接信息：${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN} 网络绑定策略 :${RESET} ${YELLOW}${bind_status_text}${RESET}"
    if [ "$bind_choice" = "2" ]; then
        echo -e "${GREEN} 唯一连接地址 :${RESET} 127.0.0.1:${PORT}"
    else
        echo -e "${GREEN} 公网连接地址 :${RESET} ${public_ip}:${PORT}"
        echo -e "${GREEN} 内网连接地址 :${RESET} 127.0.0.1:${PORT}"
    fi
    echo -e "${GREEN} 默认连接索引 :${RESET} db0 ~ db15 (共16个)"
    echo -e "${GREEN} 认证连接密码 :${RESET} ${YELLOW}${REDIS_PASSWORD}${RESET}"
    echo -e "${GREEN} 标准连接串   :${RESET} ${CYAN}redis://:${REDIS_PASSWORD}@${public_ip}:${PORT}/0${RESET}"
    echo -e "${GREEN} 配置文件路径 :${RESET} ${CONFIG_FILE}"
    echo -e "${GREEN}================================================${RESET}"
    
    pause; menu
}

function update_app() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}未检测到安装目录，请先安装${RESET}"; sleep 1; menu; fi
    cd "$APP_DIR" && $COMPOSE_CMD pull && $COMPOSE_CMD up -d
    echo -e "${GREEN}✅ Redis 镜像已更新并重启容器${RESET}"
    pause; menu
}

function uninstall_app() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}未检测到安装目录${RESET}"; sleep 1; menu; fi
    read -p "确定要彻底卸载吗？内存持久化数据(RDB/AOF)将清空！(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" || "$confirm" == "yes" ]]; then
        cd "$APP_DIR" && $COMPOSE_CMD down -v
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ Redis 已从本系统彻底卸载${RESET}"
    else
        echo -e "${YELLOW}已取消卸载${RESET}"
    fi
    pause; menu
}

function start_rd() {
    docker start redis &>/dev/null
    echo -e "${GREEN}✅ Redis 容器已启动${RESET}"
    pause; menu
}

function stop_rd() {
    docker stop redis &>/dev/null
    echo -e "${GREEN}✅ Redis 容器已停止${RESET}"
    pause; menu
}

function restart_rd() {
    docker restart redis &>/dev/null
    echo -e "${GREEN}✅ Redis 容器已重启${RESET}"
    pause; menu
}

function view_logs() {
    echo -e "${YELLOW}提示: 朝下滚动，按下 Ctrl + C 即可退出日志回到主菜单。${RESET}"
    sleep 1
    docker logs --tail 100 -f redis
    menu
}

function show_info() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 Redis${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    SERVER_IP=$(get_public_ip)
    local local_ip=$(get_local_ip)
    BIND_STRATEGY=${BIND_STRATEGY:-1}
    
    echo -e "\n${GREEN}====== Redis 运行状态信息 ======${RESET}"
    if [ "$BIND_STRATEGY" = "2" ]; then
        echo -e "${GREEN}绑定状态 :${RESET} ${YELLOW}仅限本地监听 (127.0.0.1)${RESET}"
        echo -e "${GREEN}连接地址 :${RESET} 127.0.0.1:${PORT}"
    else
        echo -e "${GREEN}绑定状态 :${RESET} ${GREEN}开放公网/局域网 (0.0.0.0)${RESET}"
        echo -e "${GREEN}公网地址 :${RESET} ${SERVER_IP}:${PORT}"
        echo -e "${GREEN}内网地址 :${RESET} 127.0.0.1:${PORT}"
    fi
    echo -e "${GREEN}连接密码 :${RESET} ${YELLOW}${REDIS_PASSWORD}${RESET}"
    echo -e "${GREEN}安装路径 :${RESET} $APP_DIR"
    echo -e "${GREEN}================================${RESET}"
    
    echo -e "${GREEN}核心性能指标摘要 (Engine INFO):${RESET}"
    docker exec -i redis redis-cli -a "$REDIS_PASSWORD" info stats 2>/dev/null | grep -E "(total_connections_received|total_commands_processed|instantaneous_ops_per_sec)"
    docker exec -i redis redis-cli -a "$REDIS_PASSWORD" info keyspace 2>/dev/null
    echo -e "${GREEN}================================${RESET}"
    pause; menu
}

function enter_cli() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 Redis${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    echo -e "${YELLOW}提示：已成功为你带密码切入交互命令行。输入 'exit' 退出交互回到面板。${RESET}"
    sleep 1
    docker exec -it redis redis-cli -a "$REDIS_PASSWORD"
    menu
}

function flush_db() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 Redis${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    read -p "确定要清空当前选中数据库索引里的所有 Key 吗？(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        docker exec -i redis redis-cli -a "$REDIS_PASSWORD" FLUSHDB &>/dev/null
        echo -e "${GREEN}✅ 当前单库数据清除成功。${RESET}"
    fi
    pause; menu
}

function flush_all() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 Redis${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    read -p "🚨 极度危险：确定要格式化整个 Redis、摧毁全部 16 个库里的所有 Key 吗？(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        docker exec -i redis redis-cli -a "$REDIS_PASSWORD" FLUSHALL &>/dev/null
        echo -e "${GREEN}✅ 整个 Redis 内存空间已被彻底抹净。${RESET}"
    fi
    pause; menu
}

function change_password() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 Redis${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    read -p "请输入新 Redis 连接密码 [留空随机生成]: " new_pass
    new_pass=${new_pass:-$(gen_pass)}

    # 在不重启容器的情况下，利用 CONFIG SET 动态热生效密码
    docker exec -i redis redis-cli -a "$REDIS_PASSWORD" CONFIG SET requirepass "$new_pass" &>/dev/null

    if [ $? -eq 0 ]; then
        sed -i "s/^REDIS_PASSWORD=.*/REDIS_PASSWORD=$new_pass/g" "$CONFIG_FILE"
        sed -i 's|--requirepass "[^"]*"|--requirepass "'"${new_pass}"'"|g' "$COMPOSE_FILE"
        echo -e "${GREEN}✅ Redis 密码修改并动态热生效成功！${RESET}"
        echo -e "${GREEN}新密码: ${YELLOW}$new_pass${RESET}（配置文件及持久化配置已同步）"
    else
        echo -e "${RED}❌ 密码修改失败，请确保容器正常运行。${RESET}"
    fi
    pause; menu
}

function backup_db() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 Redis${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    echo -e "${YELLOW}正在通知 Redis 引擎对内存进行内存全量物理盘落快照 (BGSAVE)...${RESET}"
    docker exec -i redis redis-cli -a "$REDIS_PASSWORD" BGSAVE &>/dev/null
    sleep 2 # 给予引擎磁盘落盘缓冲时间
    
    local stamp=$(date +%Y%m%d_%H%M%S)
    local target_file="$BACKUP_DIR/redis_dump_${stamp}.rdb"
    
    # 将挂载目录下的物理 dump.rdb 复制作为安全存档
    if [ -f "$APP_DIR/data/dump.rdb" ]; then
        cp "$APP_DIR/data/dump.rdb" "$target_file"
        echo -e "${GREEN}✅ Redis 物理级原子快照备份成功！${RESET}"
        echo -e "${GREEN}存档路径 :${RESET} $target_file"
    else
        echo -e "${RED}❌ 错误：未在数据目录下检测到持久化物理快照文件。${RESET}"
    fi
    pause; menu
}

function restore_db() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 Redis${RESET}"; sleep 1; menu; fi
    
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR")" ]; then
        echo -e "${RED}❌ 默认备份目录下没有找到任何 .rdb 快照存档${RESET}"; pause; menu
    fi
    
    echo -e "${GREEN}可用历史快照备份列表:${RESET}"
    ls -1 "$BACKUP_DIR"
    read -p "请输入你想恢复的完整快照文件名: " file
    local src_file="$BACKUP_DIR/$file"
    
    if [ ! -f "$src_file" ]; then
        echo -e "${RED}❌ 错误：未找到指定的备份快照文件！${RESET}"; pause; menu
    fi

    read -p "恢复快照需要临时关停并覆盖当前 Redis 内存，确定继续吗？(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo -e "${YELLOW}1. 正在停止当前 Redis 引擎...${RESET}"
        docker stop redis &>/dev/null
        
        echo -e "${YELLOW}2. 正在进行底层物理 RDB 数据替换归位...${RESET}"
        # 清除现有 aof 增量日志，防止恢复后被 aof 污染重写
        rm -f "$APP_DIR/data/appendonly.aof" "$APP_DIR/data/appendonlydir/"* 2>/dev/null
        cp "$src_file" "$APP_DIR/data/dump.rdb"
        
        echo -e "${YELLOW}3. 重新唤醒并拉起 Redis 服务...${RESET}"
        docker start redis &>/dev/null
        echo -e "${GREEN}✅ Redis 物理内存快照已成功全量复原入内存！${RESET}"
    else
        echo -e "${YELLOW}操作已取消。${RESET}"
    fi
    pause; menu
}

# ==================== 启动 ====================
menu
