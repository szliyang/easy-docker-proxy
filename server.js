#!/usr/bin/env node
// =========================================
// cmliu/CF-Workers-docker.io (https://github.com/cmliu/CF-Workers-docker.io) 的 NAT 服务器(Node 18+) 移植版
// 原项目基于 Cloudflare Workers(_worker.js, 原仓库未附带 LICENSE 文件), 本文件保留其核心逻辑并适配 Node 运行时
// Docker 镜像仓库反代: 默认 Docker Hub, 支持子域前缀路由(需域名)与 ?ns= 指定上游
// 20261011-1130 init: 从 Workers _worker.js 移植, 去除边缘缓存/事件监听, 新增 token 内存缓存与 NAT 端口自动获取
// 20261011-1140 fix: 上游转发强制 https 并清带入站端口(Workers 天然 https, Node 需手动)
// 20261011-1442 feat: 启动横幅显示服务器IP(SERVER_IP > PTERODACTYL_SERVER_IP > 出网探测 > 网卡回退)
// =========================================
'use strict';
const http = require('http');
const os = require('os');
const { Readable } = require('stream');

// ========== NAT 端口自动获取: PORT > PTERODACTYL_SERVER_PORT > SERVER_PORT > 3000 ==========
function detectPort() {
  return process.env.PORT || process.env.PTERODACTYL_SERVER_PORT || process.env.SERVER_PORT || 3000;
}
const PORT = detectPort();

let hub_host = 'registry-1.docker.io';
const auth_url = 'https://auth.docker.io';

// 环境变量: UA 黑名单(逗号分隔) / URL302 / URL(伪装页)
let blockedUA = ['netcraft'];
if (process.env.UA) blockedUA = blockedUA.concat(ADD(process.env.UA));

function routeByHosts(host) {
  const routes = {
    "quay": "quay.io",
    "gcr": "gcr.io",
    "k8s-gcr": "k8s.gcr.io",
    "k8s": "registry.k8s.io",
    "ghcr": "ghcr.io",
    "cloudsmith": "docker.cloudsmith.io",
    "nvcr": "nvcr.io",
  };
  if (host in routes) return [routes[host], false];
  return [hub_host, true];
}

function ADD(envadd) {
  const addtext = envadd.replace(/[\t|"'\r\n]+/g, ',').replace(/,+/g, ',')
    .replace(/^,/, '').replace(/,$/, '');
  return addtext.split(',');
}

// token 内存缓存: repo -> {token, ts}, 4 分钟过期(token 本身约 5 分钟)
const tokenCache = new Map();
const TOKEN_TTL = 4 * 60 * 1000;

async function nginxPage() {
  return `<!DOCTYPE html><html><head><title>Welcome to nginx!</title></head>
<body><h1>Welcome to nginx!</h1><p>If you see this page, the nginx web server is successfully installed and working.</p>
<p><em>Thank you for using nginx.</em></p></body></html>`;
}

async function searchInterface() {
  return `<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Docker Hub 镜像搜索</title>
<style>body{font-family:-apple-system,Arial,sans-serif;display:flex;flex-direction:column;justify-content:center;align-items:center;min-height:90vh;background:linear-gradient(135deg,#1a90ff,#003eb3);color:#fff}
.s{display:flex;width:90%;max-width:600px;height:55px;border-radius:12px;overflow:hidden;box-shadow:0 10px 25px rgba(0,0,0,.15)}
input{flex:1;padding:0 20px;font-size:16px;border:none;outline:none}
button{width:70px;border:none;background:#0052cc;color:#fff;font-size:16px;cursor:pointer}
p{opacity:.85;margin-top:20px}</style></head><body>
<h1>Docker Hub 镜像搜索</h1><div class="s">
<input type="text" id="q" placeholder="输入关键词搜索镜像，如: nginx, mysql, redis...">
<button onclick="doSearch()">搜索</button></div>
<p>NAT 版 docker-proxy · 基于 cmliu/CF-Workers-docker.io 移植</p>
<script>function doSearch(){const q=document.getElementById('q').value;if(q)location.href='/search?q='+encodeURIComponent(q)}
document.getElementById('q').addEventListener('keypress',e=>{if(e.key==='Enter')doSearch()});</script>
</body></html>`;
}

// ========== 核心处理逻辑(移植自 _worker.js fetch handler) ==========
async function handleRequest(request) {
  const getReqHeader = (key) => request.headers.get(key);
  let url = new URL(request.url);
  const userAgent = (getReqHeader('User-Agent') || 'null').toLowerCase();
  const workers_url = `http://${url.hostname}:${url.port}`;

  const ns = url.searchParams.get('ns');
  const hostname = url.searchParams.get('hubhost') || url.hostname;
  const hostTop = hostname.split('.')[0];

  if (ns) {
    hub_host = ns === 'docker.io' ? 'registry-1.docker.io' : ns;
  } else {
    const checkHost = routeByHosts(hostTop);
    hub_host = checkHost[0];
    var fakePage = checkHost[1];
  }
  console.log(`域名头部: ${hostTop} 反代地址: ${hub_host} searchInterface: ${!!fakePage}`);

  url.hostname = hub_host;
  url.protocol = 'https:'; // 入站是 http, 转发上游必须强制 https(Workers 版天然 https, Node 版需手动)
  url.port = '';           // 入站端口(如 :3999)不能带到上游
  const hubParams = ['/v1/search', '/v1/repositories'];

  if (blockedUA.some(u => userAgent.includes(u))) {
    return new Response(await nginxPage(), { headers: { 'Content-Type': 'text/html; charset=UTF-8' } });
  } else if (userAgent.includes('mozilla') || hubParams.some(p => url.pathname.includes(p))) {
    if (url.pathname == '/') {
      if (process.env.URL302) {
        return new Response(null, { status: 302, headers: { Location: process.env.URL302 } });
      } else if (process.env.URL) {
        if (process.env.URL.toLowerCase() == 'nginx') {
          return new Response(await nginxPage(), { headers: { 'Content-Type': 'text/html; charset=UTF-8' } });
        }
        return fetch(new Request(process.env.URL, request));
      } else if (fakePage) {
        return new Response(await searchInterface(), { headers: { 'Content-Type': 'text/html; charset=UTF-8' } });
      }
    } else {
      if (url.pathname.startsWith('/v1/')) {
        url.hostname = 'index.docker.io';
      } else if (fakePage) {
        url.hostname = 'hub.docker.com';
      }
      const q = url.searchParams.get('q');
      if (q && q.includes('library/') && q != 'library/') {
        url.searchParams.set('q', q.replace('library/', ''));
      }
      return fetch(new Request(url, request));
    }
  }

  // Docker Hub 官方镜像补全 library/ 前缀
  if (hub_host == 'registry-1.docker.io' && /^\/v2\/[^/]+\/[^/]+\/[^/]+$/.test(url.pathname) && !/^\/v2\/library/.test(url.pathname)) {
    url.pathname = '/v2/library/' + url.pathname.split('/v2/')[1];
  }

  // /token 直接转发 auth.docker.io
  if (url.pathname.includes('/token')) {
    const token_url = auth_url + url.pathname + url.search;
    return fetch(new Request(token_url, request));
  }

  // manifests/blobs/tags: 服务端代取 token 后转发
  if (url.pathname.startsWith('/v2/') &&
      (url.pathname.includes('/manifests/') || url.pathname.includes('/blobs/') ||
       url.pathname.includes('/tags/') || url.pathname.endsWith('/tags/list'))) {
    const v2Match = url.pathname.match(/^\/v2\/(.+?)(?:\/(manifests|blobs|tags)\/)/);
    const repo = v2Match ? v2Match[1] : '';
    if (repo) {
      const token = await getHubToken(repo);
      const resp = await fetch(url, { method: request.method, headers: baseHeaders(request, `Bearer ${token}`), redirect: 'manual' });
      return relayWithRewrite(request, resp, workers_url);
    }
  }

  // 通用转发
  const headers = baseHeaders(request);
  if (request.headers.has('Authorization')) headers['Authorization'] = getReqHeader('Authorization');
  if (request.headers.has('X-Amz-Content-Sha256')) headers['X-Amz-Content-Sha256'] = getReqHeader('X-Amz-Content-Sha256');
  const resp = await fetch(url, { method: request.method, headers, redirect: 'manual' });
  return relayWithRewrite(request, resp, workers_url);
}

function baseHeaders(request, authorization) {
  const h = {
    'User-Agent': request.headers.get('User-Agent') || 'docker-proxy-nat',
    'Accept': request.headers.get('Accept') || '*/*',
    'Accept-Language': request.headers.get('Accept-Language') || '',
    'Accept-Encoding': request.headers.get('Accept-Encoding') || 'identity',
  };
  if (authorization) h['Authorization'] = authorization;
  return h;
}

async function getHubToken(repo) {
  const cached = tokenCache.get(repo);
  if (cached && Date.now() - cached.ts < TOKEN_TTL) return cached.token;
  const tokenUrl = `${auth_url}/token?service=registry.docker.io&scope=repository:${repo}:pull`;
  const res = await fetch(tokenUrl);
  const data = await res.json();
  tokenCache.set(repo, { token: data.token, ts: Date.now() });
  return data.token;
}

// 响应回传: 重写 Www-Authenticate, 3xx 重定向由本服务代取
async function relayWithRewrite(request, resp, workers_url) {
  const headers = new Headers(resp.headers);
  if (headers.get('Www-Authenticate')) {
    headers.set('Www-Authenticate', headers.get('Www-Authenticate').replace(new RegExp(auth_url, 'g'), workers_url));
  }
  if (headers.get('Location')) {
    console.info(`Following redirect to ${headers.get('Location')}`);
    return proxy(new URL(headers.get('Location')), request);
  }
  headers.set('access-control-allow-origin', '*');
  return new Response(resp.body, { status: resp.status, headers });
}

// 代取重定向目标(blob CDN 等)
async function proxy(urlObj, req) {
  const headers = new Headers(req.headers);
  headers.delete('Authorization');
  headers.delete('Host');
  headers.delete('Accept-Encoding');
  const res = await fetch(urlObj.href, { method: 'GET', headers, redirect: 'follow' });
  const resHdrNew = new Headers(res.headers);
  resHdrNew.set('access-control-expose-headers', '*');
  resHdrNew.set('access-control-allow-origin', '*');
  return new Response(res.body, { status: res.status, headers: resHdrNew });
}

// ========== Node HTTP 服务器: 原生请求/响应 与 Web Fetch API 互转 ==========
const HOP_HEADERS = new Set(['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te', 'trailer', 'transfer-encoding', 'upgrade', 'host']);

const server = http.createServer(async (req, res) => {
  try {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = chunks.length ? Buffer.concat(chunks) : undefined;
    const headers = {};
    for (const [k, v] of Object.entries(req.headers)) {
      if (!HOP_HEADERS.has(k.toLowerCase())) headers[k] = Array.isArray(v) ? v.join(', ') : v;
    }
    const webReq = new Request(`http://${req.headers.host || `127.0.0.1:${PORT}`}${req.url}`, {
      method: req.method, headers, body: ['GET', 'HEAD'].includes(req.method) ? undefined : body,
    });
    const resp = await handleRequest(webReq);
    const outHeaders = {};
    resp.headers.forEach((v, k) => { if (!HOP_HEADERS.has(k.toLowerCase())) outHeaders[k] = v; });
    res.writeHead(resp.status, outHeaders);
    if (resp.body) Readable.fromWeb(resp.body).pipe(res);
    else res.end();
  } catch (err) {
    console.error('handle error:', err.message);
    if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain' });
    res.end('proxy error: ' + err.message);
  }
});

// ========== 服务器 IP 探测: SERVER_IP > PTERODACTYL_SERVER_IP > 出网探测 > 网卡回退 ==========
const isIPText = t => /^(\d{1,3}\.){3}\d{1,3}$/.test(t) || (/^[0-9a-fA-F:]+$/.test(t) && t.includes(':'));
async function detectServerIP() {
  if (process.env.SERVER_IP) return process.env.SERVER_IP;
  if (process.env.PTERODACTYL_SERVER_IP) return process.env.PTERODACTYL_SERVER_IP;
  for (const svc of ['https://api.ipify.org', 'https://checkip.amazonaws.com']) {
    try {
      const r = await fetch(svc, { signal: AbortSignal.timeout(3000) });
      const t = (await r.text()).trim();
      if (isIPText(t)) return t;
    } catch (e) { /* 超时/不通, 试下一个 */ }
  }
  for (const list of Object.values(os.networkInterfaces())) {
    for (const ni of list || []) {
      if ((ni.family === 'IPv4' || ni.family === 4) && !ni.internal) return ni.address;
    }
  }
  return '<你的IP>';
}

server.listen(PORT, '0.0.0.0', () => {
  console.log(`✅ docker-proxy(NAT) listening on :${PORT}`);
  detectServerIP().then(ip => {
    console.log(`   Docker Hub:   http://${ip}:${PORT}  (daemon.json 配 registry-mirrors + insecure-registries)`);
    console.log(`   其他仓库:     http://${ip}:${PORT}?ns=ghcr.io 或 子域前缀 ghcr.你的域名`);
    console.log(`   示例拉取:     docker pull ${ip}:${PORT}/library/nginx:latest`);
  });
});
