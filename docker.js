/*
注⚠️：脚本的运行需提前在VPS上完成相关操作
参数：
url：你的 Docker 监控服务 URL
name：Panel的标题
icon：Panel的图标

示例：
argument = url=http://127.0.0.1:7124&name=Docker监控&icon=shippingbox.fill
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

  // 每条信息单独一行
  panel.content = 
    `🐳 Docker: ${dockerStatus}\n` +
    `📦 总容器: ${totalContainers}\n` +
    `▶️ 运行中: ${runningContainers}\n` +
    `🕒 Update: ${timeString}`;

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
