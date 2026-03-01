#!/bin/bash

# ================== 颜色定义 ==================
green="\033[32m"
re="\033[0m"

# ================== 工具函数 ==================
random_port() {
    shuf -i 2000-65000 -n 1
}

random_password() {
    # 生成12位随机密码
    tr -dc A-Za-z0-9 </dev/urandom | head -c12
}


setup_port_jump() {
    local target_port=$1  # Hysteria监听端口
    read -p "是否启用端口跳跃？[1=单端口 2=端口范围]: " jumpInput
    if [[ $jumpInput == 2 ]]; then
        read -p "设置范围端口的起始端口 (10000-65535): " firstport
        read -p "设置范围端口的末尾端口 (10000-65535): " endport

        while [[ $firstport -ge $endport ]]; do
            echo -e "${green}起始端口必须小于末尾端口，请重新输入${re}"
            read -p "起始端口: " firstport
            read -p "末尾端口: " endport
        done

        # 遍历检查端口是否被占用
        for ((p=firstport; p<=endport; p++)); do
            if ss -u -l -n | grep -qw ":$p"; then
                echo -e "${green}端口 $p 已被占用，请重新选择范围${re}"
                return
            fi
        done

        # 添加iptables规则
        iptables -t nat -A PREROUTING -p udp --dport $firstport:$endport -j DNAT --to-destination 127.0.0.1:$target_port
        ip6tables -t nat -A PREROUTING -p udp --dport $firstport:$endport -j DNAT --to-destination [::1]:$target_port
        netfilter-persistent save >/dev/null 2>&1

        echo -e "${green}端口跳跃已启用：$firstport-$endport -> $target_port${re}"
    else
        echo -e "${green}使用单端口模式${re}"
    fi
}

check_udp_port() {
    local port=$1
    while ss -u -l -n | awk '{print $5}' | grep -w ":$port" >/dev/null 2>&1; do
        echo -e "${green}${port}端口已经被其他程序占用，请更换端口重试${re}"
        read -p "请输入端口（回车随机端口）: " port
        [[ -z $port ]] && port=$(random_port)
    done
    echo $port
}

open_firewall_port() {
    local port=$1
    if command -v ufw >/dev/null 2>&1; then
        ufw allow $port/udp >/dev/null 2>&1
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=${port}/udp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p udp --dport $port -j ACCEPT >/dev/null 2>&1 || \
        iptables -I INPUT -p udp --dport $port -j ACCEPT
    fi
}

show_status() {
    clear
    echo -e "${green}Hysteria2 服务状态：${re}"
    if [ -f "/etc/alpine-release" ]; then
        if pgrep -f '[w]eb' >/dev/null 2>&1; then
            echo -e "${green}运行中 (Alpine版)${re}"
            echo -e "${green}监听端口: $(grep -Po '(?<=listen: :)[0-9]+' /root/config.yaml)${re}"
        else
            echo -e "${green}未运行${re}"
        fi
    else
        if systemctl is-active --quiet hysteria-server.service; then
            echo -e "${green}运行中${re}"
            port=$(grep -Po '(?<=listen: :)[0-9]+' /etc/hysteria/config.yaml)
            echo -e "${green}监听端口: $port${re}"
        else
            echo -e "${green}未运行${re}"
        fi
    fi
    echo
    read -p "按回车返回菜单..."
}

show_client_config() {
    echo
    if [ -f "/etc/alpine-release" ]; then
        port=$(grep -Po '(?<=listen: :)[0-9]+' /root/config.yaml)
        if grep -q "password:" /root/config.yaml; then
            password=$(grep -Po '(?<=password: ).*' /root/config.yaml)
        else
            password=$(random_password)
        fi
    else
        port=$(grep -Po '(?<=listen: :)[0-9]+' /etc/hysteria/config.yaml)
        if grep -q "password:" /etc/hysteria/config.yaml; then
            password=$(grep -Po '(?<=password: ).*' /etc/hysteria/config.yaml)
        else
            password=$(random_password)
        fi
    fi
    ip=$(curl -s https://api.ipify.org)
    echo -e "${green}服务器 IP: $ip${re}"
    echo -e "${green}服务器端口: $port${re}"
    echo -e "${green}协议: hysteria${re}"
    echo -e "${green}密码: $password${re}"
    echo -e "${green}SNI: www.bing.com${re}"
    echo -e "${green}alpn:h3${re}"
    echo
    read -p "按回车返回菜单..."
}

# ================== 主菜单 ==================
while true; do
    clear
    echo -e "${green}==== Hysteria2 管理菜单 ====${re}"
    echo -e "${green}1. 安装Hysteria2${re}"
    echo -e "${green}2. 查看Hysteria2状态${re}"
    echo -e "${green}3. 更换Hysteria2端口${re}"
    echo -e "${green}4. 卸载Hysteria2${re}"
    echo -e "${green}0. 退出${re}"
    read -p "$(echo -e ${green}请选择:${re}) " sub_choice
    case $sub_choice in
        1)
            clear
            read -p $'\033[1;32m请输入Hysteria2节点端口（回车随机端口）：\033[0m' port
            [[ -z $port ]] && port=$(random_port)
            port=$(check_udp_port $port)

            open_firewall_port $port
            # 添加端口跳跃
            setup_port_jump $port

            if [ -f "/etc/alpine-release" ]; then
                SERVER_PORT=$port bash -c "$(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/hy2.sh)"
            else
                HY2_PORT=$port bash -c "$(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/azHysteria2.sh)"
            fi

            echo -e "${green}Hysteria2 安装完成！端口: $port${re}"
            show_client_config
            ;;
        2)
            show_status
            ;;
        3)
            clear
            read -p $'\033[1;32m请输入新的 Hysteria2 端口[1-65535]: \033[0m' new_port
            [[ -z $new_port ]] && new_port=$(random_port)

            new_port=$(check_udp_port $new_port)
            open_firewall_port $new_port
            # 添加端口跳跃
            setup_port_jump $port

            if [ -f "/etc/alpine-release" ]; then
                sed -i "s/^listen: :[0-9]*/listen: :$new_port/" /root/config.yaml
                pkill -f '[w]eb'
                nohup ./web server config.yaml >/dev/null 2>&1 &
            else
                sed -i "s/^listen: :[0-9]*/listen: :$new_port/" /etc/hysteria/config.yaml
                systemctl restart hysteria-server.service
            fi
            echo -e "${green}Hysteria2端口已更换成 $new_port${re}"
            show_client_config
            ;;
        4)
            clear
            if [ -f "/etc/alpine-release" ]; then
                pkill -f '[w]eb'
                pkill -f '[n]pm'
                cd && rm -rf web npm server.crt server.key config.yaml
            else
                systemctl stop hysteria-server.service
                rm -f /usr/local/bin/hysteria
                rm -f /etc/systemd/system/hysteria-server.service
                rm -f /etc/hysteria/config.yaml
                systemctl daemon-reload
            fi
            echo -e "${green}Hysteria2 已彻底卸载${re}"
            read -p "按回车返回菜单..."
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${green}无效的输入！${re}"
            sleep 1
            ;;
    esac
done
