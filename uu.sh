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
    res=req('POST',MASTER_URL+'/api/register',{'pair_code':PAIR_CODE,'name':NODE_NAME})
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
    if action=='overview':
        ic,io=shell(['sh','-lc','docker image ls -q | sort -u | wc -l']); rc,ro=shell(['sh','-lc','docker ps -q | wc -l']); ac,ao=shell(['sh','-lc','docker ps -aq | wc -l']); vc,vo=shell(['sh','-lc','docker volume ls -q | wc -l']); nc,no=shell(['sh','-lc',"docker network ls --format '{{.Name}}' | wc -l"]); pc,po=shell(['docker','ps','--format','{{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}}'])
        return f'Docker 概览\n\n节点：{NODE_NAME}\n运行中的容器：{ro.strip()}\n全部容器：{ao.strip()}\n镜像数量：{io.strip()}\n卷数量：{vo.strip()}\n网络数量：{no.strip()}\n\n运行中的容器：\n{loc(po) if pc==0 else po}'
    if action=='running': c,o=shell(['docker','ps','--format','table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}']); return loc(o)
    if action=='stats': c,o=shell(['docker','stats','--no-stream','--format','table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}']); return loc(o)
    if action=='docker_restart': c,o=shell(['systemctl','restart','docker']); return 'Docker 已重启' if c==0 else f'Docker 重启失败\n{o}'
    if action=='prune': a=shell(['docker','image','prune','-f'])[1]; b=shell(['docker','volume','prune','-f'])[1]; c=shell(['docker','network','prune','-f'])[1]; return f'清理完成\n\n[无用镜像]\n{loc(a)}\n\n[无用卷]\n{loc(b)}\n\n[无用网络]\n{loc(c)}'
    p=project(proj or '')
    if not p: return f'项目不存在：{proj}'
    base=['docker','compose','-f',p['compose']]
    if action=='status': return compose_status_text(p, proj)
    if action=='up': c,o=shell(base+['up','-d'],cwd=Path(p['dir'])); return f'[{proj}] 启动完成（退出码={c}）\n{loc(o)}'
    if action=='down': c,o=shell(base+['down'],cwd=Path(p['dir'])); return f'[{proj}] 停止完成（退出码={c}）\n{loc(o)}'
    if action=='delete_container':
        c,o=shell(base+['down','-v'],cwd=Path(p['dir']))
        return f'[{proj}] 删除容器完成（退出码={c}）\n{loc(o)}'
    if action=='delete_all':
        c1,o1=shell(base+['down','-v'],cwd=Path(p['dir']))
        c2,o2=shell(['rm','-rf',p['dir']])
        return f'[{proj}] 删除容器+文件数据完成（down={c1}, rm={c2}）\n[删除容器]\n{loc(o1)}\n\n[删除文件数据]\n{loc(o2)}'
    if action=='restart': c,o=shell(base+['restart'],cwd=Path(p['dir'])); return f'[{proj}] 重启完成（退出码={c}）\n{loc(o)}'
    if action=='pull': c,o=shell(base+['pull'],cwd=Path(p['dir'])); return f'[{proj}] 拉取镜像完成（退出码={c}）\n{loc(o)}'
    if action=='update':
        c1,o1=shell(base+['pull'],cwd=Path(p['dir']))
        if c1!=0: return f'[{proj}] 更新失败\n[拉取镜像]\n{loc(o1)}'
        c2,o2=shell(base+['up','-d'],cwd=Path(p['dir']))
        c3,o3=shell(['docker','image','prune','-f'])
        return f'[{proj}] 更新并重启完成\n[拉取镜像]\n{loc(o1)}\n\n[启动服务]\n{loc(o2)}\n\n[清理无用镜像]\n{loc(o3)}'
    if action=='logs': c,o=shell(base+['logs','--tail',str(LOG_LINES),'--no-color'],cwd=Path(p['dir']),timeout=120); return f'[{proj}] 日志\n{loc(o)}'
    return '未知操作'

def main():
    st=ensure_registered(); print('node registered:',st.get('node_id'))
    while True:
        try:
            res=req('GET',f"{st['master_url']}/api/poll?node_id={urllib.parse.quote(st['node_id'])}&node_token={urllib.parse.quote(st['node_token'])}")
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
install_app() { require_root; require_debian_ubuntu; install_deps; read -rp '请输入主控地址（如 http://1.2.3.4:8765）: ' MASTER_URL; [[ -n "$MASTER_URL" ]] || { err '主控地址不能为空'; exit 1; }; read -rp '请输入对接码: ' PAIR_CODE; [[ -n "$PAIR_CODE" ]] || { err '对接码不能为空'; exit 1; }; read -rp '请输入节点名称（留空默认主机名）: ' NODE_NAME; NODE_NAME=${NODE_NAME:-$(hostname)}; write_app; cat > "$ENV_FILE" <<EOF
MASTER_URL=$MASTER_URL
PAIR_CODE=$PAIR_CODE
NODE_NAME=$NODE_NAME
PROJECTS_DIR=/opt
STATE_DIR=/opt/docker-fleet-node/state
TG_LOG_LINES=80
EOF
chmod 600 "$ENV_FILE"; write_service; systemctl daemon-reload; systemctl enable --now "$APP_NAME"; info '节点安装完成'; echo "主控地址: $MASTER_URL"; echo "节点名称: $NODE_NAME"; }
