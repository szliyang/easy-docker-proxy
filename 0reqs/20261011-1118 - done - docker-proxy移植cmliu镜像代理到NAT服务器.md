# docker-proxy：cmliu 版 Docker 镜像代理的 NAT 服务器移植

## 需求

参考 cmliu/CF-Workers-docker.io（Cloudflare Workers 上的 Docker 镜像反代），为 NAT 服务器做一个可直接运行的版本：

1. 不依赖 Cloudflare Workers，在 NAT（翼龙/Pterodactyl）容器里用 Node 直接跑。
2. 支持一条命令自举部署（类似 `curl -Ls https://raw.githubusercontent.com/.../tuic.sh | sed 's/\r$//' | bash`）：脚本自动把所需代码下载到 NAT 服务器再启动。
3. 端口自动获取，无需手填。
4. 在 README 中注明代码移植自 cmliu 原项目。

## 讨论

- **运行时选择**：参考本项目 `nodejs/index.js` 的惯例（纯 Node、免构建、环境变量配置）。Node 18+ 内置 fetch/Request/Response/Headers，与 Workers Web API 同构，cmliu 的 `_worker.js` 核心逻辑可近平移移植；仅需一层 http.createServer 做"原生请求 ↔ Web Fetch API"互转。
- **Workers 与 Node 的差异（移植中踩到的两个坑）**：
  - Workers 入站请求天然是 https，Node 版入站是 `http://IP:端口`——换 hostname 转发上游后必须强制 `url.protocol='https:'`，否则 fetch `http://registry-1.docker.io` 直接失败。
  - 入站端口（如 :3999）会残留在 URL 对象上，变成 `https://上游:3999` 导致连接失败，需 `url.port=''`。
  - 这两点就是最初本机测试 502 的真实原因（并非网络问题，用户本机实际可直连 Docker Hub）。
- **去 Workers 化**：删除 `addEventListener`、`cacheTtl: 3600` 边缘缓存；新增 token 内存缓存（repo → token，4 分钟 TTL）作为无边缘缓存环境下的替代优化。
- **入口方式**：NAT 机没有域名时默认反代 Docker Hub（IP:端口 直接用）；其他仓库用 `?ns=ghcr.io` 参数或子域前缀（需自备域名解析到 NAT 机）；纯 HTTP 镜像源客户端需配 `insecure-registries`，可选 `ARGO_ON=1` 开 Argo 隧道获得 HTTPS 入口免此配置。

## 代码变更（全部新建）

### docker-proxy/server.js
- cmliu `_worker.js` 的 Node 18+ 移植，保留：默认 Docker Hub、`?ns=`/`hubhost` 上游选择、子域前缀路由、token 服务端代取（manifests/blobs/tags）、library/ 路径补全、blob 3xx 重定向服务端代取、`WWW-Authenticate` 重写回自身域名、浏览器 UA 搜索页/nginx 伪装页、UA 黑名单（`UA` 环境变量）、`URL302`/`URL` 环境变量、CORS。
- 新增：NAT 端口自动获取（`PORT` > `PTERODACTYL_SERVER_PORT` > `SERVER_PORT` > 3000）、token 内存缓存、启动时打印 daemon.json 配置提示。
- 头部注释注明移植来源（原仓库地址、原仓库未附带 LICENSE 文件）。

### docker-proxy/run.sh
- 一键自举部署器：支持管道执行（工作目录取 `pwd`），自动从 `raw.githubusercontent.com/szliyang/NAT-Sing-box/main/docker-proxy/` 下载 server.js，校验 node ≥ 18，崩溃自动重启。
- 可选 `ARGO_ON=1`：下载 cloudflared，`ARGO_AUTH`+`ARGO_DOMAIN` 固定域名或 trycloudflare 临时隧道，为 HTTP 端口提供 HTTPS 入口。

### docker-proxy/README.md
- docker-proxy 子目录独立说明：来源致谢、一键部署命令、客户端 daemon.json 配置、?ns 用法、环境变量表、Argo 可选配置、注意事项。

### README.md（项目根）
- 新增 docker-proxy 小节：注明移植自 cmliu/CF-Workers-docker.io，保留/改动要点，部署命令与客户端配置示例。

### sb_argo.sh（顺手修复）
- 修复临时隧道域名正则 typo：`trycloudflare\.et` → `trycloudflare\.com`（原正则永远匹配不到域名）。

## 验证

- `server.js` 过 `node --check`，`run.sh` 过 `bash -n`。
- 本机实测（端口 3999）：
  - `/v2/` → 401（标准 docker 认证入口，WWW-Authenticate 已重写为自身域名）
  - `/v2/nginx/manifests/latest` → 200 + 有效 manifest JSON 10KB（token 代取、library 补全、上游转发全链路通）
  - `?ns=github.com` 转发 → 200（上游路由与强制 https 修复验证）
  - 浏览器 UA 首页 → 搜索页正常渲染
- 待验证：真实 NAT 容器部署、Argo 隧道模式、大镜像完整 `docker pull`。
- 一键命令依赖文件推送到 GitHub 后方可生效。

## 未做

- 未做磁盘缓存（ Workers 版靠 CF 边缘缓存, NAT 版仅有 token 内存缓存）；如后续限流明显可加 manifest 磁盘缓存。
- 未提交/推送 git（等用户指示）。

---
20261011-1118
by ZCode (GLM-5.3)
