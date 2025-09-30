#!/bin/bash
# ========================================
# WireGuard 客户端 Docker 菜单管理脚本 (绿色菜单版)
# ========================================

docker_name="wireguardc"
docker_img="kjlion/wireguard:alpine"
docker_port=51820
config_dir="/opt/wireguard/config"
config_file="$config_dir/wg0.conf"

GREEN="\033[32m"
RESET="\033[0m"

# ================== 功能函数 ==================

create_config() {
    mkdir -p "$config_dir"

    if [[ -f "$config_file" ]]; then
        echo -e "${GREEN}⚠️ 检测到已有配置文件: $config_file${RESET}"
        read -p "是否覆盖？(y/N): " ans
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            echo -e "${GREEN}✅ 保留原有配置${RESET}"
            return 0
        fi
    fi

    echo -e "${GREEN}请粘贴你的客户端配置，连续按两次回车保存：${RESET}"

    local input=""
    local empty_line_count=0

    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            ((empty_line_count++))
            if [[ $empty_line_count -ge 2 ]]; then
                break
            fi
        else
            empty_line_count=0
            input+="$line"$'\n'
        fi
    done

    if [[ -z "$input" ]]; then
        echo -e "${GREEN}❌ 未输入配置，操作已取消。${RESET}"
        return 1
    fi

    echo "$input" > "$config_file"
    echo -e "${GREEN}✅ 客户端配置已保存到 $config_file${RESET}"
    return 0
}

start_container() {
    if [[ ! -f "$config_file" ]]; then
        echo -e "${GREEN}⚠️ 未检测到配置文件，需要先创建配置。${RESET}"
        create_config || return 1
    fi

    docker rm -f "$docker_name" &>/dev/null
    ip link delete wg0 &>/dev/null

    docker run -d \
      --name "$docker_name" \
      --network host \
      --cap-add NET_ADMIN \
      --cap-add SYS_MODULE \
      -v "$config_dir":/config \
      -v /lib/modules:/lib/modules:ro \
      --restart=always \
      "$docker_img"

    sleep 2
    docker logs "$docker_name"
}

stop_container() {
    docker stop "$docker_name" 2>/dev/null && echo -e "${GREEN}🛑 容器已停止${RESET}" || echo -e "${GREEN}❌ 容器未运行${RESET}"
}

restart_container() {
    stop_container
    start_container
}

logs_container() {
    docker logs -f "$docker_name"
}

update_container() {
    echo -e "${GREEN}🔄 正在更新/重建容器 (保留配置)...${RESET}"
    docker rm -f "$docker_name" &>/dev/null
    start_container
}

remove_container() {
    docker rm -f "$docker_name" &>/dev/null
    if [[ -d "$config_dir" ]]; then
        rm -rf /opt/wireguard
        echo -e "${GREEN}🗑️ 容器和配置文件已删除${RESET}"
    else
        echo -e "${GREEN}🗑️ 容器已删除，未检测到配置文件${RESET}"
    fi
}


# ================== 菜单 ==================
menu() {
    clear
    echo -e "${GREEN}========== WireGuard 客户端管理 ==========${RESET}"
    echo -e "${GREEN}1) 启动容器${RESET}"
    echo -e "${GREEN}2) 停止容器${RESET}"
    echo -e "${GREEN}3) 重启容器${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 更新配置${RESET}"
    echo -e "${GREEN}6) 更新容器 (保留配置)${RESET}"
    echo -e "${GREEN}7) 删除容器${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}==========================================${RESET}"
    read -p "请选择操作: " choice

    case "$choice" in
        1) start_container ;;
        2) stop_container ;;
        3) restart_container ;;
        4) logs_container ;;
        5) create_config ;;
        6) update_container ;;
        7) remove_container ;;
        0) exit 0 ;;
        *) echo -e "${GREEN}❌ 无效选择${RESET}" ;;
    esac
    echo
    read -p "按回车返回菜单..."
    menu
}

menu
