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

def require_env():
    miss=[k for k,v in [('TG_BOT_TOKEN',BOT_TOKEN),('TG_ALLOWED_CHAT_ID',ALLOWED_CHAT_ID),('PAIR_CODE',PAIR_CODE)] if not v]
    if miss:
        print('缺少环境变量: '+','.join(miss),file=sys.stderr); sys.exit(1)


def get_master_url():
    if MASTER_PUBLIC_URL:
        return MASTER_PUBLIC_URL
    code,out=shell(['sh','-lc',"hostname -I | awk '{print $1}'"],timeout=10)
    host=(out.strip() if code==0 else '') or 'YOUR_SERVER_IP'
    return f'http://{host}:{PORT}'

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
    for a,b in {'NAMES':'名称','NAME':'名称','IMAGES':'镜像','IMAGE':'镜像','SERVICES':'服务','SERVICE':'服务','COMMAND':'命令','CREATED':'创建时间','STATUS':'状态','PORTS':'端口','Up ':'运行中 ','Exited':'已退出','Running':'运行中','Restarting':'重启中','seconds ago':'秒前','minutes ago':'分钟前','hours ago':'小时前','days ago':'天前','About a minute':'约1分钟','About an hour':'约1小时'}.items(): s=s.replace(a,b)
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

def run_local(action,project=None):
    if action=='home':
        dc,ds=shell(['systemctl','is-active','docker'],timeout=30); rc,ro=shell(['sh','-lc','docker ps -q | wc -l'],timeout=30); ac,ao=shell(['sh','-lc','docker ps -aq | wc -l'],timeout=30)
        return f'Docker 运行面板\n\n节点：本机\nDocker 状态：{zh_status(ds)}\n运行中的容器：{ro.strip() if rc==0 else "获取失败"}\n全部容器：{ao.strip() if ac==0 else "获取失败"}\n项目数量：{len(discover_projects())}'
    if action=='projects': return json.dumps(discover_projects(),ensure_ascii=False)
    if action=='overview':
        ic,io=shell(['sh','-lc','docker image ls -q | sort -u | wc -l']); rc,ro=shell(['sh','-lc','docker ps -q | wc -l']); ac,ao=shell(['sh','-lc','docker ps -aq | wc -l']); vc,vo=shell(['sh','-lc','docker volume ls -q | wc -l']); nc,no=shell(['sh','-lc',"docker network ls --format '{{.Name}}' | wc -l"]); pc,po=shell(['docker','ps','--format','{{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}}'])
        return f'Docker 概览\n\n节点：本机\n运行中的容器：{ro.strip()}\n全部容器：{ao.strip()}\n镜像数量：{io.strip()}\n卷数量：{vo.strip()}\n网络数量：{no.strip()}\n\n运行中的容器：\n{loc(po) if pc==0 else po}'
    if action=='running': c,o=shell(['docker','ps','--format','table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}']); return loc(o)
    if action=='stats': c,o=shell(['docker','stats','--no-stream','--format','table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}']); return loc(o)
    if action=='docker_restart': c,o=shell(['systemctl','restart','docker']); return 'Docker 已重启' if c==0 else f'Docker 重启失败\n{o}'
    if action=='prune':
        a=shell(['docker','image','prune','-f'])[1]; b=shell(['docker','volume','prune','-f'])[1]; c=shell(['docker','network','prune','-f'])[1]
        return f'清理完成\n\n[无用镜像]\n{loc(a)}\n\n[无用卷]\n{loc(b)}\n\n[无用网络]\n{loc(c)}'
    p=compose_project(project or '')
    if not p: return f'项目不存在：{project}'
    base=['docker','compose','-f',p['compose']]
    if action=='status': c,o=shell(base+['ps'],cwd=Path(p['dir'])); return f'项目：{project}\n目录：{p["dir"]}\n{loc(o)}'
    if action=='up': c,o=shell(base+['up','-d'],cwd=Path(p['dir'])); return f'[{project}] 启动完成（退出码={c}）\n{loc(o)}'
    if action=='down': c,o=shell(base+['down'],cwd=Path(p['dir'])); return f'[{project}] 停止完成（退出码={c}）\n{loc(o)}'
    if action=='restart': c,o=shell(base+['restart'],cwd=Path(p['dir'])); return f'[{project}] 重启完成（退出码={c}）\n{loc(o)}'
    if action=='pull': c,o=shell(base+['pull'],cwd=Path(p['dir'])); return f'[{project}] 拉取镜像完成（退出码={c}）\n{loc(o)}'
    if action=='update':
        c1,o1=shell(base+['pull'],cwd=Path(p['dir']));
        if c1!=0: return f'[{project}] 更新失败\n[拉取镜像]\n{loc(o1)}'
        c2,o2=shell(base+['up','-d'],cwd=Path(p['dir'])); c3,o3=shell(['docker','image','prune','-f'])
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
    tid=enqueue(target,action,project)
    return wait_result(tid)

def nodes_keyboard():
    nodes=load_nodes(); rows=[[{'text':'本机','callback_data':'target:local'}]]
    for nid,n in nodes.items(): rows.append([{'text':n.get('name',nid),'callback_data':f'target:{nid}'}])
    rows.append([{'text':'🔑 对接码','callback_data':'menu:pair'}])
    return {'inline_keyboard':rows}

def main_keyboard(target):
    return {'inline_keyboard':[[{'text':'🖥 选择节点','callback_data':'menu:nodes'}],[{'text':'📦 项目列表','callback_data':f'menu:list:{target}'}],[{'text':'🎬 应用快捷管理','callback_data':f'menu:apps:{target}'}],[{'text':'🐳 Docker 管理','callback_data':f'menu:docker:{target}'}]]}

def apps_keyboard(target):
    rows=[]
    for name in CUSTOM_PROJECT_PATHS.keys(): rows.append([{'text':name,'callback_data':f'project:{target}:{name}'}])
    rows.append([{'text':'🏠 首页','callback_data':f'home:{target}'}])
    return {'inline_keyboard':rows}

def docker_keyboard(target):
    return {'inline_keyboard':[[{'text':'📊 Docker 概览','callback_data':f'docker:overview:{target}'}],[{'text':'📦 运行中的容器','callback_data':f'docker:running:{target}'}],[{'text':'📈 容器占用','callback_data':f'docker:stats:{target}'}],[{'text':'🔄 重启 Docker','callback_data':f'docker:docker_restart:{target}'}],[{'text':'🧹 清理无用镜像/卷/网络','callback_data':f'docker:prune:{target}'}],[{'text':'🏠 首页','callback_data':f'home:{target}'}]]}

def project_keyboard(target,project):
    return {'inline_keyboard':[[{'text':'▶️ 启动','callback_data':f'action:up:{target}:{project}'},{'text':'⏹ 停止','callback_data':f'action:down:{target}:{project}'}],[{'text':'🔄 重启','callback_data':f'action:restart:{target}:{project}'},{'text':'📥 拉镜像','callback_data':f'action:pull:{target}:{project}'}],[{'text':'♻️ 更新并重启','callback_data':f'action:update:{target}:{project}'}],[{'text':'📜 日志','callback_data':f'action:logs:{target}:{project}'},{'text':'📊 状态','callback_data':f'action:status:{target}:{project}'}],[{'text':'⬅️ 项目列表','callback_data':f'menu:list:{target}'},{'text':'🏠 首页','callback_data':f'home:{target}'}]]}

def projects_keyboard(target,projects):
    rows=[[{'text':p['name'],'callback_data':f'project:{target}:{p["name"]}'}] for p in projects]
    rows.append([{'text':'🏠 首页','callback_data':f'home:{target}'}]); return {'inline_keyboard':rows}

def handle_text(chat,text):
    if text.startswith('/start'):
        target=CURRENT_TARGET.get(chat,'local'); send(chat,run_target(target,'home'),main_keyboard(target)); return
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
    if data=='menu:pair': edit(chat,mid,f'节点对接信息：\n主控地址：{get_master_url()}\n对接码：{PAIR_CODE}\n\n节点安装时填写主控地址和这个码。',main_keyboard(CURRENT_TARGET.get(chat,'local'))); return
    if data.startswith('target:'):
        t=data.split(':',1)[1]; CURRENT_TARGET[chat]=t; edit(chat,mid,run_target(t,'home'),main_keyboard(t)); return
    if data.startswith('home:'):
        t=data.split(':',1)[1]; edit(chat,mid,run_target(t,'home'),main_keyboard(t)); return
    if data.startswith('menu:docker:'):
        t=data.split(':',2)[2]; edit(chat,mid,'Docker 管理',docker_keyboard(t)); return
    if data.startswith('menu:apps:'):
        t=data.split(':',2)[2]; edit(chat,mid,'应用快捷管理',apps_keyboard(t)); return
    if data.startswith('menu:list:'):
        t=data.split(':',2)[2]; raw=run_target(t,'projects')
        try: ps=json.loads(raw)
        except Exception: edit(chat,mid,raw,main_keyboard(t)); return
        edit(chat,mid,f'找到 {len(ps)} 个项目：',projects_keyboard(t,ps)); return
    if data.startswith('docker:'):
        _,act,t=data.split(':',2); edit(chat,mid,run_target(t,act),docker_keyboard(t)); return
    if data.startswith('project:'):
        _,t,p=data.split(':',2); edit(chat,mid,run_target(t,'status',p),project_keyboard(t,p)); return
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
                nid='node-'+uuid.uuid4().hex[:8]; tok=uuid.uuid4().hex; nodes=load_nodes(); nodes[nid]={'name':body.get('name') or nid,'token':tok,'last_seen':time.time()}; save_nodes(nodes); return self._json(200,{'node_id':nid,'node_token':tok})
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
                nodes[nid]['last_seen']=time.time(); save_nodes(nodes)
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
install_app() { require_root; require_debian_ubuntu; install_deps; read -rp '请输入 Telegram Bot Token: ' TG_BOT_TOKEN; [[ -n "$TG_BOT_TOKEN" ]] || { err 'Bot Token 不能为空'; exit 1; }; read -rp '请输入允许操作的 Telegram TGID: ' TG_ALLOWED_CHAT_ID; [[ -n "$TG_ALLOWED_CHAT_ID" ]] || { err 'TGID 不能为空'; exit 1; }; read -rp '请输入节点对接码（留空自动生成）: ' PAIR_CODE; PAIR_CODE=${PAIR_CODE:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)}; MASTER_IP=$(hostname -I | awk '{print $1}'); MASTER_PUBLIC_URL="http://${MASTER_IP}:8765"; write_app; cat > "$ENV_FILE" <<EOF
TG_BOT_TOKEN=$TG_BOT_TOKEN
TG_ALLOWED_CHAT_ID=$TG_ALLOWED_CHAT_ID
PAIR_CODE=$PAIR_CODE
DATA_DIR=/opt/docker-fleet-master/data
PROJECTS_DIR=/opt
MASTER_BIND=0.0.0.0
MASTER_PORT=8765
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
