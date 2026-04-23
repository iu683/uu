#!/usr/bin/env bash
# ==================================================
# GProxy 一键管理脚本
# 安装 / SSH密钥 / 加速测试 / 更新 / 卸载
# ==================================================

set -e

# ========= 基础配置 =========
BASE_DIR="/opt/gproxy-manager"
GPROXY_DIR="/opt/gproxy-tool"
SCRIPT_PATH="$BASE_DIR/gproxy.sh"

SSH_SCRIPT_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/ssh.sh"
GPROXY_REPO="https://github.com/xtianowner/gproxy-tool.git"

mkdir -p "$BASE_DIR"

# ========= 颜色 =========
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ========= 通用函数 =========
pause(){
    read -p "$(echo -e ${GREEN}按回车返回菜单${RESET})"
}

line(){
    echo -e "${GREEN}----------------------------------------${RESET}"
}

# ========= SSH 密钥配置 =========
setup_ssh(){
    echo -e "${YELLOW}正在配置 SSH 密钥...${RESET}"
    bash <(curl -fsSL "$SSH_SCRIPT_URL")
}

# ========= 安装 =========
install_gproxy(){

    if [[ -d "$GPROXY_DIR" ]]; then
        echo -e "${YELLOW}已安装，跳过${RESET}"
        return
    fi

    echo -e "${GREEN}开始安装 GProxy...${RESET}"

    apt update -y
    apt install -y git curl

    git clone "$GPROXY_REPO" "$GPROXY_DIR"

    cd "$GPROXY_DIR"
    sudo sh install.sh

    echo -e "${GREEN}安装完成 ✔${RESET}"
    echo -e "${GREEN}使用方法查看文档:https://github.com/xtianowner/gproxy-tool${RESET}"
}

# ========= 首次测试 =========
test_gproxy(){
    echo -e "${GREEN}运行加速测试...${RESET}"
    gproxy curl -I https://www.google.com || true
}

# ========= 更新 =========
update_gproxy(){

    if [[ ! -d "$GPROXY_DIR" ]]; then
        echo -e "${RED}未安装${RESET}"
        return
    fi

    echo -e "${GREEN}更新中...${RESET}"

    cd "$GPROXY_DIR"
    git pull
    sudo sh install.sh

    echo -e "${GREEN}更新完成 ✔${RESET}"
}

# ========= 卸载 =========
uninstall_gproxy(){

    read -rp "确认卸载 GProxy？(y/N): " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && return

    if [[ -f "$GPROXY_DIR/uninstall.sh" ]]; then
        sudo sh "$GPROXY_DIR/uninstall.sh"
    fi

    rm -rf "$GPROXY_DIR"
    rm -rf "$BASE_DIR"

    echo -e "${RED}已卸载完成${RESET}"
    echo -e "${YELLOW}提示：请手动检查 ~/.ssh/authorized_keys 移除不需要的公钥。${RESET}"
}

# ========= 配置管理 =========
config_gproxy(){
    echo -e "${GREEN}--- GProxy 配置管理 ---${RESET}"
    echo -e "${GREEN}1. 重新配置服务器信息 (gproxy --config)${RESET}"
    echo -e "${GREEN}2. 修改本地代理端口 (默认 19527)${RESET}"
    read -p "请选择操作: " cfg_num

    case "$cfg_num" in
        1)
            # 调用原生命令重新配置
            gproxy --config
            ;;
        2)
            # 修改本地端口
            TUNNEL_FILE="/usr/lib/gproxy/lib/tunnel.sh"
            if [[ ! -f "$TUNNEL_FILE" ]]; then
                echo -e "${RED}错误: 找不到配置文件 $TUNNEL_FILE${RESET}"
                return
            fi

            # 获取当前端口
            CURRENT_PORT=$(grep "LOCAL_PORT=" "$TUNNEL_FILE" | cut -d'=' -f2)
            echo -e "${YELLOW}当前本地端口为: $CURRENT_PORT${RESET}"
            read -p "请输入新的本地端口: " NEW_PORT

            if [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then
                # 使用 sed 直接替换
                sudo sed -i "s/LOCAL_PORT=$CURRENT_PORT/LOCAL_PORT=$NEW_PORT/g" "$TUNNEL_FILE"
                echo -e "${GREEN}端口已成功修改为 $NEW_PORT ✔${RESET}"
                echo -e "${YELLOW}提示：请运行 'gproxy stop' 然后 'gproxy start' 重启服务以生效。${RESET}"
            else
                echo -e "${RED}输入无效，请输入数字端口。${RESET}"
            fi
            ;;
        *)
            echo -e "${RED}无效选项${RESET}"
            ;;
    esac
}
# ========= 菜单 =========
menu(){

while true
do
clear
echo -e "${GREEN}GProxySSH隧道加速管理器${RESET}"
echo -e "${GREEN}1. SSH密钥自动配置${RESET}"
echo -e "${GREEN}2. 安装GProxy${RESET}"
echo -e "${GREEN}3. 加速测试(curlGoogle)${RESET}"
echo -e "${GREEN}4. 更新GProxy${RESET}"
echo -e "${GREEN}5. 配置管理 (修改服务器/端口)${RESET}" 
echo -e "${GREEN}6. 卸载GProxy${RESET}"
echo -e "${GREEN}0. 退出${RESET}"
read -p "$(echo -e ${GREEN}请选择操作: ${RESET})" num
case "$num" in
1) setup_ssh ; pause ;;
2) install_gproxy ; pause ;;
3) test_gproxy ; pause ;;
4) update_gproxy ; pause ;;
5) config_gproxy ; pause ;; 
6) uninstall_gproxy ; pause ;;
0) exit 0 ;;
*) echo -e "${GREEN}无效选项${RESET}" ; sleep 1 ;;
esac

done
}

menu
