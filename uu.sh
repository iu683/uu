#!/bin/bash

# ==========================================
# VPS AI 工具与 Agent 自动化检测脚本 
# ==========================================

# 颜色定义
G='\033[0;32m'   # 绿色 (Green)
R='\033[0;31m'   # 红色 (Red)
Y='\033[1;33m'   # 黄色 (Yellow)
B='\033[0;34m'   # 蓝色 (Blue)
NC='\033[0m'     # 无颜色 (No Color)

echo -e "${G}========================================${NC}"
echo -e "${G}                 AI工具检测            ${NC}"
echo -e "${G}========================================${NC}"

# 树状格式化输出函数
print_result() {
    local name=$1
    local location=$2
    local version=$3
    local status=$4

    # 头部：工具名称
    echo -e "${B}◈ 工具: ${NC}${Y}${name}${NC}"

    if [ "$location" == "未安装" ]; then
        # 未安装直接精简输出
        echo -e "  └─ ${R}安装状态: 未安装${NC}"
    else
        # 已安装时的树状输出
        echo -e "  ├─ ${G}安装路径: ${NC}${location}"
        
        # 处理版本号为空的情况并去除多余空白字符
        version=$(echo "$version" | xargs)
        echo -e "  ├─ ${G}当前版本: ${NC}${version:-未知}"
        
        # 状态着色逻辑
        if [[ "$status" =~ "运行中" ]]; then
            local STATUS_COLOR="${G}"
        else
            local STATUS_COLOR="${Y}"
        fi
        echo -e "  └─ ${G}活跃状态: ${NC}${STATUS_COLOR}${status}${NC}"
    fi
    echo -e "${B}----------------------------------------${NC}"
}

# 安全获取命令版本的函数，防止命令阻塞
get_version() {
    local cmd=$1
    local args=$2
    if command -v timeout &> /dev/null; then
        timeout 2s $cmd $args 2>&1 | head -n 1
    else
        $cmd $args 2>&1 | head -n 1
    fi
}

# 检查 Docker 容器状态的辅助函数
check_docker_container() {
    local keyword=$1
    if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
        # 寻找匹配的、处于运行状态的容器
        local container_info=$(docker ps --format "{{.ID}} [{{.Names}}] ({{.Image}})" | grep -i "$keyword" | head -n 1)
        if [ -n "$container_info" ]; then
            echo "$container_info"
        fi
    fi
}

# ==========================================
# 工具检测核心逻辑
# ==========================================

# 1. Claude Code 检测
if command -v claude &> /dev/null; then
    loc=$(which claude)
    ver=$(get_version "claude" "--version")
    if pgrep -f "claude" > /dev/null; then status="运行中 (Running)"; else status="已安装/闲置 (Idle)"; fi
else
    loc="未安装"; ver=""; status=""
fi
print_result "Claude Code" "$loc" "$ver" "$status"

# 2. Codex CLI 检测
if command -v codex &> /dev/null; then
    loc=$(which codex)
    ver=$(get_version "codex" "--version")
    if pgrep -f "codex" > /dev/null; then status="运行中 (Running)"; else status="已安装/闲置 (Idle)"; fi
else
    loc="未安装"; ver=""; status=""
fi
print_result "Codex CLI (OpenAI)" "$loc" "$ver" "$status"

# 3. Gemini CLI 检测
if command -v gemini &> /dev/null; then
    loc=$(which gemini)
    ver=$(get_version "gemini" "--version")
    if pgrep -f "gemini" > /dev/null; then status="运行中 (Running)"; else status="已安装/闲置 (Idle)"; fi
else
    loc="未安装"; ver=""; status=""
fi
print_result "Gemini CLI" "$loc" "$ver" "$status"

# 4. OpenCode 检测
if command -v opencode &> /dev/null; then
    loc=$(which opencode)
    ver=$(get_version "opencode" "--version")
    if pgrep -f "opencode" > /dev/null; then status="运行中 (Running)"; else status="已安装/闲置 (Idle)"; fi
elif command -v open-code &> /dev/null; then
    loc=$(which open-code)
    ver=$(get_version "open-code" "--version")
    if pgrep -f "open-code" > /dev/null; then status="运行中 (Running)"; else status="已安装/闲置 (Idle)"; fi
else
    loc="未安装"; ver=""; status=""
fi
print_result "OpenCode" "$loc" "$ver" "$status"

# 5. OpenClaw 检测 (加入 Docker 联动)
docker_res=$(check_docker_container "openclaw\|clawdbot")

if [ -n "$docker_res" ]; then
    loc="Docker Container ($docker_res)"
    ver="Docker Managed"
    status="运行中 (Running)"
elif command -v openclaw &> /dev/null || command -v clawdbot &> /dev/null; then
    loc=$(which openclaw 2>/dev/null || which clawdbot)
    ver=$(get_version "$loc" "--version")
    if pgrep -f "openclaw\|clawdbot" > /dev/null; then status="运行中 (Running)"; else status="已安装/闲置 (Idle)"; fi
elif command -v pip &> /dev/null && pip show openclaw &> /dev/null; then
    loc="Python Pip Package"
    ver=$(pip show openclaw | grep -i "^Version:" | cut -d' ' -f2)
    if pgrep -f "openclaw" > /dev/null; then status="运行中 (Running)"; else status="已安装/闲置 (Idle)"; fi
else
    loc="未安装"; ver=""; status=""
fi
print_result "OpenClaw" "$loc" "$ver" "$status"

# 6. Hermes Agent 检测 (加入 Docker 联动)
docker_res=$(check_docker_container "hermes")

if [ -n "$docker_res" ]; then
    loc="Docker Container ($docker_res)"
    ver="Docker Managed"
    status="运行中 (Running)"
elif command -v hermes &> /dev/null || command -v hermes-agent &> /dev/null; then
    loc=$(which hermes 2>/dev/null || which hermes-agent)
    ver=$(get_version "$loc" "--version")
    if pgrep -f "hermes" > /dev/null; then status="运行中 (Running)"; else status="已安装/闲置 (Idle)"; fi
elif command -v npm &> /dev/null && npm list -g --depth=0 hermes-agent &> /dev/null; then
    loc="NPM Global Module"
    ver=$(npm list -g --depth=0 hermes-agent | grep hermes-agent | awk -F@ '{print $2}')
    status="已安装 (可通过 npm 启动)"
elif command -v pip &> /dev/null && pip show hermes-agent &> /dev/null; then
    loc="Python Pip Package"
    ver=$(pip show hermes-agent | grep -i "^Version:" | cut -d' ' -f2)
    status="已安装 (可通过 python 运行)"
else
    loc="未安装"; ver=""; status=""
fi
print_result "Hermes Agent" "$loc" "$ver" "$status"
