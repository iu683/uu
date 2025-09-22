#!/bin/bash
# Sestea 管理脚本

SERVICE_NAME="sestea"
INSTALL_DIR="/opt/$SERVICE_NAME"
PY_FILE="$INSTALL_DIR/sestea.py"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
PORT_FILE="$INSTALL_DIR/port.conf"
DEFAULT_PORT=7122

# 颜色
GREEN="\e[32m"
RESET="\e[0m"

get_port() {
    if [ -f "$PORT_FILE" ]; then
        cat "$PORT_FILE"
    else
        echo "$DEFAULT_PORT"
    fi
}

check_env() {
    echo ">>> 检查运行环境..."
    if ! command -v python3 &>/dev/null; then
        echo ">>> 未检测到 python3，正在安装..."
        if command -v apt &>/dev/null; then
            apt update -y && apt install -y python3 python3-pip curl
        elif command -v yum &>/dev/null; then
            yum install -y python3 python3-pip curl
        elif command -v dnf &>/dev/null; then
            dnf install -y python3 python3-pip curl
        else
            echo "请手动安装 python3"
            exit 1
        fi
    fi

    if ! python3 -m pip show psutil &>/dev/null; then
        echo ">>> 未检测到 psutil，正在安装..."
        python3 -m pip install --upgrade pip
        python3 -m pip install psutil
    fi
}

get_public_ip() {
    ip=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || curl -s api.ipify.org)
    echo "$ip"
}

install_sestea() {
    check_env
    PORT=$(get_port)
    echo ">>> 安装 Sestea 服务 (端口: $PORT)..."
    mkdir -p $INSTALL_DIR

    # 写入 Python 文件
    cat > $PY_FILE <<EOF
#!/usr/bin/env python3
# Sestea

import http.server
import socketserver
import json
import time
import psutil

port = $PORT

class RequestHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()

        time.sleep(1)

        cpu_usage = psutil.cpu_percent()
        mem_usage = psutil.virtual_memory().percent
        bytes_sent = psutil.net_io_counters().bytes_sent
        bytes_recv = psutil.net_io_counters().bytes_recv
        bytes_total = bytes_sent + bytes_recv

        utc_timestamp = int(time.time())
        uptime = int(time.time() - psutil.boot_time())
        last_time = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())

        response_dict = {
            "utc_timestamp": utc_timestamp,
            "uptime": uptime,
            "cpu_usage": cpu_usage,
            "mem_usage": mem_usage,
            "bytes_sent": str(bytes_sent),
            "bytes_recv": str(bytes_recv),
            "bytes_total": str(bytes_total),
            "last_time": last_time
        }

        response_json = json.dumps(response_dict).encode('utf-8')
        self.wfile.write(response_json)

    def log_message(self, format, *args):
        return

with socketserver.ThreadingTCPServer(("", port), RequestHandler) as httpd:
    try:
        print(f"Serving at port {port}")
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("Shutting down server...")
        httpd.shutdown()
EOF

    chmod +x $PY_FILE

    # 写入 systemd 服务
    cat > $SERVICE_FILE <<EOF
[Unit]
Description=Sestea Monitoring Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 $PY_FILE
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # 重新加载 systemd 并启动
    systemctl daemon-reexec
    systemctl enable --now $SERVICE_NAME

    public_ip=$(get_public_ip)
    echo ">>> 安装完成，服务已启动"
    echo -e "访问地址: ${GREEN}http://$public_ip:$PORT/${RESET}"
}

uninstall_sestea() {
    echo ">>> 卸载 Sestea 服务..."
    systemctl stop $SERVICE_NAME
    systemctl disable $SERVICE_NAME
    rm -f $SERVICE_FILE
    rm -rf $INSTALL_DIR
    systemctl daemon-reexec
    echo ">>> 已卸载完成"
}

start_sestea() {
    systemctl start $SERVICE_NAME
    echo ">>> 服务已启动"
}

stop_sestea() {
    systemctl stop $SERVICE_NAME
    echo ">>> 服务已停止"
}

status_sestea() {
    systemctl status $SERVICE_NAME --no-pager
}

change_port() {
    read -p "请输入新的端口号: " new_port
    if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -le 0 ] || [ "$new_port" -gt 65535 ]; then
        echo "无效端口号"
        return
    fi
    echo "$new_port" > $PORT_FILE
    echo "端口已修改为 $new_port，请卸载后，重新安装服务。"
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}======================${RESET}"
        echo -e "${GREEN}   Sestea 管理菜单     ${RESET}"
        echo -e "${GREEN}======================${RESET}"
        echo -e "${GREEN}1. 安装/部署${RESET}"
        echo -e "${GREEN}2. 启动${RESET}"
        echo -e "${GREEN}3. 停止${RESET}"
        echo -e "${GREEN}4. 查看状态${RESET}"
        echo -e "${GREEN}5. 卸载${RESET}"
        echo -e "${GREEN}6. 修改端口${RESET}"
        echo -e "${GREEN}0. 退出${RESET}"
        echo -e "${GREEN}======================${RESET}"
        read -p "请输入选项: " choice

        case $choice in
            1) install_sestea ;;
            2) start_sestea ;;
            3) stop_sestea ;;
            4) status_sestea ;;
            5) uninstall_sestea ;;
            6) change_port ;;
            0) exit 0 ;;
            *) echo "无效选项" ;;
        esac

        read -p "按回车键继续..."
    done
}

menu
