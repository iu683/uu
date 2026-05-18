#!/bin/bash

# ==========================================
# VPS AI 工具与 Agent 自动化检测脚本
# ==========================================

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}       AI 命令行工具 / Agent 环境检测          ${NC}"
echo -e "${BLUE}==================================================${NC}"

# 格式化输出函数
print_result() {
    local name=$1
    local location=$2
    local version=$3
    local status=$4

    echo -e "${YELLOW}[+] 工具名称:${NC} ${name}"
    if [ "$location" == "未安装" ]; then
        echo -e "  - ${RED}安装状态:${NC} 未检测到二进制文件或全局命令"
    else
        echo -e "  - ${GREEN}安装路径:${NC} ${location}"
        echo -e "  - ${GREEN}当前版本:${NC} ${version}"
        echo -e "  - ${GREEN}活跃状态:${NC} ${status}"
    fi
    echo -e "--------------------------------------------------"
}

# 1. Claude Code 检测 (Anthropic 官方 CLI)
if command -v claude &> /dev/null; then
    loc=$(which claude)
    ver=$(claude --version 2>&1 | head -n 1)
    # 检测是否有相关进程在后台运行
    if pgrep -f "claude" > /dev/null; then status="运行中 (Running)"; else status="已安装/闲置 (Idle)"; fi
else
    loc="未安装"; ver=""; status=""
fi
print_result "Claude Code" "$loc" "$ver" "$status"

# 2. Codex CLI 检测 (OpenAI 官方本地开发 CLI)
if command -v codex &> /dev/null; then
    loc=$(which codex)
    ver=$(codex --version 2>&1 | head -n 1)
    if pgrep -f "codex" > /dev/null; then status="运行中 (Running)"; else status="已安装/闲置 (Idle)"; fi
else
    loc="未安装"; ver=""; status=""
fi
print_result "Codex CLI (OpenAI)" "$loc" "$ver" "$status"

# 3. Gemini CLI 检测 (Google 官方终端 AI Agent)
if command -v gemini &> /dev/null; then
    loc=$(which gemini)
    ver=$(gemini --version 2>&1 | head -n 1)
    if pgrep -f "gemini" > /dev/null; then status="运行中 (Running)"; else status="已安装/闲置 (Idle)"; fi
else
    loc="未安装"; ver=""; status=""
fi
print_result "Gemini CLI" "$loc" "$ver" "$status"

# 4. OpenCode 检测 (开源 AI 编码辅助工具)
if command -v opencode &> /dev/null; then
    loc=$(which opencode)
    ver=$(opencode --version 2>&1 | head -n 1)
    if pgrep -f "opencode" > /dev/null; then status="运行中 (Running)"; else status="已安装/闲置 (Idle)"; fi
else
    # 兼容性检查，部分用户可能映射为 open-code
    if command -v open-code &> /dev/null; then
        loc=$(which open-code)
        ver=$(open-code --version 2>&1 | head -n 1)
        if pgrep -f "open-code" > /dev/null; then status="运行中 (Running)"; else status="已安装/闲置 (Idle)"; fi
    else
        loc="未安装"; ver=""; status=""
    fi
fi
print_result "OpenCode" "$loc" "$ver" "$status"

# 5. OpenClaw 检测 (开源多模态/IM 自动化 Agent 框架)
# OpenClaw 常常通过 Python 模块或独立命令 openclaw 运行
if command -v openclaw &> /dev/null || command -v clawdbot &> /dev/null; then
    loc=$(which openclaw 2>/dev/null || which clawdbot)
    ver=$($loc --version 2>&1 | head -n 1)
    if pgrep -f "openclaw\|clawdbot" > /dev/null; then status="运行中 (Running)"; else status="已安装/闲置 (Idle)"; fi
else
    # 检查常见的 python 虚拟环境/全局包形式
    if pip show openclaw &> /dev/null; then
        loc="Python Pip Package ($(pip show openclaw | grep Location | awk '{print $2}'))"
        ver=$(pip show openclaw | grep Version | awk '{print $2}')
        if pgrep -f "openclaw" > /dev/null; then status="运行中 (Running)"; else status="已安装/闲置 (Idle)"; fi
    else
        loc="未安装"; ver=""; status=""
    fi
fi
print_result "OpenClaw" "$loc" "$ver" "$status"

# 6. Hermes Agent 检测 (基于 Nous Hermes 模型的自主 Agent 节点)
if command -v hermes &> /dev/null || command -v hermes-agent &> /dev/null; then
    loc=$(which hermes 2>/dev/null || which hermes-agent)
    ver=$($loc --version 2>&1 | head -n 1)
    if pgrep -f "hermes" > /dev/null; then status="运行中 (Running)"; else status="已安装/闲置 (Idle)"; fi
else
    # 检查是否作为 Node.js 全局模块或独立 Python 包
    if npm list -g hermes-agent &> /dev/null; then
        loc="NPM Global Module"
        ver=$(npm list -g hermes-agent | grep hermes-agent | awk -F@ '{print $2}')
        status="已安装 (可通过 npm 启动)"
    elif pip show hermes-agent &> /dev/null; then
        loc="Python Pip Package"
        ver=$(pip show hermes-agent | grep Version | awk '{print $2}')
        status="已安装 (可通过 python 运行)"
    else
        loc="未安装"; ver=""; status=""
    fi
fi
print_result "Hermes Agent" "$loc" "$ver" "$status"
