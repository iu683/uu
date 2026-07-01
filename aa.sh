#!/bin/bash

# 颜色定义
G='\033[0;32m' # 绿
B='\033[0;34m' # 蓝
Y='\033[1;33m' # 黄
R='\033[0;31m' # 红
NC='\033[0m'   # 无色

# 1. 严格的环境检查
if ! command -v docker &> /dev/null; then
    echo -e "${R}❌ 错误: 未检测到 Docker，请先安装！${NC}"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo -e "${R}❌ 错误: Docker 服务未启动或无权限！${NC}"
    exit 1
fi

# 2. 静默执行清理并判断结果
echo -e "${Y}⏳ 正在一键清理未使用的 Docker 镜像与数据卷...${NC}"

if docker image prune -a -f && docker volume prune -f; then
    echo -e "${G}✅ 清理完成！系统空间已释放。${NC}"
else
    echo -e "${R}❌ 清理失败，请检查 Docker 状态或权限！${NC}"
    exit 1
fi
