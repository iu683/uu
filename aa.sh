#!/usr/bin/env sh
# Alpine 专属 Telegram Docker 机器人管理脚本
set -eu

APP_NAME='tg-docker-manager'
INSTALL_DIR='/opt/tg-docker-manager'
APP_FILE="$INSTALL_DIR/tg_docker_manager.py"
ENV_FILE='/etc/tg-docker-manager.env'
SERVICE_FILE="/etc/init.d/$APP_NAME"

GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
BLUE='\033[34m'
RESET='\033[0m'

info() { echo "${GREEN}[信息] $*${RESET}"; }
warn() { echo "${YELLOW}[警告] $*${RESET}"; }
err() { echo "${RED}[错误] $*${RESET}" >&2; }

require_root() {
    [ "$(id -u)" -eq 0 ] || { err '请用 root 用户运行此脚本'; exit 1; }
}

require_alpine() {
    [ -f /etc/os-release ] || { err '无法识别系统，本脚本仅支持 Alpine Linux'; exit 1; }
    . /etc/os-release
    if [ "${ID:-}" != "alpine" ]; then
        err "本脚本仅支持 Alpine Linux，当前系统为: ${PRETTY_NAME:-unknown}"
        exit 1
    fi
}

# 1. 安装功能
install_bot() {
    info '开始安装 Alpine 依赖包...'
    apk update
    apk add python3 curl ca-certificates

    if ! command -v docker >/dev/null 2>&1; then
        warn '未检测到 Docker 环境。'
        warn '请稍后自行执行: apk add docker docker-cli-compose && rc-update add docker default && rc-service docker start'
    fi

    info '正在创建程序目录...'
    mkdir -p "$INSTALL_DIR"

    info '正在写入内嵌 Python 核心代码...'
    # 填入之前为你适配好的 Alpine 专属无依赖 Python 源码
    cat > "$APP_FILE" <<'PYEOF'
#!/usr/bin/env python3
import json, os, subprocess, sys, time, urllib.parse, urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

BOT_TOKEN = os.environ.get("TG_BOT_TOKEN", "")
ALLOWED_CHAT_ID = os.environ.get("TG_ALLOWED_CHAT_ID", "")
PROJECTS_DIR = Path(os.environ.get("PROJECTS_DIR", "/opt"))
POLL_TIMEOUT = int(os.environ.get("TG_POLL_TIMEOUT", "30"))
LOG_LINES_DEFAULT = int(os.environ.get("TG_LOG_LINES", "80"))

COMPOSE_FILES = ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"]
CUSTOM_PROJECT_PATHS = {
    "Moviepilot": "/opt/1panel/apps/local/moviepilot/moviepilot",
    "Jellyfin": "/opt/1panel/apps/jellyfin/jellyfin",
    "emby-amilys": "/opt/1panel/apps/local/emby-amilys/emby-amilys",
    "Vertex": "/opt/1panel/apps/local/vertex/localvertex",
    "Autobangumi": "/opt/1panel/apps/local/autobangumi/autobangumi",
}
API_BASE = f"https://api.telegram.org/bot{BOT_TOKEN}"

@dataclass
class Project:
    name: str
    directory: Path
    compose_file: Path

def require_env() -> None:
    if not BOT_TOKEN or not ALLOWED_CHAT_ID:
        print("Missing Environment Variables", file=sys.stderr)
        sys.exit(1)

def tg_api(method: str, payload: Optional[dict] = None) -> dict:
    payload = payload or {}
    data = urllib.parse.urlencode(payload).encode()
    req = urllib.request.Request(f"{API_BASE}/{method}", data=data)
    with urllib.request.urlopen(req, timeout=POLL_TIMEOUT + 15) as resp:
        return json.loads(resp.read().decode())

def split_text(text: str, limit: int = 3500) -> List[str]:
    if len(text) <= limit: return [text]
    parts, buf = [], ""
    for line in text.splitlines(True):
        if len(buf) + len(line) > limit and buf:
            parts.append(buf)
            buf = line
        else: buf += line
    if buf: parts.append(buf)
    return parts

def send_message(chat_id: str, text: str, reply_markup: Optional[dict] = None) -> None:
    chunks = split_text(text)
    for idx, chunk in enumerate(chunks):
        payload = {"chat_id": chat_id, "text": chunk}
        if reply_markup and idx == len(chunks) - 1: payload["reply_markup"] = json.dumps(reply_markup)
        tg_api("sendMessage", payload)

def answer_callback(callback_id: str, text: str = "") -> None:
    payload = {"callback_query_id": callback_id}
    if text: payload["text"] = text
    tg_api("answerCallbackQuery", payload)

def edit_message(chat_id: str, message_id: int, text: str, reply_markup: Optional[dict] = None) -> None:
    payload = {"chat_id": chat_id, "message_id": message_id, "text": text}
    if reply_markup is not None: payload["reply_markup"] = json.dumps(reply_markup)
    tg_api("editMessageText", payload)

def run_shell(cmd: List[str], cwd: Optional[Path] = None, timeout: int = 300) -> Tuple[int, str]:
    try:
        proc = subprocess.run(cmd, cwd=str(cwd) if cwd else None, text=True, capture_output=True, timeout=timeout)
        output = ((proc.stdout or "") + ("\n" + proc.stderr if proc.stderr else "")).strip()
        return proc.returncode, output or "(无输出)"
    except Exception as e: return 1, f"失败: {e}"

def localize_docker_text(text: str) -> str:
    replacements = {
        "Running": "运行中", "Exited": "已退出", "Restarting": "重启中", "Up ": "运行中 ",
        "About a minute": "约1分钟", "About an hour": "约1小时", "seconds ago": "秒前", 
        "minutes ago": "分钟前", "hours ago": "小时前", "days ago": "天前", "started": "已启动", "stopped": "已停止"
    }
    for src, dst in replacements.items(): text = text.replace(src, dst)
    return text

def discover_projects() -> Dict[str, Project]:
    projects = {}
    if PROJECTS_DIR.exists():
        for item in sorted(PROJECTS_DIR.iterdir()):
            if not item.is_dir(): continue
            for f in COMPOSE_FILES:
                if (item / f).exists():
                    projects[item.name] = Project(item.name, item, item / f)
                    break
    for name, raw_path in CUSTOM_PROJECT_PATHS.items():
        directory = Path(raw_path)
        if not directory.exists(): continue
        for f in COMPOSE_FILES:
            if (directory / f).exists():
                projects[name] = Project(name, directory, directory / f)
                break
    return projects

def resolve_project(name: str) -> Optional[Project]: return discover_projects().get(name.strip())
def run_compose(project: Project, args: List[str]) -> Tuple[int, str]: return run_shell(["docker", "compose", "-f", str(project.compose_file)] + args, cwd=project.directory)

def status_text(project: Project) -> str:
    code, out = run_compose(project, ["ps", "--format", "json"])
    head = f"项目: {project.name}\n目录: {project.directory}\n"
    if code != 0: return head + f"查询失败:\n{localize_docker_text(out)}"
    return head + localize_docker_text(out)

def main_keyboard() -> dict:
    return {"inline_keyboard": [
        [{"text": "📦 项目列表", "callback_data": "menu:list"}, {"text": "🎬 应用管理", "callback_data": "menu:apps"}],
        [{"text": "🐳 Docker 管理", "callback_data": "menu:docker"}, {"text": "🖥 系统管理", "callback_data": "menu:system"}]
    ]}

def system_manage_keyboard() -> dict:
    return {"inline_keyboard": [[{"text": "📡 系统信息", "callback_data": "system:info"}, {"text": "🌐 网络信息", "callback_data": "system:network"}],[{"text": "🧽 一键清理系统", "callback_data": "confirm_global:system_cleanup"}],[{"text": "⬅️ 返回", "callback_data": "menu:home"}]]}

def docker_manage_keyboard() -> dict:
    return {"inline_keyboard": [[{"text": "📊 Docker 概览", "callback_data": "docker:overview"}, {"text": "📈 容器占用", "callback_data": "docker:stats"}],[{"text": "🔄 重启 Docker 服务", "callback_data": "confirm_global:docker_restart"}],[{"text": "⬅️ 返回", "callback_data": "menu:home"}]]}

def project_list_keyboard(projects: Dict[str, Project]) -> dict:
    rows = [[{"text": name, "callback_data": f"project:{name}"}] for name in sorted(projects.keys())]
    rows.append([{"text": "⬅️ 返回", "callback_data": "menu:home"}])
    return {"inline_keyboard": rows}

def project_keyboard(project_name: str) -> dict:
    return {"inline_keyboard": [
        [{"text": "▶️ 启动", "callback_data": f"action:up:{project_name}"}, {"text": "⏹ 停止", "callback_data": f"action:stop:{project_name}"}],
        [{"text": "🔄 重启", "callback_data": f"action:restart:{project_name}"}, {"text": "📜 日志", "callback_data": f"action:logs:{project_name}"}],
        [{"text": "⬅️ 列表", "callback_data": "menu:list"}, {"text": "🏠 首页", "callback_data": "menu:home"}]
    ]}

def global_confirm_keyboard(action: str) -> dict:
    cb = "system:cleanup" if action == "system_cleanup" else "docker:restart"
    return {"inline_keyboard": [[{"text": "✅ 确认执行", "callback_data": cb}, {"text": "❌ 取消", "callback_data": "menu:home"}]]}

def system_info_text() -> str:
    mem = run_shell(["sh", "-c", "free -m | awk '/Mem:/ {print $3 \"MB / \" $2 \"MB\"}'"])[1]
    disk = run_shell(["sh", "-c", "df -h / | awk 'NR==2 {print $3 \" / \" $2 \" (\" $5 \")\"}'"])[1]
    uptime = run_shell(["uptime"])[1].strip()
    return f"📡 Alpine VPS 信息\n━━━━━━━━━━\n内存占用: {mem}\n磁盘占用: {disk}\n运行时间: {uptime}"

def handle_text_command(chat_id: str, text: str) -> None:
    if text.strip().startswith("/start"): send_message(chat_id, "🐳 Alpine Docker 运行面板", main_keyboard())

def handle_callback_query(chat_id: str, message_id: int, callback_id: str, data: str) -> None:
    if data == "menu:home": edit_message(chat_id, message_id, "🐳 Alpine Docker 运行面板", main_keyboard())
    elif data == "menu:list": edit_message(chat_id, message_id, "请选择 Compose 项目:", project_list_keyboard(discover_projects()))
    elif data == "menu:docker": edit_message(chat_id, message_id, "🐳 Docker 管理", docker_manage_keyboard())
    elif data == "menu:system": edit_message(chat_id, message_id, "🖥 系统管理", system_manage_keyboard())
    elif data == "system:info": edit_message(chat_id, message_id, system_info_text(), system_manage_keyboard())
    elif data == "confirm_global:docker_restart": edit_message(chat_id, message_id, "⚠️ 确认通过 OpenRC 重启 Docker 引擎？", global_confirm_keyboard("docker_restart"))
    elif data == "docker:restart":
        edit_message(chat_id, message_id, "正在重启 Docker...")
        run_shell(["rc-service", "docker", "restart"])
        edit_message(chat_id, message_id, "✅ Docker 已完成重启", docker_manage_keyboard())
    elif data.startswith("project:"):
        p_name = data.split(":", 1)[1]
        proj = resolve_project(p_name)
        if proj: edit_message(chat_id, message_id, status_text(proj), project_keyboard(p_name))
    elif data.startswith("action:"):
        _, act, p_name = data.split(":", 2)
        proj = resolve_project(p_name)
        if proj:
            answer_callback(callback_id, f"正在执行 {act}...")
            code, out = run_compose(proj, [act] if act != "up" else ["up", "-d"])
            send_message(chat_id, f"【{p_name}】{act} 结果:\n\n{localize_docker_text(out)}", main_keyboard())
    answer_callback(callback_id)

def run_bot():
    require_env()
    offset = 0
    while True:
        try:
            updates = tg_api("getUpdates", {"offset": offset, "timeout": POLL_TIMEOUT})
            if "result" in updates:
                for u in updates["result"]:
                    offset = u["update_id"] + 1
                    if "message" in u and "text" in u["message"] and str(u["message"]["chat"]["id"]) == ALLOWED_CHAT_ID:
                        handle_text_command(str(u["message"]["chat"]["id"]), u["message"]["text"])
                    elif "callback_query" in u and "message" in u["callback_query"] and str(u["callback_query"]["message"]["chat"]["id"]) == ALLOWED_CHAT_ID:
                        handle_callback_query(str(u["callback_query"]["message"]["chat"]["id"]), u["callback_query"]["message"]["message_id"], u["callback_query"]["id"], u["callback_query"].get("data", ""))
        except Exception: time.sleep(5)

if __name__ == "__main__": run_bot()
PYEOF
    chmod +x "$APP_FILE"

    info '生成 Alpine OpenRC 系统服务控制脚本...'
    cat > "$SERVICE_FILE" <<'EOF'
#!/sbin/openrc-run

description="Telegram Docker Manager Bot"
pidfile="/run/tg-docker-manager.pid"
command="/usr/bin/python3"
command_args="/opt/tg-docker-manager/tg_docker_manager.py"
command_background="yes"

depend() {
    need net docker
    after firewall
}

start_pre() {
    if [ ! -f /etc/tg-docker-manager.env ]; then
        eerror "/etc/tg-docker-manager.env 配置文件缺失！"
        return 1
    fi
    export $(grep -v '^#' /etc/tg-docker-manager.env | xargs)
}
EOF
    chmod +x "$SERVICE_FILE"

    if [ ! -f "$ENV_FILE" ]; then
        info '初始化配置文件...'
        cat > "$ENV_FILE" <<'EOF'
# Telegram 机器人配置令牌
TG_BOT_TOKEN="在双引号内填写你的_BOT_TOKEN"
# 允许操控的个人 Telegram 账户 Chat ID
TG_ALLOWED_CHAT_ID="在双引号内填写你的_CHAT_ID"
PROJECTS_DIR="/opt"
TG_POLL_TIMEOUT="30"
TG_LOG_LINES="80"
EOF
    fi

    # 注册到系统开机自启
    rc-update add "$APP_NAME" default >/dev/null 2>&1 || true

    echo "--------------------------------------------------------"
    info "🎉 安装成功！"
    warn "请记得马上去编辑配置文件填写秘钥: vi $ENV_FILE"
    info "配置完成后，在当前菜单中选择【选项 3】启动服务即可。"
    echo "--------------------------------------------------------"
}

# 2. 卸载功能
uninstall_bot() {
    warn '⚠️ 确定要彻底卸载 Telegram Docker 机器人吗？(y/n)'
    read -r choice
    if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
        info '正在停止服务并清理开机自启...'
        rc-service "$APP_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$APP_NAME" default >/dev/null 2>&1 || true
        
        info '正在删除核心程序与系统服务文件...'
        rm -rf "$INSTALL_DIR"
        rm -f "$SERVICE_FILE"
        
        warn '是否保留机器人配置文件？(y=保留/n=连配置文件一起删)'
        read -r keep_env
        if [ "$keep_env" = "n" ] || [ "$keep_env" = "N" ]; then
            rm -f "$ENV_FILE"
            info '已清除配置文件。'
        fi
        info '✨ 机器人已从本台 Alpine Linux 上彻底卸载！'
    else
        info '已取消卸载。'
    fi
}

# 3. 基础服务运维控制
control_service() {
    action=$1
    if [ ! -f "$SERVICE_FILE" ]; then
        err '机器人未安装，请先执行安装！'
        return
    fi
    info "正在执行 OpenRC: rc-service $APP_NAME $action"
    rc-service "$APP_NAME" "$action"
}

view_logs() {
    # Alpine 的 OpenRC 默认后台挂载不生产全局独立日志，直接尝试读取标准错误捕获或查看进程
    if [ -f "/var/log/$APP_NAME.log" ]; then
        tail -n 50 "/var/log/$APP_NAME.log"
    else
        info '正在检查当前进程运行状态:'
        ps | grep tg_docker_manager.py | grep -v grep || warn "未发现正在运行的进程。"
    fi
}

edit_config() {
    if [ -f "$ENV_FILE" ]; then
        vi "$ENV_FILE"
        info "配置更新成功，请选择重启服务使配置生效！"
    else
        err "配置文件 $ENV_FILE 不存在"
    fi
}

# 4. 终端交互主菜单
show_menu() {
    clear
    echo "=================================================="
    echo "             TG Docker Manager -菜单"
    echo "=================================================="
    echo " 1.  安装 机器人环境与服务"
    echo " 2.  卸载 机器人系统与服务"
    echo "──────────────────────────────────────────────────"
    echo " 3.  启动 机器人后台守护服务"
    echo " 4.  停止 机器人后台服务"
    echo " 5.  重启 机器人服务"
    echo " 6.  查看 机器人当前服务状态"
    echo "──────────────────────────────────────────────────"
    echo " 7.  修改 机器人秘钥与环境变量配置"
    echo " 8.  查看 机器人本地运行进程/日志"
    echo " 0.  退出"
    echo "=================================================="
    printf "请输入数字: "
    read -r opt
    case $opt in
        1) install_bot ;;
        2) uninstall_bot ;;
        3) control_service start ;;
        4) control_service stop ;;
        5) control_service restart ;;
        6) control_service status ;;
        7) edit_config ;;
        8) view_logs ;;
        0) exit 0 ;;
        *) err "输入错误，请输入 0-8 之间的数字！"; sleep 2; show_menu ;;
    esac
}

# 进入主循环流程
require_root
require_alpine

while true; do
    show_menu
    echo "\n按任意键返回主菜单..."
    # 兼容 BusyBox 的普通 read 读取
    read -r dummy
done
