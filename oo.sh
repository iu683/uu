#!/bin/bash

# =======================================================================
# 🦞 OpenClaw 一键管理面板
# =======================================================================

# 终端高亮颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
RESET="\033[0m"

gl_lv="\033[32m"
gl_huang="\033[33m"
gl_hong="\033[31m"
gl_bai="\033[0m"

# 全局环境静态参数
SCRIPT_VERSION="1.3.5"
ENABLE_STATS="true"
gh_proxy=""

# 统一获取 OpenClaw 配置文件路径
openclaw_get_config_file() {
    echo "${HOME}/.openclaw/openclaw.json"
}

# 辅助函数：按键返回
break_end() {
    echo -e "\n${BLUE}----------------------------------------${RESET}"
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo
}

# 辅助函数：基础依赖检查与安装
install() {
    for pkg in "$@"; do
        if ! command -v "$pkg" &>/dev/null; then
            echo "正在安装系统依赖: $pkg..."
            if command -v apt &>/dev/null; then
                sudo apt update -y && sudo apt install -y "$pkg"
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y "$pkg"
            elif command -v yum &>/dev/null; then
                sudo yum install -y "$pkg"
            fi
        fi
    done
}

# 状态遥测发送函数
send_stats() {
    :
}

# 动态获取 OpenClaw 状态、配置数以及核心版本号
get_openclaw_status() {
    # 1. 检测运行状态
    if command -v openclaw &>/dev/null; then
        if pgrep -f "openclaw gateway" &>/dev/null || pgrep -f "gateway" &>/dev/null; then
            STATUS="${GREEN}运行中 (Running)${RESET}"
        else
            STATUS="${RED}已停止 (Stopped)${RESET}"
        fi
        # 2. 动态获取 OpenClaw 核心版本号并精细清洗
        local raw_v
        raw_v=$(openclaw -v 2>/dev/null | head -n 1 || openclaw --version 2>/dev/null | head -n 1 || echo "未知")
        # 去除 ANSI 颜色字符
        raw_v=$(echo "$raw_v" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
        # 精准提取 "OpenClaw " 后面的所有内容
        if [[ "$raw_v" =~ OpenClaw[[:space:]]+(.*) ]]; then
            OPENCLAW_VERSION="${BASH_REMATCH[1]}"
        else
            # 如果没匹配到，则兜底取最后两列
            OPENCLAW_VERSION=$(echo "$raw_v" | awk '{if(NF>1) print $(NF-1)" "$NF; else print $1}')
        fi
    else
        STATUS="${RED}未安装 (Not Installed)${RESET}"
        OPENCLAW_VERSION="${RED}未安装${RESET}"
    fi

    # 3. 获取配置供应商数量
    local config_file
    config_file=$(openclaw_get_config_file)
    if [ -f "$config_file" ] && command -v jq &>/dev/null; then
        CONFIG_COUNT=$(jq '.models.providers | length' "$config_file" 2>/dev/null || echo "0")
    else
        CONFIG_COUNT="0"
    fi
}


# 用于在机器人菜单头部展示本地状态的区块
openclaw_show_bot_local_status_block() {
    local config_file
    config_file=$(openclaw_get_config_file)
    if [ -f "$config_file" ] && command -v jq &>/dev/null; then
        local port
        port=$(jq -r '.gateway.port // .port // "9000"' "$config_file" 2>/dev/null)
        echo -e " 本地网关端口: ${YELLOW}${port}${RESET}"
        echo -n " 接口监听状态: "
        if command -v ss &>/dev/null; then
            if ss -tlnp | grep -q "$port"; then echo -e "${GREEN}正常监听中${RESET}"; else echo -e "${RED}未监听 (请先启动网关)${RESET}"; fi
        else
            if netstat -tlnp | grep -q "$port"; then echo -e "${GREEN}正常监听中${RESET}"; else echo -e "${RED}未监听 (请先启动网关)${RESET}"; fi
        fi
    else
        echo -e " 提示: ${RED}未检测到有效配置，请先执行配置向导。${RESET}"
    fi
}

# 重启消息网关后台
start_gateway() {
    echo "🔄 正在重启 OpenClaw Gateway..."
    openclaw gateway stop >/dev/null 2>&1
    sleep 1
    openclaw gateway start
    sleep 3
}

# 安装环境所依赖的 Node 及编译工具树
install_node_and_tools() {
    if command -v dnf &>/dev/null; then
        curl -fsSL https://rpm.nodesource.com/setup_24.x | sudo bash -
        sudo dnf update -y
        sudo dnf group install -y "Development Tools" "Development Libraries"
        sudo dnf install -y cmake libatomic nodejs
    fi

    if command -v apt &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
        sudo apt update -y
        sudo apt install build-essential python3 libatomic1 nodejs -y
    fi
}

# 同步指定或全量 Sessions 默认模型
openclaw_sync_sessions_model() {
    local target_model="$1"
    echo "🎯 全局会话默认模型已同步变变成: $target_model"
}

# =======================================================================
# 核心数据操作区域 (包含 Python / JQ 以及机器人对接子选单)
# =======================================================================

# 1. 安装 OpenClaw 环境
install_moltbot() {
    echo "开始安装 OpenClaw..."
    send_stats "开始安装 OpenClaw..."
    install git jq curl python3 tmux

    install_node_and_tools

    local country
    country=$(curl -s --max-time 3 ipinfo.io/country)
    if [[ "$country" == "CN" || "$country" == "HK" ]]; then
        npm config set registry https://registry.npmmirror.com
    fi

    git config --global url."${gh_proxy}github.com/".insteadOf ssh://git@github.com/
    git config --global url."${gh_proxy}github.com/".insteadOf git@github.com:

    sudo npm install -g openclaw@latest
    openclaw onboard --install-daemon
    start_gateway
    break_end
}

# 4. 状态日志查看
view_logs() {
    echo "📋 查看 OpenClaw 状态日志"
    send_stats "查看 OpenClaw 日志"
    openclaw status
    echo "----------------------------------------"
    openclaw gateway status
    echo "💡 提示: 正在加载实时日志流，按 Ctrl+C 可退出当前日志模式"
    sleep 2
    openclaw logs
    break_end
}

# =======================================================================
# 核心业务逻辑区域（移除自动探测，完全自维护架构）
# =======================================================================

# 构造模型配置 JSON 节点数组
build-openclaw-provider-models-json() {
    local provider_name="$1"
    local model_ids="$2"
    local models_array="["
    local first=true

    while read -r model_id; do
        [ -z "$model_id" ] && continue
        [[ $first == false ]] && models_array+=","
        first=false

        # 基准默认参数设置
        local context_window=128000
        local max_tokens=4096
        local input_cost=0.15
        local output_cost=0.60

        # 根据特定模型标志智能微调默认权重
        case "$model_id" in
            *opus*|*pro*|*preview*|*thinking*|*sonnet*)
                context_window=200000
                max_tokens=8192
                input_cost=2.00
                output_cost=12.00
                ;;
            *gpt-4*|*gpt-5*|*codex*)
                context_window=128000
                max_tokens=4096
                input_cost=1.25
                output_cost=10.00
                ;;
            *flash*|*lite*|*haiku*|*mini*|*nano*|*deepseek-v3*)
                context_window=64000
                max_tokens=4096
                input_cost=0.10
                output_cost=0.40
                ;;
        esac

        models_array+=$(cat <<EOF
{
    "id": "$model_id",
    "name": "$provider_name / $model_id",
    "input": ["text", "image"],
    "contextWindow": $context_window,
    "maxTokens": $max_tokens,
    "cost": {
        "input": $input_cost,
        "output": $output_cost,
        "cacheRead": 0,
        "cacheWrite": 0
    }
}
EOF
)
    done <<< "$model_ids"

    models_array+="]"
    echo "$models_array"
}

# 写入新添加的 provider 节点 (解除硬编码，严格继承上层传入协议)
write-openclaw-provider-models() {
    local provider_name="$1"
    local base_url="$2"
    local api_key="$3"
    local models_array="$4"
    local api_type="$5"  # 核心修复点：接收明确指定的协议类型
    local config_file
    config_file=$(openclaw_get_config_file)

    [[ -f "$config_file" ]] && cp "$config_file" "${config_file}.bak.$(date +%s)"

    jq --arg prov "$provider_name" \
       --arg url "$base_url" \
       --arg key "$api_key" \
       --arg api "$api_type" \
       --argjson models "$models_array" \
    '
    .models |= (
        (. // { mode: "merge", providers: {} })
        | .mode = "merge"
        | .providers[$prov] = {
            baseUrl: $url,
            apiKey: $key,
            api: $api,
            models: $models
        }
    )
    | .agents |= (. // {})
    | .agents.defaults |= (. // {})
    | .agents.defaults.models |= (
        (if type == "object" then .
         elif type == "array" then reduce .[] as $m ({}; if ($m|type) == "string" then .[$m] = {} else . end)
         else {}
         end) as $existing
        | reduce ($models[]? | .id? // empty | tostring) as $mid (
            $existing;
            if ($mid | length) > 0 then
                .["\($prov)/\($mid)"] //= {}
            else
                .
            end
        )
    )
    ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
}

# 从指定提供商节点拉取全量可用模型
add-all-models-from-provider() {
    local provider_name="$1"
    local base_url="$2"
    local api_key="$3"
    local api_type="$4"

    echo "🔍 正在拉取 $provider_name 的全量模型列表..."
    local models_json
    models_json=$(curl -s -m 10 -H "Authorization: Bearer $api_key" "${base_url}/models")

    if [[ -z "$models_json" ]]; then
        echo "❌ 无法获取模型列表，请求超时或上游端点未响应"
        return 1
    fi

    local model_ids
    model_ids=$(echo "$models_json" | grep -oP '"id":\s*"\K[^"]+' 2>/dev/null)

    if [[ -z "$model_ids" ]]; then
        echo "❌ 未在返回数据中解析到任何有效 Model ID"
        return 1
    fi

    local model_count
    model_count=$(echo "$model_ids" | wc -l)
    echo "✅ 成功匹配获取到 $model_count 个上游模型"

    local models_array
    models_array=$(build-openclaw-provider-models-json "$provider_name" "$model_ids")

    write-openclaw-provider-models "$provider_name" "$base_url" "$api_key" "$models_array" "$api_type"
}

# 仅向提供商写入用户选定的单个默认模型
add-default-model-only-to-provider() {
    local provider_name="$1"
    local base_url="$2"
    local api_key="$3"
    local default_model="$4"
    local api_type="$5"

    if [[ -z "$default_model" ]]; then
        echo "❌ 写入终止：默认设定模型 ID 不能为空"
        return 1
    fi

    local models_array
    models_array=$(build-openclaw-provider-models-json "$provider_name" "$default_model")
    write-openclaw-provider-models "$provider_name" "$base_url" "$api_key" "$models_array" "$api_type"
}


# =======================================================================
# 交互式菜单入口层
# =======================================================================

# 交互式添加具体服务商数据流
add-openclaw-provider-interactive() {
    send_stats "OpenClaw API添加"
    clear
    echo -e "${GREEN}=== 交互式添加 OpenClaw Provider ===${RESET}\n"

    read -erp "请输入 Provider 标识名称 (如 deepseek): " provider_name
    while [[ -z "$provider_name" ]]; do
        echo "❌ 名称不能为空！"
        read -erp "请输入 Provider 标识名称: " provider_name
    done

    read -erp "请输入 Base URL 端点 (如 https://api.deepseek.com/v1): " base_url
    while [[ -z "$base_url" ]]; do
        echo "❌ 端点链接不能为空！"
        read -erp "请输入 Base URL 端点: " base_url
    done
    base_url="${base_url%/}"

    read -rsp "请输入对接令牌 API Key (输入内容隐藏保护): " api_key
    echo
    while [[ -z "$api_key" ]]; do
        echo "❌ API Key 不能为空！"
        read -rsp "请输入 API Key: " api_key
        echo
    done

    # 显式提供协议类型配置选择（替代被移除的模糊自动探测）
    echo -e "\n请选择该 Provider 对应的 OpenClaw 协议流映射类型："
    echo "1. openai-completions (标准 Chat 补全流，绝大多数通用中转均采用此协议)"
    echo "2. openai-responses   (原生特定响应结构流)"
    read -erp "请输入选择序号 (1/2, 默认 1): " proto_choice
    local selected_api="openai-completions"
    [[ "$proto_choice" == "2" ]] && selected_api="openai-responses"

    echo -e "\n🔍 正在获取可用模型列表..."
    local models_json
    models_json=$(curl -s -m 10 -H "Authorization: Bearer $api_key" "${base_url}/models")

    local available_models=""
    local -a model_list=()
    local model_count=0

    if [[ -n "$models_json" ]]; then
        available_models=$(echo "$models_json" | grep -oP '"id":\s*"\K[^"]+' | sort 2>/dev/null)
        if [[ -n "$available_models" ]]; then
            model_count=$(echo "$available_models" | wc -l)
            echo -e "✅ 发现 ${YELLOW}$model_count${RESET} 个可用模型："
            echo "----------------------------------------"
            local i=1
            while read -r model; do
                echo " [$i] $model"
                model_list+=("$model")
                ((i++))
            done <<< "$available_models"
            echo "----------------------------------------"
        fi
    fi

    echo
    read -erp "请输入默认 Model ID (或输入对应序号，留空默认选中第 1 个): " input_model

    local default_model=""
    if [[ -z "$input_model" && -n "$available_models" ]]; then
        default_model=$(echo "$available_models" | head -1)
        echo "🎯 已为您默认选中首位模型: $default_model"
    elif [[ "$input_model" =~ ^[0-9]+$ ]] && [ "${#model_list[@]}" -gt 0 ] && [ "$input_model" -ge 1 ] && [ "$input_model" -le "${#model_list[@]}" ]; then
        default_model="${model_list[$((input_model-1))]}"
        echo "🎯 已确认选中模型: $default_model"
    else
        default_model="$input_model"
    fi

    if [[ -z "$default_model" ]]; then
        echo "❌ 未检测到线上模型，且未手动设定任何默认模型，操作中止。"
        break_end
        return 1
    fi

    echo -e "\n====== 配置审计核对 ======"
    echo " 供应商名称 : $provider_name"
    echo " 接口端点   : $base_url"
    echo " 协议类型   : $selected_api"
    echo " 默认模型   : $default_model"
    echo " 检索总数   : $model_count"
    echo "=========================="
    read -erp "是否同时把上游其它所有可用模型同步写入本地？(y/N): " confirm

    install jq
    local add_result=1
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        add-all-models-from-provider "$provider_name" "$base_url" "$api_key" "$selected_api"
        add_result=$?
    else
        add-default-model-only-to-provider "$provider_name" "$base_url" "$api_key" "$default_model" "$selected_api"
        add_result=$?
    fi

    if [[ $add_result -eq 0 ]]; then
        echo -e "\n🔄 正在写入默认会话架构参数并重启网关核心..."
        if command -v openclaw &>/dev/null; then
            openclaw models set "$provider_name/$default_model" >/dev/null 2>&1
        fi
        openclaw_sync_sessions_model "$provider_name/$default_model"
        start_gateway
        echo -e "${GREEN}✅ 供应商添加流程圆满结束！(当前协议: $selected_api)${RESET}"
    else
        echo -e "${RED}❌ 供应商模型写入失败，请检查配置文件权限结构。${RESET}"
    fi
    break_end
}

# API 看板展示与性能检测延迟流
openclaw_api_manage_list() {
    local config_file
    config_file=$(openclaw_get_config_file)
    send_stats "OpenClaw API列表"

    clear
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "      🌐  API 供应商集群状态看板       "
    echo -e "${GREEN}=======================================${RESET}"

    if [ ! -f "$config_file" ]; then
        echo "ℹ️ 未找到配置文件，请先执行初始化安装或添加供应商。"
        break_end
        return 0
    fi

    while IFS=$'\t' read -r rec_type idx name base_url model_count api_type latency_txt latency_level; do
        case "$rec_type" in
            MSG)
                echo -e "${YELLOW}$idx${RESET}"
                ;;
            ROW)
                local latency_color="$gl_bai"
                case "$latency_level" in
                    low) latency_color="$gl_lv" ;;
                    medium) latency_color="$gl_huang" ;;
                    high|unavailable) latency_color="$gl_hong" ;;
                    unchecked) latency_color="$gl_bai" ;;
                esac
                printf ' [%s] %-12s | 协议: %-18s | 数量: %b%-3s%b | 延迟: %b%-8s%b | 接口: %s\n' \
                       "$idx" "$name" "$api_type" "$gl_huang" "$model_count" "$gl_bai" "$latency_color" "$latency_txt" "$gl_bai" "$base_url"
                ;;
        esac
    done < <(python3 - "$config_file" <<-'PY'
import json
import sys
import time
import urllib.request

path = sys.argv[1]
SUPPORTED_APIS = {'openai-completions', 'openai-responses'}

def ping_models(base_url, api_key):
    req = urllib.request.Request(
        base_url.rstrip('/') + '/models',
        headers={
            'Authorization': f'Bearer {api_key}',
            'User-Agent': 'OpenClaw-API-Manage/1.0',
        },
    )
    start = time.perf_counter()
    with urllib.request.urlopen(req, timeout=4) as resp:
        resp.read(1024)
    return int((time.perf_counter() - start) * 1000)

def classify_latency(latency):
    if latency == '不可用': return '不可用', 'unavailable'
    if latency == '未检测': return '未检测', 'unchecked'
    if isinstance(latency, int):
        if latency <= 800: return f'{latency}ms', 'low'
        elif latency <= 2000: return f'{latency}ms', 'medium'
        else: return f'{latency}ms', 'high'
    return str(latency), 'unchecked'

try:
    with open(path, 'r', encoding='utf-8') as f:
        obj = json.load(f)
except Exception as e:
    print(f'MSG\t❌ 文件读取异常: {type(e).__name__}')
    sys.exit(0)

providers = obj.get('models', {}).get('providers', {})
if not isinstance(providers, dict) or not providers:
    print('MSG\tℹ️ 节点下未映射配置任何有效的 API 供应商。')
    sys.exit(0)

for idx, name in enumerate(sorted(providers.keys()), start=1):
    provider = providers.get(name)
    if not isinstance(provider, dict):
        base_url, model_count, latency_raw, api_label = '-', 0, '不可用', '-'
    else:
        base_url = provider.get('baseUrl') or provider.get('url') or '-'
        models = provider.get('models', [])
        model_count = sum(1 for m in models if isinstance(m, dict) and m.get('id'))
        api = provider.get('api', '')
        api_key = provider.get('apiKey')
        
        latency_raw = '未检测'
        if api in SUPPORTED_APIS:
            if base_url != '-' and api_key:
                try: latency_raw = ping_models(base_url, api_key)
                except Exception: latency_raw = '不可用'
            else: latency_raw = '不可用'
        else:
            latency_raw = '未检测'

    latency_text, latency_level = classify_latency(latency_raw)
    api_label = api if api in SUPPORTED_APIS else '-'
    print('\t'.join(['ROW', str(idx), str(name), str(base_url), str(model_count), str(api_label), str(latency_text), str(latency_level)]))
PY
)
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e " ➕ 输入 [ a ] 添加新 API 供应商"
    echo -e " 🔄 输入 [ s ] 单独指定 Provider 上游同步"
    echo -e " 🔧 输入 [ f ] 强制修复/切换 Provider 映射协议"
    echo -e " 🗑️ 输入 [ d ] 级联删除指定 Provider"
    echo -e " ↩️ 直接回车返回主菜单"
    echo -e "${GREEN}---------------------------------------${RESET}"
    read -erp "请输入您的动作选择: " api_choice
    case "$api_choice" in
        a|A) add-openclaw-provider-interactive ;;
        s|S) sync_openclaw_provider_interactive ;;
        f|F) fix-openclaw-provider-protocol-interactive ;;
        d|D) delete-openclaw-provider-interactive ;;
        *) return 0 ;;
    esac
}

# 全局或者精准按单个 Provider 进行上游拉取同步模型
sync_openclaw_provider_interactive() {
    local config_file
    config_file=$(openclaw_get_config_file)
    send_stats "OpenClaw API按Provider同步"

    if [ ! -f "$config_file" ]; then
        echo "❌ 未找到配置文件: $config_file"
        break_end
        return 1
    fi

    read -erp "请输入要同步的 API 标识名称(provider)，直接回车将执行全局同步探测: " provider_name
    if [ -z "$provider_name" ]; then
        if sync_openclaw_api_models; then
            start_gateway
        else
            echo "❌ 全局一致性同步失败，已熔断网关重启操作。"
        fi
        break_end
        return 0
    fi

    install jq curl python3 >/dev/null 2>&1

    python3 - "$config_file" "$provider_name" <<'PY2'
import copy
import json
import sys
import time
import urllib.request

path = sys.argv[1]
target = sys.argv[2]
SUPPORTED_APIS = {'openai-completions', 'openai-responses'}

with open(path, 'r', encoding='utf-8') as f:
    obj = json.load(f)

work = copy.deepcopy(obj)
models_cfg = work.setdefault('models', {})
providers = models_cfg.get('providers', {})
if not isinstance(providers, dict) or not providers:
    print('❌ 同步中止：当前配置文件无任何基础 Provider 节点')
    sys.exit(2)

provider = providers.get(target)
if not isinstance(provider, dict):
    print(f'❌ 同步中止：本地未匹配识别到名为 [{target}] 的 Provider')
    sys.exit(2)

api = provider.get('api', '')
if api not in SUPPORTED_APIS:
    print(f'❌ 校验不通过：该 Provider 的映射协议标记 api="{api}" 非法。')
    print('💡 架构已移除自动纠错，请返回主看板使用选项 [ f ] 强制切换协议后再试。')
    sys.exit(3)

base_url = provider.get('baseUrl')
api_key = provider.get('apiKey')
model_list = provider.get('models', [])

if not base_url or not api_key or not isinstance(model_list, list) or not model_list:
    print(f'❌ 同步中止：节点核心参数(baseUrl/apiKey/models)不完整')
    sys.exit(3)

agents = work.setdefault('agents', {})
defaults = agents.setdefault('defaults', {})
defaults_models_raw = defaults.get('models')
if isinstance(defaults_models_raw, dict):
    defaults_models = defaults_models_raw
elif isinstance(defaults_models_raw, list):
    defaults_models = {str(x): {} for x in defaults_models_raw if isinstance(x, str)}
else:
    defaults_models = {}
defaults['models'] = defaults_models

def model_ref(provider_name, model_id):
    return f"{provider_name}/{model_id}"

def get_primary_ref(defaults_obj):
    model_obj = defaults_obj.get('model')
    if isinstance(model_obj, str): return model_obj
    if isinstance(model_obj, dict): return model_obj.get('primary')
    return None

def set_primary_ref(defaults_obj, new_ref):
    model_obj = defaults_obj.get('model')
    if isinstance(model_obj, str): defaults_obj['model'] = new_ref
    elif isinstance(model_obj, dict): model_obj['primary'] = new_ref
    else: defaults_obj['model'] = {'primary': new_ref}

def fetch_remote_models_with_retry(base_url, api_key, retries=3):
    for attempt in range(1, retries + 1):
        req = urllib.request.Request(
            base_url.rstrip('/') + '/models',
            headers={'Authorization': f'Bearer {api_key}', 'User-Agent': 'OpenClaw-Core-Sync/1.0'}
        )
        try:
            with urllib.request.urlopen(req, timeout=12) as resp:
                payload = resp.read().decode('utf-8', 'ignore')
            return json.loads(payload), None, attempt
        except Exception as e:
            if attempt == retries: return None, e, attempt
            time.sleep(1)

data, err, attempts = fetch_remote_models_with_retry(base_url, api_key)
if err is not None:
    print(f'❌ 网络通信异常：拉取上游错误，重试 {attempts} 次已满 ({type(err).__name__})')
    sys.exit(4)

if not (isinstance(data, dict) and isinstance(data.get('data'), list)):
    print(f'❌ 解析异常：上游传回格式并非标准 OpenAI API 模型字典集合')
    sys.exit(4)

remote_ids = [str(item['id']) for item in data['data'] if isinstance(item, dict) and item.get('id')]
remote_set = set(remote_ids)
if not remote_set:
    print(f'❌ 安全防护熔断：线上返回模型池为空，拒绝重写覆盖本地活跃业务')
    sys.exit(5)

local_models = [m for m in model_list if isinstance(m, dict) and m.get('id')]
local_ids = [str(m['id']) for m in local_models]
local_set = set(local_ids)

template = copy.deepcopy(local_models[0]) if local_models else None
if template is None:
    print(f'❌ 依赖断层：本地原模型池为空，提取不到改写映射所需的元数据模板')
    sys.exit(3)

removed_ids = [mid for mid in local_ids if mid not in remote_set]
added_ids = [mid for mid in remote_ids if mid not in local_set]

kept_models = [copy.deepcopy(m) for m in local_models if str(m['id']) in remote_set]
new_models = kept_models[:]
for mid in added_ids:
    nm = copy.deepcopy(template)
    nm['id'] = mid
    if isinstance(nm.get('name'), str): nm['name'] = f'{target} / {mid}'
    new_models.append(nm)

if not new_models:
    print(f'❌ 安全中止：过滤后无可续存写入的模型集')
    sys.exit(5)

expected_refs = {model_ref(target, str(m['id'])) for m in new_models}
local_refs = {model_ref(target, mid) for mid in local_ids}
removed_refs = local_refs - expected_refs
first_ref = model_ref(target, str(new_models[0]['id']))

changed = False
primary_ref = get_primary_ref(defaults)
if isinstance(primary_ref, str) and primary_ref in removed_refs:
    set_primary_ref(defaults, first_ref)
    changed = True
    print(f'🔁 默认主核心模型已被上游清理，系统平滑自动指向为: {first_ref}')

for fk in ('modelFallback', 'imageModelFallback'):
    val = defaults.get(fk)
    if isinstance(val, str) and val in removed_refs:
        defaults[fk] = first_ref
        changed = True
        print(f'🔁 级联降级锚点 {fk} 失效，已切换至: {first_ref}')

stale_refs = [r for r in list(defaults_models.keys()) if r.startswith(target + '/') and r not in expected_refs]
for r in stale_refs:
    defaults_models.pop(r, None)
    changed = True

for r in sorted(expected_refs):
    if r not in defaults_models:
        defaults_models[r] = {}
        changed = True

if removed_ids or added_ids or len(local_models) != len(new_models):
    provider['models'] = new_models
    changed = True

if changed:
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(work, f, ensure_ascii=False, indent=2)
        f.write('\n')

print(f'✅ {target} 模型同步比对结束。增补 {len(added_ids)} 个，下架 {len(removed_ids)} 个过时模型。')
if added_ids: print(f" ➕ 新增: {', '.join(added_ids)}")
if removed_ids: print(f" ➖ 移除: {', '.join(removed_ids)}")
PY2

    if [ $? -eq 0 ]; then
        start_gateway
    fi
    break_end
}

# 全量模型一致性双层循环同步探测（全局资产比对）
sync_openclaw_api_models() {
    local config_file
    config_file=$(openclaw_get_config_file)

    [ ! -f "$config_file" ] && return 0
    install jq curl python3 >/dev/null 2>&1

    python3 - "$config_file" "$ENABLE_STATS" "$sh_v" <<'PY'
import copy
import json
import sys
import time
import urllib.request

path = sys.argv[1]

with open(path, 'r', encoding='utf-8') as f:
    obj = json.load(f)

work = copy.deepcopy(obj)
models_cfg = work.setdefault('models', {})
providers = models_cfg.get('providers', {})
if not isinstance(providers, dict) or not providers:
    print('ℹ️ 未检测到 API providers 资产，忽略全局同步')
    sys.exit(0)

agents = work.setdefault('agents', {})
defaults = agents.setdefault('defaults', {})
defaults_models_raw = defaults.get('models')
if isinstance(defaults_models_raw, dict):
    defaults_models = defaults_models_raw
elif isinstance(defaults_models_raw, list):
    defaults_models = {str(x): {} for x in defaults_models_raw if isinstance(x, str)}
else:
    defaults_models = {}
defaults['models'] = defaults_models

SUPPORTED_APIS = {'openai-completions', 'openai-responses'}
changed = False
summary = []

def model_ref(p_name, m_id): return f"{p_name}/{m_id}"
def get_primary_ref(d_obj):
    m_obj = d_obj.get('model')
    if isinstance(m_obj, str): return m_obj
    if isinstance(m_obj, dict): return m_obj.get('primary')
    return None
def set_primary_ref(d_obj, n_ref):
    m_obj = d_obj.get('model')
    if isinstance(m_obj, str): d_obj['model'] = n_ref
    elif isinstance(m_obj, dict): m_obj['primary'] = n_ref
    else: d_obj['model'] = {'primary': n_ref}

for name, provider in list(providers.items()):
    if not isinstance(provider, dict): continue
    api = provider.get('api', '')
    base_url = provider.get('baseUrl')
    api_key = provider.get('apiKey')
    model_list = provider.get('models', [])

    if not base_url or not api_key or api not in SUPPORTED_APIS:
        summary.append(f'❌ 跳过 {name}: 协议不合规或参数残缺。请使用选单手动订正。')
        continue

    try:
        req = urllib.request.Request(base_url.rstrip('/') + '/models', headers={'Authorization': f'Bearer {api_key}'})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode('utf-8', 'ignore'))
    except Exception as e:
        summary.append(f'⚠️ 同步失败 {name}: 联机上游异常 ({type(e).__name__})')
        continue

    if not (isinstance(data, dict) and isinstance(data.get('data'), list)):
        summary.append(f'⚠️ 跳过 {name}: 上游响应流非规范 OpenAI 集合结构')
        continue

    remote_ids = [str(x['id']) for x in data['data'] if isinstance(x, dict) and x.get('id')]
    if not remote_ids:
        summary.append(f'⚠️ 拦截 {name}: 线上模型池为空，熔断保护')
        continue

    local_models = [m for m in model_list if isinstance(m, dict) and m.get('id')]
    local_ids = [str(m['id']) for m in local_models]
    template = copy.deepcopy(local_models[0]) if local_models else None
    if not template: continue

    kept_models = [copy.deepcopy(m) for m in local_models if str(m['id']) in set(remote_ids)]
    added_ids = [x for x in remote_ids if x not in set(local_ids)]
    
    for mid in added_ids:
        nm = copy.deepcopy(template)
        nm['id'] = mid
        if isinstance(nm.get('name'), str): nm['name'] = f'{name} / {mid}'
        kept_models.append(nm)

    expected_refs = {model_ref(name, str(m['id'])) for m in kept_models}
    local_refs = {model_ref(name, mid) for mid in local_ids}
    first_ref = model_ref(name, str(kept_models[0]['id']))

    p_ref = get_primary_ref(defaults)
    if isinstance(p_ref, str) and p_ref in (local_refs - expected_refs):
        set_primary_ref(defaults, first_ref)
        changed = True

    for fk in ('modelFallback', 'imageModelFallback'):
        val = defaults.get(fk)
        if isinstance(val, str) and val in (local_refs - expected_refs):
            defaults[fk] = first_ref
            changed = True

    stale_refs = [r for r in list(defaults_models.keys()) if r.startswith(name + '/') and r not in expected_refs]
    for r in stale_refs:
        defaults_models.pop(r, None)
        changed = True

    for r in sorted(expected_refs):
        if r not in defaults_models:
            defaults_models[r] = {}
            changed = True

    provider['models'] = kept_models
    changed = True
    summary.append(f'✅ {name}: 现行同步存活共计 {len(kept_models)} 个模型')

if changed:
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(work, f, ensure_ascii=False, indent=2)
        f.write('\n')

for line in summary: print(line)
PY
}

# 交互式切换并强制修正指定 Provider 的底层通信协议类型
fix-openclaw-provider-protocol-interactive() {
    local config_file=$(openclaw_get_config_file)
    send_stats "OpenClaw API协议切换"

    if [ ! -f "$config_file" ]; then
        echo "❌ 未找到中心配置文件: $config_file"
        break_end
        return 1
    fi

    read -erp "请输入要执行协议变更的 Provider 标识名称: " provider_name
    if [ -z "$provider_name" ]; then
        echo "❌ 输入标识不可为空"
        break_end
        return 1
    fi

    echo "请手动选择强制指派的目标协议流映射类型："
    echo "1. openai-completions"
    echo "2. openai-responses"
    read -erp "请输入序号 (1/2): " proto_choice

    local new_api=""
    case "$proto_choice" in
        1) new_api="openai-completions" ;;
        2) new_api="openai-responses" ;;
        *) echo "❌ 动作被废弃，非法输入" ; break_end ; return 1 ;;
    esac

    python3 - "$config_file" "$provider_name" "$new_api" <<'PY'
import copy
import json
import sys

path = sys.argv[1]
name = sys.argv[2]
new_api = sys.argv[3]

with open(path, 'r', encoding='utf-8') as f:
    obj = json.load(f)

work = copy.deepcopy(obj)
providers = ((work.get('models') or {}).get('providers') or {})
if not isinstance(providers, dict) or name not in providers:
    print(f'❌ 订正失败：本地尚未建立名为 [{name}] 的节点配置')
    sys.exit(2)

providers[name]['api'] = new_api

with open(path, 'w', encoding='utf-8') as f:
    json.dump(work, f, ensure_ascii=False, indent=2)
    f.write('\n')
print(f'✅ 底层映射协议修正成功：[{name}] -> {new_api}')
PY
    if [ $? -eq 0 ]; then
        start_gateway
    fi
    break_end
}

# 级联删除指定 Provider 配置及 defaults 依赖残留链
delete-openclaw-provider-interactive() {
    local config_file=$(openclaw_get_config_file)
    send_stats "OpenClaw API删除入口"

    if [ ! -f "$config_file" ]; then
        echo "❌ 找不到配置文件: $config_file"
        break_end
        return 1
    fi

    read -erp "请输入准备彻底清退移除的 Provider 标识名称: " provider_name
    if [ -z "$provider_name" ]; then
        echo "❌ 输入不能为空"
        break_end
        return 1
    fi

    python3 - "$config_file" "$provider_name" <<'PY'
import copy
import json
import sys

path = sys.argv[1]
name = sys.argv[2]

with open(path, 'r', encoding='utf-8') as f:
    obj = json.load(f)

work = copy.deepcopy(obj)
models_cfg = work.setdefault('models', {})
providers = models_cfg.get('providers', {})
if not isinstance(providers, dict) or name not in providers:
    print(f'❌ 解绑失败：配置文件内未包含指定名称的供应商。')
    sys.exit(2)

agents = work.setdefault('agents', {})
defaults = agents.setdefault('defaults', {})
defaults_models_raw = defaults.get('models')
if isinstance(defaults_models_raw, dict): defaults_models = defaults_models_raw
elif isinstance(defaults_models_raw, list): defaults_models = {str(x): {} for x in defaults_models_raw}
else: defaults_models = {}
defaults['models'] = defaults_models

def model_ref(p_name, m_id): return f"{p_name}/{m_id}"
def ref_provider(ref): return ref.split('/', 1)[0] if isinstance(ref, str) and '/' in ref else None
def get_primary_ref(d_obj):
    m_obj = d_obj.get('model')
    return m_obj if isinstance(m_obj, str) else (m_obj.get('primary') if isinstance(m_obj, dict) else None)
def set_primary_ref(d_obj, n_ref):
    if isinstance(d_obj.get('model'), str): d_obj['model'] = n_ref
    elif isinstance(d_obj.get('model'), dict): d_obj['model']['primary'] = n_ref
    else: d_obj['model'] = {'primary': n_ref}

candidates = []
for p, v in providers.items():
    if p != name and isinstance(v, dict):
        for m in v.get('models', []) or []:
            if isinstance(m, dict) and m.get('id'): candidates.append(model_ref(p, str(m['id'])))

replacement = candidates[0] if candidates else None

p_ref = get_primary_ref(defaults)
if ref_provider(p_ref) == name:
    if not replacement:
        print('❌ 拦截安全警告：当前全局核心主控依赖此 Provider，外部无替代链，拒绝强行将其卸载！')
        sys.exit(3)
    set_primary_ref(defaults, replacement)

for fk in ('modelFallback', 'imageModelFallback'):
    if ref_provider(defaults.get(fk)) == name:
        if replacement: defaults[fk] = replacement

removed_refs = [r for r in list(defaults_models.keys()) if r.startswith(name + '/')]
for r in removed_refs: defaults_models.pop(r, None)

providers.pop(name, None)

with open(path, 'w', encoding='utf-8') as f:
    json.dump(work, f, ensure_ascii=False, indent=2)
    f.write('\n')

print(f'🗑️ 销毁成功：供应商 [{name}] 及其下游引用的 {len(removed_refs)} 个会话追踪模型链已被深度级联清洗。')
PY
    if [ $? -eq 0 ]; then
        start_gateway
    fi
    break_end
}

# 7. 机器人连接对接交互式子选单
bot_connection_menu() {
    while true; do
        clear
        echo -e "${GREEN}========================================${RESET}"
        echo -e "             机器人连接对接             "
        echo -e "${GREEN}========================================${RESET}"
        openclaw_show_bot_local_status_block
        echo "----------------------------------------"
        echo -e " 1. Telegram 机器人对接"
        echo -e " 2. 飞书 (Lark) 机器人对接"
        echo -e " 3. WhatsApp 机器人对接"
        echo -e " 4. QQ 机器人对接"
        echo -e " 5. 微信机器人对接"
        echo "----------------------------------------"
        echo -e " ${YELLOW}0. 返回上一级选单${RESET}"
        echo "----------------------------------------"
        read -erp "请输入你的选择: " bot_choice

        case $bot_choice in
            1)
                read -erp "请输入TG机器人收到的连接码 (例如 NYA99R2F)（输入 0 退出）： " code
                if [ "$code" = "0" ] || [ -z "$code" ]; then 
                    [ -z "$code" ] && echo -e "${RED}错误：连接码不能为空。${RESET}" && sleep 1
                    continue
                fi
                openclaw pairing approve telegram "$code"
                break_end
                ;;
            2)
                echo -e "${YELLOW}🔄 正在通过 npx 调度部署飞书适配通道...${RESET}"
                npx -y @larksuite/openclaw-lark install
                openclaw config set channels.feishu.streaming true
                openclaw config set channels.feishu.requireMention true --json
                echo -e "${GREEN}✅ 飞书通道参数设置成功！${RESET}"
                break_end
                ;;
            3)
                read -erp "请输入WhatsApp收到的连接码 (例如 NYA99R2F)（输入 0 退出）： " code
                if [ "$code" = "0" ] || [ -z "$code" ]; then 
                    [ -z "$code" ] && echo -e "${RED}错误：连接码不能为空。${RESET}" && sleep 1
                    continue
                fi
                openclaw pairing approve whatsapp "$code"
                break_end
                ;;
            4)
                echo -e "\n${GREEN}QQ 官方对接指引链接：${RESET}"
                echo -e "${BLUE}https://q.qq.com/qqbot/openclaw/login.html${RESET}\n"
                break_end
                ;;
            5)
                echo -e "${YELLOW}🔄 正在下载并注入企业微信/微信开放平台支持组件...${RESET}"
                npx -y @tencent-weixin/openclaw-weixin-cli@latest install
                break_end
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${RED}无效的选择，请重试。${RESET}"
                sleep 1
                ;;
        esac
    done
}

# 12. 健康检测与自动环境修复
health_doctor_fix() {
    echo -e "${GREEN}=== OpenClaw 全自动化故障巡检与修复 ===${RESET}"
    local config_file
    config_file=$(openclaw_get_config_file)

    echo -n "[1/3] 核心进程状态扫描: "
    if pgrep -f "openclaw" &>/dev/null; then
        echo -e "${GREEN}正常运行${RESET}"
    else
        echo -e "${YELLOW}离线。正在为您强制拉起网关进程守护...${RESET}"
        openclaw gateway start
    fi

    echo -n "[2/3] 核心配置文件格式校验: "
    if [ -f "$config_file" ]; then
        if jq . "$config_file" &>/dev/null; then
            echo -e "${GREEN}结构合法 (Valid JSON)${RESET}"
        else
            echo -e "${RED}结构损坏！正在为您排查加载最近一次的备份恢复...${RESET}"
            local bak
            bak=$(ls -t "${config_file}.bak."* 2>/dev/null | head -n 1)
            if [ -n "$bak" ]; then
                cp "$bak" "$config_file" && echo -e "${GREEN}已成功还原历史快照配置: $bak${RESET}"
            else
                echo -e "${RED}无历史快照备份，建议执行选项 11 重新进行 onboard向导初始化。${RESET}"
            fi
        fi
    else
        echo -e "${RED}缺失核心配置文件${RESET}"
    fi

    echo -n "[3/3] 全系统底层运行环境依属检测: "
    if command -v node &>/dev/null && command -v tmux &>/dev/null; then
        echo -e "${GREEN}环境完备${RESET}"
    else
        echo -e "${YELLOW}发现缺失，自动补全修复依赖项...${RESET}"
        install tmux jq nodejs
    fi
    break_end
}

# =======================================================================
# 主菜单及指令控制层
# =======================================================================
show_menu() {
    get_openclaw_status
    clear
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}     ◈   🦞 OPENCLAW 管理工具  ◈      ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}核心状态 : $STATUS${RESET}"
    echo -e "${GREEN}核心版本 :${RESET} ${YELLOW}$OPENCLAW_VERSION${RESET}"
    echo -e "${GREEN}集群数据 :${RESET} ${YELLOW}$CONFIG_COUNT 个 API 供应商${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "  1. 安装 环境依赖与 OpenClaw"
    echo -e "  2. 启动 Gateway (消息网关后台)"
    echo -e "  3. 停止 Gateway (消息网关服务)"
    echo -e " -------------------------------------"
    echo -e "  4. 状态日志查看"
    echo -e "  6. API 管理 "
    echo -e "  7. 机器人连接对接窗口"
    echo -e " -------------------------------------"
    echo -e " 11. 配置向导 (Onboard 初始化)"
    echo -e " 12. 健康检测与自动故障修复"
    echo -e " 14. TUI 命令行窗口本地对话"
    echo -e " 19. 更新 OpenClaw 核心程序"
    echo -e " 20. 卸载 清理全部运行环境"
    echo -e " -------------------------------------"
    echo -e "  0. 退出"
    echo -e "${GREEN}=======================================${RESET}"
    printf " 请输入选项并回车: "
}

main() {
    while true; do
        show_menu
        read -r choice
        case "$choice" in
            1)  install_moltbot ;;
            2)  start_gateway && echo -e "${GREEN}✅ 启动指令发送执行完成${RESET}" && break_end ;;
            3)  
                echo "停止 OpenClaw..."
                send_stats "停止 OpenClaw..."
                tmux kill-session -t gateway > /dev/null 2>&1
                openclaw gateway stop >/dev/null 2>&1
                echo -e "${GREEN}✅ 网关核心及守护会话已完全离线停止${RESET}"
                break_end 
                ;;
            4)  view_logs ;;
            6)  openclaw_api_manage_list ;;
            7)  bot_connection_menu ;;
            11) openclaw onboard; break_end ;;
            12) health_doctor_fix ;;
            14) openclaw chat ;;
            19) 
                echo "🔄 正在为您执行 NPM 全量拉取覆写更新 OpenClaw..."
                sudo npm install -g openclaw@latest && start_gateway
                echo -e "${GREEN}✅ 覆写更新完成！${RESET}"
                break_end
                ;;
            20) 
                echo -e "${RED}⚠️ 警告：您正准备全盘卸载 OpenClaw 控制程序及清空所有配置。${RESET}"
                read -erp "确定要继续执行强力清除吗？(y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    openclaw gateway stop >/dev/null 2>&1
                    sudo npm uninstall -g openclaw
                    rm -rf "${HOME}/.openclaw"
                    echo -e "${GREEN}✅ OpenClaw 卸载洗刷完成。${RESET}"
                else
                    echo "❌ 操作已取消。"
                fi
                break_end
                ;;
            0)  echo "退出 OpenClaw 管理面板，再见！"; exit 0 ;;
            *)  echo -e "${RED}输入有误，请输入菜单中有效的数字代号！${RESET}"; sleep 1 ;;
        esac
    done
}

# 启动执行
main
