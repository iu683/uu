#!/bin/bash

GREEN="\033[32m"
RESET="\033[0m"
gl_huang="\033[33m"
gl_bai="\033[97m"
gl_lv="\033[34m"

docker_name="wireguard"
docker_img="lscr.io/linuxserver/wireguard:latest"
DEFAULT_PORT=51820  # 默认端口
docker_port=$DEFAULT_PORT

# 默认配置
DEFAULT_COUNT=5
DEFAULT_NETWORK="10.13.13.0"

# 获取当前配置
COUNT=${DEFAULT_COUNT}
NETWORK=${DEFAULT_NETWORK}

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
    echo -e "${gl_huang}当前配置: ${gl_bai}客户端数量 = $COUNT, 网段 = $NETWORK, 端口 = $docker_port"
    
    # 修改客户端数量
    read -e -p "请输入新的客户端数量 (默认 ${DEFAULT_COUNT}): " new_count
    COUNT=${new_count:-$DEFAULT_COUNT}

    # 修改网段
    read -e -p "请输入新的 WireGuard 网段 (默认 ${DEFAULT_NETWORK}): " new_network
    NETWORK=${new_network:-$DEFAULT_NETWORK}

    # 修改端口
    read -e -p "请输入新的 WireGuard 端口 (默认 ${DEFAULT_PORT}): " new_port
    docker_port=${new_port:-$DEFAULT_PORT}

    echo -e "${gl_huang}新配置: ${gl_bai}客户端数量 = $COUNT, 网段 = $NETWORK, 端口 = $docker_port"

    PEERS=$(seq -f "wg%02g" 1 "$COUNT" | paste -sd,)

    ip link delete wg0 &>/dev/null

    docker run -d \
      --name=wireguard \
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
      -v /home/docker/wireguard/config:/config \
      -v /lib/modules:/lib/modules \
      --restart=always \
      lscr.io/linuxserver/wireguard:latest

    sleep 3
    docker exec wireguard sh -c "
    f='/config/wg_confs/wg0.conf'
    sed -i 's/51820/${docker_port}/g' \$f
    "

    docker exec wireguard sh -c "
    for d in /config/peer_*; do
      sed -i 's/51820/${docker_port}/g' \$d/*.conf
    done
    "

    docker exec wireguard sh -c '
    for d in /config/peer_*; do
      sed -i "/^DNS/d" "$d"/*.conf
    done
    '

    docker exec wireguard sh -c '
    for d in /config/peer_*; do
      for f in "$d"/*.conf; do
        grep -q "^PersistentKeepalive" "$f" || \
        sed -i "/^AllowedIPs/ a PersistentKeepalive = 25" "$f"
      done
    done
    '

    docker exec -it wireguard bash -c '
    for d in /config/peer_*; do
      cd "$d" || continue
      conf_file=$(ls *.conf)
      base_name="${conf_file%.conf}"
      qrencode -o "$base_name.png" < "$conf_file"
    done
    '

    docker restart wireguard

    sleep 2
    echo
    echo -e "${gl_huang}所有客户端二维码配置: ${gl_bai}"
    docker exec -it wireguard bash -c 'for i in $(ls /config | grep peer_ | sed "s/peer_//"); do echo "--- $i ---"; /app/show-peer $i; done'
    sleep 2
    echo
    echo -e "${gl_huang}所有客户端配置代码: ${gl_bai}"
    docker exec wireguard sh -c 'for d in /config/peer_*; do echo "# $(basename $d) "; cat $d/*.conf; echo; done'
    sleep 2
    echo -e "${gl_lv}${COUNT}个客户端配置全部输出，使用方法如下：${gl_bai}"
    echo -e "${gl_lv}1. 手机下载wg的APP，扫描上方二维码，可以快速连接网络${gl_bai}"
    echo -e "${gl_lv}2. Windows下载客户端，复制配置代码连接网络。${gl_bai}"
    echo -e "${gl_lv}3. Linux用脚本部署WG客户端，复制配置代码连接网络。${gl_bai}"
    echo -e "${gl_lv}官方客户端下载方式: https://www.wireguard.com/install/${gl_bai}"
    read -p "按任意键返回主菜单..." && show_menu
}

# 更新 WireGuard 服务，无需输入
update_wireguard() {
    echo "更新 WireGuard 服务..."
    docker pull lscr.io/linuxserver/wireguard:latest

    # 停止并删除旧容器
    docker stop wireguard
    docker rm wireguard

    # 使用当前配置重新启动容器
    echo -e "${gl_huang}当前配置: ${gl_bai}客户端数量 = $COUNT, 网段 = $NETWORK, 端口 = $docker_port"
    PEERS=$(seq -f "wg%02g" 1 "$COUNT" | paste -sd,)

    ip link delete wg0 &>/dev/null

    docker run -d \
      --name=wireguard \
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
      -v /home/docker/wireguard/config:/config \
      -v /lib/modules:/lib/modules \
      --restart=always \
      lscr.io/linuxserver/wireguard:latest

    sleep 3
    docker exec wireguard sh -c "
    f='/config/wg_confs/wg0.conf'
    sed -i 's/51820/${docker_port}/g' \$f
    "

    docker exec wireguard sh -c "
    for d in /config/peer_*; do
      sed -i 's/51820/${docker_port}/g' \$d/*.conf
    done
    "

    docker exec wireguard sh -c '
    for d in /config/peer_*; do
      sed -i "/^DNS/d" "$d"/*.conf
    done
    '

    docker exec wireguard sh -c '
    for d in /config/peer_*; do
      for f in "$d"/*.conf; do
        grep -q "^PersistentKeepalive" "$f" || \
        sed -i "/^AllowedIPs/ a PersistentKeepalive = 25" "$f"
      done
    done
    '

    docker exec -it wireguard bash -c '
    for d in /config/peer_*; do
      cd "$d" || continue
      conf_file=$(ls *.conf)
      base_name="${conf_file%.conf}"
      qrencode -o "$base_name.png" < "$conf_file"
    done
    '

    docker restart wireguard

    sleep 2
    echo
    echo -e "${gl_huang}所有客户端二维码配置: ${gl_bai}"
    docker exec -it wireguard bash -c 'for i in $(ls /config | grep peer_ | sed "s/peer_//"); do echo "--- $i ---"; /app/show-peer $i; done'
    sleep 2
    echo
    echo -e "${gl_huang}所有客户端配置代码: ${gl_bai}"
    docker exec wireguard sh -c 'for d in /config/peer_*; do echo "# $(basename $d) "; cat $d/*.conf; echo; done'
    sleep 2
    echo -e "${gl_lv}${COUNT}个客户端配置全部输出，使用方法如下：${gl_bai}"
    echo -e "${gl_lv}1. 手机下载wg的APP，扫描上方二维码，可以快速连接网络${gl_bai}"
    echo -e "${gl_lv}2. Windows下载客户端，复制配置代码连接网络。${gl_bai}"
    echo -e "${gl_lv}3. Linux用脚本部署WG客户端，复制配置代码连接网络。${gl_bai}"
    echo -e "${gl_lv}官方客户端下载方式: https://www.wireguard.com/install/${gl_bai}"
    read -p "按任意键返回主菜单..." && show_menu
}

view_client_configs() {
    echo "查看所有客户端配置..."
    docker exec wireguard sh -c 'for d in /config/peer_*; do echo "# $(basename $d) "; cat $d/*.conf; done'
    read -p "按任意键返回主菜单..." && show_menu
}

# 停止并删除 WireGuard 服务及所有数据
stop_wireguard() {
    echo "停止 WireGuard 服务并删除配置数据..."
    docker stop wireguard
    docker rm wireguard
    # 删除配置文件
    rm -rf $CONFIG_DIR
    echo -e "${gl_huang}WireGuard 服务及所有配置数据已删除！${gl_bai}"
    read -p "按任意键返回主菜单..." && show_menu
}

# 启动菜单
show_menu
