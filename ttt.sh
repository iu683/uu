#!/bin/bash

# ================== 颜色定义 ==================
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"
BOLD="\033[1m"

# ================== 脚本路径 ==================
SCRIPT_PATH="$HOME/store.sh"

# ================== 首次运行自动保存 ==================
if [ ! -f "$SCRIPT_PATH" ]; then
    echo -e "${YELLOW}首次运行，正在保存脚本到 $SCRIPT_PATH ...${RESET}"
    curl -fsSL -o "$SCRIPT_PATH" "https://raw.githubusercontent.com/Polarisiu/app-store/main/store.sh"
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}保存完成！${RESET}"
fi

# ================== 快捷键 d/D ==================
added=false
if ! grep -q "alias d=" ~/.bashrc; then
    echo "alias d='bash $SCRIPT_PATH'" >> ~/.bashrc
    added=true
fi
if ! grep -q "alias D=" ~/.bashrc; then
    echo "alias D='bash $SCRIPT_PATH'" >> ~/.bashrc
    added=true
fi

if [ "$added" = true ]; then
    source ~/.bashrc 2>/dev/null || true
    echo -e "${GREEN}已添加快捷键 D/d，重启终端可直接输入启动脚本！${RESET}"
fi

# ================== 一级菜单分类 ==================
declare -A categories=(
    [1]="Docker及数据库"
    [2]="订阅服务"
    [3]="监控通知"
    [4]="管理面板"
    [5]="多媒体工具"
    [6]="图床工具"
    [7]="实用工具"
    [8]="交易商店"
)

# ================== 二级菜单应用 ==================
declare -A apps=(
    [1,1]="安装/管理 Docker"
    [1,2]="MySQL数据管理"
    [1,3]="Docker备份恢复"
    [1,4]="Docker容器迁移"
    [2,1]="Wallos订阅"
    [2,2]="Vaultwarden (密码管理)"
    [2,3]="2FBA"
    [3,1]="Kuma-Mieru"
    [3,2]="Komari监控"
    [3,3]="哪吒监控"
    [4,1]="运维面板"
    [4,2]="XTrafficDash(流量监控)"
    [4,3]="Sun-Panel"
    [4,4]="WebSSH"
    [4,5]="NexusTerminal(SSH)"
    [4,6]="Sub-store"
    [4,7]="Poste.io邮局"
    [4,8]="oci-start"
    [4,9]="Y探长"
    [4,10]="R探长"
    [4,11]="OneNav书签管理"
    [4,12]="彩虹聚合DNS"
    [4,13]="ONE API"
    [4,14]="NEW API"
    [4,15]="青龙面板"
    [5,1]="音乐服务（三合一）"
    [5,2]="LrcApi(歌词)"
    [5,3]="Openlist"
    [5,4]="SPlayer音乐"
    [5,5]="AutoBangumi"
    [5,6]="MoviePilot"
    [5,7]="qBittorrentv4.6.3"
    [5,8]="Vertex"
    [5,9]="yt-dlp视频下载工具"
    [5,10]="libretv"
    [5,11]="MoonTV"
    [5,12]="Emby(开心版)"
    [5,13]="Emby"
    [5,14]="Jellyfin"
    [6,1]="Foxel图片管理"
    [6,2]="STB图床"
    [6,3]="兰空图床(无MySQL)"
    [6,4]="兰空图床(有MySQL)"
    [6,5]="图片API (兰空图床)"
    [6,6]="简单图床"
    [7,1]="ALLinSSL证书"
    [7,2]="SaveAnyBot(TG转存)"
    [7,3]="github镜像"
    [7,4]="Docker加速"
    [7,5]="计算圆周率"
    [7,6]="DockerGitHub加速代理"
    [7,7]="超级短链"
    [7,8]="多功能文件分享"
    [7,9]="订阅转换"
    [7,10]="笔记"
    [8,1]="异次元商城"
    [8,2]="萌次元商城"
    [8,3]="BEpusdt收款"
)

# ================== 二级菜单命令 ==================
declare -A commands=(
    [1,1]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/Docker.sh)'
    [1,2]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/mysql.sh)'
    [1,3]='curl -fsSL https://raw.githubusercontent.com/xymn2023/DMR/main/docker_back.sh -o docker_back.sh && chmod +x docker_back.sh && ./docker_back.sh'
    [1,4]='curl -sL https://raw.githubusercontent.com/ceocok/Docker_container_migration/refs/heads/main/Docker_container_migration.sh -o Docker_container_migration.sh && chmod +x Docker_container_migration.sh && ./Docker_container_migration.sh'
    [2,1]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/wallos.sh)'
    [2,2]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/vaultwarden.sh)'
    [2,3]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/2fauth.sh)'
    [3,1]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/kuma-mieru.sh)'
    [3,2]='bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/app-store/main/komarigl.sh)'
    [3,3]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/panel/main/nezha.sh)'
    [4,1]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/panel/main/Panel.sh)'
    [4,2]='bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/app-store/main/xtrafficdash.sh)'
    [4,3]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/sun-panel.sh)'
    [4,4]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/webssh.sh)'
    [4,5]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/nexus-terminal.sh)'
    [4,6]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/sub-store.sh)'
    [4,7]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/Poste.io.sh)'
    [4,8]='bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/oracle/main/oci-start.sh)'
    [4,9]='bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/oracle/main/Yoci-helper.sh)'
    [4,10]='bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/oracle/main/R-Bot.sh)'
    [4,11]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/onenav.sh)'
    [4,12]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/dnss.sh)'
    [4,13]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/oneapi.sh)'
    [4,14]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/newapi.sh)'
    [4,15]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/qlmb.sh)'
    [5,1]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/music_full_auto.sh)'
    [5,2]='bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/app-store/main/lacapi.sh)'
    [5,3]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/Openlist.sh)'
    [5,4]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/splayer.sh)'
    [5,5]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/Autobangumi.sh)'
    [5,6]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/moviepilot.sh)'
    [5,7]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/qbittorrent.sh)'
    [5,8]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/vertex.sh)'
    [5,9]='bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/app-store/main/ytdlb.sh)'
    [5,10]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/libretv.sh)'
    [5,11]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/mootv.sh)'
    [5,12]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/kxemby.sh)'
    [5,13]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/emby.sh)'
    [5,14]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/Jellyfin.sh)'
    [6,1]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/foxel.sh)'
    [6,2]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/stb.sh)'
    [6,3]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/lsky_menu.sh)'
    [6,4]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/Lsky.sh)'
    [6,5]='bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/app-store/main/apitu.sh)'
    [6,6]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/EasyImage.sh)'
    [7,1]='bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/app-store/main/ALLSSL.sh)'
    [7,2]='bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/app-store/main/SaveAnyBot.sh)'
    [7,3]='bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/app-store/main/fdgit.sh)'
    [7,4]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/dockhub.sh)'
    [7,5]='bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/toy/main/pai.sh)'
    [7,6]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/hubproxy.sh)'
    [7,7]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/Zurl.sh)'
    [7,8]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/Zdir.sh)'
    [7,9]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/subzh.sh)'
    [7,10]='bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/Trilium.sh)'
    [8,1]='bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/app-store/main/ycyk.sh)'
    [8,2]='bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/app-store/main/mcygl.sh)'
    [8,3]='bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/app-store/main/BEpusdt.sh)'
)

# ================== 菜单显示函数 ==================
show_category_menu() {
    printf '\033c'  # 替代 clear，避免闪屏
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}         应用分类菜单${RESET}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════╝${RESET}\n"

    for i in $(seq 1 ${#categories[@]}); do
        printf "${GREEN}[%02d] %-20s${RESET}\n" "$i" "${categories[$i]}"
    done
    printf "${GREEN}[88] %-20s${RESET}\n" "更新脚本"
    printf "${GREEN}[99] %-20s${RESET}\n" "卸载脚本"
    printf "${GREEN}[0 ] %-20s${RESET}\n" "退出脚本"
}

show_app_menu() {
    local cat=$1
    printf '\033c'
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}        ${categories[$cat]}${RESET}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════╝${RESET}\n"

    local i=1
    declare -gA menu_map
    menu_map=()

    keys=()
    for key in "${!apps[@]}"; do
        if [[ $key == $cat,* ]]; then
            keys+=("$key")
        fi
    done

    IFS=$'\n' sorted_keys=($(sort -t, -k2n <<<"${keys[*]}"))
    unset IFS

    for key in "${sorted_keys[@]}"; do
        menu_map[$i]=$key
        printf "${GREEN}[%02d] %-25s${RESET}\n" "$i" "${apps[$key]}"
        ((i++))
    done

    printf "${GREEN}[0 ] %-25s${RESET}\n" "返回上一级"
}



# ================== 菜单处理函数 ==================
category_menu_handler() {
    while true; do
        show_category_menu
        read -rp "$(echo -e "${RED}请输入分类编号: ${RESET}")" cat_choice
        cat_choice=$(echo "$cat_choice" | xargs)

        if ! [[ "$cat_choice" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}无效选择，请输入数字!${RESET}"
            sleep 1
            continue
        fi

        case "$cat_choice" in
            0) echo -e "${RED}退出脚本！${RESET}"; exit 0 ;;
            88) update_script ;;
            99) uninstall_script ;;
            *) 
               if [[ -n "${categories[$cat_choice]}" ]]; then
                   app_menu_handler "$cat_choice"
               else
                   echo -e "${RED}无效选择，请重新输入!${RESET}"
                   sleep 1
               fi
            ;;
        esac
    done
}

app_menu_handler() {
    local cat=$1
    while true; do
        show_app_menu "$cat"
        read -rp "$(echo -e "${RED}请输入应用编号: ${RESET}")" app_choice
        app_choice=$(echo "$app_choice" | xargs)

        if ! [[ "$app_choice" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}无效选择，请输入数字!${RESET}"
            sleep 1
            continue
        fi

        if [[ "$app_choice" == "0" ]]; then
            break
        elif [[ -n "${menu_map[$app_choice]}" ]]; then
            key="${menu_map[$app_choice]}"
            bash -c "${commands[$key]}"
        else
            echo -e "${RED}无效选择，请重新输入!${RESET}"
            sleep 1
        fi

        read -rp $'\n\033[33m按回车返回应用菜单...\033[0m'
    done
}

# ================== 脚本更新与卸载 ==================
update_script() {
    echo -e "${YELLOW}正在更新脚本...${RESET}"
    curl -fsSL -o "$SCRIPT_PATH" https://raw.githubusercontent.com/Polarisiu/app-store/main/store.sh
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}更新完成! 可直接使用 D/d 启动脚本${RESET}"
}

uninstall_script() {
    echo -e "${YELLOW}正在卸载脚本...${RESET}"
    rm -f "$SCRIPT_PATH"

    sed -i "/alias d='bash .*store.sh'/d" ~/.bashrc
    sed -i "/alias D='bash .*store.sh'/d" ~/.bashrc
    sed -i "/alias d='bash .*store.sh'/d" ~/.zshrc 2>/dev/null || true
    sed -i "/alias D='bash .*store.sh'/d" ~/.zshrc 2>/dev/null || true
    source ~/.bashrc 2>/dev/null || true

    echo -e "${RED}卸载完成! 已清理 D/d 快捷键${RESET}"
    exit 0
}

# ================== 主循环 ==================
while true; do
    category_menu_handler
done
