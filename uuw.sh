#!/bin/bash
# Docker 容器监控管理脚本（菜单版，绿色字体，可自定义端口）

SERVICE_NAME="docker-container-monitor"
PY_FILE="/root/docker_container_monitor.py"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# 颜色
GREEN="\e[32m"
RESET="\e[0m"

# 安装服务
install_service() {
    read -p "请输入服务端口（默认7124）: " PORT
    PORT=${PORT:-7124}
    echo -e "${GREEN}安装 Docker 容器监控服务，端口: $PORT${RESET}"

    # 检查 Python3
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${GREEN}Python3 未安装，正在安装...${RESET}"
        apt update
        apt install -y python3
    else
        echo -e "${GREEN}Python3 已安装: $(python3 --version)${RESET}"
    fi

    # 写入 Python 脚本
    cat > "$PY_FILE" <<EOF
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import time

PORT = $PORT

class DockerContainerMonitor(http.server.BaseHTTPRequestHandler):
    def get_docker_status(self):
        try:
            subprocess.run(["docker", "info"], capture_output=True, text=True, check=True)
            docker_status = "运行中"
        except subprocess.CalledProcessError:
            docker_status = "未运行"

        try:
            total = len(subprocess.check_output(["docker", "ps", "-a", "-q"]).decode().splitlines())
            running = len(subprocess.check_output(["docker", "ps", "-q"]).decode().splitlines())
        except Exception:
            total = 0
            running = 0

        return {
            "docker_status": docker_status,
            "total_containers": total,
            "running_containers": running
        }

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        response = self.get_docker_status()
        response["last_time"] = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
        self.wfile.write(json.dumps(response, indent=2).encode('utf-8'))

with socketserver.ThreadingTCPServer(("", PORT), DockerContainerMonitor) as httpd:
    print(f"Serving Docker 容器监控服务 at port {PORT}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("KeyboardInterrupt captured, exiting")
EOF

    chmod +x "$PY_FILE"

    # 创建 systemd 服务
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Docker 容器监控服务
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=/root
ExecStart=/usr/bin/python3 $PY_FILE
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    # 启动并开机自启
    systemctl daemon-reload
    systemctl start "$SERVICE_NAME"
    systemctl enable "$SERVICE_NAME"
    echo -e "${GREEN}安装完成，服务正在运行。访问端口: $PORT${RESET}"
}

# 卸载服务
uninstall_service() {
    echo -e "${GREEN}卸载 Docker 容器监控服务...${RESET}"
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
    echo -e "${GREEN}        Docker 容器监控管理菜单       ${RESET}"
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
