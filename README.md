# docker-proxy（NAT 版 Docker 镜像加速）

移植自 [cmliu/CF-Workers-docker.io](https://github.com/cmliu/CF-Workers-docker.io)（Cloudflare Workers 版 Docker 镜像反代，原仓库未附带 LICENSE 文件），改为 Node 18+ 直接运行在 NAT 服务器上，不依赖 Cloudflare。

## 一键部署（NAT 服务器上执行）

```bash
curl -Ls "https://raw.githubusercontent.com/szliyang/easy-docker-proxy/master/run.sh?t=$(date +%s)" | sed 's/\r$//' | bash
```

脚本会自动下载/更新 `server.js` 到最新版（每次部署拉取，有变化才替换）并启动（守护循环，崩溃自动重启）。要求：

- 系统 **Node 18+**；缺失或版本过低时脚本自动从 nodejs.org 下载便携版到 `node-bin/`（免 root，`NODE_VER` 可指定版本）
- NAT 服务器可直连 Docker Hub（海外机器）

## 端口

自动获取，优先级：`PORT` > `PTERODACTYL_SERVER_PORT` > `SERVER_PORT` > 3000。

```bash
PORT=18080 curl -Ls .../run.sh | sed 's/\r$//' | bash   # 指定端口
```

## 客户端使用

能访问该 NAT 服务器的机器上，配置 `/etc/docker/daemon.json`：

```json
{
  "registry-mirrors": ["http://<NAT服务器IP>:<端口>"],
  "insecure-registries": ["<NAT服务器IP>:<端口>"]
}
```

重启 docker 后 `docker pull nginx` 即走该镜像源。

**其他仓库**（ghcr.io、quay.io、k8s.gcr.io 等）：

- 拉取 URL 带 `?ns=` 参数：`http://<IP>:<端口>?ns=ghcr.io/v2/...`
- 或将 `ghcr.<你的域名>`、`quay.<你的域名>` 等子域解析到 NAT 服务器（脚本按子域前缀路由）

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | 自动 | 监听端口（优先于翼龙注入变量） |
| `UA` | `netcraft` | UA 黑名单，逗号/换行分隔，命中返回 nginx 伪装页 |
| `URL302` | 空 | 首页 302 跳转地址（浏览器 UA 访问时） |
| `URL` | 空 | 首页伪装：`nginx` 返回 nginx 页，其他值反代该地址 |
| `ARGO_ON` | `0` | `1` 时启动 Argo 隧道，获得 HTTPS 入口（可免配 insecure-registries） |
| `ARGO_AUTH` + `ARGO_DOMAIN` | 空 | Argo 固定域名隧道 token + 域名；留空则用 trycloudflare 临时隧道 |
| `ARGO_PORT` | `3000` | Argo 隧道指向的本地端口 |
| `NODE_VER` | `v22.14.0` | 系统无 node≥18 时自动下载的便携版 node 版本 |
| `SERVER_IP` | 自动 | 启动横幅显示的服务器 IP（默认探测：翼龙变量 > 出网探测 > 网卡） |

## 与 Workers 原版的差异

- 移植保留：默认 Docker Hub、`?ns=` 指定上游、token 服务端代取、library/ 路径补全、blob 重定向代取、搜索页、UA 黑名单、CORS。
- 去除：Cloudflare 边缘缓存（`cacheTtl`）——NAT 版以 token 内存缓存（4 分钟 TTL）部分替代。
- 新增：NAT 端口自动获取、自举下载部署、Node http 服务器与 Web Fetch API 互转层、上游转发强制 https 并清带入站端口。

## 注意

- 临时隧道（trycloudflare）域名每次重启会变；要固定域名请用 `ARGO_AUTH`+`ARGO_DOMAIN`。
- 镜像加速效果取决于 NAT 服务器到 Docker Hub 的连通性与带宽；本机到 NAT 服务器的链路由客户端自行保证。
