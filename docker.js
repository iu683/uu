/*
注⚠️：脚本需在 VPS 上运行 Docker 监控服务
参数：
url：你的 Docker 监控服务 URL
name：Panel标题
icon：Panel图标
*/

(async () => {
  let params = getParams($argument);
  let stats = await httpAPI(params.url);
  const jsonData = JSON.parse(stats.body);

  const updateTime = new Date(jsonData.last_time);
  const timeString = updateTime.toLocaleString();

  const dockerStatus = jsonData.docker_status || '未知';
  const totalContainers = jsonData.total_containers ?? 0;
  const runningContainers = jsonData.running_containers ?? 0;

  let panel = {};
  panel.title = params.name || 'Docker Info';
  panel.icon = params.icon || 'shippingbox.fill';
  panel["icon-color"] = dockerStatus === '运行中' ? '#06D6A0' : '#f44336';

  // 构建运行中容器信息
  let containersInfo = '';
  if (jsonData.containers && jsonData.containers.length > 0) {
    jsonData.containers.forEach(c => {
      if (c.status === 'running') {
        const name = c.name || '未知';
        const status = c.status || '未知';
        const uptime = c.uptime || '未知';
        const cpu = c.cpu !== undefined ? c.cpu.toFixed(1) + '%' : '未知';
        const memory = c.memory || '未知';
        const netIO = c.net || '未知';
        containersInfo += `\n▶️ ${name} (${status})\n   ⏱️ ${uptime} | CPU: ${cpu} | MEM: ${memory} | NET: ${netIO}`;
      }
    });
  } else {
    containersInfo = '\n无运行中容器';
  }

  // Panel 内容
  panel.content = 
    `🐳 Docker: ${dockerStatus}\n` +
    `📦 总容器: ${totalContainers}\n` +
    `▶️ 运行中: ${runningContainers}` +
    containersInfo +
    `\n🕒 Update: ${timeString}`;

  $done(panel);
})().catch((e) => {
  console.log('error: ' + e);
  $done({
    title: 'Error',
    content: `获取 Docker 状态失败: ${e}`,
    icon: 'error',
    'icon-color': '#f44336'
  });
});

function httpAPI(path = '') {
  let headers = {'User-Agent': 'Mozilla/5.0'};
  return new Promise((resolve, reject) => {
    $httpClient.get({url: path, headers: headers}, (err, resp, body) => {
      if (err) reject(err);
      else {
        resp.body = body;
        resp.statusCode = resp.status ? resp.status : resp.statusCode;
        resp.status = resp.statusCode;
        resolve(resp);
      }
    });
  });
}

function getParams(param) {
  return Object.fromEntries(
    $argument
      .split('&')
      .map(item => item.split('='))
      .map(([k, v]) => [k, decodeURIComponent(v)])
  );
}
