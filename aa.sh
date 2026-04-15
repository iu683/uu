#!/usr/bin/env bash
set -euo pipefail
APP_NAME='docker-fleet-master'
INSTALL_DIR='/opt/docker-fleet-master'
APP_FILE="$INSTALL_DIR/docker_fleet_master.py"
ENV_FILE='/etc/docker-fleet-master.env'
SERVICE_FILE='/etc/systemd/system/docker-fleet-master.service'
GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; RESET='\033[0m'
info() { echo -e "${GREEN}[信息] $*${RESET}"; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}"; }
err() { echo -e "${RED}[错误] $*${RESET}" >&2; }
require_root() { [[ "$(id -u)" -eq 0 ]] || { err '请用 root 运行'; exit 1; }; }
require_debian_ubuntu() { [[ -f /etc/os-release ]] || { err '无法识别系统，只支持 Debian/Ubuntu'; exit 1; }; . /etc/os-release; case "${ID:-}" in debian|ubuntu) ;; *) [[ "${ID_LIKE:-}" == *debian* ]] || { err "只支持 Debian/Ubuntu，当前: ${PRETTY_NAME:-unknown}"; exit 1; } ;; esac; }
install_deps() { info '安装依赖...'; apt-get update; apt-get install -y python3 curl ca-certificates; if ! command -v docker >/dev/null 2>&1; then warn '未检测到 docker。脚本不会自动安装 Docker，请先自行安装 Docker 和 docker compose 插件。'; fi; }
get_public_ip() {
  local ip=''
  for url in https://api.ipify.org https://ip.sb https://checkip.amazonaws.com; do
    ip=$(curl -4s --max-time 5 "$url" 2>/dev/null || true)
    [[ -n "$ip" ]] && { echo "$ip"; return; }
    ip=$(wget -4qO- --timeout=5 "$url" 2>/dev/null || true)
    [[ -n "$ip" ]] && { echo "$ip"; return; }
  done
  for url in https://api64.ipify.org https://ip.sb; do
    ip=$(curl -6s --max-time 5 "$url" 2>/dev/null || true)
    [[ -n "$ip" ]] && { echo "$ip"; return; }
    ip=$(wget -6qO- --timeout=5 "$url" 2>/dev/null || true)
    [[ -n "$ip" ]] && { echo "$ip"; return; }
  done
  hostname -I | awk '{print $1}'
}
write_app() { mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/data"; cat > "$APP_FILE" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys, time, uuid, urllib.parse, urllib.request, subprocess, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, List, Optional, Tuple

BOT_TOKEN=os.environ.get('TG_BOT_TOKEN','')
ALLOWED_CHAT_ID=os.environ.get('TG_ALLOWED_CHAT_ID','')
PAIR_CODE=os.environ.get('PAIR_CODE','')
DATA_DIR=Path(os.environ.get('DATA_DIR','/opt/docker-fleet-master/data'))
PROJECTS_DIR=Path(os.environ.get('PROJECTS_DIR','/opt'))
BIND=os.environ.get('MASTER_BIND','0.0.0.0')
PORT=int(os.environ.get('MASTER_PORT','8765'))
MASTER_PUBLIC_URL=os.environ.get('MASTER_PUBLIC_URL','').rstrip('/')
POLL_TIMEOUT=int(os.environ.get('TG_POLL_TIMEOUT','30'))
LOG_LINES=int(os.environ.get('TG_LOG_LINES','80'))
API_BASE=f'https://api.telegram.org/bot{BOT_TOKEN}'
COMPOSE_FILES=['docker-compose.yml','docker-compose.yaml','compose.yml','compose.yaml']
CUSTOM_PROJECT_PATHS={
    'Moviepilot':'/opt/1panel/apps/local/moviepilot/moviepilot',
    'Jellyfin':'/opt/1panel/apps/jellyfin/jellyfin',
    'emby-amilys':'/opt/1panel/apps/local/emby-amilys/emby-amilys',
    'Vertex':'/opt/1panel/apps/local/vertex/localvertex',
    'Autobangumi':'/opt/1panel/apps/local/autobangumi/autobangumi',
}

DATA_DIR.mkdir(parents=True, exist_ok=True)
NODES_FILE=DATA_DIR/'nodes.json'
TASKS:Dict[str,List[dict]]={}
RESULTS:Dict[str,dict]={}
CURRENT_TARGET:Dict[str,str]={}
LOCK=threading.Lock()

def load_nodes():
    if not NODES_FILE.exists(): return {}
    try: return json.loads(NODES_FILE.read_text())
    except Exception: return {}

def save_nodes(nodes):
    NODES_FILE.write_text(json.dumps(nodes,ensure_ascii=False,indent=2))

def node_status_text(node):
    last_seen=float(node.get('last_seen',0) or 0)
    if not last_seen:
        return '未知'
    diff=time.time()-last_seen
    if diff < 90:
        return '在线'
    if diff < 600:
        return '离线（刚掉线）'
    return '离线'

def node_is_online(node):
    last_seen=float(node.get('last_seen',0) or 0)
    return bool(last_seen) and (time.time()-last_seen) < 90

def require_env():
    miss=[k for k,v in [('TG_BOT_TOKEN',BOT_TOKEN),('TG_ALLOWED_CHAT_ID',ALLOWED_CHAT_ID),('PAIR_CODE',PAIR_CODE)] if not v]
    if miss:
        print('缺少环境变量: '+','.join(miss),file=sys.stderr); sys.exit(1)


def detect_public_ip():
    for url in ['https://api.ipify.org','https://ip.sb','https://checkip.amazonaws.com']:
        code,out=shell(['curl','-4s','--max-time','5',url],timeout=10)
        if code==0 and out.strip():
            return out.strip()
        code,out=shell(['wget','-4qO-','--timeout=5',url],timeout=10)
        if code==0 and out.strip():
            return out.strip()
    for url in ['https://api64.ipify.org','https://ip.sb']:
        code,out=shell(['curl','-6s','--max-time','5',url],timeout=10)
        if code==0 and out.strip():
            return out.strip()
        code,out=shell(['wget','-6qO-','--timeout=5',url],timeout=10)
        if code==0 and out.strip():
            return out.strip()
    return ''


def get_master_url():
    if MASTER_PUBLIC_URL:
        return MASTER_PUBLIC_URL.replace('http://','').replace('https://','')
    host=detect_public_ip()
    if not host:
        code,out=shell(['sh','-lc',"hostname -I | awk '{print $1}'"],timeout=10)
        host=(out.strip() if code==0 else '') or 'YOUR_SERVER_IP'
    return f'{host}:{PORT}'

def tg(method,payload=None):
    data=urllib.parse.urlencode(payload or {}).encode()
    req=urllib.request.Request(f'{API_BASE}/{method}',data=data)
    with urllib.request.urlopen(req,timeout=POLL_TIMEOUT+15) as r:
        return json.loads(r.read().decode())

def send(chat,text,markup=None):
    chunks=[]; s=text
    while len(s)>3500: chunks.append(s[:3500]); s=s[3500:]
    chunks.append(s)
    for i,c in enumerate(chunks):
        p={'chat_id':chat,'text':c}
        if markup and i==len(chunks)-1: p['reply_markup']=json.dumps(markup)
        tg('sendMessage',p)

def edit(chat,msg,text,markup=None):
    p={'chat_id':chat,'message_id':msg,'text':text[:3500]}
    if markup: p['reply_markup']=json.dumps(markup)
    tg('editMessageText',p)

def answer(cid,text=''):
    p={'callback_query_id':cid}
    if text: p['text']=text
    tg('answerCallbackQuery',p)

def shell(cmd,cwd=None,timeout=300):
    try:
        p=subprocess.run(cmd,cwd=str(cwd) if cwd else None,text=True,capture_output=True,timeout=timeout)
        out=((p.stdout or '')+('\n'+p.stderr if p.stderr else '')).strip() or '(无输出)'
        return p.returncode,out
    except subprocess.TimeoutExpired: return 124,f'命令超时（{timeout}秒）'
    except Exception as e: return 1,f'执行失败: {e}'

def zh_status(s):
    m={'active':'运行中','inactive':'未运行','failed':'异常','activating':'启动中','deactivating':'停止中'}
    return m.get(s.strip(),s.strip() or '未知')

def loc(s):
    for a,b in {'NAMES':'名称','NAME':'名称','IMAGES':'镜像','IMAGE':'镜像','SERVICES':'服务','SERVICE':'服务','COMMAND':'命令','CREATED':'创建时间','STATUS':'状态','PORTS':'端口','Up ':'运行中 ','Exited':'已退出','Running':'运行中','Restarting':'重启中','seconds ago':'秒前','minutes ago':'分钟前','hours ago':'小时前','days ago':'天前',' seconds':' 秒',' minutes':' 分钟',' hours':' 小时',' days':' 天','About a minute':'约1分钟','About an hour':'约1小时','active':'运行中','inactive':'未运行','failed':'异常','activating':'启动中','deactivating':'停止中'}.items(): s=s.replace(a,b)
    return s

def find_compose_file(directory: Path):
    for f in COMPOSE_FILES:
        candidate=directory/f
        if candidate.exists(): return candidate
    return None

def discover_projects(base=PROJECTS_DIR):
    res=[]
    if base.exists():
        for d in sorted(base.iterdir()):
            if not d.is_dir(): continue
            compose=find_compose_file(d)
            if compose: res.append({'name':d.name,'dir':str(d),'compose':str(compose)})
    for name,raw in CUSTOM_PROJECT_PATHS.items():
        d=Path(raw)
        if not d.exists(): continue
        compose=find_compose_file(d)
        if compose: res.append({'name':name,'dir':str(d),'compose':str(compose)})
    return res

def compose_project(name):
    for p in discover_projects():
        if p['name']==name: return p
    return None

def format_ports(raw_ports):
    if not raw_ports:
        return '无'
    return str(raw_ports).replace(', ', '\n')

def compose_status_text(p, project):
    code,out=shell(['docker','compose','-f',p['compose'],'ps','--format','json'],cwd=Path(p['dir']))
    head=f'项目：{project}\n目录：{p["dir"]}\n'
    if code!=0:
        return head + loc(out)
    try:
        parsed=json.loads(out)
        if isinstance(parsed,list):
            rows=parsed
        elif isinstance(parsed,dict):
            rows=[parsed]
        else:
            rows=[]
    except Exception:
        rows=[]
        for line in out.splitlines():
            line=line.strip()
            if not line:
                continue
            try:
                item=json.loads(line)
                if isinstance(item,dict):
                    rows.append(item)
            except Exception:
                return head + loc(out)
    if not rows:
        return head + '当前没有容器'
    blocks=[]
    for row in rows:
        name=row.get('Name') or row.get('Service') or '(未知容器)'
        image=row.get('Image','-')
        service=row.get('Service','-')
        state=loc(row.get('State','-'))
        status=loc(row.get('Status','-'))
        created=loc(row.get('RunningFor', row.get('CreatedAt','-')))
        publishers=row.get('Publishers') or []
        if publishers:
            ports='\n'.join(f"{x.get('URL','0.0.0.0')}:{x.get('PublishedPort')} -> {x.get('TargetPort')}/{x.get('Protocol','')}".rstrip('/') for x in publishers)
        else:
            ports=format_ports(row.get('Ports',''))
        blocks.append(
            f'【{name}】\n'
            f'服务：{service}\n'
            f'镜像：{image}\n'
            f'状态：{state}\n'
            f'详情：{status}\n'
            f'运行：{created}\n'
            f'端口：{ports}'
        )
    return head + '\n\n'.join(blocks)

def run_local(action,project=None):
    if action=='home':
        dc,ds=shell(['systemctl','is-active','docker'],timeout=30); rc,ro=shell(['sh','-lc','docker ps -q | wc -l'],timeout=30); ac,ao=shell(['sh','-lc','docker ps -aq | wc -l'],timeout=30)
        return f'Docker 运行面板\n\n节点：本机\nDocker 状态：{zh_status(ds)}\n运行中的容器：{ro.strip() if rc==0 else "获取失败"}\n全部容器：{ao.strip() if ac==0 else "获取失败"}\n项目数量：{len(discover_projects())}'
    if action=='projects': return json.dumps(discover_projects(),ensure_ascii=False)
    if action=='system_info':
        hostname=shell(['hostname'],timeout=10)[1]
        os_info=shell(['bash','-lc','. /etc/os-release 2>/dev/null; echo ${PRETTY_NAME:-未知系统}'],timeout=10)[1]
        kernel=shell(['uname','-r'],timeout=10)[1]
        arch=shell(['uname','-m'],timeout=10)[1]
        cpu_model=shell(['bash','-lc','lscpu | sed -n "s/^Model name:[[:space:]]*//p" | head -n1'],timeout=10)[1]
        cpu_cores=shell(['nproc'],timeout=10)[1]
        mem=shell(['bash','-lc',"free -h | awk '/Mem:/ {print $3 " / " $2}'"],timeout=10)[1]
        swap_total=shell(['bash','-lc',"free -b | awk '/Swap:/ {print $2}'"],timeout=10)[1].strip()
        swap_used=shell(['bash','-lc',"free -h | awk '/Swap:/ {print $3}'"],timeout=10)[1].strip()
        swap_total_h=shell(['bash','-lc',"free -h | awk '/Swap:/ {print $2}'"],timeout=10)[1].strip()
        swap='未启用' if swap_total in {'0','0B','0.0B',''} or swap_total_h in {'0','0B','0.0B'} else f'{swap_used} / {swap_total_h}'
        disk=shell(['bash','-lc',"df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}'"],timeout=10)[1]
        dns=shell(['bash','-lc',"grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd ',' -"],timeout=10)[1]
        ipv4=shell(['bash','-lc','curl -4s --max-time 5 https://api.ipify.org || wget -4qO- --timeout=5 https://api.ipify.org || true'],timeout=10)[1]
        ipv6=shell(['bash','-lc','curl -6s --max-time 5 https://api64.ipify.org || wget -6qO- --timeout=5 https://api64.ipify.org || true'],timeout=10)[1]
        geo=shell(['bash','-lc','curl -4s --max-time 5 https://ipinfo.io/json || wget -4qO- --timeout=5 https://ipinfo.io/json || true'],timeout=10)[1]
        city=country=org='未知'
        try:
            geo_data=json.loads(geo)
            city=geo_data.get('city') or '未知'
            country=geo_data.get('country') or '未知'
            org=geo_data.get('org') or '未知'
        except Exception:
            pass
        uptime=shell(['uptime','-p'],timeout=10)[1]
        uptime=(uptime.replace('up ','').replace(' hours',' 小时').replace(' hour',' 小时').replace(' minutes',' 分钟').replace(' minute',' 分钟').replace(' days',' 天').replace(' day',' 天').replace(',',''))
        current_time=shell(['date','+%Y-%m-%d %H:%M:%S %Z'],timeout=10)[1]
        traffic=shell(['python3','-c',"from pathlib import Path; rx=tx=0
for line in Path('/proc/net/dev').read_text().splitlines()[2:]:
 iface,data=line.split(':',1); iface=iface.strip()
 if iface=='lo': continue
 cols=data.split(); rx+=int(cols[0]); tx+=int(cols[8])
print(f'{rx} {tx}')"],timeout=10)[1].split()
        def fmt_bytes(num):
            units=['B','KB','MB','GB','TB']
            value=float(num)
            for unit in units:
                if value<1024 or unit==units[-1]:
                    return f'{value:.2f} {unit}'
                value/=1024
            return f'{num} B'
        total_rx=fmt_bytes(int(traffic[0])) if len(traffic)==2 else '未知'
        total_tx=fmt_bytes(int(traffic[1])) if len(traffic)==2 else '未知'
        congestion=shell(['bash','-lc','cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo 未知'],timeout=10)[1]
        qdisc=shell(['bash','-lc','cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo 未知'],timeout=10)[1]
        return (
            f'📡 VPS 系统信息
'
            f'━━━━━━━━━━
'
            f'主机名：{hostname}
'
            f'运营商：{org}
'
            f'地理位置：{country} {city}
'
            f'系统版本：{os_info}
'
            f'内核版本：{kernel}
'
            f'CPU 架构：{arch}
'
            f'CPU 型号：{cpu_model}
'
            f'CPU 核心数：{cpu_cores}
'
            f'物理内存：{mem}
'
            f'虚拟内存：{swap}
'
            f'硬盘占用：{disk}
'
            f'总接收：{total_rx}
'
            f'总发送：{total_tx}
'
            f'网络拥堵算法：{congestion} {qdisc}
'
            f'公网 IPv4：{ipv4 or "无"}
'
            f'公网 IPv6：{ipv6 or "无"}
'
            f'DNS 服务器：{dns or "无"}
'
            f'系统时间：{current_time}
'
            f'运行时长：{uptime}'
        )
    if action=='network_info':
        interfaces=shell(['bash','-lc','for IFACE in $(ls /sys/class/net/); do echo "接口: $IFACE"; IPv4=$(ip -4 addr show $IFACE | grep -oP "inet \K[\d./]+" | head -n1); [ -n "$IPv4" ] && echo "IPv4: $IPv4" || echo "IPv4: 无"; IPv6=$(ip -6 addr show $IFACE scope global | grep -oP "inet6 \K[0-9a-f:]+/[0-9]+" | head -n1); [ -n "$IPv6" ] && echo "IPv6: $IPv6" || echo "IPv6: 无"; LL6=$(ip -6 addr show $IFACE scope link | grep -oP "inet6 \K[0-9a-f:]+/[0-9]+" | head -n1); [ -n "$LL6" ] && echo "链路本地 IPv6: $LL6" || true; echo "MAC: $(cat /sys/class/net/$IFACE/address)"; echo; done'],timeout=30)[1]
        route4=shell(['ip','route','show','default'],timeout=10)[1]
        route6=shell(['ip','-6','route','show','default'],timeout=10)[1]
        ping4=shell(['ping','-c','2','-W','2','8.8.8.8'],timeout=10)[1]
        ping6=shell(['ping6','-c','2','-W','2','google.com'],timeout=10)[1]
        if 'Network is unreachable' in ping6 or 'connect:' in ping6:
            ping6='当前没有可用 IPv6 路由或 IPv6 未连通'
        return (
            '🌐 VPS 网络信息
'
            '━━━━━━━━━━
'
            f'【网络接口】
{interfaces}
'
            f'【默认路由】
IPv4 默认路由：
{route4}

IPv6 默认路由：
{route6}

'
            f'【网络连通性测试】
IPv4 测试：
{ping4}

IPv6 测试：
{ping6}'
        )
    if action=='system_cleanup':
        j=shell(['journalctl','--vacuum-time=7d'],timeout=120); a=shell(['apt-get','clean'],timeout=120); i=shell(['docker','image','prune','-a','-f'],timeout=120); v=shell(['docker','volume','prune','-f'],timeout=120); n=shell(['docker','network','prune','-f'],timeout=120)
        return f'系统清理完成\n\n[日志清理] exit={j[0]}\n{loc(j[1])}\n\n[缓存清理] exit={a[0]}\n{loc(a[1])}\n\n[无用镜像] exit={i[0]}\n{loc(i[1])}\n\n[无用卷] exit={v[0]}\n{loc(v[1])}\n\n[无用网络] exit={n[0]}\n{loc(n[1])}'
    if action=='overview':
        ic,io=shell(['sh','-lc','docker image ls -q | sort -u | wc -l']); rc,ro=shell(['sh','-lc','docker ps -q | wc -l']); ac,ao=shell(['sh','-lc','docker ps -aq | wc -l']); vc,vo=shell(['sh','-lc','docker volume ls -q | wc -l']); nc,no=shell(['sh','-lc',"docker network ls --format '{{.Name}}' | wc -l"]); pc,po=shell(['docker','ps','--format','{{json .}}'])
        lines=[f'Docker 概览\n\n节点：本机\n运行中的容器：{ro.strip()}\n全部容器：{ao.strip()}\n镜像数量：{io.strip()}\n卷数量：{vo.strip()}\n网络数量：{no.strip()}']
        if pc==0 and po.strip() and po.strip()!='(无输出)':
            lines.append('运行中的容器：')
            for line in po.splitlines():
                line=line.strip()
                if not line: continue
                try: row=json.loads(line)
                except Exception: continue
                lines.append(f"【{row.get('Names','(未知容器)')}】\n镜像：{row.get('Image','-')}\n状态：{loc(row.get('Status','-'))}\n端口：{format_ports(row.get('Ports',''))}")
        else:
            lines.append('运行中的容器：\n无')
        return '\n\n'.join(lines)
    if action=='running':
        c,o=shell(['docker','ps','--format','{{json .}}'])
        if c!=0: return f'查看运行中容器失败\n{loc(o)}'
        rows=[]
        for line in o.splitlines():
            line=line.strip()
            if not line or line=='(无输出)': continue
            try: rows.append(json.loads(line))
            except Exception: return loc(o)
        if not rows: return '运行中的容器\n\n无'
        return '运行中的容器\n\n' + '\n\n'.join(f"【{r.get('Names','(未知容器)')}】\n镜像：{r.get('Image','-')}\n状态：{loc(r.get('Status','-'))}\n端口：{format_ports(r.get('Ports',''))}" for r in rows)
    if action=='containers':
        c,o=shell(['docker','ps','-a','--format','{{json .}}'])
        if c!=0: return f'容器管理\n\n{loc(o)}'
        rows=[]
        for line in o.splitlines():
            line=line.strip()
            if not line or line=='(无输出)': continue
            try: rows.append(json.loads(line))
            except Exception: return '容器管理\n\n'+loc(o)
        if not rows: return '容器管理\n\n无'
        return '容器管理\n\n' + '\n\n'.join(f"【{r.get('Names','(未知容器)')}】\n镜像：{r.get('Image','-')}\n状态：{loc(r.get('Status','-'))}\n端口：{format_ports(r.get('Ports',''))}" for r in rows)
    if action.startswith('container_'):
        name=(project or '').strip()
        act=action.split('_',1)[1]
        if act=='start': c,o=shell(['docker','start',name],timeout=120); return f'[{name}] 启动完成（退出码={c}）\n{loc(o)}'
        if act=='stop': c,o=shell(['docker','stop',name],timeout=120); return f'[{name}] 停止完成（退出码={c}）\n{loc(o)}'
        if act=='restart': c,o=shell(['docker','restart',name],timeout=120); return f'[{name}] 重启完成（退出码={c}）\n{loc(o)}'
        if act=='logs': c,o=shell(['docker','logs','--tail',str(LOG_LINES),name],timeout=120); return f'[{name}] 日志\n{loc(o)}'
        if act=='remove': c,o=shell(['docker','rm','-f',name],timeout=120); return f'[{name}] 删除容器完成（退出码={c}）\n{loc(o)}'
        return '未知容器操作'
    if action=='stats':
        c,o=shell(['docker','stats','--no-stream','--format','{{json .}}'])
        if c!=0: return f'查看容器占用失败\n{loc(o)}'
        rows=[]
        for line in o.splitlines():
            line=line.strip()
            if not line or line=='(无输出)':
                continue
            try: rows.append(json.loads(line))
            except Exception: return loc(o)
        if not rows: return '当前没有可显示的容器占用'
        return '容器占用\n\n' + '\n\n'.join(
            f"【{r.get('Name','(未知容器)')}】\nCPU：{r.get('CPUPerc','-')}\n内存：{r.get('MemUsage','-')}\n内存占比：{r.get('MemPerc','-')}\n网络 I/O：{r.get('NetIO','-')}\n磁盘 I/O：{r.get('BlockIO','-')}"
            for r in rows
        )
    if action=='docker_restart':
        c,o=shell(['systemctl','restart','docker'])
        if c!=0: return f'Docker 重启失败\n{o}'
        time.sleep(3)
        sc,so=shell(['systemctl','is-active','docker'],timeout=30)
        status=zh_status(so)
        if status!='运行中':
            dc,do=shell(['systemctl','status','docker','--no-pager'],timeout=60)
            return f'Docker 重启后状态异常\n当前状态：{status}\n\n{loc(do)}'
        return f'Docker 已重启\n当前状态：{status}'
    if action=='prune':
        a=shell(['docker','image','prune','-a','-f'])[1]; b=shell(['docker','volume','prune','-f'])[1]; c=shell(['docker','network','prune','-f'])[1]
        return f'清理完成\n\n[无用镜像]\n{loc(a)}\n\n[无用卷]\n{loc(b)}\n\n[无用网络]\n{loc(c)}'
    p=compose_project(project or '')
    if not p: return f'项目不存在：{project}'
    base=['docker','compose','-f',p['compose']]
    if action=='status': return compose_status_text(p, project)
    if action=='up': c,o=shell(base+['up','-d'],cwd=Path(p['dir'])); return f'[{project}] 启动完成（退出码={c}）\n{loc(o)}'
    if action=='down': c,o=shell(base+['down'],cwd=Path(p['dir'])); return f'[{project}] 停止完成（退出码={c}）\n{loc(o)}'
    if action=='delete_container':
        c,o=shell(base+['down','-v','--rmi','all'],cwd=Path(p['dir']))
        return f'[{project}] 删除容器完成（退出码={c}）\n{loc(o)}'
    if action=='delete_all':
        c1,o1=shell(base+['down','-v','--rmi','all'],cwd=Path(p['dir']))
        c2,o2=shell(['rm','-rf',p['dir']])
        return f'[{project}] 删除容器+文件数据完成（down={c1}, rm={c2}）\n[删除容器]\n{loc(o1)}\n\n[删除文件数据]\n{loc(o2)}'
    if action=='restart': c,o=shell(base+['restart'],cwd=Path(p['dir'])); return f'[{project}] 重启完成（退出码={c}）\n{loc(o)}'
    if action=='pull': c,o=shell(base+['pull'],cwd=Path(p['dir'])); return f'[{project}] 拉取镜像完成（退出码={c}）\n{loc(o)}'
    if action=='update':
        c1,o1=shell(base+['pull'],cwd=Path(p['dir']));
        if c1!=0: return f'[{project}] 更新失败\n[拉取镜像]\n{loc(o1)}'
        c2,o2=shell(base+['up','-d'],cwd=Path(p['dir'])); c3,o3=shell(['docker','image','prune','-a','-f'])
        return f'[{project}] 更新并重启完成\n[拉取镜像]\n{loc(o1)}\n\n[启动服务]\n{loc(o2)}\n\n[清理无用镜像]\n{loc(o3)}'
    if action=='logs': c,o=shell(base+['logs','--tail',str(LOG_LINES),'--no-color'],cwd=Path(p['dir']),timeout=120); return f'[{project}] 日志\n{loc(o)}'
    return '未知操作'

def enqueue(node_id,action,project=None):
    tid=str(uuid.uuid4())
    task={'id':tid,'action':action,'project':project,'created':time.time()}
    with LOCK: TASKS.setdefault(node_id,[]).append(task)
    return tid

def wait_result(tid,timeout=90):
    end=time.time()+timeout
    while time.time()<end:
        with LOCK:
            if tid in RESULTS: return RESULTS.pop(tid).get('text','(无输出)')
        time.sleep(1)
    return '节点执行超时，请检查节点是否在线'

def run_target(target,action,project=None):
    if target=='local': return run_local(action,project)
    nodes=load_nodes(); n=nodes.get(target)
    if not n: return '节点不存在'
    if not node_is_online(n):
        return f"节点 {n.get('name',target)} 当前离线，请先删除该节点或等待它恢复在线。"
    tid=enqueue(target,action,project)
    return wait_result(tid)

def nodes_keyboard():
    nodes=load_nodes(); rows=[[{'text':'本机｜在线','callback_data':'target:local'}]]
    for nid,n in nodes.items(): rows.append([{'text':f"{n.get('name',nid)}｜{n.get('public_ip','未知')}｜{node_status_text(n)}",'callback_data':f'target:{nid}'}])
    rows.append([{'text':'🧩 节点管理','callback_data':'menu:node_manage'}])
    rows.append([{'text':'🔑 对接码','callback_data':'menu:pair'}])
    return {'inline_keyboard':rows}

def node_manage_keyboard():
    nodes=load_nodes(); rows=[]
    for nid,n in nodes.items():
        rows.append([{'text':f"{n.get('name',nid)}｜{n.get('public_ip','未知')}｜{node_status_text(n)}",'callback_data':f'node:info:{nid}'}])
    rows.append([{'text':'⬅️ 返回','callback_data':'menu:nodes'}])
    return {'inline_keyboard':rows}

def node_detail_keyboard(node_id):
    return {'inline_keyboard':[
        [{'text':'🗑 删除节点','callback_data':f'node:delete:{node_id}'}],
        [{'text':'⬅️ 节点管理','callback_data':'menu:node_manage'},{'text':'🏠 首页','callback_data':'home:local'}]
    ]}

def node_detail_text(node_id):
    nodes=load_nodes(); n=nodes.get(node_id)
    if not n:
        return '节点不存在'
    last_seen=float(n.get('last_seen',0) or 0)
    last_seen_text=time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(last_seen)) if last_seen else '无'
    return f"节点名称：{n.get('name',node_id)}\n节点 IP：{n.get('public_ip','未知')}\n节点 ID：{node_id}\n状态：{node_status_text(n)}\n最后心跳：{last_seen_text}"

def main_keyboard(target):
    return {'inline_keyboard':[[{'text':'🖥 选择节点','callback_data':'menu:nodes'}],[{'text':'📦 项目列表','callback_data':f'menu:list:{target}'}],[{'text':'🎬 应用快捷管理','callback_data':f'menu:apps:{target}'}],[{'text':'🐳 Docker 管理','callback_data':f'menu:docker:{target}'}],[{'text':'🖥 系统管理','callback_data':f'menu:system:{target}'}]]}

def system_keyboard(target):
    return {'inline_keyboard':[[{'text':'📡 系统信息','callback_data':f'docker:system_info:{target}'}],[{'text':'🌐 网络信息','callback_data':f'docker:network_info:{target}'}],[{'text':'🧽 一键清理','callback_data':f'confirm_global:system_cleanup:{target}'}],[{'text':'🏠 首页','callback_data':f'home:{target}'}]]}

def apps_keyboard(target):
    rows=[]
    for name in CUSTOM_PROJECT_PATHS.keys(): rows.append([{'text':name,'callback_data':f'project:{target}:{name}'}])
    rows.append([{'text':'🏠 首页','callback_data':f'home:{target}'}])
    return {'inline_keyboard':rows}

def docker_keyboard(target):
    return {'inline_keyboard':[[{'text':'📊 Docker 概览','callback_data':f'docker:overview:{target}'}],[{'text':'📦 运行中的容器','callback_data':f'docker:running:{target}'}],[{'text':'🧰 容器管理','callback_data':f'docker:containers:{target}'}],[{'text':'📈 容器占用','callback_data':f'docker:stats:{target}'}],[{'text':'🔄 重启 Docker','callback_data':f'confirm_global:docker_restart:{target}'}],[{'text':'🧹 清理无用镜像/卷/网络','callback_data':f'docker:prune:{target}'}],[{'text':'🏠 首页','callback_data':f'home:{target}'}]]}

def containers_keyboard(target):
    raw=run_target(target,'containers')
    rows=[]
    for line in raw.splitlines():
        line=line.strip()
        if line.startswith('【') and '】' in line:
            name=line[1:line.index('】')]
            rows.append([{'text':name,'callback_data':f'container:{target}:{name}'}])
    if not rows:
        rows.append([{'text':'(没有容器)','callback_data':f'menu:docker:{target}'}])
    rows.append([{'text':'⬅️ 返回','callback_data':f'menu:docker:{target}'}])
    return {'inline_keyboard':rows}

def container_detail_text(target, name):
    raw=run_target(target,'containers')
    blocks = raw.split('\n\n')
    for block in blocks:
        if block.startswith(f'【{name}】'):
            return block
    return f'容器：{name}\n\n当前未找到更多详情，可直接使用下方按钮操作。'

def container_keyboard(target,name):
    return {'inline_keyboard':[[{'text':'▶️ 启动','callback_data':f'container_action:start:{target}:{name}'},{'text':'⏹ 停止','callback_data':f'container_action:stop:{target}:{name}'}],[{'text':'🔄 重启','callback_data':f'container_action:restart:{target}:{name}'},{'text':'📜 日志','callback_data':f'container_action:logs:{target}:{name}'}],[{'text':'🗑 删除容器','callback_data':f'confirm_container:remove:{target}:{name}'}],[{'text':'⬅️ 容器列表','callback_data':f'docker:containers:{target}'},{'text':'🏠 Docker 管理','callback_data':f'menu:docker:{target}'}]]}

def global_confirm_text(action, target):
    if action=='docker_restart':
        return f'危险操作确认\n\n节点：{target}\n动作：重启 Docker\n\n这会重启 Docker 服务，短时间内可能影响容器连接。'
    if action=='system_cleanup':
        return f'危险操作确认\n\n节点：{target}\n动作：一键清理系统日志/缓存/Docker垃圾\n\n这会清理 journal 日志、软件包缓存，以及 Docker 无用镜像、卷、网络。'
    return '未知确认操作'

def global_confirm_keyboard(action, target):
    return {'inline_keyboard':[[{'text':'✅ 确认执行','callback_data':f'docker:{action}:{target}'}],[{'text':'❌ 取消','callback_data':f'menu:docker:{target}'}]]}

def container_confirm_text(action, target, name):
    if action=='remove':
        return f'危险操作确认\n\n节点：{target}\n容器：{name}\n动作：删除容器+镜像\n\n这会先删除容器，再尝试删除该容器使用的镜像。'
    return '未知确认操作'

def container_confirm_keyboard(action, target, name):
    return {'inline_keyboard':[[{'text':'✅ 确认执行','callback_data':f'container_action:{action}:{target}:{name}'}],[{'text':'❌ 取消','callback_data':f'container:{target}:{name}'}]]}

def project_keyboard(target,project):
    return {'inline_keyboard':[[{'text':'▶️ 启动','callback_data':f'action:up:{target}:{project}'},{'text':'⏹ 停止','callback_data':f'action:down:{target}:{project}'}],[{'text':'🔄 重启','callback_data':f'action:restart:{target}:{project}'},{'text':'📥 拉镜像','callback_data':f'action:pull:{target}:{project}'}],[{'text':'♻️ 更新并重启','callback_data':f'action:update:{target}:{project}'}],[{'text':'📜 日志','callback_data':f'action:logs:{target}:{project}'},{'text':'📊 状态','callback_data':f'action:status:{target}:{project}'}],[{'text':'🗑 删除容器','callback_data':f'confirm:delete_container:{target}:{project}'}],[{'text':'☠️ 删除容器+文件数据','callback_data':f'confirm:delete_all:{target}:{project}'}],[{'text':'⬅️ 项目列表','callback_data':f'menu:list:{target}'},{'text':'🏠 首页','callback_data':f'home:{target}'}]]}

def confirm_keyboard(target, project, action):
    label='删除容器' if action=='delete_container' else '删除容器+文件数据'
    return {'inline_keyboard':[
        [{'text':f'✅ 确认{label}','callback_data':f'action:{action}:{target}:{project}'}],
        [{'text':'❌ 取消','callback_data':f'project:{target}:{project}'}]
    ]}

def confirm_text(project, action):
    if action=='delete_container':
        return f'危险操作确认\n\n项目：{project}\n动作：删除容器\n\n这会执行 docker compose down -v --rmi all。'
    return f'危险操作确认\n\n项目：{project}\n动作：删除容器 + 文件数据\n\n这会先执行 docker compose down -v --rmi all，然后删除整个项目目录。'

def projects_keyboard(target,projects):
    rows=[[{'text':p['name'],'callback_data':f'project:{target}:{p["name"]}'}] for p in projects]
    rows.append([{'text':'🏠 首页','callback_data':f'home:{target}'}]); return {'inline_keyboard':rows}

def handle_text(chat,text):
    if text.startswith('/start'):
        target=CURRENT_TARGET.get(chat,'local')
        nodes=load_nodes()
        if target!='local' and target not in nodes:
            CURRENT_TARGET[chat]='local'; target='local'
        send(chat,run_target(target,'home'),main_keyboard(target)); return
    if text.startswith('/nodes'):
        send(chat,'选择要管理的节点：',nodes_keyboard()); return
    if text.startswith('/pair'):
        send(chat,f'节点对接信息：\n主控地址：{get_master_url()}\n对接码：{PAIR_CODE}\n\n在节点脚本里填写主控地址和这个对接码即可。',main_keyboard(CURRENT_TARGET.get(chat,'local'))); return
    send(chat,'发 /start 打开面板',main_keyboard(CURRENT_TARGET.get(chat,'local')))

def handle_callback(cb):
    cid=cb['id']; msg=cb.get('message',{}); chat=str(msg.get('chat',{}).get('id','')); mid=msg.get('message_id'); data=cb.get('data','')
    if chat!=str(ALLOWED_CHAT_ID): return
    answer(cid)
    if data=='menu:nodes': edit(chat,mid,'选择要管理的节点：',nodes_keyboard()); return
    if data=='menu:node_manage': edit(chat,mid,'节点管理',node_manage_keyboard()); return
    if data=='menu:pair': edit(chat,mid,f'节点对接信息：\n主控地址：{get_master_url()}\n对接码：{PAIR_CODE}\n\n节点安装时填写主控地址和这个码。',main_keyboard(CURRENT_TARGET.get(chat,'local'))); return
    if data.startswith('node:info:'):
        nid=data.split(':',2)[2]
        edit(chat,mid,node_detail_text(nid),node_detail_keyboard(nid)); return
    if data.startswith('node:delete:'):
        nid=data.split(':',2)[2]
        nodes=load_nodes()
        if nid in nodes:
            name=nodes[nid].get('name',nid)
            del nodes[nid]
            save_nodes(nodes)
            edit(chat,mid,f'已删除节点：{name}',node_manage_keyboard())
        else:
            edit(chat,mid,'节点不存在',node_manage_keyboard())
        return
    if data.startswith('target:'):
        t=data.split(':',1)[1]
        if t!='local':
            nodes=load_nodes(); n=nodes.get(t)
            if not n:
                edit(chat,mid,'节点不存在或已删除，请重新选择。',nodes_keyboard()); return
            if not node_is_online(n):
                edit(chat,mid,f"节点 {n.get('name',t)} 当前离线，请在节点管理里删除或等待恢复。",nodes_keyboard()); return
        CURRENT_TARGET[chat]=t; edit(chat,mid,run_target(t,'home'),main_keyboard(t)); return
    if data.startswith('home:'):
        t=data.split(':',1)[1]; edit(chat,mid,run_target(t,'home'),main_keyboard(t)); return
    if data.startswith('menu:docker:'):
        t=data.split(':',2)[2]; edit(chat,mid,'Docker 管理',docker_keyboard(t)); return
    if data.startswith('menu:system:'):
        t=data.split(':',2)[2]; edit(chat,mid,'系统管理',system_keyboard(t)); return
    if data.startswith('menu:apps:'):
        t=data.split(':',2)[2]; edit(chat,mid,'应用快捷管理',apps_keyboard(t)); return
    if data.startswith('menu:list:'):
        t=data.split(':',2)[2]; raw=run_target(t,'projects')
        try: ps=json.loads(raw)
        except Exception: edit(chat,mid,raw,main_keyboard(t)); return
        edit(chat,mid,f'找到 {len(ps)} 个项目：',projects_keyboard(t,ps)); return
    if data.startswith('docker:'):
        _,act,t=data.split(':',2)
        if act=='containers':
            edit(chat,mid,run_target(t,act),containers_keyboard(t)); return
        if act in ('system_info','network_info','system_cleanup'):
            edit(chat,mid,run_target(t,act),system_keyboard(t)); return
        edit(chat,mid,run_target(t,act),docker_keyboard(t)); return
    if data.startswith('confirm_global:'):
        _,act,t=data.split(':',2)
        edit(chat,mid,global_confirm_text(act,t),global_confirm_keyboard(act,t)); return
    if data.startswith('container:'):
        _,t,name=data.split(':',2)
        edit(chat,mid,container_detail_text(t,name),container_keyboard(t,name)); return
    if data.startswith('confirm_container:'):
        _,act,t,name=data.split(':',3)
        edit(chat,mid,container_confirm_text(act,t,name),container_confirm_keyboard(act,t,name)); return
    if data.startswith('container_action:'):
        _,act,t,name=data.split(':',3)
        edit(chat,mid,run_target(t,f'container_{act}',name),container_keyboard(t,name)); return
    if data.startswith('project:'):
        _,t,p=data.split(':',2); edit(chat,mid,run_target(t,'status',p),project_keyboard(t,p)); return
    if data.startswith('confirm:'):
        _,act,t,p=data.split(':',3)
        edit(chat,mid,confirm_text(p,act),confirm_keyboard(t,p,act)); return
    if data.startswith('action:'):
        _,act,t,p=data.split(':',3); edit(chat,mid,run_target(t,act,p),project_keyboard(t,p)); return

def bot_loop():
    tg('setMyCommands',{'commands':json.dumps([{'command':'start','description':'打开管理面板'},{'command':'nodes','description':'选择节点'},{'command':'pair','description':'查看对接码'}])})
    offset=0
    while True:
        try:
            r=tg('getUpdates',{'timeout':POLL_TIMEOUT,'offset':offset,'allowed_updates':json.dumps(['message','callback_query'])})
            for u in r.get('result',[]):
                offset=u['update_id']+1
                if 'callback_query' in u: handle_callback(u['callback_query']); continue
                m=u.get('message') or {}; chat=str(m.get('chat',{}).get('id','')); text=m.get('text','')
                if chat==str(ALLOWED_CHAT_ID) and text: handle_text(chat,text)
        except Exception as e:
            print('bot loop error:',e,file=sys.stderr); time.sleep(3)

class Handler(BaseHTTPRequestHandler):
    def _json(self,code,obj):
        b=json.dumps(obj,ensure_ascii=False).encode(); self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def read_body(self):
        l=int(self.headers.get('Content-Length','0') or 0); return json.loads(self.rfile.read(l).decode() or '{}')
    def do_POST(self):
        try:
            body=self.read_body()
            if self.path=='/api/register':
                if body.get('pair_code')!=PAIR_CODE: return self._json(403,{'error':'bad pair code'})
                nid='node-'+uuid.uuid4().hex[:8]; tok=uuid.uuid4().hex; nodes=load_nodes(); nodes[nid]={'name':body.get('name') or nid,'token':tok,'last_seen':time.time(),'public_ip':body.get('public_ip') or self.client_address[0]}; save_nodes(nodes); return self._json(200,{'node_id':nid,'node_token':tok})
            if self.path=='/api/result':
                nid=body.get('node_id'); tok=body.get('node_token'); nodes=load_nodes();
                if not nid or nid not in nodes or nodes[nid].get('token')!=tok: return self._json(403,{'error':'unauthorized'})
                with LOCK: RESULTS[body.get('task_id','')]={'text':body.get('text','')}
                return self._json(200,{'ok':True})
        except Exception as e: return self._json(500,{'error':str(e)})
        self._json(404,{'error':'not found'})
    def do_GET(self):
        try:
            p=urllib.parse.urlparse(self.path); qs=urllib.parse.parse_qs(p.query)
            if p.path=='/api/poll':
                nid=qs.get('node_id',[''])[0]; tok=qs.get('node_token',[''])[0]; nodes=load_nodes()
                if not nid or nid not in nodes or nodes[nid].get('token')!=tok: return self._json(403,{'error':'unauthorized'})
                nodes[nid]['last_seen']=time.time()
                if qs.get('public_ip',[''])[0]:
                    nodes[nid]['public_ip']=qs.get('public_ip',[''])[0]
                save_nodes(nodes)
                with LOCK: task=TASKS.get(nid,[]).pop(0) if TASKS.get(nid) else None
                return self._json(200,{'task':task})
        except Exception as e: return self._json(500,{'error':str(e)})
        self._json(404,{'error':'not found'})
    def log_message(self,*args): pass

def main():
    require_env()
    threading.Thread(target=bot_loop,daemon=True).start()
    print(f'master listening on {BIND}:{PORT}')
    ThreadingHTTPServer((BIND,PORT),Handler).serve_forever()

if __name__=='__main__': main()

PYEOF
chmod 755 "$APP_FILE"; }
write_service() { cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Docker Fleet Master
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
install_app() { require_root; require_debian_ubuntu; install_deps; read -rp '请输入 Telegram Bot Token: ' TG_BOT_TOKEN; [[ -n "$TG_BOT_TOKEN" ]] || { err 'Bot Token 不能为空'; exit 1; }; read -rp '请输入允许操作的 Telegram TGID: ' TG_ALLOWED_CHAT_ID; [[ -n "$TG_ALLOWED_CHAT_ID" ]] || { err 'TGID 不能为空'; exit 1; }; read -rp '请输入主控端口（默认 8765）: ' MASTER_PORT; MASTER_PORT=${MASTER_PORT:-8765}; read -rp '请输入节点对接码（留空自动生成）: ' PAIR_CODE; PAIR_CODE=${PAIR_CODE:-$(python3 - <<'PY'
import secrets, string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(8)))
PY
)}; MASTER_IP=$(get_public_ip); MASTER_PUBLIC_URL="${MASTER_IP}:${MASTER_PORT}"; write_app; cat > "$ENV_FILE" <<EOF
TG_BOT_TOKEN=$TG_BOT_TOKEN
TG_ALLOWED_CHAT_ID=$TG_ALLOWED_CHAT_ID
PAIR_CODE=$PAIR_CODE
DATA_DIR=/opt/docker-fleet-master/data
PROJECTS_DIR=/opt
MASTER_BIND=0.0.0.0
MASTER_PORT=$MASTER_PORT
MASTER_PUBLIC_URL=$MASTER_PUBLIC_URL
TG_POLL_TIMEOUT=30
TG_LOG_LINES=80
EOF
chmod 600 "$ENV_FILE"; write_service; systemctl daemon-reload; systemctl enable --now "$APP_NAME"; info '安装完成'; echo "主控地址: $MASTER_PUBLIC_URL"; echo "对接码: $PAIR_CODE"; }
uninstall_app() { require_root; systemctl disable --now "$APP_NAME" >/dev/null 2>&1 || true; rm -f "$SERVICE_FILE" "$ENV_FILE"; systemctl daemon-reload; rm -rf "$INSTALL_DIR"; info '已卸载 docker-fleet-master'; }
status_app() { systemctl --no-pager status "$APP_NAME" || true; [[ -f "$ENV_FILE" ]] && echo && grep -E '^(MASTER_PUBLIC_URL|PAIR_CODE)=' "$ENV_FILE" || true; }
restart_app() { require_root; systemctl restart "$APP_NAME"; info '已重启'; }
show_menu() { echo; echo '====== Docker Fleet 主控 ======'; echo '1. 安装'; echo '2. 卸载'; echo '3. 查看状态'; echo '4. 重启服务'; echo '0. 退出'; echo; }
pause_return() { echo; read -rp '按回车返回菜单...' _; }
menu_loop() { while true; do show_menu; read -rp '请输入选项: ' choice; case "$choice" in 1) install_app; pause_return ;; 2) uninstall_app; pause_return ;; 3) status_app; pause_return ;; 4) restart_app; pause_return ;; 0) exit 0 ;; *) err '无效选项'; pause_return ;; esac; done; }
case "${1:-menu}" in install) install_app ;; uninstall) uninstall_app ;; status) status_app ;; restart) restart_app ;; menu) menu_loop ;; *) menu_loop ;; esac
