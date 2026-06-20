#!/bin/bash
# =================================================================
# Danmu-API 弹幕聚合服务 自动化集成与热更新无缝管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="danmu-api"
BASE_DIR="/opt/danmu-api"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/config/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 获取容器运行状态及端口、本地目录挂载信息
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="latest"

        # 提取宿主机映射出来的 API 监听端口 (内部默认 9321)
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "9321/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="9321"

        # 提取本地 Config / Cache 真实路径
        path_config_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/config"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_cache_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/.cache"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$path_config_show" ]] && path_config_show="$BASE_DIR/config"
        [[ -z "$path_cache_show" ]] && path_cache_show="$BASE_DIR/.cache"
    else
        img_version="N/A"
        webui_port="N/A"
        path_config_show="N/A"
        path_cache_show="N/A"
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

# 部署核心逻辑
install_translate() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. API 基础服务网络端口 ======${RESET}"
    echo -ne "${YELLOW}请输入弹幕 API 访问映射端口 (宿主机) [默认: 9321]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="9321"

    echo -e "\n${CYAN}====== 2. 本地数据与热更新卷自定义 ======${RESET}"
    echo -ne "${YELLOW}1. 请输入【本地配置文件路径 ./config】保存位置 [默认: $BASE_DIR/config]: ${RESET}"
    read -r path_config
    [[ -z "$path_config" ]] && path_config="$BASE_DIR/config"

    echo -ne "${YELLOW}2. 请输入【本地实时缓存路径 ./.cache】保存位置 [默认: $BASE_DIR/.cache]: ${RESET}"
    read -r path_cache
    [[ -z "$path_cache" ]] && path_cache="$BASE_DIR/.cache"

    # 初始化本地目录，赋予 777 权限
    echo -e "\n${YELLOW}正在初始化本地高性能缓存卷与权限结构...${RESET}"
    mkdir -p "$path_config" "$path_cache"
    chmod -R 777 "$path_config" "$path_cache"

    # 生成安全的规范化 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在构建弹幕服务网络 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  danmu-api:
    image: logvar/danmu-api:latest
    container_name: ${CONTAINER_NAME}
    ports:
      - "${custom_port}:9321"
    volumes:
      - "${path_config}:/app/config"
      - "${path_cache}:/app/.cache"
    restart: unless-stopped
EOF

    # 核心：自动判定并释放原始的 .env 模板
    local local_env_file="${path_config}/.env"
    if [[ ! -f "$local_env_file" ]]; then
        echo -e "${GREEN}检测到本地无环境配置文件，正在自动初始化释放完整的弹幕环境变量规则表...${RESET}"
        cat <<'EOF' > "$local_env_file"
# ==================== 基础配置 ====================
TOKEN=87654321
OTHER_SERVER=https://api.danmu.icu

# ==================== VOD 配置 ====================
VOD_SERVERS=金蝉@https://zy.jinchancaiji.com,789@https://www.caiji.cyou,听风@https://gctf.tfdh.top
VOD_RETURN_MODE=fastest
VOD_REQUEST_TIMEOUT=10000

# ==================== 优酷配置 ====================
YOUKU_CONCURRENCY=8

# ==================== 源排序配置 ====================
SOURCE_ORDER=douban,360,renren,hanjutv

# ==================== 剧集标题过滤 ====================
EPISODE_TITLE_FILTER=(特别|惊喜|纳凉)?企划(?!(书|案|部))|合伙人手记|超前(营业|vlog)?|速览|vlog|(?<!(Chain|Chemical|Nuclear|连锁|化学|核|生化|生理|应激))reaction|(?<!(单))纯享|加更(版|篇)?|抢先(看|版|集|篇)?|(?<!(被|争|谁))抢[先鲜](?!(一步|手|攻|了|告|言|机|话))|抢鲜|预告(?!(函|信|书|犯))|(?<!(死亡|恐怖|灵异|怪谈))花絮(独家)?|(?<!(一|直))直拍|(制作|拍摄|幕后|花絮|未播|独家|演员|导演|主创|杀青|探班|收官|开播|先导|彩蛋|NG|回顾|高光|个人|主创)特辑|(?<!(行动|计划|游戏|任务|危机|神秘|黄金))彩蛋|(?<!(嫌疑人|证人|家属|律师|警方|凶手|死者))专访|(?<!(证人))采访(?!(吸血鬼|鬼))|(正式|角色|先导|概念|首曝|定档|剧情|动画|宣传|主题曲|印象)[\s\.]*[PpＰｐ][VvＶｖ]|(?<!(退居|回归|走向|转战|隐身|藏身|的))幕后(?!(主谋|主使|黑手|真凶|玩家|老板|金主|英雄|功臣|推手|大佬|操纵|交易|策划|博弈|BOSS|真相))(故事|花絮|独家)?|直播(陪看|回顾)?|直播(?!(.*(事件|杀人|自杀|谋杀|犯罪|现场|游戏|挑战)))|未播(片段)?|衍生(?!(品|物|兽))|番外(?!(地|人))|会员(专享|加长|尊享|专属|版)?|(?<!(鸦|雪|纸|相|照|图|名|大))片花|(?<!(提取|吸收|生命|魔法|修护|美白))精华|看点|速看|解读(?!.*(密文|密码|密电|电报|档案|书信|遗书|碑文|代码|信号|暗号|讯息|谜题|人心|唇语|真相|谜团|梦境))|(?<!(案情|人生|死前|历史|世纪))回顾|影评|解说|吐槽|(?<!(年终|季度|库存|资产|物资|财务|收获|战利))盘点|拍摄花絮|制作花絮|幕后花絮|未播花絮|独家花絮|花絮特辑|先导预告|终极预告|正式预告|官方预告|彩蛋片段|删减片段|未播片段|番外彩蛋|精彩片段|精彩看点|精彩集锦|看点解析|看点预告|NG镜头|NG花絮|番外篇|番外特辑|制作特辑|拍摄特辑|幕后特辑|导演特辑|演员特辑|片尾曲|(?<!(生命|生活|情感|爱情|一段|小|意外))插曲|高光回顾|背景音乐|OST|音乐MV|歌曲MV|前季回顾|剧情回顾|往期回顾|内容总结|剧情盘点|精选合集|剪辑合集|混剪视频|独家专访|演员访谈|导演访谈|主创访谈|媒体采访|发布会采访|陪看(记)?|试看版|短剧|精编|(?<!(Love|Disney|One|C|Note|S\d+|\+|&|\s))Plus|独家版|(?<!(导演|加长|周年))特别版(?!(图|画))|短片|(?<!(新闻|紧急|临时|召开|破坏|大闹|澄清|道歉|新品|产品|事故))发布会|解忧局|走心局|火锅局|巅峰时刻|坞里都知道|福持目标坞民|福利(?!(院|会|主义|课))篇|(福利|加更|番外|彩蛋|衍生|特别|收官|游戏|整蛊|日常)篇|独家(?!(记忆|试爱|报道|秘方|占有|宠爱|恩宠))|.{2,}(?<!(市|分|警|总|省|卫|药|政|监|结|大|开|破|布|僵|困|骗|赌|胜|败|定|乱|危|迷|谜|入|搅|设|中|残|平|和|终|变|对|安|做|书|画|察|务|案|通|信|育|商|象|源|业|冰))局(?!(长|座|势|面|部|内|外|中|限|促|气))|(?<!(重症|隔离|实验|心理|审讯|单向|术后))观察室|上班那点事儿|周top|赛段|VLOG|(?<!(大案|要案|刑侦|侦查|破案|档案|风云|历史|战争|探案|自然|人文|科学|医学|地理|宇宙|赛事|世界杯|奥运))全纪录|开播|先导|总宣|展演|集锦|旅行日记|精彩分享|剧情揭秘(?!(者|人))|(?:^|】\s*|\]\s*)(?:[SC]|SP|OP|ED|PV)\d+(?:[\s:：\.\-]|$)

# ==================== 性能与转换 ====================
GROUP_MINUTE=1
DANMU_LIMIT=0
CONVERT_TOP_BOTTOM_TO_SCROLL=false
CONVERT_COLOR=default
DANMU_SIMPLIFIED_TRADITIONAL=default
LIKE_SWITCH=true
DANMU_PUSH_URL=http://127.0.0.1:9978/action?do=refresh&type=danmaku&path=
DANMU_OUTPUT_FORMAT=json
RATE_LIMIT_MAX_REQUESTS=3
ENABLE_ANIME_EPISODE_FILTER=false
STRICT_TITLE_MATCH=false
USE_BANGUMI_DATA=false
LOG_LEVEL=info
SEARCH_CACHE_MINUTES=3
COMMENT_CACHE_MINUTES=3
REMEMBER_LAST_SELECT=true
MAX_LAST_SELECT_MAP=100
MAX_ANIMES=100
BANGUMI_DATA_CACHE_DAYS=7
ANIME_TITLE_SIMPLIFIED=false
EOF
        echo -e "${GREEN}模板释放成功！路径为: ${local_env_file}${RESET}"
    else
        echo -e "${YELLOW}检测到本地已有 .env 配置文件，将直接复用，保障数据安全。${RESET}"
    fi

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 部署并拉取弹幕多源集群...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务构建并扫描环境 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}            Danmu-API 部署成功！                ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}API 基础网关地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}默认连接鉴权口令 : 87654321${RESET}"
    echo -e "${YELLOW}本地配置与 .env  : ${path_config}${RESET}"
    echo -e "${YELLOW}本地高性能缓存   : ${path_cache}${RESET}"
    echo -e "${CYAN}💡 核心特长：修改 ${path_config}/.env 规则后，容器秒级自动加载${RESET}"
    echo -e "${CYAN}   无需执行重启命令，真正的零影响热更新观影！${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 快捷交互：编辑/修改环境变量
edit_env_config() {
    get_status_info
    local current_env="${path_config_show}/.env"
    if [[ ! -f "$current_env" ]]; then
        echo -e "${RED}错误: 未检测到本地配置文件，请先执行选项 1 部署服务！${RESET}"
        return
    fi
    
    if command -v nano &> /dev/null; then
        nano "$current_env"
    elif command -v vi &> /dev/null; then
        vi "$current_env"
    else
        echo -e "${RED}错误: 系统未检测到 nano 或 vi 编辑器，请手动修改路径下的 .env 文件。${RESET}"
        return
    fi
    echo -e "${GREEN}配置已成功保存！由于热更新支持，Danmu-API 容器已在后台实时重新加载新规则。${RESET}"
}

# 更新服务
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 Danmu-API 聚合镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！服务已平滑重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 Danmu-API 弹幕容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地保存的弹幕过滤规则和本地磁盘搜索缓存？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$path_config_show" != "$BASE_DIR"* && -d "$path_config_show" ]] && rm -rf "$path_config_show"
                [[ "$path_cache_show" != "$BASE_DIR"* && -d "$path_cache_show" ]] && rm -rf "$path_cache_show"
                echo -e "${GREEN}所有相关的本地环境参数与缓存文件已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_translate() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_translate() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_translate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_translate() { docker logs -f --tail=100 "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态     : $status"
    echo -e "${YELLOW}核心镜像版本     : ${img_version}${RESET}"
    echo -e "${YELLOW}网关访问地址     : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}本地配置存储路径 : ${path_config_show}${RESET}"
    echo -e "${YELLOW}本地缓存物理路径 : ${path_cache_show}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}  ◈  Danmu-API 弹幕聚合管理面板  ◈ ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}状态    :${RESET} $status"
    echo -e "${GREEN}端口    :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 交互修改${RESET}"
    echo -e "${GREEN}9. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_translate ;;
        2) update_translate ;;
        3) uninstall_translate ;;
        4) start_translate ;;
        5) stop_translate ;;
        6) restart_translate ;;
        7) logs_translate ;;
        8) edit_env_config ;;
        9) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
