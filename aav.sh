#!/bin/bash
# ================== 配色 ==================
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

pause() {
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read
}

# ================== 获取自定义网络 ==================
get_custom_networks() {
    NETWORKS=($(docker network ls --filter "driver=bridge" --format '{{.Name}}'))
    NETWORKS=($(for n in "${NETWORKS[@]}"; do [[ $n != "bridge" && $n != "host" && $n != "none" ]] && echo $n; done))
}

# ================== 本地备份 ==================
backup() {
    read -rp "请输入要备份的 Docker Compose 项目目录（可多选，用空格分隔）: " -a PROJECT_DIRS
    [[ ${#PROJECT_DIRS[@]} -eq 0 ]] && { echo -e "${RED}❌ 没有输入项目目录${RESET}"; return; }

    read -rp "请输入本地备份存放目录（默认 /opt/docker_backups）: " BACKUP_DIR
    BACKUP_DIR=${BACKUP_DIR:-/opt/docker_backups}
    mkdir -p "$BACKUP_DIR"

    for PROJECT_DIR in "${PROJECT_DIRS[@]}"; do
        [[ ! -d "$PROJECT_DIR" ]] && { echo -e "${RED}❌ 目录不存在: $PROJECT_DIR${RESET}"; continue; }

        TIMESTAMP=$(date +%F_%H-%M-%S)
        BACKUP_FILE="$BACKUP_DIR/$(basename "$PROJECT_DIR")_backup_$TIMESTAMP.tar.gz"
        echo -e "${CYAN}📦 开始备份项目目录及卷数据: $PROJECT_DIR → $BACKUP_FILE${RESET}"

        TEMP_DIR=$(mktemp -d)
        cp -r "$PROJECT_DIR"/* "$TEMP_DIR/"

        cd "$PROJECT_DIR" || continue

        # 备份卷
        VOLUMES=($(docker compose config --volumes | awk '{print $2}'))
        for VOL in "${VOLUMES[@]}"; do
            VOL_PATH=$(docker volume inspect "$VOL" --format '{{.Mountpoint}}')
            if [[ -d "$VOL_PATH" ]]; then
                echo -e "${CYAN}📂 备份卷: $VOL → $TEMP_DIR/volumes/$VOL${RESET}"
                mkdir -p "$TEMP_DIR/volumes/$VOL"
                rsync -a "$VOL_PATH/" "$TEMP_DIR/volumes/$VOL/"
            fi
        done

        # 备份自定义网络
        get_custom_networks
        mkdir -p "$TEMP_DIR/networks"
        for NET in "${NETWORKS[@]}"; do
            echo -e "${CYAN}🌐 备份网络: $NET${RESET}"
            docker network inspect "$NET" > "$TEMP_DIR/networks/$NET.json"
        done

        tar czf "$BACKUP_FILE" -C "$TEMP_DIR" .
        rm -rf "$TEMP_DIR"
        echo -e "${GREEN}✅ 已完成备份: $BACKUP_FILE${RESET}"
    done
}

# ================== 远程上传 ==================
remote_backup() {
    read -rp "请输入本地备份存放目录（默认 /opt/docker_backups）: " BACKUP_DIR
    BACKUP_DIR=${BACKUP_DIR:-/opt/docker_backups}
    [[ ! -d "$BACKUP_DIR" ]] && { echo -e "${RED}❌ 目录不存在: $BACKUP_DIR${RESET}"; return; }

    FILE_LIST=("$BACKUP_DIR"/*.tar.gz)
    [[ ${#FILE_LIST[@]} -eq 0 ]] && { echo -e "${RED}❌ 没有备份文件${RESET}"; return; }

    echo -e "${CYAN}📂 本地备份文件列表:${RESET}"
    for i in "${!FILE_LIST[@]}"; do
        echo -e "${GREEN}$((i+1)). $(basename "${FILE_LIST[$i]}")${RESET}"
    done

    read -rp "请输入要上传的序号（可多选，all 全部）: " SELECTION
    SELECTED_FILES=()
    if [[ "$SELECTION" == "all" ]]; then
        SELECTED_FILES=("${FILE_LIST[@]}")
    else
        for num in $SELECTION; do
            [[ $num =~ ^[0-9]+$ ]] && (( num>=1 && num<=${#FILE_LIST[@]} )) && SELECTED_FILES+=("${FILE_LIST[$((num-1))]}")
        done
    fi
    [[ ${#SELECTED_FILES[@]} -eq 0 ]] && { echo -e "${RED}❌ 没有选择有效文件${RESET}"; return; }

    read -rp "请输入远程用户名: " REMOTE_USER
    read -rp "请输入远程IP: " REMOTE_IP
    read -rp "请输入远程目录（默认 /opt/docker_backups）: " REMOTE_DIR
    REMOTE_DIR=${REMOTE_DIR:-/opt/docker_backups}
    read -rp "请输入 SSH 端口（默认 22）: " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}

    echo -e "${CYAN}📂 确认远程目录 $REMOTE_USER@$REMOTE_IP:$REMOTE_DIR 存在...${RESET}"
    ssh -p "$SSH_PORT" "$REMOTE_USER@$REMOTE_IP" "mkdir -p $REMOTE_DIR"

    mkdir -p /tmp/docker_upload
    TIMESTAMP=$(date +%F_%H-%M-%S)
    TEMP_PACKAGE="/tmp/docker_upload/backup_upload_$TIMESTAMP.tar.gz"

    echo -e "${CYAN}📦 打包选择文件...${RESET}"
    tar czf "$TEMP_PACKAGE" -C "$BACKUP_DIR" $(for f in "${SELECTED_FILES[@]}"; do basename "$f"; done)

    echo -e "${CYAN}📤 上传 $TEMP_PACKAGE → $REMOTE_USER@$REMOTE_IP:$REMOTE_DIR${RESET}"
    scp -P "$SSH_PORT" "$TEMP_PACKAGE" "$REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/"

    echo -e "${CYAN}📂 远程解压中...${RESET}"
    ssh -p "$SSH_PORT" "$REMOTE_USER@$REMOTE_IP" "tar xzf $REMOTE_DIR/$(basename "$TEMP_PACKAGE") -C $REMOTE_DIR && rm -f $REMOTE_DIR/$(basename "$TEMP_PACKAGE")"

    echo -e "${GREEN}✅ 上传并解压完成${RESET}"
    rm -f "$TEMP_PACKAGE"
}

# ================== 恢复备份 ==================
restore() {
    read -rp "请输入备份存放目录（默认 /opt/docker_backups）: " BACKUP_DIR
    BACKUP_DIR=${BACKUP_DIR:-/opt/docker_backups}
    FILE_LIST=("$BACKUP_DIR"/*.tar.gz)
    [[ ${#FILE_LIST[@]} -eq 0 ]] && { echo -e "${RED}❌ 没有备份文件${RESET}"; return; }

    echo -e "${CYAN}📂 本地备份文件列表:${RESET}"
    for i in "${!FILE_LIST[@]}"; do
        echo -e "${GREEN}$((i+1)). $(basename "${FILE_LIST[$i]}")${RESET}"
    done

    read -rp "请输入要恢复的序号（可多选，all 全部）: " SELECTION
    BACKUP_FILES=()
    if [[ "$SELECTION" == "all" ]]; then
        BACKUP_FILES=("${FILE_LIST[@]}")
    else
        for num in $SELECTION; do
            [[ $num =~ ^[0-9]+$ ]] && (( num>=1 && num<=${#FILE_LIST[@]} )) && BACKUP_FILES+=("${FILE_LIST[$((num-1))]}")
        done
    fi
    [[ ${#BACKUP_FILES[@]} -eq 0 ]] && { echo -e "${RED}❌ 没有选择有效文件${RESET}"; return; }

    read -rp "请输入恢复到的项目目录（默认 /opt/原项目名）: " PROJECT_DIR_INPUT

    for FILE in "${BACKUP_FILES[@]}"; do
        BASE_NAME=$(basename "$FILE" | sed 's/_backup_.*\.tar\.gz//')
        TARGET_DIR=${PROJECT_DIR_INPUT:-/opt/$BASE_NAME}
        mkdir -p "$TARGET_DIR"

        echo -e "${CYAN}📂 解压备份 $(basename "$FILE") → $TARGET_DIR${RESET}"
        tar xzf "$FILE" -C "$TARGET_DIR"

        # 恢复网络
        if [[ -d "$TARGET_DIR/networks" ]]; then
            for NET_JSON in "$TARGET_DIR/networks"/*.json; do
                NET_NAME=$(basename "$NET_JSON" .json)
                echo -e "${CYAN}🌐 恢复网络: $NET_NAME${RESET}"
                docker network create "$NET_NAME" || echo -e "${YELLOW}⚠ 网络 $NET_NAME 已存在，跳过${RESET}"
            done
        fi

        # 恢复卷
        if [[ -d "$TARGET_DIR/volumes" ]]; then
            for VOL_DIR in "$TARGET_DIR/volumes"/*; do
                VOL_NAME=$(basename "$VOL_DIR")
                echo -e "${CYAN}📂 恢复卷 $VOL_NAME → Docker卷${RESET}"
                docker volume create "$VOL_NAME"
                docker run --rm -v "$VOL_NAME":/vol -v "$VOL_DIR":/backup alpine sh -c "cp -a /backup/. /vol/"
            done
            rm -rf "$TARGET_DIR/volumes"
        fi

        # 启动容器
        if [[ -f "$TARGET_DIR/docker-compose.yml" ]]; then
            echo -e "${CYAN}🚀 启动容器...${RESET}"
            cd "$TARGET_DIR" || continue
            docker compose up -d
            echo -e "${GREEN}✅ 恢复完成: $TARGET_DIR${RESET}"
        else
            echo -e "${RED}❌ docker-compose.yml 不存在，无法启动容器${RESET}"
        fi
    done
}

# ================== 删除备份 ==================
delete_backup() {
    read -rp "请输入备份存放目录（默认 /opt/docker_backups）: " BACKUP_DIR
    BACKUP_DIR=${BACKUP_DIR:-/opt/docker_backups}
    FILE_LIST=("$BACKUP_DIR"/*.tar.gz)
    [[ ${#FILE_LIST[@]} -eq 0 ]] && { echo -e "${RED}❌ 没有备份文件${RESET}"; return; }

    echo -e "${CYAN}📂 本地备份文件列表:${RESET}"
    for i in "${!FILE_LIST[@]}"; do
        echo -e "${GREEN}$((i+1)). $(basename "${FILE_LIST[$i]}")${RESET}"
    done

    read -rp "请输入要删除的序号（可多选，all 全部）: " SELECTION
    FILES_TO_DELETE=()
    if [[ "$SELECTION" == "all" ]]; then
        FILES_TO_DELETE=("${FILE_LIST[@]}")
    else
        for num in $SELECTION; do
            [[ $num =~ ^[0-9]+$ ]] && (( num>=1 && num<=${#FILE_LIST[@]} )) && FILES_TO_DELETE+=("${FILE_LIST[$((num-1))]}")
        done
    fi
    [[ ${#FILES_TO_DELETE[@]} -eq 0 ]] && { echo -e "${RED}❌ 没有选择有效文件${RESET}"; return; }

    for FILE in "${FILES_TO_DELETE[@]}"; do
        rm -f "$FILE"
        echo -e "${GREEN}✅ 已删除 $(basename "$FILE")${RESET}"
    done
}

# ================== 主菜单 ==================
while true; do
    clear
    echo -e "${CYAN}===== Docker Compose 项目备份与恢复 =====${RESET}"
    echo -e "${GREEN}1. 本地完整备份项目（含卷、网络）${RESET}"
    echo -e "${GREEN}2. 远程备份（上传已有备份）${RESET}"
    echo -e "${GREEN}3. 恢复备份项目（含卷、网络）${RESET}"
    echo -e "${GREEN}4. 删除备份文件${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    read -rp "请选择操作: " CHOICE

    case $CHOICE in
        1) backup ;;
        2) remote_backup ;;
        3) restore ;;
        4) delete_backup ;;
        0) exit 0 ;;
        *) echo -e "${RED}❌ 无效选择${RESET}" ;;
    esac
    pause
done
