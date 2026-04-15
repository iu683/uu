#!/usr/bin/env bash
set -euo pipefail
APP_NAME='docker-fleet-node'
INSTALL_DIR='/opt/docker-fleet-node'
APP_FILE="$INSTALL_DIR/docker_fleet_node.py"
ENV_FILE='/etc/docker-fleet-node.env'
SERVICE_FILE='/etc/systemd/system/docker-fleet-node.service'
GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; RESET='\033[0m'
info() { echo -e "${GREEN}[信息] $*${RESET}"; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}"; }
err() { echo -e "${RED}[错误] $*${RESET}" >&2; }
require_root() { [[ "$(id -u)" -eq 0 ]] || { err '请用 root 运行'; exit 1; }; }
require_debian_ubuntu() { [[ -f /etc/os-release ]] || { err '无法识别系统，只支持 Debian/Ubuntu'; exit 1; }; . /etc/os-release; case "${ID:-}" in debian|ubuntu) ;; *) [[ "${ID_LIKE:-}" == *debian* ]] || { err "只支持 Debian/Ubuntu，当前: ${PRETTY_NAME:-unknown}"; exit 1; } ;; esac; }
install_deps() { info '安装依赖...'; apt-get update; apt-get install -y python3 curl ca-certificates; if ! command -v docker >/dev/null 2>&1; then warn '未检测到 docker。脚本不会自动安装 Docker，请先自行安装 Docker 和 docker compose 插件。'; fi; }
write_app() { mkdir -p "$INSTALL_DIR"; cat > "$APP_FILE" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys, time, socket, urllib.request, urllib.parse, subprocess
from pathlib import Path

MASTER_URL=os.environ.get('MASTER_URL','').rstrip('/')
PAIR_CODE=os.environ.get('PAIR_CODE','')
NODE_NAME=os.environ.get('NODE_NAME',socket.gethostname())
PROJECTS_DIR=Path(os.environ.get('PROJECTS_DIR','/opt'))
STATE_DIR=Path(os.environ.get('STATE_DIR','/opt/docker-fleet-node'))
STATE_DIR.mkdir(parents=True, exist_ok=True)
STATE_FILE=STATE_DIR/'state.json'
LOG_LINES=int(os.environ.get('TG_LOG_LINES','80'))
COMPOSE_FILES=['docker-compose.yml','docker-compose.yaml','compose.yml','compose.yaml']
CUSTOM_PROJECT_PATHS={
    'Moviepilot':'/opt/1panel/apps/local/moviepilot/moviepilot',
    'Jellyfin':'/opt/1panel/apps/jellyfin/jellyfin',
    'emby-amilys':'/opt/1panel/apps/local/emby-amilys/emby-amilys',
    'Vertex':'/opt/1panel/apps/local/vertex/localvertex',
    'Autobangumi':'/opt/1panel/apps/local/autobangumi/autobangumi',
}

def req(method,url,obj=None):
    data=None
    if obj is not None:
        data=json.dumps(obj).encode(); headers={'Content-Type':'application/json'}
    else:
        headers={}
    r=urllib.request.Request(url,data=data,headers=headers,method=method)
    with urllib.request.urlopen(r,timeout=90) as resp: return json.loads(resp.read().decode())

def detect_public_ip():
    for url in ['https://api.ipify.org','https://ip.sb','https://checkip.amazonaws.com']:
        c,o=shell(['curl','-4s','--max-time','5',url],timeout=10)
        if c==0 and o.strip(): return o.strip()
        c,o=shell(['wget','-4qO-','--timeout=5',url],timeout=10)
        if c==0 and o.strip(): return o.strip()
    return ''

def load_state():
    if not STATE_FILE.exists(): return {}
    try: return json.loads(STATE_FILE.read_text())
    except Exception: return {}

def save_state(s): STATE_FILE.write_text(json.dumps(s,ensure_ascii=False,indent=2))

def ensure_registered():
    st=load_state()
    if st.get('node_id') and st.get('node_token'): return st
    if not MASTER_URL or not PAIR_CODE:
        print('缺少 MASTER_URL 或 PAIR_CODE',file=sys.stderr); sys.exit(1)
    res=req('POST',MASTER_URL+'/api/register',{'pair_code':PAIR_CODE,'name':NODE_NAME,'public_ip':detect_public_ip()})
    st={'master_url':MASTER_URL,'node_id':res['node_id'],'node_token':res['node_token'],'name':NODE_NAME}
    save_state(st)
    return st

def shell(cmd,cwd=None,timeout=300):
    try:
        p=subprocess.run(cmd,cwd=str(cwd) if cwd else None,text=True,capture_output=True,timeout=timeout)
        out=((p.stdout or '')+('\n'+p.stderr if p.stderr else '')).strip() or '(无输出)'
        return p.returncode,out
    except subprocess.TimeoutExpired: return 124,f'命令超时（{timeout}秒）'
    except Exception as e: return 1,f'执行失败: {e}'

def loc(s):
    for a,b in {'NAMES':'名称','NAME':'名称','IMAGES':'镜像','IMAGE':'镜像','SERVICES':'服务','SERVICE':'服务','COMMAND':'命令','CREATED':'创建时间','STATUS':'状态','PORTS':'端口','Up ':'运行中 ','Exited':'已退出','Running':'运行中','Restarting':'重启中'}.items(): s=s.replace(a,b)
    return s

def find_compose_file(directory: Path):
    for f in COMPOSE_FILES:
        candidate=directory/f
        if candidate.exists(): return candidate
    return None

def discover_projects():
    res=[]
    if PROJECTS_DIR.exists():
        for d in sorted(PROJECTS_DIR.iterdir()):
            if not d.is_dir(): continue
            compose=find_compose_file(d)
            if compose: res.append({'name':d.name,'dir':str(d),'compose':str(compose)})
    for name,raw in CUSTOM_PROJECT_PATHS.items():
        d=Path(raw)
        if not d.exists(): continue
        compose=find_compose_file(d)
        if compose: res.append({'name':name,'dir':str(d),'compose':str(compose)})
    return res

def project(name):
    for p in discover_projects():
        if p['name']==name: return p
    return None

def format_ports(raw_ports):
    if not raw_ports:
        return '无'
    return str(raw_ports).replace(', ', '\n')

def compose_status_text(p, proj):
    code,out=shell(['docker','compose','-f',p['compose'],'ps','--format','json'],cwd=Path(p['dir']))
    head=f'项目：{proj}\n目录：{p["dir"]}\n'
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

def compose_status_text(p, proj):
    code,out=shell(['docker','compose','-f',p['compose'],'ps','--format','json'],cwd=Path(p['dir']))
    head=f'项目：{proj}\n目录：{p["dir"]}\n'
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

def run_task(task):
    action=task.get('action'); proj=task.get('project')
    if action=='home':
        dc,ds=shell(['systemctl','is-active','docker'],timeout=30); rc,ro=shell(['sh','-lc','docker ps -q | wc -l'],timeout=30); ac,ao=shell(['sh','-lc','docker ps -aq | wc -l'],timeout=30)
        z={'active':'运行中','inactive':'未运行','failed':'异常','activating':'启动中','deactivating':'停止中'}
        return f'Docker 运行面板\n\n节点：{NODE_NAME}\nDocker 状态：{z.get(ds.strip(),ds.strip() or "未知")}\n运行中的容器：{ro.strip() if rc==0 else "获取失败"}\n全部容器：{ao.strip() if ac==0 else "获取失败"}\n项目数量：{len(discover_projects())}'
    if action=='projects': return json.dumps(discover_projects(),ensure_ascii=False)
    if action=='system_info':
        hostname=shell(['hostname'],timeout=10)[1]
        os_info=shell(['bash','-lc','. /etc/os-release 2>/dev/null; echo ${PRETTY_NAME:-未知系统}'],timeout=10)[1]
        kernel=shell(['uname','-r'],timeout=10)[1]
        arch=shell(['uname','-m'],timeout=10)[1]
        cpu_model=shell(['bash','-lc',"lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -n1"],timeout=10)[1]
        cpu_cores=shell(['nproc'],timeout=10)[1]
        mem=shell(['bash','-lc',"free -h | awk '/Mem:/ {print $3 \" / \" $2}'"],timeout=10)[1]
        swap_total=shell(['bash','-lc',"free -b | awk '/Swap:/ {print $2}'"],timeout=10)[1].strip()
        swap_used=shell(['bash','-lc',"free -h | awk '/Swap:/ {print $3}'"],timeout=10)[1].strip()
        swap_total_h=shell(['bash','-lc',"free -h | awk '/Swap:/ {print $2}'"],timeout=10)[1].strip()
        swap='未启用' if swap_total in {'0','0B','0.0B',''} or swap_total_h in {'0','0B','0.0B'} else f'{swap_used} / {swap_total_h}'
        disk=shell(['bash','-lc',"df -h / | awk 'NR==2 {print $3 \" / \" $2 \" (\" $5 \")\"}'"],timeout=10)[1]
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
        traffic=shell(['python3','-c','from pathlib import Path; rx=tx=0\nfor line in Path("/proc/net/dev").read_text().splitlines()[2:]:\n    iface,data=line.split(":",1); iface=iface.strip()\n    if iface=="lo":\n        continue\n    cols=data.split(); rx+=int(cols[0]); tx+=int(cols[8])\nprint(f"{rx} {tx}")'],timeout=10)[1].split()
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
            f'📡 VPS 系统信息\n'
            f'━━━━━━━━━━━━━━\n'
            f'主机名：{hostname}\n'
            f'运营商：{org}\n'
            f'地理位置：{country} {city}\n'
            f'系统版本：{os_info}\n'
            f'内核版本：{kernel}\n'
            f'CPU 架构：{arch}\n'
            f'CPU 型号：{cpu_model}\n'
            f'CPU 核心数：{cpu_cores}\n'
            f'物理内存：{mem}\n'
            f'虚拟内存：{swap}\n'
            f'硬盘占用：{disk}\n'
            f'总接收：{total_rx}\n'
            f'总发送：{total_tx}\n'
            f'网络拥堵算法：{congestion} {qdisc}\n'
            f'公网 IPv4：{ipv4 or "无"}\n'
            f'公网 IPv6：{ipv6 or "无"}\n'
            f'DNS 服务器：{dns or "无"}\n'
            f'系统时间：{current_time}\n'
            f'运行时长：{uptime}'
        )
    if action=='network_info':
        interfaces=shell(['bash','-lc','for IFACE in $(ls /sys/class/net/); do echo "接口: $IFACE"; IPv4=$(ip -4 addr show $IFACE | grep -oP "inet \\K[\\d./]+" | head -n1); [ -n "$IPv4" ] && echo "IPv4: $IPv4" || echo "IPv4: 无"; IPv6=$(ip -6 addr show $IFACE scope global | grep -oP "inet6 \\K[0-9a-f:]+/[0-9]+" | head -n1); [ -n "$IPv6" ] && echo "IPv6: $IPv6" || echo "IPv6: 无"; LL6=$(ip -6 addr show $IFACE scope link | grep -oP "inet6 \\K[0-9a-f:]+/[0-9]+" | head -n1); [ -n "$LL6" ] && echo "链路本地 IPv6: $LL6" || true; echo "MAC: $(cat /sys/class/net/$IFACE/address)"; echo; done'],timeout=30)[1]
        route4=shell(['ip','route','show','default'],timeout=10)[1]
        route6=shell(['ip','-6','route','show','default'],timeout=10)[1]
        ping4=shell(['ping','-c','2','-W','2','8.8.8.8'],timeout=10)[1]
        ping6=shell(['ping6','-c','2','-W','2','google.com'],timeout=10)[1]
        if 'Network is unreachable' in ping6 or 'connect:' in ping6:
            ping6='当前没有可用 IPv6 路由或 IPv6 未连通'
        return (
            '🌐 VPS 网络信息\n'
            '━━━━━━━━━━━━━━\n'
            f'【网络接口】\n{interfaces}\n'
            f'【默认路由】\nIPv4 默认路由：\n{route4}\n\nIPv6 默认路由：\n{route6}\n\n'
            f'【网络连通性测试】\nIPv4 测试：\n{ping4}\n\nIPv6 测试：\n{ping6}'
        )
    if action=='system_cleanup':
        j=shell(['journalctl','--vacuum-time=7d'],timeout=120); a=shell(['apt-get','clean'],timeout=120); i=shell(['docker','image','prune','-a','-f'],timeout=120); v=shell(['docker','volume','prune','-f'],timeout=120); n=shell(['docker','network','prune','-f'],timeout=120)
        return f'系统清理完成\n\n[日志清理] exit={j[0]}\n{loc(j[1])}\n\n[缓存清理] exit={a[0]}\n{loc(a[1])}\n\n[无用镜像] exit={i[0]}\n{loc(i[1])}\n\n[无用卷] exit={v[0]}\n{loc(v[1])}\n\n[无用网络] exit={n[0]}\n{loc(n[1])}'
    if action=='overview':
        ic,io=shell(['sh','-lc','docker image ls -q | sort -u | wc -l']); rc,ro=shell(['sh','-lc','docker ps -q | wc -l']); ac,ao=shell(['sh','-lc','docker ps -aq | wc -l']); vc,vo=shell(['sh','-lc','docker volume ls -q | wc -l']); nc,no=shell(['sh','-lc',"docker network ls --format '{{.Name}}' | wc -l"]); pc,po=shell(['docker','ps','--format','{{json .}}'])
        lines=[f'Docker 概览\n\n节点：{NODE_NAME}\n运行中的容器：{ro.strip()}\n全部容器：{ao.strip()}\n镜像数量：{io.strip()}\n卷数量：{vo.strip()}\n网络数量：{no.strip()}']
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
        name=(proj or '').strip()
        act=action.split('_',1)[1]
        if act=='start': c,o=shell(['docker','start',name],timeout=120); return f'[{name}] 启动完成（退出码={c}）\n{loc(o)}'
        if act=='stop': c,o=shell(['docker','stop',name],timeout=120); return f'[{name}] 停止完成（退出码={c}）\n{loc(o)}'
        if act=='restart': c,o=shell(['docker','restart',name],timeout=120); return f'[{name}] 重启完成（退出码={c}）\n{loc(o)}'
        if act=='logs': c,o=shell(['docker','logs','--tail',str(LOG_LINES),name],timeout=120); return f'[{name}] 日志\n{loc(o)}'
        if act=='remove':
            c0,o0=shell(['docker','inspect','-f','{{.Config.Image}}',name],timeout=30)
            image=o0.strip() if c0==0 else ''
            c1,o1=shell(['docker','rm','-f',name],timeout=120)
            if image:
                c2,o2=shell(['docker','rmi','-f',image],timeout=120)
            else:
                c2,o2=0,'(未获取到镜像名)'
            return f'[{name}] 删除容器+镜像完成（rm={c1}, rmi={c2}）\n[删除容器]\n{loc(o1)}\n\n[删除镜像]\n{loc(o2)}'
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
        status={'active':'运行中','inactive':'未运行','failed':'异常','activating':'启动中','deactivating':'停止中'}.get(so.strip(), so.strip() or '未知')
        if status!='运行中':
            dc,do=shell(['systemctl','status','docker','--no-pager'],timeout=60)
            return f'Docker 重启后状态异常\n当前状态：{status}\n\n{loc(do)}'
        return f'Docker 已重启\n当前状态：{status}'
    if action=='prune': a=shell(['docker','image','prune','-a','-f'])[1]; b=shell(['docker','volume','prune','-f'])[1]; c=shell(['docker','network','prune','-f'])[1]; return f'清理完成\n\n[无用镜像]\n{loc(a)}\n\n[无用卷]\n{loc(b)}\n\n[无用网络]\n{loc(c)}'
    p=project(proj or '')
    if not p: return f'项目不存在：{proj}'
    base=['docker','compose','-f',p['compose']]
    if action=='status': return compose_status_text(p, proj)
    if action=='up': c,o=shell(base+['up','-d'],cwd=Path(p['dir'])); return f'[{proj}] 启动完成（退出码={c}）\n{loc(o)}'
    if action=='down': c,o=shell(base+['down'],cwd=Path(p['dir'])); return f'[{proj}] 停止完成（退出码={c}）\n{loc(o)}'
    if action=='delete_container':
        c,o=shell(base+['down','-v','--rmi','all'],cwd=Path(p['dir']))
        return f'[{proj}] 删除容器完成（退出码={c}）\n{loc(o)}'
    if action=='delete_all':
        c1,o1=shell(base+['down','-v','--rmi','all'],cwd=Path(p['dir']))
        c2,o2=shell(['rm','-rf',p['dir']])
        return f'[{proj}] 删除容器+文件数据完成（down={c1}, rm={c2}）\n[删除容器]\n{loc(o1)}\n\n[删除文件数据]\n{loc(o2)}'
    if action=='restart': c,o=shell(base+['restart'],cwd=Path(p['dir'])); return f'[{proj}] 重启完成（退出码={c}）\n{loc(o)}'
    if action=='pull': c,o=shell(base+['pull'],cwd=Path(p['dir'])); return f'[{proj}] 拉取镜像完成（退出码={c}）\n{loc(o)}'
    if action=='update':
        c1,o1=shell(base+['pull'],cwd=Path(p['dir']))
        if c1!=0: return f'[{proj}] 更新失败\n[拉取镜像]\n{loc(o1)}'
        c2,o2=shell(base+['up','-d'],cwd=Path(p['dir']))
        c3,o3=shell(['docker','image','prune','-a','-f'])
        return f'[{proj}] 更新并重启完成\n[拉取镜像]\n{loc(o1)}\n\n[启动服务]\n{loc(o2)}\n\n[清理无用镜像]\n{loc(o3)}'
    if action=='logs': c,o=shell(base+['logs','--tail',str(LOG_LINES),'--no-color'],cwd=Path(p['dir']),timeout=120); return f'[{proj}] 日志\n{loc(o)}'
    return '未知操作'

def main():
    st=ensure_registered(); print('node registered:',st.get('node_id'))
    while True:
        try:
            public_ip=detect_public_ip()
            res=req('GET',f"{st['master_url']}/api/poll?node_id={urllib.parse.quote(st['node_id'])}&node_token={urllib.parse.quote(st['node_token'])}&public_ip={urllib.parse.quote(public_ip)}")
            task=res.get('task')
            if task:
                text=run_task(task)
                req('POST',st['master_url']+'/api/result',{'node_id':st['node_id'],'node_token':st['node_token'],'task_id':task['id'],'text':text})
            else:
                time.sleep(2)
        except Exception as e:
            print('node loop error:',e,file=sys.stderr); time.sleep(5)

if __name__=='__main__': main()

PYEOF
chmod 755 "$APP_FILE"; }
write_service() { cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Docker Fleet Node
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
install_app() { require_root; require_debian_ubuntu; install_deps; read -rp '请输入主控地址（如 1.2.3.4:8765）: ' MASTER_URL; MASTER_URL=${MASTER_URL#http://}; MASTER_URL=${MASTER_URL#https://}; MASTER_URL="http://${MASTER_URL}"; [[ -n "$MASTER_URL" ]] || { err '主控地址不能为空'; exit 1; }; read -rp '请输入对接码: ' PAIR_CODE; [[ -n "$PAIR_CODE" ]] || { err '对接码不能为空'; exit 1; }; read -rp '请输入节点名称（留空默认主机名）: ' NODE_NAME; NODE_NAME=${NODE_NAME:-$(hostname)}; write_app; cat > "$ENV_FILE" <<EOF
MASTER_URL=$MASTER_URL
PAIR_CODE=$PAIR_CODE
NODE_NAME=$NODE_NAME
PROJECTS_DIR=/opt
STATE_DIR=/opt/docker-fleet-node/state
TG_LOG_LINES=80
EOF
chmod 600 "$ENV_FILE"; write_service; systemctl daemon-reload; systemctl enable --now "$APP_NAME"; info '节点安装完成'; echo "主控地址: $MASTER_URL"; echo "节点名称: $NODE_NAME"; }
uninstall_app() { require_root; systemctl disable --now "$APP_NAME" >/dev/null 2>&1 || true; rm -f "$SERVICE_FILE" "$ENV_FILE"; systemctl daemon-reload; rm -rf "$INSTALL_DIR"; info '已卸载 docker-fleet-node'; }
status_app() { systemctl --no-pager status "$APP_NAME" || true; [[ -f "$ENV_FILE" ]] && echo && grep -E '^(MASTER_URL|NODE_NAME)=' "$ENV_FILE" || true; }
restart_app() { require_root; systemctl restart "$APP_NAME"; info '已重启'; }
show_menu() { echo; echo '====== Docker Fleet 节点 ======'; echo '1. 安装'; echo '2. 卸载'; echo '3. 查看状态'; echo '4. 重启服务'; echo '0. 退出'; }
pause_return() { echo; read -rp '按回车返回菜单...' _; }
menu_loop() { while true; do show_menu; read -rp '请输入选项: ' choice; case "$choice" in 1) install_app; pause_return ;; 2) uninstall_app; pause_return ;; 3) status_app; pause_return ;; 4) restart_app; pause_return ;; 0) exit 0 ;; *) err '无效选项'; pause_return ;; esac; done; }
case "${1:-menu}" in install) install_app ;; uninstall) uninstall_app ;; status) status_app ;; restart) restart_app ;; menu) menu_loop ;; *) menu_loop ;; esac
