#!/bin/bash
# ==========================================
# FRP-Panel Master 管理脚本
# 统一目录: /opt/frp/Master
# 支持安装/卸载/更新/查看日志
# 卸载可选择是否清理数据
# 部署完成后返回菜单
# 菜单字体为绿色
# ==========================================

set -e

BASE_DIR="/opt/frp/Master"
DATA_DIR="$BASE_DIR/data"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# -----------------------------
# 颜色定义
# -----------------------------
GREEN='\033[0;32m'
NC='\033[0m'  # No Color

# -----------------------------
# docker-compose 兼容
# -----------------------------
DOCKER_COMPOSE=$(command -v docker-compose || command -v "docker compose")

while true; do
    echo -e "${GREEN}===== Master 管理菜单 =======${NC}"
    echo -e "${GREEN}1) 安装部署 Master${NC}"
    echo -e "${GREEN}2) 卸载 Master${NC}"
    echo -e "${GREEN}3) 更新 Master${NC}"
    echo -e "${GREEN}4) 查看 Master 日志${NC}"
    echo -e "${GREEN}0) 退出${NC}"
    read -p "输入选项 : " choice

    case "$choice" in
    1)
        # -----------------------------
        # 安装 / 部署 Master
        # -----------------------------
        read -p "请输入 Master 密钥 (APP_GLOBAL_SECRET): " APP_SECRET
        [ -z "$APP_SECRET" ] && { echo "密钥不能为空！"; continue; }

        read -p "请输入 Master RPC 绑定 IP 或域名 (默认 127.0.0.1): " MASTER_RPC_HOST
        MASTER_RPC_HOST=${MASTER_RPC_HOST:-127.0.0.1}

        read -p "请输入 Master RPC 端口 (默认 9001): " RPC_PORT
        RPC_PORT=${RPC_PORT:-9001}

        read -p "请输入 Master API IP 或域名 (默认 127.0.0.1): " MASTER_API_HOST
        MASTER_API_HOST=${MASTER_API_HOST:-127.0.0.1}

        read -p "请输入 Master API 端口 (默认 9000): " API_PORT
        API_PORT=${API_PORT:-9000}

        read -p "请输入 Master API 协议 (默认 http): " MASTER_API_SCHEME
        MASTER_API_SCHEME=${MASTER_API_SCHEME:-http}

        # 创建目录
        mkdir -p "$DATA_DIR"

        # 生成 docker-compose.yml
        cat > "$COMPOSE_FILE" <<EOF
services:
  frpp-master:
    image: vaalacat/frp-panel:latest
    network_mode: host
    environment:
      APP_GLOBAL_SECRET: $APP_SECRET
      MASTER_RPC_HOST: $MASTER_RPC_HOST
      MASTER_RPC_PORT: $RPC_PORT
      MASTER_API_HOST: $MASTER_API_HOST
      MASTER_API_PORT: $API_PORT
      MASTER_API_SCHEME: $MASTER_API_SCHEME
    volumes:
      - $DATA_DIR:/data
    restart: unless-stopped
    command: master
EOF

        echo -e "${GREEN}docker-compose.yml 已生成: $COMPOSE_FILE${NC}"
        echo -e "${GREEN}启动 FRP-Panel Master...${NC}"
        cd "$BASE_DIR"
        $DOCKER_COMPOSE up -d
        echo -e "${GREEN}✅ 部署完成！${NC}"
        echo -e "${GREEN}访问地址: ${MASTER_API_SCHEME}://${MASTER_API_HOST}:${API_PORT}${NC}"
        ;;
    2)
        # -----------------------------
        # 卸载 Master
        # -----------------------------
        echo -e "${GREEN}停止并移除 Master...${NC}"
        cd "$BASE_DIR"
        $DOCKER_COMPOSE down || true

        read -p "是否删除目录 $BASE_DIR ? [y/N]: " del_data
        if [[ "$del_data" =~ ^[Yy]$ ]]; then
            rm -rf "$BASE_DIR"
            echo -e "${GREEN}✅ $BASE_DIR 已删除${NC}"
        else
            echo -e "${GREEN}保留目录: $BASE_DIR${NC}"
        fi
        ;;
    3)
        # -----------------------------
        # 更新 Master 镜像
        # -----------------------------
        echo -e "${GREEN}拉取最新镜像...${NC}"
        cd "$BASE_DIR"
        $DOCKER_COMPOSE pull
        echo -e "${GREEN}重新启动 Master...${NC}"
        $DOCKER_COMPOSE up -d
        echo -e "${GREEN}✅ Master 已更新${NC}"
        ;;
    4)
        # -----------------------------
        # 查看日志
        # -----------------------------
        echo -e "${GREEN}显示 Master 日志 (Ctrl+C 退出)...${NC}"
        cd "$BASE_DIR"
        $DOCKER_COMPOSE logs -f
        ;;
    0)
        echo -e "${GREEN}退出脚本${NC}"
        exit 0
        ;;
    *)
        echo -e "${GREEN}无效选项，请重新输入${NC}"
        ;;
    esac
done
