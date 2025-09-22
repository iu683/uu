#!/bin/bash
# ServerTraffic 管理脚本（菜单版，绿色字体，直接使用系统 Python + 系统 psutil）

SERVICE_NAME="servertraffic"
PY_FILE="/root/${SERVICE_NAME}.py"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# 颜色
GREEN="\e[32m"
RESET="\e[0m"

# 安装服务
install_service() {
    read -p "请输入服务端口（默认7122）: " PORT
    PORT=${PORT:-7122}
    echo -e "${GREEN}安装 ServerTraffic 服务，端口: $PORT${RESET}"

    # 检查 Python3
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${GREEN}Python3 未安装，正在安装...${RESET}"
        apt update
        apt install -y python3
    else
        echo -e "${GREEN}Python3 已安装: $(python3 --version)${RESET}"
    fi

    # 安装系统依赖 psutil
    apt install -y python3-psutil

    # 写入 Python 脚本
    cat > "$PY_FILE" <<EOF
#!/usr/bin/env python3
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
        net = psutil.net_io_counters()
        bytes_sent = net.bytes_sent
        bytes_recv = net.bytes_recv
        bytes_total = bytes_sent + bytes_recv
        response_dict = {
            "utc_timestamp": int(time.time()),
            "uptime": int(time.time() - psutil.boot_time()),
            "cpu_usage": cpu_usage,
            "mem_usage": mem_usage,
            "bytes_sent": str(bytes_sent),
            "bytes_recv": str(bytes_recv),
            "bytes_total": str(bytes_total),
            "last_time": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
        }
        self.wfile.write(json.dumps(response_dict).encode('utf-8'))

with socketserver.ThreadingTCPServer(("", port), RequestHandler) as httpd:
    try:
        print(f"Serving at port {port}")
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("KeyboardInterrupt captured, exiting")
EOF

    chmod +x "$PY_FILE"

    # 创建 systemd 服务
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Server Traffic Monitor

[Service]
Type=simple
WorkingDirectory=/root/
User=root
ExecStart=/usr/bin/python3 $PY_FILE
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    # 启动并开机自启
    systemctl daemon-reload
    systemctl start "$SERVICE_NAME"
    systemctl enable "$SERVICE_NAME"
    echo -e "${GREEN}安装完成，服务正在运行。${RESET}"
}

# 卸载服务
uninstall_service() {
    echo -e "${GREEN}卸载 ServerTraffic 服务...${RESET}"
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -f "$PY_FILE"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${RESET}"
}

# 查看状态
status_service() {
    systemctl status "$SERVICE_NAME" --no-pager
}

# 菜单循环
while true; do
    echo -e "${GREEN}======================================${RESET}"
    echo -e "${GREEN}        ServerTraffic 管理菜单        ${RESET}"
    echo -e "${GREEN}======================================${RESET}"
    echo -e "${GREEN}1) 安装服务${RESET}"
    echo -e "${GREEN}2) 卸载服务${RESET}"
    echo -e "${GREEN}3) 查看服务状态${RESET}"
    echo -e "${GREEN}4) 退出${RESET}"
    read -p "$(echo -e ${GREEN}请选择操作 [1-4]: ${RESET})" choice

    case "$choice" in
        1)
            install_service
            ;;
        2)
            uninstall_service
            ;;
        3)
            status_service
            ;;
        4)
            echo -e "${GREEN}退出脚本${RESET}"
            exit 0
            ;;
        *)
            echo -e "${GREEN}无效选项，请重新选择${RESET}"
            ;;
    esac
done
