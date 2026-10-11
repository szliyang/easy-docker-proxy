#!/bin/bash
# =========================================
# docker-proxy NAT 一键部署启动器(免 root, 支持管道执行)
# 用法1(推荐, 自动下载 server.js):
#   curl -Ls "https://raw.githubusercontent.com/szliyang/easy-docker-proxy/master/run.sh?t=$(date +%s)" | sed 's/\r$//' | bash
# 用法2(已下载到本地): bash run.sh
# 可选: PORT=xxxx 指定端口(默认自动取 PTERODACTYL_SERVER_PORT/SERVER_PORT/3000)
#       ARGO_ON=1 开启 Argo 隧道(HTTPS 入口); ARGO_AUTH+ARGO_DOMAIN 用固定域名
#       NODE_VER=vXX.X.X 指定便携版 node 版本(默认 v22.14.0, 仅系统无 node>=18 时下载)
# 20261011-1130 init: 新建脚本, 参考 sb_argo.sh 部署风格
# 20261011-1140 fix: 支持管道自举, 自动下载 server.js 到当前目录
# 20261011-1130 fix: RAW_BASE 改指独立仓库 easy-docker-proxy(原 NAT-Sing-box 子目录已 404)
# 20261011-1418 fix: 下载失败不再静默退出, curl 去 -s 显示进度/错误码, 残留空 server.js 自动清理
# 20261011-1432 feat: 系统 node 缺失或 <18 时自动下载官方便携版到 node-bin/ (免 root)
# 20261011-1436 fix: node 便携版 x86 架构名 amd64→x64(官方无 linux-amd64 包, 404)
# 20261011-1437 fix: 部署命令加 ?t=$(date +%s) 绕过 raw CDN 5 分钟缓存, 避免跑到旧脚本
# 20261011-1526 fix: server.js 每次部署都拉最新(存在不再跳过), 有变化才替换, 失败时沿用本地
# 20261012-0118 fix: Argo 隧道目标端口默认跟随自动探测的服务端口(原写死 3000, 非默认端口机器上 502)
# =========================================
set -euo pipefail
export LC_ALL=C

WORKDIR="$(pwd)"                      # 管道执行时无脚本目录, 统一用当前目录
SERVER_JS="${WORKDIR}/server.js"
CFD_BIN="${WORKDIR}/cloudflared"
RAW_BASE="https://raw.githubusercontent.com/szliyang/easy-docker-proxy/master"
NODE_VER="${NODE_VER:-v22.14.0}"
NODE_BIN=""

red()    { echo -e "\e[1;91m$1\033[0m"; }
green()  { echo -e "\e[1;32m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }

# ========== 端口自动获取: PORT > PTERODACTYL_SERVER_PORT > SERVER_PORT > 3000 ==========
detect_port() {
  if [[ -n "${PORT:-}" ]]; then echo "$PORT"
  elif [[ -n "${PTERODACTYL_SERVER_PORT:-}" ]]; then echo "$PTERODACTYL_SERVER_PORT"
  elif [[ -n "${SERVER_PORT:-}" ]]; then echo "$SERVER_PORT"
  else echo "3000"
  fi
}

# ========== 自举: 每次部署拉取最新 server.js, 有变化才替换 ==========
ensure_server_js() {
  local rc=0
  echo "📥 Downloading server.js from ${RAW_BASE}/server.js ..."
  curl -fL --connect-timeout 20 --retry 2 -o "${SERVER_JS}.tmp" \
    "${RAW_BASE}/server.js?t=$(date +%s)" || rc=$?
  if [[ $rc -ne 0 || ! -s "${SERVER_JS}.tmp" ]]; then
    rm -f "${SERVER_JS}.tmp"
    if [[ -s "$SERVER_JS" ]]; then
      echo "⚠️ server.js 下载失败 (curl 退出码 ${rc}), 沿用本地已有版本 ($(wc -c < "$SERVER_JS") bytes)"
      return
    fi
    red "❌ server.js 下载失败 (curl 退出码 ${rc})"
    red "   URL: ${RAW_BASE}/server.js"
    red "   常见原因: 服务器无法访问 raw.githubusercontent.com (网络/DNS/被墙)"
    red "   手动诊断: curl -v ${RAW_BASE}/server.js -o /dev/null"
    exit 1
  fi
  if [[ -s "$SERVER_JS" ]] && cmp -s "${SERVER_JS}.tmp" "$SERVER_JS"; then
    rm -f "${SERVER_JS}.tmp"
    green "✅ server.js 已是最新 ($(wc -c < "$SERVER_JS") bytes)"
  else
    mv "${SERVER_JS}.tmp" "$SERVER_JS"
    green "✅ server.js 已更新到最新 ($(wc -c < "$SERVER_JS") bytes)"
  fi
}

# ========== Node: 优先系统 node>=18, 否则免 root 下载官方便携版 ==========
ensure_node() {
  if command -v node >/dev/null 2>&1 \
     && node -e 'process.exit(process.versions.node.split(".")[0]>=18?0:1)'; then
    NODE_BIN="$(command -v node)"
    green "✅ node $(node -v) (系统)"
    return
  fi
  if command -v node >/dev/null 2>&1; then
    echo "⚠️ 系统 node 版本过低 ($(node -v), 需 18+)"
  else
    echo "⚠️ 未找到 node"
  fi
  local arch; arch=$(detect_arch)
  local narch="${arch/amd64/x64}"         # node 官方包 x86 架构名为 x64 而非 amd64(cloudflared 才用 amd64)
  local dest="${WORKDIR}/node-bin"
  if [[ -x "${dest}/bin/node" && "$("${dest}/bin/node" -v 2>/dev/null)" == "${NODE_VER}" ]]; then
    NODE_BIN="${dest}/bin/node"
    green "✅ node $("${NODE_BIN}" -v) (便携版已存在)"
    return
  fi
  local pkg="node-${NODE_VER}-linux-${narch}"
  local rc=0
  echo "📥 Downloading ${pkg}.tar.gz from nodejs.org (免 root 便携版)..."
  curl -fL --connect-timeout 20 --retry 2 -o "${WORKDIR}/node.tar.gz" \
    "https://nodejs.org/dist/${NODE_VER}/${pkg}.tar.gz" || rc=$?
  if [[ $rc -ne 0 || ! -s "${WORKDIR}/node.tar.gz" ]]; then
    rm -f "${WORKDIR}/node.tar.gz"
    red "❌ node 便携版下载失败 (curl 退出码 ${rc})"
    red "   URL: https://nodejs.org/dist/${NODE_VER}/${pkg}.tar.gz"
    red "   请手动安装 node 18+ 后重试"
    exit 1
  fi
  rm -rf "$dest"
  mkdir -p "$dest"
  if ! tar -xzf "${WORKDIR}/node.tar.gz" -C "$dest" --strip-components=1; then
    rm -f "${WORKDIR}/node.tar.gz"; rm -rf "$dest"
    red "❌ node 便携版解压失败 (tar), 请手动安装 node 18+ 后重试"
    exit 1
  fi
  rm -f "${WORKDIR}/node.tar.gz"
  NODE_BIN="${dest}/bin/node"
  green "✅ node $("${NODE_BIN}" -v) (便携版)"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo ""; red "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}

# ========== 可选 Argo 隧道(为纯 HTTP 端口提供 HTTPS 入口) ==========
start_argo() {
  [[ "${ARGO_ON:-0}" != "1" ]] && return 0
  local arch; arch=$(detect_arch)
  if [[ ! -x "$CFD_BIN" ]]; then
    echo "📥 Downloading cloudflared (${arch})..."
    local rc=0
    curl -fL --connect-timeout 20 --retry 2 -o "${CFD_BIN}.tmp" \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" || rc=$?
    if [[ $rc -ne 0 || ! -s "${CFD_BIN}.tmp" ]]; then
      rm -f "${CFD_BIN}.tmp"
      red "❌ cloudflared 下载失败 (curl 退出码 ${rc}), 跳过 Argo 隧道"
      return 0
    fi
    mv "${CFD_BIN}.tmp" "$CFD_BIN"
    chmod +x "$CFD_BIN"
  fi
  if [[ -n "${ARGO_AUTH:-}" && -n "${ARGO_DOMAIN:-}" ]]; then
    nohup "$CFD_BIN" tunnel run --token "$ARGO_AUTH" >/dev/null 2>&1 &
    green "✅ Argo 隧道(token)已启动: https://${ARGO_DOMAIN}"
  else
    nohup "$CFD_BIN" tunnel --url "http://127.0.0.1:${ARGO_PORT:-$PORT}" \
      --no-autoupdate --protocol http2 --logfile argo.log --loglevel info >/dev/null 2>&1 &
    local i argo_host=""
    for i in $(seq 1 30); do
      argo_host=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' argo.log 2>/dev/null | head -n1 || true)
      [[ -n "$argo_host" ]] && break
      sleep 1
    done
    if [[ -n "$argo_host" ]]; then
      green "✅ Argo 临时隧道: ${argo_host} (HTTPS, 免 insecure-registries 配置)"
      green "   registry-mirrors 可直接填 ${argo_host}"
    else
      red "⚠️ Argo 域名获取失败, 查看 argo.log; 不影响本地 HTTP 端口"
    fi
  fi
}

# ========== 守护 ==========
run_loop() {
  purple "🚀 Starting docker-proxy on :${PORT} ..."
  while true; do
    "$NODE_BIN" "$SERVER_JS" || true
    echo "⚠️ docker-proxy crashed. Restarting in 5s..."
    sleep 5
  done
}

PORT=$(detect_port)
echo "📁 工作目录: ${WORKDIR}"
echo "✅ 端口: ${PORT}"
ensure_node
ensure_server_js
start_argo
run_loop
