#!/bin/bash

GREEN="\033[32m"
RESET="\033[0m"
gl_huang="\033[33m"
gl_bai="\033[97m"
gl_lv="\033[34m"

docker_name="wireguard"
docker_img="lscr.io/linuxserver/wireguard:latest"
DEFAULT_PORT=51820
DEFAULT_COUNT=5
DEFAULT_NETWORK="10.13.13.0"

CONFIG_DIR="/opt/wireguard/config"

COUNT=${DEFAULT_COUNT}
NETWORK=${DEFAULT_NETWORK}
docker_port=${DEFAULT_PORT}

show_menu() {
    clear
    echo -e "${GREEN}=== WireGuard VPN 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动 WireGuard 服务${RESET}"
    echo -e "${GREEN}2) 更新 WireGuard 服务${RESET}"
    echo -e "${GREEN}3) 查看所有客户端配置${RESET}"
    echo -e "${GREEN}4) 卸载 WireGuard 服务${RESET}"
    echo -e "${GREEN}5) 退出${RESET}"
    read -e -p "请输入选项 (1-5): " option
    case $option in
        1) modify_and_install_start_wireguard ;;
        2) update_wireguard ;;
        3) view_client_configs ;;
        4) stop_wireguard ;;
        5) exit 0 ;;
        *) echo -e "${gl_huang}无效选项，请重新选择！${gl_bai}" && sleep 2 && show_menu ;;
    esac
}

modify_and_install_start_wireguard() {
    echo -e "${gl_huang}当前配置: ${gl_bai}客户端数量=$COUNT, 网段=$NETWORK, 端口=$docker_port"

    read -e -p "请输入新的客户端数量 (默认 $DEFAULT_COUNT): " new_count
    COUNT=${new_count:-$DEFAULT_COUNT}

    read -e -p "请输入新的 WireGuard 网段 (默认 $DEFAULT_NETWORK): " new_network
    NETWORK=${new_network:-$DEFAULT_NETWORK}

    read -e -p "请输入新的 WireGuard 端口 (默认 $DEFAULT_PORT): " new_port
    docker_port=${new_port:-$DEFAULT_PORT}

    run_wireguard
}

# 更新：不需要输入，直接读取旧配置或默认值
update_wireguard() {
    echo "更新 WireGuard 服务..."
    docker pull $docker_img

    # 如果容器存在，读取之前的配置
    if docker inspect $docker_name &>/dev/null; then
        COUNT=$(docker inspect -f '{{ index .Config.Env }}' $docker_name | tr ' ' '\n' | grep '^PEERS=' | tr -d 'PEERS=' | tr ',' '\n' | wc -l)
        NETWORK=$(docker inspect -f '{{ range .Config.Env }}{{ println .}}{{ end }}' $docker_name | grep '^INTERNAL_SUBNET=' | cut -d= -f2)
        docker_port=$(docker inspect -f '{{ range .Config.Env }}{{ println .}}{{ end }}' $docker_name | grep '^SERVERPORT=' | cut -d= -f2)
    fi

    docker stop $docker_name 2>/dev/null
    docker rm $docker_name 2>/dev/null

    run_wireguard
}

run_wireguard() {
    echo -e "${gl_huang}使用配置: ${gl_bai}客户端数量=$COUNT, 网段=$NETWORK, 端口=$docker_port"

    PEERS=$(seq -f "wg%02g" 1 "$COUNT" | paste -sd,)

    ip link delete wg0 &>/dev/null
    mkdir -p $CONFIG_DIR

    docker run -d \
      --name=$docker_name \
      --network host \
      --cap-add=NET_ADMIN \
      --cap-add=SYS_MODULE \
      -e PUID=1000 \
      -e PGID=1000 \
      -e TZ=Etc/UTC \
      -e SERVERURL=$(curl -s https://api.ipify.org) \
      -e SERVERPORT=$docker_port \
      -e PEERS=${PEERS} \
      -e INTERNAL_SUBNET=${NETWORK} \
      -e ALLOWEDIPS=${NETWORK}/24 \
      -e PERSISTENTKEEPALIVE_PEERS=all \
      -e LOG_CONFS=true \
      -v $CONFIG_DIR:/config \
      -v /lib/modules:/lib/modules \
      --restart=always \
      $docker_img

    sleep 3

    # 修改配置文件端口、去掉DNS、加PersistentKeepalive
    docker exec $docker_name sh -c "
    sed -i 's/51820/${docker_port}/g' /config/wg_confs/wg0.conf
    for d in /config/peer_*; do
      sed -i 's/51820/${docker_port}/g' \$d/*.conf
      sed -i '/^DNS/d' \$d/*.conf
      for f in \$d/*.conf; do
        grep -q '^PersistentKeepalive' \$f || \
        sed -i '/^AllowedIPs/ a PersistentKeepalive = 25' \$f
      done
    done
    "

    # 生成二维码
    docker exec $docker_name bash -c '
    for d in /config/peer_*; do
      cd "$d" || continue
      conf_file=$(ls *.conf)
      base_name="${conf_file%.conf}"
      qrencode -o "$base_name.png" < "$conf_file"
    done
    '

    docker restart $docker_name
    echo -e "${gl_huang}WireGuard 服务已启动！${gl_bai}"
    read -p "按任意键返回主菜单..." && show_menu
}

view_client_configs() {
    echo "查看所有客户端配置..."
    docker exec $docker_name sh -c 'for d in /config/peer_*; do echo "# $(basename $d) "; cat $d/*.conf; done'
    read -p "按任意键返回主菜单..." && show_menu
}

stop_wireguard() {
    echo "停止 WireGuard 服务并删除配置数据..."
    docker stop $docker_name
    docker rm $docker_name
    rm -rf $CONFIG_DIR
    echo -e "${gl_huang}WireGuard 服务及所有配置数据已删除！${gl_bai}"
    read -p "按任意键返回主菜单..." && show_menu
}

show_menu
