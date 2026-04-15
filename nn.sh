#!/usr/bin/env bash
set -euo pipefail

APP_NAME='tg-docker-manager'
INSTALL_DIR='/opt/tg-docker-manager'
APP_FILE="$INSTALL_DIR/tg_docker_manager.py"
ENV_FILE='/etc/tg-docker-manager.env'
SERVICE_FILE='/etc/systemd/system/tg-docker-manager.service'
PROJECTS_DIR='/opt'

GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
RESET='\033[0m'

info() { echo -e "${GREEN}[信息] $*${RESET}"; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}"; }
err() { echo -e "${RED}[错误] $*${RESET}" >&2; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || { err '请用 root 运行'; exit 1; }
}

require_debian_ubuntu() {
  [[ -f /etc/os-release ]] || { err '无法识别系统，只支持 Debian/Ubuntu'; exit 1; }
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *)
      [[ "${ID_LIKE:-}" == *debian* ]] || { err "只支持 Debian/Ubuntu，当前: ${PRETTY_NAME:-unknown}"; exit 1; }
      ;;
  esac
}

install_deps() {
  info '安装依赖...'
  apt-get update
  apt-get install -y python3 curl ca-certificates
  if ! command -v docker >/dev/null 2>&1; then
    warn '未检测到 docker。脚本不会自动安装 Docker，请先自行安装 Docker 和 docker compose 插件。'
  fi
}

write_app() {
  mkdir -p "$INSTALL_DIR"
  cat > "$APP_FILE" <<'PYEOF'
#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

BOT_TOKEN = os.environ.get("TG_BOT_TOKEN", "")
ALLOWED_CHAT_ID = os.environ.get("TG_ALLOWED_CHAT_ID", "")
PROJECTS_DIR = Path(os.environ.get("PROJECTS_DIR", "/opt"))
POLL_TIMEOUT = int(os.environ.get("TG_POLL_TIMEOUT", "30"))
LOG_LINES_DEFAULT = int(os.environ.get("TG_LOG_LINES", "80"))

COMPOSE_FILES = [
    "docker-compose.yml",
    "docker-compose.yaml",
    "compose.yml",
    "compose.yaml",
]
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
    if not BOT_TOKEN:
        print("Missing TG_BOT_TOKEN", file=sys.stderr)
        sys.exit(1)
    if not ALLOWED_CHAT_ID:
        print("Missing TG_ALLOWED_CHAT_ID", file=sys.stderr)
        sys.exit(1)


def set_bot_commands() -> None:
    commands = [
        {"command": "start", "description": "打开管理面板"},
        {"command": "help", "description": "查看可用命令"},
    ]
    try:
        tg_api("setMyCommands", {"commands": json.dumps(commands)})
    except Exception as e:
        print(f"setMyCommands failed: {e}", file=sys.stderr)


def tg_api(method: str, payload: Optional[dict] = None) -> dict:
    payload = payload or {}
    data = urllib.parse.urlencode(payload).encode()
    req = urllib.request.Request(f"{API_BASE}/{method}", data=data)
    with urllib.request.urlopen(req, timeout=POLL_TIMEOUT + 15) as resp:
        return json.loads(resp.read().decode())


def split_text(text: str, limit: int = 3500) -> List[str]:
    if len(text) <= limit:
        return [text]
    parts: List[str] = []
    buf = ""
    for line in text.splitlines(True):
        if len(buf) + len(line) > limit and buf:
            parts.append(buf)
            buf = line
        else:
            buf += line
    if buf:
        parts.append(buf)
    return parts


def send_message(chat_id: str, text: str, reply_markup: Optional[dict] = None) -> None:
    chunks = split_text(text)
    for idx, chunk in enumerate(chunks):
        payload = {"chat_id": chat_id, "text": chunk}
        if reply_markup and idx == len(chunks) - 1:
            payload["reply_markup"] = json.dumps(reply_markup)
        tg_api("sendMessage", payload)


def answer_callback(callback_id: str, text: str = "") -> None:
    payload = {"callback_query_id": callback_id}
    if text:
        payload["text"] = text
    tg_api("answerCallbackQuery", payload)


def edit_message(chat_id: str, message_id: int, text: str, reply_markup: Optional[dict] = None) -> None:
    payload = {
        "chat_id": chat_id,
        "message_id": message_id,
        "text": text,
    }
    if reply_markup is not None:
        payload["reply_markup"] = json.dumps(reply_markup)
    tg_api("editMessageText", payload)


def run_shell(cmd: List[str], cwd: Optional[Path] = None, timeout: int = 300) -> Tuple[int, str]:
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd) if cwd else None,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return 124, f"命令超时({timeout} 秒)"
    except Exception as e:
        return 1, f"执行失败: {e}"
    output = ((proc.stdout or "") + ("\n" + proc.stderr if proc.stderr else "")).strip()
    return proc.returncode, output or "(无输出)"


def localize_docker_text(text: str) -> str:
    replacements = {
        "NAMES": "名称",
        "NAME": "名称",
        "IMAGES": "镜像",
        "IMAGE": "镜像",
        "COMMAND": "命令",
        "SERVICES": "服务",
        "SERVICE": "服务",
        "CREATED": "创建时间",
        "STATUS": "状态",
        "PORTS": "端口",
        "Running": "运行中",
        "Exited": "已退出",
        "Restarting": "重启中",
        "Paused": "已暂停",
        "Created": "已创建",
        "Up ": "运行中 ",
        "About a minute": "约 1 分钟",
        "About an hour": "约 1 小时",
        "Less than a second": "不到 1 秒",
        "seconds ago": "秒前",
        "minutes ago": "分钟前",
        "hours ago": "小时前",
        "days ago": "天前",
        " seconds": " 秒",
        " minutes": " 分钟",
        " hours": " 小时",
        " days": " 天",
        "active": "运行中",
        "inactive": "未运行",
        "failed": "异常",
        "activating": "启动中",
        "deactivating": "停止中",
    }
    for src, dst in replacements.items():
        text = text.replace(src, dst)
    return text


def find_compose_file(directory: Path) -> Optional[Path]:
    for filename in COMPOSE_FILES:
        candidate = directory / filename
        if candidate.exists():
            return candidate
    return None


def discover_projects() -> Dict[str, Project]:
    projects: Dict[str, Project] = {}
    if PROJECTS_DIR.exists():
        for item in sorted(PROJECTS_DIR.iterdir()):
            if not item.is_dir():
                continue
            compose_file = find_compose_file(item)
            if compose_file:
                projects[item.name] = Project(item.name, item, compose_file)

    for name, raw_path in CUSTOM_PROJECT_PATHS.items():
        directory = Path(raw_path)
        if not directory.exists():
            continue
        compose_file = find_compose_file(directory)
        if compose_file:
            projects[name] = Project(name, directory, compose_file)
    return projects


def resolve_project(name: str) -> Optional[Project]:
    return discover_projects().get(name.strip().rstrip("/"))


def run_compose(project: Project, args: List[str], timeout: int = 300) -> Tuple[int, str]:
    return run_shell(["docker", "compose", "-f", str(project.compose_file)] + args, cwd=project.directory, timeout=timeout)


def format_ports(raw_ports: str) -> str:
    if not raw_ports:
        return "无"
    return raw_ports.replace(", ", "\n")


def status_text(project: Project) -> str:
    code, out = run_compose(project, ["ps", "--format", "json"])
    head = f"项目: {project.name}\n目录: {project.directory}\n"
    if code != 0:
        return head + f"状态查询失败(exit={code})\n{localize_docker_text(out)}"

    try:
        parsed = json.loads(out)
        if isinstance(parsed, list):
            rows = parsed
        elif isinstance(parsed, dict):
            rows = [parsed]
        else:
            rows = []
    except Exception:
        rows = []
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
                if isinstance(item, dict):
                    rows.append(item)
            except Exception:
                return head + localize_docker_text(out)

    if not rows:
        return head + "当前没有容器"

    blocks = []
    for row in rows:
        name = row.get("Name") or row.get("Service") or "(未知容器)"
        image = row.get("Image", "-")
        service = row.get("Service", "-")
        state = localize_docker_text(row.get("State", "-"))
        status = localize_docker_text(row.get("Status", "-"))
        created = localize_docker_text(row.get("RunningFor", row.get("CreatedAt", "-")))
        ports = format_ports(row.get("Publishers") and "\n".join(
            f"{p.get('URL', '0.0.0.0')}:{p.get('PublishedPort')} -> {p.get('TargetPort')}/{p.get('Protocol', '')}".rstrip('/')
            for p in row.get("Publishers", [])
        ) or row.get("Ports", ""))
        blocks.append(
            f"【{name}】\n"
            f"服务:{service}\n"
            f"镜像:{image}\n"
            f"状态:{state}\n"
            f"详情:{status}\n"
            f"运行:{created}\n"
            f"端口:{ports}"
        )

    return head + "\n\n".join(blocks)


def main_keyboard() -> dict:
    return {
        "inline_keyboard": [
            [{"text": "📦 项目列表", "callback_data": "menu:list"}],
            [{"text": "🎬 应用快捷管理", "callback_data": "menu:apps"}],
            [{"text": "🐳 Docker 管理", "callback_data": "menu:docker"}],
            [{"text": "🖥 系统管理", "callback_data": "menu:system"}],
        ]
    }


def system_manage_keyboard() -> dict:
    return {
        "inline_keyboard": [
            [{"text": "📡 系统信息", "callback_data": "system:info"}],
            [{"text": "🌐 网络信息", "callback_data": "system:network"}],
            [{"text": "🧽 一键清理", "callback_data": "confirm_global:system_cleanup"}],
            [{"text": "⬅️ 返回", "callback_data": "menu:home"}],
        ]
    }


def custom_apps_keyboard() -> dict:
    rows = []
    for name in CUSTOM_PROJECT_PATHS.keys():
        rows.append([{"text": name, "callback_data": f"project:{name}"}])
    rows.append([{"text": "⬅️ 返回", "callback_data": "menu:home"}])
    return {"inline_keyboard": rows}


def docker_manage_keyboard() -> dict:
    return {
        "inline_keyboard": [
            [{"text": "📊 Docker 概览", "callback_data": "docker:overview"}],
            [{"text": "📦 运行中的容器", "callback_data": "docker:running"}],
            [{"text": "🧰 容器管理", "callback_data": "docker:containers"}],
            [{"text": "📈 容器占用", "callback_data": "docker:stats"}],
            [{"text": "🔄 重启 Docker", "callback_data": "confirm_global:docker_restart"}],
            [{"text": "🧹 一键清理无用镜像/卷/网络", "callback_data": "docker:prune_all"}],
            [{"text": "⬅️ 返回", "callback_data": "menu:home"}],
        ]
    }


def project_list_keyboard(projects: Dict[str, Project]) -> dict:
    rows = []
    for name in sorted(projects.keys()):
        rows.append([{"text": name, "callback_data": f"project:{name}"}])
    rows.append([{"text": "⬅️ 返回", "callback_data": "menu:home"}])
    return {"inline_keyboard": rows}


def project_keyboard(project_name: str) -> dict:
    return {
        "inline_keyboard": [
            [
                {"text": "▶️ 启动", "callback_data": f"action:up:{project_name}"},
                {"text": "⏹ 停止", "callback_data": f"action:stop:{project_name}"},
            ],
            [
                {"text": "🔄 重启", "callback_data": f"action:restart:{project_name}"},
                {"text": "📥 拉镜像", "callback_data": f"action:pull:{project_name}"},
            ],
            [
                {"text": "♻️ 更新并重启", "callback_data": f"action:update_restart:{project_name}"},
            ],
            [
                {"text": "📜 日志", "callback_data": f"action:logs:{project_name}"},
                {"text": "📊 状态", "callback_data": f"action:status:{project_name}"},
            ],
            [
                {"text": "🗑 删除容器", "callback_data": f"confirm:delete_container:{project_name}"},
            ],
            [
                {"text": "☠️ 删除容器+文件数据", "callback_data": f"confirm:delete_all:{project_name}"},
            ],
            [
                {"text": "⬅️ 项目列表", "callback_data": "menu:list"},
                {"text": "🏠 首页", "callback_data": "menu:home"},
            ],
        ]
    }


def confirm_keyboard(project_name: str, action: str) -> dict:
    return {
        "inline_keyboard": [
            [{"text": "✅ 确认执行", "callback_data": f"action:{action}:{project_name}"}],
            [{"text": "❌ 取消", "callback_data": f"project:{project_name}"}],
        ]
    }


def confirm_text(project_name: str, action: str) -> str:
    if action == "delete_container":
        return (
            f"危险操作确认\n\n"
            f"项目:{project_name}\n"
            f"动作:删除容器\n\n"
            f"这会执行 docker compose down -v --rmi all。"
        )
    if action == "delete_all":
        return (
            f"危险操作确认\n\n"
            f"项目:{project_name}\n"
            f"动作:删除容器 + 文件数据\n\n"
            f"这会先执行 docker compose down -v --rmi all,然后删除整个项目目录。"
        )
    return "未知确认操作"


def help_text() -> str:
    return (
        "可用命令:\n"
        "/start - 打开主菜单\n"
        "/list - 列出 /opt 下项目\n"
        "/status <项目> - 查看状态\n"
        "/up <项目> - 启动\n"
        "/down <项目> - 停止\n"
        "/restart <项目> - 重启\n"
        "/pull <项目> - 拉镜像\n"
        "/update <项目> - 更新镜像并重启\n"
        "/logs <项目> [行数] - 查看日志\n"
        "/ps - 查看运行中的容器\n"
        "/docker - 打开 Docker 管理\n"
        "/docker_overview - 查看 Docker 概览\n"
        "/docker_stats - 查看容器占用\n"
        "/docker_restart - 重启 Docker\n"
        "/docker_prune - 清理无用镜像/卷/网络\n"
    )


def send_project_list(chat_id: str) -> None:
    projects = discover_projects()
    if not projects:
        send_message(chat_id, f"/opt 下没找到 compose 项目\n扫描目录: {PROJECTS_DIR}", main_keyboard())
        return
    send_message(chat_id, f"找到 {len(projects)} 个项目,点按钮管理:", project_list_keyboard(projects))


def docker_overview_text() -> str:
    ps_code, ps_out = run_shell(["docker", "ps", "--format", "{{json .}}"], timeout=60)
    images_code, images_out = run_shell(["sh", "-lc", "docker image ls -q | sort -u | wc -l"], timeout=60)
    all_containers_code, all_containers_out = run_shell(["sh", "-lc", "docker ps -aq | wc -l"], timeout=60)
    running_code, running_out = run_shell(["sh", "-lc", "docker ps -q | wc -l"], timeout=60)
    volumes_code, volumes_out = run_shell(["sh", "-lc", "docker volume ls -q | wc -l"], timeout=60)
    networks_code, networks_out = run_shell(["sh", "-lc", "docker network ls --format '{{.Name}}' | wc -l"], timeout=60)

    lines = [
        "Docker 概览",
        f"运行中的容器:{running_out.strip() if running_code == 0 else '获取失败'}",
        f"全部容器:{all_containers_out.strip() if all_containers_code == 0 else '获取失败'}",
        f"镜像数量:{images_out.strip() if images_code == 0 else '获取失败'}",
        f"卷数量:{volumes_out.strip() if volumes_code == 0 else '获取失败'}",
        f"网络数量:{networks_out.strip() if networks_code == 0 else '获取失败'}",
    ]

    if ps_code != 0:
        lines.append("")
        lines.append(f"读取运行中容器失败(exit={ps_code})")
        lines.append(localize_docker_text(ps_out))
        return "\n".join(lines)

    try:
        rows = [json.loads(line) for line in ps_out.splitlines() if line.strip()]
    except Exception:
        lines.append("")
        lines.append(localize_docker_text(ps_out) if ps_out.strip() else "当前没有运行中的容器")
        return "\n".join(lines)

    if not rows:
        lines.append("")
        lines.append("当前没有运行中的容器")
        return "\n".join(lines)

    lines.append("")
    lines.append("运行中的容器:")
    for row in rows:
        name = row.get("Names") or row.get("Name") or "(未知容器)"
        image = row.get("Image", "-")
        status = localize_docker_text(row.get("Status", row.get("State", "-")))
        ports = format_ports(row.get("Ports", ""))
        lines.append(
            f"【{name}】\n"
            f"镜像:{image}\n"
            f"状态:{status}\n"
            f"端口:{ports}"
        )

    return "\n\n".join(lines)


def docker_running_text() -> str:
    code, out = run_shell(["docker", "ps", "--format", "{{json .}}"], timeout=60)
    if code != 0:
        return f"查看运行中容器失败(exit={code})\n{localize_docker_text(out)}"
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if not line or line == "(无输出)":
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            return localize_docker_text(out)
    if not rows:
        return "运行中的容器\n\n无"
    blocks = []
    for row in rows:
        blocks.append(
            f"【{row.get('Names', '(未知容器)')}】\n"
            f"镜像:{row.get('Image', '-')}\n"
            f"状态:{localize_docker_text(row.get('Status', '-'))}\n"
            f"端口:{format_ports(row.get('Ports', ''))}"
        )
    return "运行中的容器\n\n" + "\n\n".join(blocks)


def docker_all_containers() -> List[dict]:
    code, out = run_shell(["docker", "ps", "-a", "--format", "{{json .}}"], timeout=60)
    if code != 0:
        return []
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if not line or line == "(无输出)":
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            pass
    return rows


def docker_containers_keyboard() -> dict:
    rows = []
    for row in docker_all_containers():
        name = row.get("Names") or row.get("Name") or "(未知容器)"
        status = localize_docker_text(row.get("Status", "-"))
        rows.append([{"text": f"{name}|{status}", "callback_data": f"container:{name}"}])
    if not rows:
        rows.append([{"text": "(没有容器)", "callback_data": "menu:docker"}])
    rows.append([{"text": "⬅️ 返回", "callback_data": "menu:docker"}])
    return {"inline_keyboard": rows}


def container_detail_text(name: str) -> str:
    code, out = run_shell(["docker", "ps", "-a", "--filter", f"name=^{name}$", "--format", "{{json .}}"], timeout=60)
    if code != 0 or not out.strip() or out.strip() == "(无输出)":
        return f"容器不存在:{name}"
    try:
        row = json.loads(out.splitlines()[0])
    except Exception:
        return localize_docker_text(out)
    return (
        f"容器：{row.get('Names', name)}\n"
        f"镜像：{row.get('Image', '-')}\n"
        f"状态：{localize_docker_text(row.get('Status', '-'))}\n"
        f"端口：{row.get('Ports', '无')}"
    )


def container_keyboard(name: str) -> dict:
    return {
        "inline_keyboard": [
            [{"text": "▶️ 启动", "callback_data": f"container_action:start:{name}"}, {"text": "⏹ 停止", "callback_data": f"container_action:stop:{name}"}],
            [{"text": "🔄 重启", "callback_data": f"container_action:restart:{name}"}, {"text": "📜 日志", "callback_data": f"container_action:logs:{name}"}],
            [{"text": "🗑 删除容器", "callback_data": f"confirm_container:remove:{name}"}],
            [{"text": "⬅️ 容器列表", "callback_data": "docker:containers"}, {"text": "🏠 Docker 管理", "callback_data": "menu:docker"}],
        ]
    }


def global_confirm_keyboard(action: str) -> dict:
    confirm_callback = "system:cleanup" if action == "system_cleanup" else ("docker:restart" if action == "docker_restart" else f"docker:{action}")
    cancel_callback = "menu:system" if action == "system_cleanup" else "menu:docker"
    return {
        "inline_keyboard": [
            [{"text": "✅ 确认执行", "callback_data": confirm_callback}],
            [{"text": "❌ 取消", "callback_data": cancel_callback}],
        ]
    }


def global_confirm_text(action: str) -> str:
    if action == "docker_restart":
        return "危险操作确认\n\n动作:重启 Docker\n\n这会重启 Docker 服务,短时间内可能影响容器连接。"
    if action == "system_cleanup":
        return "危险操作确认\n\n动作:一键清理系统日志/缓存/Docker垃圾\n\n这会清理 journal 日志、软件包缓存,以及 Docker 无用镜像、卷、网络。"
    return "未知确认操作"


def container_confirm_keyboard(action: str, name: str) -> dict:
    return {
        "inline_keyboard": [
            [{"text": "✅ 确认执行", "callback_data": f"container_action:{action}:{name}"}],
            [{"text": "❌ 取消", "callback_data": f"container:{name}"}],
        ]
    }


def container_confirm_text(action: str, name: str) -> str:
    if action == "remove":
        return f"危险操作确认\n\n容器:{name}\n动作:删除容器+镜像\n\n这会先删除容器，再尝试删除该容器使用的镜像。"
    return "未知确认操作"


def container_action_text(action: str, name: str) -> str:
    if action == "start":
        code, out = run_shell(["docker", "start", name], timeout=120)
        return f"[{name}] 启动完成(退出码={code})\n{localize_docker_text(out)}"
    if action == "stop":
        code, out = run_shell(["docker", "stop", name], timeout=120)
        return f"[{name}] 停止完成(退出码={code})\n{localize_docker_text(out)}"
    if action == "restart":
        code, out = run_shell(["docker", "restart", name], timeout=120)
        return f"[{name}] 重启完成(退出码={code})\n{localize_docker_text(out)}"
    if action == "logs":
        code, out = run_shell(["docker", "logs", "--tail", str(LOG_LINES_DEFAULT), name], timeout=120)
        return f"[{name}] 日志(退出码={code})\n{localize_docker_text(out)}"
    if action == "remove":
        inspect_code, inspect_out = run_shell(["docker", "inspect", "-f", "{{.Config.Image}}", name], timeout=30)
        image_name = inspect_out.strip() if inspect_code == 0 else ""
        code1, out1 = run_shell(["docker", "rm", "-f", name], timeout=120)
        if image_name:
            code2, out2 = run_shell(["docker", "rmi", "-f", image_name], timeout=120)
        else:
            code2, out2 = 0, "(未获取到镜像名)"
        return f"[{name}] 删除容器+镜像完成（rm={code1}, rmi={code2}）\n[删除容器]\n{localize_docker_text(out1)}\n\n[删除镜像]\n{localize_docker_text(out2)}"
    return "未知容器操作"


def docker_stats_text() -> str:
    code, out = run_shell([
        "docker", "stats", "--no-stream", "--format", "{{json .}}"
    ], timeout=120)
    if code != 0:
        return f"查看容器占用失败(exit={code})\n{localize_docker_text(out)}"
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if not line or line == "(无输出)":
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            return localize_docker_text(out)
    if not rows:
        return "当前没有可显示的容器占用"
    blocks = []
    for row in rows:
        blocks.append(
            f"【{row.get('Name', '(未知容器)')}】\n"
            f"CPU:{row.get('CPUPerc', '-')}\n"
            f"内存:{row.get('MemUsage', '-')}\n"
            f"内存占比:{row.get('MemPerc', '-')}\n"
            f"网络 I/O:{row.get('NetIO', '-')}\n"
            f"磁盘 I/O:{row.get('BlockIO', '-')}"
        )
    return "容器占用\n\n" + "\n\n".join(blocks)


def docker_restart_text() -> str:
    code, out = run_shell(["systemctl", "restart", "docker.service"], timeout=120)
    if code != 0:
        return f"重启 Docker 失败(exit={code})\n{out}"
    time.sleep(5)
    status_code, status_out = run_shell(["systemctl", "is-active", "docker.service"], timeout=30)
    status = localize_docker_text(status_out.strip()) if status_code == 0 else f"未知(exit={status_code})"
    if status.strip() != "运行中":
        detail_code, detail_out = run_shell(["journalctl", "-u", "docker.service", "-n", "20", "--no-pager"], timeout=60)
        return f"Docker 重启后状态异常\n当前状态:{status}\n\n最近日志:\n{localize_docker_text(detail_out)}"
    return f"✅ Docker 已重启\n当前状态:{status}"


def docker_prune_text() -> str:
    image_code, image_out = run_shell(["docker", "image", "prune", "-a", "-f"], timeout=120)
    volume_code, volume_out = run_shell(["docker", "volume", "prune", "-f"], timeout=120)
    network_code, network_out = run_shell(["docker", "network", "prune", "-f"], timeout=120)
    return (
        f"一键清理完成\n"
        f"[无用镜像] exit={image_code}\n{localize_docker_text(image_out)}\n\n"
        f"[无用卷] exit={volume_code}\n{localize_docker_text(volume_out)}\n\n"
        f"[无用网络] exit={network_code}\n{localize_docker_text(network_out)}"
    )


def _format_bytes(num: int) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    value = float(num)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            return f"{value:.2f} {unit}"
        value /= 1024
    return f"{num} B"


def system_info_text() -> str:
    hostname = run_shell(["hostname"], timeout=10)[1]
    os_info = run_shell(["sh", "-lc", ". /etc/os-release 2>/dev/null; echo ${PRETTY_NAME:-未知系统}"], timeout=10)[1]
    kernel = run_shell(["uname", "-r"], timeout=10)[1]
    arch = run_shell(["uname", "-m"], timeout=10)[1]
    cpu_model = run_shell(["sh", "-lc", "lscpu | awk -F: '/Model name/ {gsub(/^ +/,\"\",$2); print $2; exit}'"], timeout=10)[1]
    cpu_cores = run_shell(["nproc"], timeout=10)[1]
    mem = run_shell(["sh", "-lc", "free -h | awk '/Mem:/ {print $3 \" / \" $2}'"], timeout=10)[1]
    swap_total = run_shell(["sh", "-lc", "free -b | awk '/Swap:/ {print $2}'"], timeout=10)[1].strip()
    swap_used = run_shell(["sh", "-lc", "free -h | awk '/Swap:/ {print $3}'"], timeout=10)[1].strip()
    swap_total_h = run_shell(["sh", "-lc", "free -h | awk '/Swap:/ {print $2}'"], timeout=10)[1].strip()
    swap = "未启用" if swap_total in {"0", "0B", "0.0B", ""} or swap_total_h in {"0B", "0", "0.0B"} else f"{swap_used} / {swap_total_h}"
    disk = run_shell(["sh", "-lc", "df -h / | awk 'NR==2 {print $3 \" / \" $2 \" (\" $5 \")\"}'"], timeout=10)[1]
    dns = run_shell(["sh", "-lc", "grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd ',' -"], timeout=10)[1]
    ipv4 = run_shell(["sh", "-lc", "curl -4s --max-time 5 https://api.ipify.org || wget -4qO- --timeout=5 https://api.ipify.org || true"], timeout=10)[1]
    ipv6 = run_shell(["sh", "-lc", "curl -6s --max-time 5 https://api64.ipify.org || wget -6qO- --timeout=5 https://api64.ipify.org || true"], timeout=10)[1]
    geo = run_shell(["sh", "-lc", "curl -4s --max-time 5 https://ipinfo.io/json || wget -4qO- --timeout=5 https://ipinfo.io/json || true"], timeout=10)[1]
    isp = city = country = org = "未知"
    try:
        geo_data = json.loads(geo)
        city = geo_data.get("city") or "未知"
        country = geo_data.get("country") or "未知"
        org = geo_data.get("org") or "未知"
    except Exception:
        pass
    uptime = run_shell(["uptime", "-p"], timeout=10)[1]
    uptime = (uptime.replace("up ", "")
                    .replace(" hours", " 小时")
                    .replace(" hour", " 小时")
                    .replace(" minutes", " 分钟")
                    .replace(" minute", " 分钟")
                    .replace(" days", " 天")
                    .replace(" day", " 天")
                    .replace(",", ""))
    current_time = run_shell(["date", "+%Y-%m-%d %H:%M:%S %Z"], timeout=10)[1]
    traffic = run_shell(["python3", "-c", "import os; rx=tx=0\nfrom pathlib import Path\nfor line in Path('/proc/net/dev').read_text().splitlines()[2:]:\n    iface,data=line.split(':',1)\n    iface=iface.strip()\n    if iface=='lo':\n        continue\n    cols=data.split()\n    rx += int(cols[0]); tx += int(cols[8])\nprint(f'{rx} {tx}')"], timeout=10)[1].split()
    total_rx = _format_bytes(int(traffic[0])) if len(traffic) == 2 else "未知"
    total_tx = _format_bytes(int(traffic[1])) if len(traffic) == 2 else "未知"
    congestion = run_shell(["sh", "-lc", "cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo 未知"], timeout=10)[1]
    qdisc = run_shell(["sh", "-lc", "cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo 未知"], timeout=10)[1]
    return (
        "📡 VPS 系统信息\n"
        "━━━━━━━━━━\n"
        f"主机名:{hostname}\n"
        f"运营商:{org}\n"
        f"地理位置:{country} {city}\n"
        f"系统版本:{os_info}\n"
        f"内核版本:{kernel}\n"
        f"CPU 架构:{arch}\n"
        f"CPU 型号:{cpu_model}\n"
        f"CPU 核心数:{cpu_cores}\n"
        f"物理内存:{mem}\n"
        f"虚拟内存:{swap}\n"
        f"硬盘占用:{disk}\n"
        f"总接收:{total_rx}\n"
        f"总发送:{total_tx}\n"
        f"网络拥堵算法:{congestion} {qdisc}\n"
        f"公网 IPv4:{ipv4 or '无'}\n"
        f"公网 IPv6:{ipv6 or '无'}\n"
        f"DNS 服务器:{dns or '无'}\n"
        f"系统时间:{current_time}\n"
        f"运行时长:{uptime}"
    )


def network_info_text() -> str:
    interfaces = run_shell(["sh", "-lc", "for IFACE in $(ls /sys/class/net/); do echo \"接口: $IFACE\"; ip -4 addr show $IFACE | grep -oP 'inet \\K[\\d./]+' | sed 's/^/IPv4: /' || echo 'IPv4: 无'; ip -6 addr show $IFACE scope global | grep -oP 'inet6 \\K[0-9a-f:]+/[0-9]+' | sed 's/^/IPv6: /' || echo 'IPv6: 无'; ip -6 addr show $IFACE scope link | grep -oP 'inet6 \\K[0-9a-f:]+/[0-9]+' | sed 's/^/链路本地 IPv6: /' || true; echo \"MAC: $(cat /sys/class/net/$IFACE/address)\"; echo; done"], timeout=30)[1]
    route4 = run_shell(["ip", "route", "show", "default"], timeout=10)[1]
    route6 = run_shell(["ip", "-6", "route", "show", "default"], timeout=10)[1]
    ping4 = run_shell(["ping", "-c", "2", "-W", "2", "8.8.8.8"], timeout=10)[1]
    ping6 = run_shell(["ping6", "-c", "2", "-W", "2", "google.com"], timeout=10)[1]
    return (
        "🌐 VPS 网络信息\n"
        "━━━━━━━━━━\n"
        f"【网络接口】\n{interfaces}\n"
        f"【默认路由】\nIPv4 默认路由:\n{route4}\n\nIPv6 默认路由:\n{route6}\n\n"
        f"【网络连通性测试】\nIPv4 测试:\n{ping4}\n\nIPv6 测试:\n{ping6}"
    )


def system_cleanup_text() -> str:
    j_code, j_out = run_shell(["journalctl", "--vacuum-time=7d"], timeout=120)
    a_code, a_out = run_shell(["apt-get", "clean"], timeout=120)
    i_code, i_out = run_shell(["docker", "image", "prune", "-a", "-f"], timeout=120)
    v_code, v_out = run_shell(["docker", "volume", "prune", "-f"], timeout=120)
    n_code, n_out = run_shell(["docker", "network", "prune", "-f"], timeout=120)
    return (
        "系统清理完成\n\n"
        f"[日志清理] exit={j_code}\n{localize_docker_text(j_out)}\n\n"
        f"[缓存清理] exit={a_code}\n{localize_docker_text(a_out)}\n\n"
        f"[无用镜像] exit={i_code}\n{localize_docker_text(i_out)}\n\n"
        f"[无用卷] exit={v_code}\n{localize_docker_text(v_out)}\n\n"
        f"[无用网络] exit={n_code}\n{localize_docker_text(n_out)}"
    )


def home_text() -> str:
    docker_code, docker_status = run_shell(["systemctl", "is-active", "docker"], timeout=30)
    running_code, running_out = run_shell(["sh", "-lc", "docker ps -q | wc -l"], timeout=30)
    all_code, all_out = run_shell(["sh", "-lc", "docker ps -aq | wc -l"], timeout=30)
    projects = discover_projects()

    docker_line = localize_docker_text(docker_status.strip()) if docker_code == 0 else "未知"
    running_line = running_out.strip() if running_code == 0 else "获取失败"
    all_line = all_out.strip() if all_code == 0 else "获取失败"

    return (
        "Docker 运行面板\n"
        f"Docker 状态:{docker_line}\n"
        f"运行中的容器:{running_line}\n"
        f"全部容器:{all_line}\n"
        f"项目数量:{len(projects)}"
    )


def handle_text_command(chat_id: str, text: str) -> None:
    parts = text.strip().split()
    if not parts:
        send_message(chat_id, "发 /start。", main_keyboard())
        return
    cmd = parts[0].lower()

    if cmd == "/start":
        send_message(chat_id, home_text(), main_keyboard())
        return
    if cmd == "/help":
        send_message(chat_id, help_text(), main_keyboard())
        return
    if cmd == "/list":
        send_project_list(chat_id)
        return
    if cmd == "/apps":
        send_message(chat_id, "应用快捷管理", custom_apps_keyboard())
        return
    if cmd == "/ps":
        send_message(chat_id, docker_running_text(), docker_manage_keyboard())
        return
    if cmd == "/docker":
        send_message(chat_id, "Docker 管理", docker_manage_keyboard())
        return
    if cmd == "/system":
        send_message(chat_id, "系统管理", system_manage_keyboard())
        return
    if cmd == "/docker_overview":
        send_message(chat_id, docker_overview_text(), docker_manage_keyboard())
        return
    if cmd == "/docker_stats":
        send_message(chat_id, docker_stats_text(), docker_manage_keyboard())
        return
    if cmd == "/docker_restart":
        send_message(chat_id, docker_restart_text(), docker_manage_keyboard())
        return
    if cmd == "/docker_prune":
        send_message(chat_id, docker_prune_text(), docker_manage_keyboard())
        return

    if len(parts) < 2:
        send_message(chat_id, "缺少项目名。先用 /list 或按钮选项目。", main_keyboard())
        return

    project = resolve_project(parts[1])
    if not project:
        send_message(chat_id, f"项目不存在: {parts[1]}", main_keyboard())
        return

    if cmd == "/status":
        send_message(chat_id, status_text(project), project_keyboard(project.name))
        return
    if cmd == "/up":
        code, out = run_compose(project, ["up", "-d"])
        send_message(chat_id, f"[{project.name}] 启动完成(退出码={code})\n{localize_docker_text(out)}", project_keyboard(project.name))
        return
    if cmd == "/stop":
        code, out = run_compose(project, ["stop"])
        send_message(chat_id, f"[{project.name}] 停止完成(退出码={code})\n{localize_docker_text(out)}", project_keyboard(project.name))
        return
    if cmd == "/delete":
        code, out = run_compose(project, ["down", "-v", "--rmi", "all"])
        send_message(chat_id, f"[{project.name}] 删除容器完成(退出码={code})\n{localize_docker_text(out)}", project_keyboard(project.name))
        return
    if cmd == "/deleteall":
        code1, out1 = run_compose(project, ["down", "-v", "--rmi", "all"])
        code2, out2 = run_shell(["rm", "-rf", str(project.directory)])
        send_message(chat_id, f"[{project.name}] 删除容器+文件数据完成(down={code1}, rm={code2})\n[删除容器]\n{localize_docker_text(out1)}\n\n[删除文件数据]\n{localize_docker_text(out2)}", project_keyboard(project.name))
        return
    if cmd == "/restart":
        code, out = run_compose(project, ["restart"])
        send_message(chat_id, f"[{project.name}] 重启完成(退出码={code})\n{localize_docker_text(out)}", project_keyboard(project.name))
        return
    if cmd == "/pull":
        code, out = run_compose(project, ["pull"])
        send_message(chat_id, f"[{project.name}] 拉取镜像完成(退出码={code})\n{localize_docker_text(out)}", project_keyboard(project.name))
        return
    if cmd == "/update":
        pull_code, pull_out = run_compose(project, ["pull"])
        if pull_code != 0:
            send_message(chat_id, f"[{project.name}] 更新失败(退出码={pull_code})\n[拉取镜像]\n{localize_docker_text(pull_out)}", project_keyboard(project.name))
            return
        up_code, up_out = run_compose(project, ["up", "-d"])
        if up_code != 0:
            send_message(chat_id, f"[{project.name}] 更新并重启失败(pull=0, up={up_code})\n[拉取镜像]\n{localize_docker_text(pull_out)}\n\n[启动服务]\n{localize_docker_text(up_out)}", project_keyboard(project.name))
            return
        prune_code, prune_out = run_shell(["docker", "image", "prune", "-a", "-f"], timeout=120)
        send_message(chat_id, f"[{project.name}] 更新并重启完成(pull=0, up=0, prune={prune_code})\n[拉取镜像]\n{localize_docker_text(pull_out)}\n\n[启动服务]\n{localize_docker_text(up_out)}\n\n[清理无用镜像]\n{localize_docker_text(prune_out)}", project_keyboard(project.name))
        return
    if cmd == "/logs":
        lines = LOG_LINES_DEFAULT
        if len(parts) >= 3:
            try:
                lines = max(1, min(500, int(parts[2])))
            except ValueError:
                send_message(chat_id, "日志行数必须是数字", project_keyboard(project.name))
                return
        code, out = run_compose(project, ["logs", "--tail", str(lines), "--no-color"], timeout=120)
        send_message(chat_id, f"[{project.name}] 日志(退出码={code})\n{localize_docker_text(out)}", project_keyboard(project.name))
        return

    send_message(chat_id, "不支持的命令", main_keyboard())


def handle_callback(callback: dict) -> None:
    callback_id = callback["id"]
    message = callback.get("message", {})
    chat_id = str(message.get("chat", {}).get("id", ""))
    message_id = message.get("message_id")
    data = callback.get("data", "")

    if chat_id != str(ALLOWED_CHAT_ID):
        return

    if data == "menu:home":
        answer_callback(callback_id)
        edit_message(chat_id, message_id, home_text(), main_keyboard())
        return

    if data == "menu:help":
        answer_callback(callback_id)
        edit_message(chat_id, message_id, help_text(), main_keyboard())
        return

    if data == "menu:ps":
        answer_callback(callback_id, "正在获取 Docker 信息")
        edit_message(chat_id, message_id, docker_running_text(), docker_manage_keyboard())
        return

    if data == "menu:docker":
        answer_callback(callback_id)
        edit_message(chat_id, message_id, "Docker 管理", docker_manage_keyboard())
        return

    if data == "menu:system":
        answer_callback(callback_id)
        edit_message(chat_id, message_id, "系统管理", system_manage_keyboard())
        return

    if data == "menu:apps":
        answer_callback(callback_id)
        edit_message(chat_id, message_id, "应用快捷管理", custom_apps_keyboard())
        return

    if data == "menu:list":
        answer_callback(callback_id)
        projects = discover_projects()
        if not projects:
            edit_message(chat_id, message_id, f"/opt 下没找到 compose 项目\n扫描目录: {PROJECTS_DIR}", main_keyboard())
            return
        edit_message(chat_id, message_id, f"找到 {len(projects)} 个项目,点按钮管理:", project_list_keyboard(projects))
        return

    if data.startswith("docker:"):
        answer_callback(callback_id)
        if data == "docker:overview":
            edit_message(chat_id, message_id, docker_overview_text(), docker_manage_keyboard())
        elif data == "docker:running":
            edit_message(chat_id, message_id, docker_running_text(), docker_manage_keyboard())
        elif data == "docker:containers":
            edit_message(chat_id, message_id, "容器管理", docker_containers_keyboard())
        elif data == "docker:stats":
            edit_message(chat_id, message_id, docker_stats_text(), docker_manage_keyboard())
        elif data == "docker:restart":
            edit_message(chat_id, message_id, docker_restart_text(), docker_manage_keyboard())
        elif data == "docker:prune_all":
            edit_message(chat_id, message_id, docker_prune_text(), docker_manage_keyboard())
        else:
            edit_message(chat_id, message_id, "未知 Docker 操作", docker_manage_keyboard())
        return

    if data.startswith("system:"):
        answer_callback(callback_id)
        if data == "system:info":
            edit_message(chat_id, message_id, system_info_text(), system_manage_keyboard())
        elif data == "system:network":
            edit_message(chat_id, message_id, network_info_text(), system_manage_keyboard())
        elif data == "system:cleanup":
            edit_message(chat_id, message_id, system_cleanup_text(), system_manage_keyboard())
        else:
            edit_message(chat_id, message_id, "未知系统操作", system_manage_keyboard())
        return

    if data.startswith("confirm_global:"):
        _, action = data.split(":", 1)
        answer_callback(callback_id)
        edit_message(chat_id, message_id, global_confirm_text(action), global_confirm_keyboard(action))
        return

    if data.startswith("project:"):
        project_name = data.split(":", 1)[1]
        project = resolve_project(project_name)
        answer_callback(callback_id)
        if not project:
            edit_message(chat_id, message_id, f"项目不存在: {project_name}", main_keyboard())
            return
        edit_message(chat_id, message_id, status_text(project), project_keyboard(project.name))
        return

    if data.startswith("confirm_container:"):
        _, action, name = data.split(":", 2)
        answer_callback(callback_id)
        edit_message(chat_id, message_id, container_confirm_text(action, name), container_confirm_keyboard(action, name))
        return

    if data.startswith("container:"):
        name = data.split(":", 1)[1]
        answer_callback(callback_id)
        edit_message(chat_id, message_id, container_detail_text(name), container_keyboard(name))
        return

    if data.startswith("container_action:"):
        _, action, name = data.split(":", 2)
        answer_callback(callback_id)
        edit_message(chat_id, message_id, container_action_text(action, name), container_keyboard(name))
        return

    if data.startswith("confirm:"):
        _, action, project_name = data.split(":", 2)
        answer_callback(callback_id)
        edit_message(chat_id, message_id, confirm_text(project_name, action), confirm_keyboard(project_name, action))
        return

    if data.startswith("action:"):
        _, action, project_name = data.split(":", 2)
        project = resolve_project(project_name)
        if not project:
            answer_callback(callback_id, "项目不存在")
            edit_message(chat_id, message_id, f"项目不存在: {project_name}", main_keyboard())
            return

        answer_callback(callback_id, f"执行 {action} ...")
        if action == "status":
            text = status_text(project)
        elif action == "up":
            code, out = run_compose(project, ["up", "-d"])
            text = f"[{project.name}] 启动完成(退出码={code})\n{localize_docker_text(out)}"
        elif action == "stop":
            code, out = run_compose(project, ["stop"])
            text = f"[{project.name}] 停止完成(退出码={code})\n{localize_docker_text(out)}"
        elif action == "delete_container":
            code, out = run_compose(project, ["down", "-v", "--rmi", "all"])
            text = f"[{project.name}] 删除容器完成(退出码={code})\n{localize_docker_text(out)}"
        elif action == "delete_all":
            code1, out1 = run_compose(project, ["down", "-v", "--rmi", "all"])
            code2, out2 = run_shell(["rm", "-rf", str(project.directory)])
            text = f"[{project.name}] 删除容器+文件数据完成(down={code1}, rm={code2})\n[删除容器]\n{localize_docker_text(out1)}\n\n[删除文件数据]\n{localize_docker_text(out2)}"
        elif action == "restart":
            code, out = run_compose(project, ["restart"])
            text = f"[{project.name}] 重启完成(退出码={code})\n{localize_docker_text(out)}"
        elif action == "pull":
            code, out = run_compose(project, ["pull"])
            text = f"[{project.name}] 拉取镜像完成(退出码={code})\n{localize_docker_text(out)}"
        elif action == "update_restart":
            pull_code, pull_out = run_compose(project, ["pull"])
            if pull_code != 0:
                text = f"[{project.name}] 更新失败(退出码={pull_code})\n[拉取镜像]\n{localize_docker_text(pull_out)}"
            else:
                up_code, up_out = run_compose(project, ["up", "-d"])
                if up_code != 0:
                    text = f"[{project.name}] 更新并重启失败(pull=0, up={up_code})\n[拉取镜像]\n{localize_docker_text(pull_out)}\n\n[启动服务]\n{localize_docker_text(up_out)}"
                else:
                    prune_code, prune_out = run_shell(["docker", "image", "prune", "-a", "-f"], timeout=120)
                    text = f"[{project.name}] 更新并重启完成(pull=0, up=0, prune={prune_code})\n[拉取镜像]\n{localize_docker_text(pull_out)}\n\n[启动服务]\n{localize_docker_text(up_out)}\n\n[清理无用镜像]\n{localize_docker_text(prune_out)}"
        elif action == "logs":
            code, out = run_compose(project, ["logs", "--tail", str(LOG_LINES_DEFAULT), "--no-color"], timeout=120)
            text = f"[{project.name}] 日志(退出码={code})\n{localize_docker_text(out)}"
        else:
            text = "不支持的动作"
        edit_message(chat_id, message_id, text, project_keyboard(project.name))
        return

    answer_callback(callback_id, "未知操作")


def main() -> None:
    require_env()
    set_bot_commands()
    offset = 0
    print(f"TG Docker manager running. projects_dir={PROJECTS_DIR}")
    while True:
        try:
            result = tg_api("getUpdates", {
                "timeout": POLL_TIMEOUT,
                "offset": offset,
                "allowed_updates": json.dumps(["message", "edited_message", "callback_query"]),
            })
            for update in result.get("result", []):
                offset = update["update_id"] + 1

                callback = update.get("callback_query")
                if callback:
                    handle_callback(callback)
                    continue

                message = update.get("message") or update.get("edited_message")
                if not message:
                    continue
                chat_id = str(message.get("chat", {}).get("id", ""))
                text = message.get("text")
                if not chat_id or not text:
                    continue
                if chat_id != str(ALLOWED_CHAT_ID):
                    continue
                handle_text_command(chat_id, text)
        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"loop error: {e}", file=sys.stderr)
            time.sleep(3)


if __name__ == "__main__":
    main()

PYEOF
  chmod 755 "$APP_FILE"
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Telegram Docker Compose Manager
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 $APP_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

install_app() {
  require_root
  require_debian_ubuntu
  install_deps

  read -rp '请输入 Telegram Bot Token: ' TG_BOT_TOKEN
  [[ -n "$TG_BOT_TOKEN" ]] || { err 'Bot Token 不能为空'; exit 1; }
  read -rp '请输入允许操作的 Telegram TGID: ' TG_ALLOWED_CHAT_ID
  [[ -n "$TG_ALLOWED_CHAT_ID" ]] || { err 'TGID 不能为空'; exit 1; }

  write_app
  cat > "$ENV_FILE" <<EOF
TG_BOT_TOKEN=$TG_BOT_TOKEN
TG_ALLOWED_CHAT_ID=$TG_ALLOWED_CHAT_ID
PROJECTS_DIR=$PROJECTS_DIR
TG_POLL_TIMEOUT=30
TG_LOG_LINES=80
EOF
  chmod 600 "$ENV_FILE"
  write_service

  systemctl daemon-reload
  systemctl enable --now "$APP_NAME"

  info '安装完成'
  echo "服务状态：systemctl status $APP_NAME"
  echo "日志查看：journalctl -u $APP_NAME -f"
}

uninstall_app() {
  require_root
  systemctl disable --now "$APP_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$ENV_FILE"
  systemctl daemon-reload
  rm -rf "$INSTALL_DIR"
  info '已卸载'
}

status_app() {
  systemctl --no-pager status "$APP_NAME" || true
}

restart_app() {
  require_root
  systemctl restart "$APP_NAME"
  info '已重启'
}

usage() {
  cat <<EOF
用法:
  bash $0 install     安装Telegram Docker 管理器
  bash $0 uninstall   卸载
  bash $0 status      查看状态
  bash $0 restart     重启服务
  bash $0 menu        打开菜单
EOF
}

show_menu() {
  echo
  echo '===== Telegram Docker 管理器 ====='
  echo '1. 安装'
  echo '2. 卸载'
  echo '3. 查看状态'
  echo '4. 重启服务'
  echo '0. 退出'
}

pause_return() {
  echo
  read -rp '按回车返回菜单...' _
}

menu_loop() {
  while true; do
    show_menu
    read -rp '请输入选项: ' choice
    case "$choice" in
      1) install_app; pause_return ;;
      2) uninstall_app; pause_return ;;
      3) status_app; pause_return ;;
      4) restart_app; pause_return ;;
      0) exit 0 ;;
      *) err '无效选项'; pause_return ;;
    esac
  done
}

case "${1:-menu}" in
  install) install_app ;;
  uninstall) uninstall_app ;;
  status) status_app ;;
  restart) restart_app ;;
  menu) menu_loop ;;
  *) usage; exit 1 ;;
esac
