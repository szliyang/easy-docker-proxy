#!/bin/bash
# =========================================
# docker-proxy NAT 一键部署启动器(免 root, 支持管道执行)
# 用法1(推荐, 自动下载 server.js):
#   curl -Ls https://raw.githubusercontent.com/szliyang/NAT-Sing-box/main/docker-proxy/run.sh | sed 's/\r$//' | bash
# 用法2(已下载到本地): bash run.sh
# 可选: PORT=xxxx 指定端口(默认自动取 PTERODACTYL_SERVER_PORT/SERVER_PORT/3000)
#       ARGO_ON=1 开启 Argo 隧道(HTTPS 入口); ARGO_AUTH+ARGO_DOMAIN 用固定域名
# 20261011-1130 init: 新建脚本, 参考 sb_argo.sh 部署风格
# 20261011-1140 fix: 支持管道自举, 自动下载 server.js 到当前目录
# =========================================
set -euo pipefail
export LC_ALL=C

WORKDIR="$(pwd)"                      # 管道执行时无脚本目录, 统一用当前目录
SERVER_JS="${WORKDIR}/server.js"
CFD_BIN="${WORKDIR}/cloudflared"
RAW_BASE="https://raw.githubusercontent.com/szliyang/NAT-Sing-box/main/docker-proxy"
ARGO_LOCAL_PORT="${ARGO_PORT:-3000}"

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

# ========== 自举: 下载 server.js ==========
ensure_server_js() {
  if [[ -f "$SERVER_JS" ]]; then
    green "✅ server.js 已存在"
    return
  fi
  echo "📥 Downloading server.js..."
  curl -Ls --fail --connect-timeout 20 -o "$SERVER_JS" "${RAW_BASE}/server.js"
  green "✅ server.js 下载完成"
}

check_node() {
  if ! command -v node >/dev/null 2>&1; then
    red "❌ 未找到 node (需 18+), 请先安装"
    exit 1
  fi
  if ! node -e 'process.exit(process.versions.node.split(".")[0]>=18?0:1)'; then
    red "❌ node 版本过低 ($(node -v)), 需 18+ (依赖内置 fetch)"
    exit 1
  fi
  green "✅ node $(node -v)"
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
    curl -Ls --fail -o "$CFD_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    chmod +x "$CFD_BIN"
  fi
  if [[ -n "${ARGO_AUTH:-}" && -n "${ARGO_DOMAIN:-}" ]]; then
    nohup "$CFD_BIN" tunnel run --token "$ARGO_AUTH" >/dev/null 2>&1 &
    green "✅ Argo 隧道(token)已启动: https://${ARGO_DOMAIN}"
  else
    nohup "$CFD_BIN" tunnel --url "http://127.0.0.1:${ARGO_LOCAL_PORT}" \
      --no-autoupdate --protocol http2 --logfile argo.log --loglevel info >/dev/null 2>&1 &
    local i argo_host=""
    for i in $(seq 1 30); do
      argo_host=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' argo.log 2>/dev/null | head -n1)
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
    node "$SERVER_JS" || true
    echo "⚠️ docker-proxy crashed. Restarting in 5s..."
    sleep 5
  done
}

PORT=$(detect_port)
echo "✅ 端口: ${PORT}"
ensure_server_js
check_node
start_argo
run_loop
