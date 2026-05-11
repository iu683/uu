#!/bin/bash

# 颜色定义
G='\033[0;32m' # 绿
B='\033[0;34m' # 蓝
Y='\033[1;33m' # 黄
C='\033[0;36m' # 青
R='\033[0;31m' # 红
NC='\033[0m'    # 无色

# 检查 Docker 状态
if ! docker info > /dev/null 2>&1; then
    echo -e "${R}错误: Docker 未运行。${NC}"
    exit 1
fi

clear
echo -e "${B}================================================================================${NC}"
echo -e "${Y}          🚀 Docker 容器资源占用 (按内存排序)${NC}"
echo -e "${B}================================================================================${NC}"

# 1. 获取基础数据并处理
# 使用 docker stats 获取数据，用 " | " 作为分隔符以便 column 处理
raw_data=$(docker stats --no-stream --format "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}")

# 2. 构建带磁盘空间的临时数据
processed_data=""
while IFS='|' read -r name cpu mem; do
    # 获取磁盘占用：只提取第一部分大小，不带任何空格或括号
    # 使用 docker inspect 辅助确保获取该容器的真实 RW 层大小
    disk=$(docker ps -s --filter "name=^/${name}$" --format "{{.Size}}" | awk '{print $1}')
    
    # 拼接一行数据
    processed_data+="${name}|${cpu}|${mem}|${disk}\n"
done <<< "$raw_data"

# 3. 打印表头并使用 column 自动对齐
# 先输出表头，再通过 sort 排序，最后通过 column 对齐
(
echo -e "${C}容器名称|CPU占用|内存使用|磁盘空间(RW层)${NC}"
echo -e "${processed_data}" | sort -t'|' -k3 -hr
) | column -t -s '|'

echo -e "${B}--------------------------------------------------------------------------------${NC}"
echo -e "${G}总计占用:${NC} $(docker system df | grep 'Containers' | awk '{print $4}')"
echo -e "${B}================================================================================${NC}"
