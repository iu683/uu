#!/bin/bash

GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

BACKUP_ROOT="/opt/docker_backups"

# ================== 备份函数 ==================
backup_container() {
    CONTAINERS=($(docker ps -a --format '{{.Names}}'))
    if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
        echo -e "${RED}❌ 没有可用容器${RESET}"
        return
    fi

    echo -e "${CYAN}📦 可备份容器列表:${RESET}"
    for i in "${!CONTAINERS[@]}"; do
        printf "%s) %s\n" "$((i+1))" "${CONTAINERS[$i]}"
    done
    echo "输入容器序号（空格分隔，输入 all 全部备份）:"
    read -rp "> " choices

    SELECTED_CONTAINERS=()
    if [[ "$choices" == "all" ]]; then
        SELECTED_CONTAINERS=("${CONTAINERS[@]}")
    else
        for c in $choices; do
            idx=$((c-1))
            [[ -n "${CONTAINERS[$idx]}" ]] && SELECTED_CONTAINERS+=("${CONTAINERS[$idx]}")
        done
    fi

    mkdir -p "$BACKUP_ROOT"
    for c in "${SELECTED_CONTAINERS[@]}"; do
        TIMESTAMP=$(date +%F_%H-%M-%S)
        TARGET_DIR="$BACKUP_ROOT/${c}_$TIMESTAMP"
        mkdir -p "$TARGET_DIR"

        echo -e "${CYAN}📦 正在备份容器: $c${RESET}"

        docker inspect "$c" > "$TARGET_DIR/config.json"
        docker commit "$c" "${c}_backup:$TIMESTAMP" >/dev/null
        docker save -o "$TARGET_DIR/image.tar" "${c}_backup:$TIMESTAMP"
        docker rmi "${c}_backup:$TIMESTAMP" >/dev/null
        docker cp "$c:/." "$TARGET_DIR/data" >/dev/null 2>&1 || echo -e "${YELLOW}⚠️ 无法导出数据卷，可能容器未挂载数据${RESET}"

        echo -e "${GREEN}✅ 备份完成: $TARGET_DIR${RESET}"
    done
}

# ================== 恢复函数 ==================
restore_container() {
    read -rp "请输入要恢复的备份目录路径（可多选，用空格分隔）: " -a DIRS
    for d in "${DIRS[@]}"; do
        if [[ ! -d "$d" ]]; then
            echo -e "${RED}❌ 目录不存在: $d${RESET}"
            continue
        fi
        echo -e "${CYAN}📂 正在恢复 $d${RESET}"
        IMAGE=$(jq -r '.[0].Config.Image' "$d/config.json")
        NAME=$(jq -r '.[0].Name' "$d/config.json" | sed 's#^/##')

        docker load -i "$d/image.tar"
        docker rm -f "$NAME" >/dev/null 2>&1

        CMD="docker run -d --name $NAME"
        PORTS=$(jq -r '.[0].HostConfig.PortBindings | to_entries[]? | "-p \(.value[0].HostPort):\(.key)"' "$d/config.json")
        VOLUMES=$(jq -r '.[0].Mounts[]? | "-v \(.Source):\(.Destination)"' "$d/config.json")
        ENV=$(jq -r '.[0].Config.Env[]? | "-e \(. )"' "$d/config.json")

        CMD="$CMD $PORTS $VOLUMES $ENV $IMAGE"
        eval $CMD
        echo -e "${GREEN}✅ 容器 $NAME 已恢复${RESET}"
    done
}

# ================== 远程上传函数 ==================
upload_backups_remote() {
    if [[ ! -d "$BACKUP_ROOT" ]]; then
        echo -e "${RED}❌ 本地没有任何备份${RESET}"
        return
    fi

    echo -e "${CYAN}📦 选择上传的备份（输入序号，空格分隔，输入 all 上传全部）:${RESET}"
    ls -1 "$BACKUP_ROOT" | nl
    read -rp "请输入选择: " choices

    UPLOAD_LIST=()
    if [[ "$choices" == "all" ]]; then
        for d in $BACKUP_ROOT/*; do
            [[ -d "$d" ]] && UPLOAD_LIST+=("$d")
        done
    else
        for c in $choices; do
            d=$(ls -1 "$BACKUP_ROOT" | sed -n "${c}p")
            [[ -n "$d" ]] && UPLOAD_LIST+=("$BACKUP_ROOT/$d")
        done
    fi

    if [[ ${#UPLOAD_LIST[@]} -eq 0 ]]; then
        echo -e "${RED}❌ 未选择任何备份${RESET}"
        return
    fi

    read -rp "请输入远程用户名: " REMOTE_USER
    read -rp "请输入远程主机 IP: " REMOTE_IP
    read -rp "请输入 SSH 端口 (默认 22): " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
    read -rp "请输入远程目标目录 (默认 /opt/docker_backups): " REMOTE_DIR
    REMOTE_DIR=${REMOTE_DIR:-/opt/docker_backups}

    echo -e "${CYAN}📤 开始打包并上传...${RESET}"
    tar czf /tmp/docker_backups_upload.tar.gz -C "$BACKUP_ROOT" $(for d in "${UPLOAD_LIST[@]}"; do basename "$d"; done)

    scp -P "$SSH_PORT" /tmp/docker_backups_upload.tar.gz ${REMOTE_USER}@${REMOTE_IP}:/tmp/
    ssh -p "$SSH_PORT" ${REMOTE_USER}@${REMOTE_IP} "mkdir -p $REMOTE_DIR && tar xzf /tmp/docker_backups_upload.tar.gz -C $REMOTE_DIR && rm -f /tmp/docker_backups_upload.tar.gz"

    rm -f /tmp/docker_backups_upload.tar.gz
    echo -e "${GREEN}✅ 备份已上传至 ${REMOTE_USER}@${REMOTE_IP}:$REMOTE_DIR${RESET}"
}

# ================== 菜单 ==================
while true; do
    clear
    echo -e "${CYAN}===== Docker run 容器备份与恢复 =====${RESET}"
    echo -e "${GREEN}1. 备份容器${RESET}"
    echo -e "${GREEN}2. 恢复容器${RESET}"
    echo -e "${GREEN}3. 远程上传备份${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    read -rp "请选择操作: " CHOICE

    case $CHOICE in
        1) backup_container ;;
        2) restore_container ;;
        3) upload_backups_remote ;;
        0) exit 0 ;;
        *) echo -e "${RED}❌ 无效选择${RESET}" ;;
    esac
    echo -e "\n按回车键继续..."
    read
done
