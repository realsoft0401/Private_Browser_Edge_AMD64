#!/usr/bin/env bash
set -euo pipefail

extract_proxy_server_from_config() {
  local config_path="$1"
  local mixed_port=""
  local http_port=""
  local socks_port=""

  mixed_port="$(sed -nE 's/^[[:space:]]*mixed-port[[:space:]]*:[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "${config_path}" | head -n 1)"
  http_port="$(sed -nE 's/^[[:space:]]*port[[:space:]]*:[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "${config_path}" | head -n 1)"
  socks_port="$(sed -nE 's/^[[:space:]]*socks-port[[:space:]]*:[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "${config_path}" | head -n 1)"

  if [ -n "${mixed_port}" ]; then
    printf 'http://127.0.0.1:%s\n' "${mixed_port}"
    return 0
  fi

  if [ -n "${http_port}" ]; then
    printf 'http://127.0.0.1:%s\n' "${http_port}"
    return 0
  fi

  if [ -n "${socks_port}" ]; then
    printf 'socks5://127.0.0.1:%s\n' "${socks_port}"
    return 0
  fi

  return 1
}

extract_tun_enabled_from_config() {
  local config_path="$1"
  awk '
    BEGIN { in_tun=0 }
    /^[^[:space:]].*:/ {
      if ($0 ~ /^tun:[[:space:]]*$/) {
        in_tun=1
        next
      }
      if (in_tun == 1) {
        in_tun=0
      }
    }
    in_tun == 1 && /^[[:space:]]+enable:[[:space:]]*true[[:space:]]*$/ {
      print "true"
      exit
    }
  ' "${config_path}"
}

fail_tun_requirements_missing() {
  # 这个错误说明函数的来历：
  # - 用户明确要求“可以报错，但必须告诉我怎么解决”，不能只给一句 Docker 条件不够；
  # - 代理配置里的 tun.enable=true 代表用户希望 Mihomo 接管更完整的网络/DNS 链路；
  # - 这类配置不能被容器静默改写，缺少运行条件时必须清楚说明缺什么、怎么补、临时替代会损失什么。
  #
  # 职责边界：
  # - 这里只负责输出可执行的修复建议并终止启动；
  # - 不自动关闭 TUN，不修改 proxy/clash.yaml，不尝试在容器里创建宿主机缺失的 /dev/net/tun；
  # - 后续 Go 边缘服务创建容器时，应在 Docker 参数层自动补齐 NET_ADMIN 和 /dev/net/tun。
  cat >&2 <<'EOF'
Mihomo config has tun.enable=true, but this container cannot access /dev/net/tun.

Why it fails:
- tun.enable=true requires a TUN device and network administration capability.
- Without them, Mihomo cannot create the virtual network interface or apply the expected DNS/routing behavior.
- The browser image will not silently change tun.enable to false, because that would weaken the proxy/DNS isolation defined by proxy/clash.yaml.

How to fix docker run:
  docker run ... \
    --cap-add NET_ADMIN \
    --device /dev/net/tun:/dev/net/tun \
    -e ENABLE_PROXY=true \
    -e MIHOMO_CONFIG_BASE64=...

How to fix docker compose:
  cap_add:
    - NET_ADMIN
  devices:
    - "/dev/net/tun:/dev/net/tun"

Linux host check:
  ls -l /dev/net/tun
  sudo modprobe tun

Mac / Docker Desktop note:
- /dev/net/tun support depends on Docker Desktop and VM capabilities.
- For full TUN/DNS protection, prefer a Linux edge node.
- Temporary mixed-port only testing is possible only after changing the proxy config yourself; the image will not do that automatically.
EOF
}

fail_proxy_port_missing() {
  # 代理端口解析错误也必须给出修复方向：
  # - 边缘服务把 proxy/clash.yaml 以 Base64 传入容器；
  # - Chromium 需要明确的本地代理入口才能设置 --proxy-server；
  # - 如果 YAML 里没有 mixed-port/port/socks-port，Mihomo 即使启动，Chrome 也不知道该接哪个端口。
  cat >&2 <<'EOF'
Unable to resolve a browser proxy port from Mihomo config.

How to fix proxy/clash.yaml:
- Add one of these top-level fields:
  mixed-port: 7897
  port: 7890
  socks-port: 7891

Recommended:
  mixed-port: 7897
  allow-lan: true
  bind-address: 0.0.0.0

Why it matters:
- Chrome is started with --proxy-server=<local Mihomo port>.
- Without mixed-port/port/socks-port, the browser cannot be wired to the proxy core.
EOF
}

fail_proxy_config_base64_invalid() {
  # Base64 解码失败通常来自 API 调用方把 YAML 原文直接塞进 JSON，或复制时截断。
  # 这里给出明确修复方式，避免用户只看到容器启动失败却不知道应该检查 configBase64。
  cat >&2 <<'EOF'
MIHOMO_CONFIG_BASE64 is not valid Base64.

How to fix:
- Encode the full proxy YAML as Base64 and pass it as MIHOMO_CONFIG_BASE64.
- Do not pass raw YAML directly into this environment variable.
- Make sure the Base64 text is not truncated by JSON escaping or API tooling.

Example:
  base64 -w 0 proxy/clash.yaml

macOS example:
  base64 < proxy/clash.yaml | tr -d '\n'
EOF
}

fail_proxy_config_missing() {
  # 启用代理但没有传配置时，不能只提示变量为空。
  # 这里直接告诉调用方应该从环境包 proxy/clash.yaml 读取、Base64 编码后传入。
  cat >&2 <<'EOF'
ENABLE_PROXY=true but MIHOMO_CONFIG_BASE64 is empty.

How to fix:
- Read the environment package file: proxy/clash.yaml
- Base64 encode the full YAML content.
- Pass it into the browser container as MIHOMO_CONFIG_BASE64.

macOS example:
  MIHOMO_CONFIG_BASE64="$(base64 < proxy/clash.yaml | tr -d '\n')"

Linux example:
  MIHOMO_CONFIG_BASE64="$(base64 -w 0 proxy/clash.yaml)"

Compatibility note:
- CLASH_VERGE_CONFIG_BASE64 is accepted temporarily as an alias, but new code should use MIHOMO_CONFIG_BASE64.
EOF
}

extract_port_from_proxy_server() {
  local proxy_server="$1"
  printf '%s\n' "${proxy_server}" | sed -E 's#^.+:([0-9]+)$#\1#'
}

wait_for_proxy_port() {
  local fallback_proxy_server="$1"
  local retries="${2:-45}"
  local attempt
  local candidate_proxy_server=""
  local candidate_port=""

  for attempt in $(seq 1 "${retries}"); do
    candidate_proxy_server="${fallback_proxy_server}"
    candidate_port="$(extract_port_from_proxy_server "${candidate_proxy_server}")"
    if [ -n "${candidate_port}" ] && (echo >"/dev/tcp/127.0.0.1/${candidate_port}") >/dev/null 2>&1; then
      printf '%s\n' "${candidate_proxy_server}"
      return 0
    fi
    sleep 1
  done

  return 1
}

wait_for_tcp_port() {
  local host="$1"
  local port="$2"
  local retries="${3:-30}"
  local name="${4:-tcp service}"
  local attempt

  # 这个通用 TCP 就绪检查用于把 VNC、CDP 端口暴露也纳入启动原子性：
  # 进程被拉起不等于端口已监听，端口未就绪时继续启动会让上层看到“容器 Up 但能力不可用”的半健康状态。
  for attempt in $(seq 1 "${retries}"); do
    if (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "${name} did not expose ${host}:${port} after ${retries} attempts" >&2
  return 1
}

apply_udp_egress_block() {
  if ! command -v iptables >/dev/null 2>&1; then
    echo "warning: iptables not found, skip UDP egress block" >&2
    return 0
  fi

  if ! iptables -L >/dev/null 2>&1; then
    echo "warning: iptables is unavailable in this container, skip UDP egress block" >&2
    return 0
  fi

  iptables -N WEBRTC_UDP_GUARD 2>/dev/null || true
  iptables -F WEBRTC_UDP_GUARD
  iptables -C OUTPUT -j WEBRTC_UDP_GUARD 2>/dev/null || iptables -I OUTPUT 1 -j WEBRTC_UDP_GUARD

  # Keep loopback UDP untouched, then reject all other UDP egress.
  iptables -A WEBRTC_UDP_GUARD -o lo -j RETURN
  iptables -A WEBRTC_UDP_GUARD -p udp -j REJECT
  iptables -A WEBRTC_UDP_GUARD -j RETURN

  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -N WEBRTC_UDP_GUARD 2>/dev/null || true
    ip6tables -F WEBRTC_UDP_GUARD
    ip6tables -C OUTPUT -j WEBRTC_UDP_GUARD 2>/dev/null || ip6tables -I OUTPUT 1 -j WEBRTC_UDP_GUARD
    ip6tables -A WEBRTC_UDP_GUARD -o lo -j RETURN
    ip6tables -A WEBRTC_UDP_GUARD -p udp -j REJECT
    ip6tables -A WEBRTC_UDP_GUARD -j RETURN
  fi
}

cleanup_stale_x_lock() {
  local display_id="${DISPLAY#:}"
  local lock_path="/tmp/.X${display_id}-lock"
  local socket_path="/tmp/.X11-unix/X${display_id}"
  local owner_pid=""

  if [ -f "${lock_path}" ]; then
    owner_pid="$(tr -dc '0-9' < "${lock_path}" 2>/dev/null || true)"
    if [ -n "${owner_pid}" ] && kill -0 "${owner_pid}" 2>/dev/null; then
      return 0
    fi
    rm -f "${lock_path}"
  fi

  if [ -S "${socket_path}" ] && ! pgrep -f "Xvfb ${DISPLAY}" >/dev/null 2>&1; then
    rm -f "${socket_path}"
  fi
}

cleanup_stale_chromium_profile_lock() {
  local singleton_lock="${USER_DATA_DIR}/SingletonLock"
  local singleton_socket="${USER_DATA_DIR}/SingletonSocket"
  local singleton_cookie="${USER_DATA_DIR}/SingletonCookie"

  # 这段清理逻辑的来历：
  # - 当前项目明确要求浏览器 userDataDir 挂到宿主机，保证删容器后能复用登录态和本地环境；
  # - 但容器如果被强制删除，Chromium 留在宿主机目录里的 Singleton* 锁文件不会自动清理；
  # - 下一次新容器挂回同一目录时，Chromium 会误以为“旧实例还在另一台机器占用这个 profile”，
  #   从而直接拒绝启动，最终表现成容器反复重启、VNC 端口始终连不上。
  #
  # 职责边界：
  # - 这里只处理“容器冷启动前的陈旧 profile 锁文件”；
  # - 不负责在多实例并发共享同一 userDataDir 的场景兜底，那种用法本身就不允许；
  # - 后续如果引入更严格的实例调度，也必须继续保留这里的宿主机残锁清理，不要退回人工删文件。
  rm -f "${singleton_lock}" "${singleton_socket}" "${singleton_cookie}"
}

wait_for_x_display() {
  local display_id="${DISPLAY#:}"
  local socket_path="/tmp/.X11-unix/X${display_id}"
  local retries="${1:-15}"
  local attempt

  for attempt in $(seq 1 "${retries}"); do
    if [ -S "${socket_path}" ]; then
      return 0
    fi
    sleep 1
  done

  return 1
}

wait_for_chromium_cdp_ready() {
  local retries="${CHROME_CDP_HEALTH_RETRIES:-30}"
  local endpoint="http://127.0.0.1:${INTERNAL_DEBUG_PORT}"
  local external_endpoint="http://127.0.0.1:${DEBUG_PORT}"
  local attempt
  local target_json
  local target_id
  local ws_url

  # 这段健康探测的来历：
  # - Chromium 进程启动不等于 CDP 可用，之前容易出现“容器 Up，但 /json/version 或 WebSocket 还不可用”的假健康；
  # - RPA/CDP 任务真正依赖的是 DevTools HTTP、target 和 Runtime.evaluate 三层都可用；
  # - 因此这里在容器启动阶段同步探测，失败时直接退出容器，让 Client/Server 拿到明确的启动失败事实。
  #
  # 职责边界：
  # - 只验证 CDP 基础能力，不访问第三方业务站点，不做验证码或风控处理；
  # - 探测创建的 about:blank target 会在结束前关闭，避免污染真实业务会话。
  echo "Waiting for Chromium CDP endpoint ${endpoint} ..."

  for attempt in $(seq 1 "${retries}"); do
    if ! curl -fsS --connect-timeout 1 --max-time 2 "${endpoint}/json/version" >/dev/null 2>&1; then
      sleep 1
      continue
    fi

    target_json="$(curl -fsS --connect-timeout 1 --max-time 3 -X PUT "${endpoint}/json/new?about:blank" 2>/dev/null || true)"
    if [ -z "${target_json}" ]; then
      target_json="$(curl -fsS --connect-timeout 1 --max-time 3 "${endpoint}/json/new?about:blank" 2>/dev/null || true)"
    fi
    target_id="$(printf '%s' "${target_json}" | sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1)"
    ws_url="$(printf '%s' "${target_json}" | sed -nE 's/.*"webSocketDebuggerUrl"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1)"

    if [ -z "${target_id}" ] || [ -z "${ws_url}" ]; then
      sleep 1
      continue
    fi

    if python3 - "${ws_url}" <<'PYEOF'
import json
import sys
import websocket

# Chrome 新版本会校验 DevTools WebSocket 的 Origin。健康探测运行在容器本机，只验证内部 CDP
# 是否能执行 Runtime.evaluate，不代表对外开放任意 Origin；因此这里显式不发送 Origin 头，
# 避免为了探测通过而把 --remote-allow-origins=* 变成默认值。
ws = websocket.create_connection(sys.argv[1], timeout=3, suppress_origin=True)
try:
    ws.send(json.dumps({
        "id": 1,
        "method": "Runtime.evaluate",
        "params": {
            "expression": "1+1",
            "returnByValue": True,
        },
    }))
    while True:
        message = json.loads(ws.recv())
        if message.get("id") != 1:
            continue
        result = message.get("result", {}).get("result", {})
        if result.get("type") == "number" and result.get("value") == 2:
            sys.exit(0)
        sys.exit(1)
finally:
    ws.close()
PYEOF
    then
      curl -fsS --connect-timeout 1 --max-time 2 "${endpoint}/json/close/${target_id}" >/dev/null 2>&1 || true
      if ! curl -fsS --connect-timeout 1 --max-time 2 "${external_endpoint}/json/version" >/dev/null 2>&1; then
        echo "external CDP proxy did not return /json/version through ${external_endpoint}" >&2
        return 1
      fi
      echo "Chromium CDP health check passed"
      return 0
    fi

    curl -fsS --connect-timeout 1 --max-time 2 "${endpoint}/json/close/${target_id}" >/dev/null 2>&1 || true
    sleep 1
  done

  echo "Chromium CDP health check failed after ${retries} attempts" >&2
  tail -n 80 /tmp/chrome.log >&2 || true
  return 1
}

DISPLAY_STACK_STARTED=false

start_clipboard_bridge() {
  if [ "${ENABLE_VNC}" != "true" ]; then
    return 0
  fi

  # 这段桥接逻辑的来历：
  # - 用户现在明确提出，外部设备在 VNC 客户端里复制的账号密码，需要能稳定粘贴到容器内浏览器；
  # - 仅仅启动 x11vnc 并不等于 X11 的 CLIPBOARD / PRIMARY 选择区会被桌面环境长期稳定托管；
  # - 当前容器只跑 Xvfb + fluxbox，环境足够轻，但默认没有剪贴板管理器，因此这里显式补一层 bridge。
  #
  # 职责边界：
  # - 这里只负责把 VNC 传进来的 X11 剪贴板同步到 Chromium 可读的 CLIPBOARD/PRIMARY；
  # - 不负责绕过目标站点自己对粘贴事件的限制，如果网页主动拦截 paste，仍需要业务侧单独处理；
  # - 后续如果切到 noVNC 或别的桌面栈，也建议保留这层同步，避免再次回到“能输入不能粘贴”的老问题。
  if command -v autocutsel >/dev/null 2>&1; then
    autocutsel -display "${DISPLAY}" -fork >/tmp/autocutsel-clipboard.log 2>&1 || true
    autocutsel -display "${DISPLAY}" -selection PRIMARY -fork >/tmp/autocutsel-primary.log 2>&1 || true
  fi

  # 预先创建一次空剪贴板，避免部分轻量 X11 会话在首次粘贴前没有 clipboard owner。
  if command -v xclip >/dev/null 2>&1; then
    printf '' | xclip -display "${DISPLAY}" -selection clipboard >/tmp/xclip-clipboard.log 2>&1 || true
    printf '' | xclip -display "${DISPLAY}" -selection primary >/tmp/xclip-primary.log 2>&1 || true
  fi
}

start_display_stack() {
  if [ "${CHROME_HEADLESS}" = "true" ] || [ "${DISPLAY_STACK_STARTED}" = "true" ]; then
    return 0
  fi

  # 这里在启动 fluxbox 前写入一份最小 init 并把 toolbar 和默认壁纸命令关掉，来历如下：
  # - 实测发现当前容器内 fluxbox 会带着工具栏启动，工具栏自身占据顶部约 25px 空间；
  # - Chromium 用 --start-maximized 时会尊重窗口管理器的可用工作区，结果浏览器窗口顶部
  #   被工具栏压出一条黑带，用户在 webVNC 里看到的就是"上面有一层遮罩"；
  # - Debian fluxbox 默认还可能调用 fbsetbg 设置壁纸，容器没有壁纸工具时会弹 xmessage，
  #   这个弹窗虽然不影响 CDP/VNC 端口，但会挡住浏览器画面，形成“容器健康但桌面脏”的体验问题；
  # - 因此这里在每次容器冷启动时显式写入 toolbar.visible: false，保证 VNC 画面里
  #   Chromium 能真正吃满 1366x768，不再被工具栏吃掉顶部空间，同时禁用默认壁纸命令。
  #
  # 维护约束：
  # - 只关工具栏，不关窗口装饰（titlebar 等），否则 Chromium 可能连地址栏都看不见；
  # - 不安装 Eterm/feh 等壁纸工具来“满足”fbsetbg，因为当前镜像的桌面职责只是承载浏览器；
  # - 后续如果要加多窗口操作，不要重新启用 toolbar，应改用其他方式切换窗口。
  mkdir -p /root/.fluxbox
  cat > /root/.fluxbox/init <<'FBEOF'
session.screen0.rootCommand: /bin/true
session.screen0.toolbar.visible: false
session.screen0.toolbar.onTop: false
session.screen0.toolbar.autoHide: true
session.screen0.toolbar.widthPercent: 0
FBEOF
  cat > /root/.fluxbox/overlay <<'FBEOF'
! 当前容器的 fluxbox 只负责托管浏览器窗口，不需要样式包设置壁纸。
! Debian 默认 overlay 里只是注释示例 "! background: none"，不会真正阻止 fbsetbg；
! 这里显式写入 background: none，避免缺少 Eterm/feh 等壁纸工具时弹出 xmessage。
background: none
FBEOF

  mkdir -p /tmp/.X11-unix
  cleanup_stale_x_lock
  Xvfb "${DISPLAY}" -screen 0 "${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}" &
  wait_for_x_display 15 || {
    echo "Xvfb failed to expose display ${DISPLAY}" >&2
    exit 1
  }
  fluxbox >/tmp/fluxbox.log 2>&1 &
  # 等 fluxbox 窗口管理器完全就绪后再继续，避免 Chromium 先于 WM 启动导致
  # --start-maximized 被忽略、最终只拿到 200x200 的默认窗口。
  sleep 2
  pkill -f "xmessage .*fbsetbg" >/dev/null 2>&1 || true
  start_clipboard_bridge

  if [ "${ENABLE_VNC}" = "true" ]; then
    x11vnc \
      -display "${DISPLAY}" \
      -forever \
      -shared \
      -noxdamage \
      -nopw \
      -listen 0.0.0.0 \
      -rfbport "${VNC_PORT}" \
      -xkb \
      >/tmp/x11vnc.log 2>&1 &
    wait_for_tcp_port "127.0.0.1" "${VNC_PORT}" 15 "VNC server" || {
      tail -n 80 /tmp/x11vnc.log >&2 || true
      exit 1
    }
  fi

  DISPLAY_STACK_STARTED=true
}

export DISPLAY="${DISPLAY:-:99}"
export SCREEN_WIDTH="${SCREEN_WIDTH:-1366}"
export SCREEN_HEIGHT="${SCREEN_HEIGHT:-768}"
export SCREEN_DEPTH="${SCREEN_DEPTH:-24}"
export DEBUG_PORT="${DEBUG_PORT:-9222}"
export INTERNAL_DEBUG_PORT="${INTERNAL_DEBUG_PORT:-19222}"
export BROWSER_LANG="${BROWSER_LANG:-zh-CN}"
export USER_DATA_DIR="${USER_DATA_DIR:-/data/profile}"
export START_URL="${START_URL:-about:blank}"
export ENABLE_VNC="${ENABLE_VNC:-false}"
export VNC_PORT="${VNC_PORT:-5900}"
export CHROME_BIN="${CHROME_BIN:-/usr/bin/chromium}"
# 这里增加缓存上限的来历：
# - 当前项目需要长期保留 Chromium 用户目录，才能保住账号登录态和环境绑定；
# - 但用户明确反馈访问变多后 profile 缓存会越来越大，继续放任增长会让宿主机磁盘被 Cache 类目录持续吞掉；
# - 因此这里先用 Chromium 官方参数给磁盘缓存和媒体缓存设上限，只压缩“可再生缓存”，不碰登录态数据。
#
# 维护约束：
# - 这两个变量只负责限制缓存体积，不承担清理 Cookies / Local Storage / IndexedDB 的职责；
# - 如果后续要调优容量，优先改环境变量，不要把数字散落到多个脚本分支里。
export CHROME_DISK_CACHE_SIZE_BYTES="${CHROME_DISK_CACHE_SIZE_BYTES:-268435456}"
export CHROME_MEDIA_CACHE_SIZE_BYTES="${CHROME_MEDIA_CACHE_SIZE_BYTES:-134217728}"
# 正式代理开关是 ENABLE_PROXY，旧 ENABLE_CLASH_VERGE 只作为迁移期只读别名。
# 这样 Client 新代码可以统一 Mihomo 命名，同时旧测试脚本在过渡期仍能启动。
export ENABLE_PROXY="${ENABLE_PROXY:-${ENABLE_CLASH_VERGE:-false}}"
export MIHOMO_BIN="${MIHOMO_BIN:-/opt/private-browser/mihomo/verge-mihomo}"
export MIHOMO_HOME="${MIHOMO_HOME:-/tmp/private-browser-mihomo}"
# 正式配置变量是 MIHOMO_CONFIG_BASE64，旧 CLASH_VERGE_CONFIG_BASE64 只作为迁移期只读别名。
# entrypoint 不会再向外写旧变量，避免后续代码误以为 Clash Verge GUI 仍是运行入口。
export MIHOMO_CONFIG_BASE64="${MIHOMO_CONFIG_BASE64:-${CLASH_VERGE_CONFIG_BASE64:-}}"
export PROXY_STATUS_EXTENSION_DIR="${PROXY_STATUS_EXTENSION_DIR:-/tmp/private-browser-proxy-status-extension}"
export WEBRTC_BLOCKER_DIR="${WEBRTC_BLOCKER_DIR:-/tmp/webrtc-blocker-extension}"
# 系统层 UDP 封禁必须显式开启。
#
# 设计来源：
# - Chromium 自身已经通过 WebRTC 参数和扩展限制非代理 UDP；
# - iptables 级别的“全容器非 loopback UDP 拦截”会同时影响 Mihomo 自身的 DNS/UDP 转发能力，
#   如果默认打开，可能出现 proxy 配置正确、Mihomo 已启动，但实际代理链路被容器规则误伤；
# - 用户明确提醒 VNC、CDP、Clash/Mihomo 配置是原子能力，不能为了 WebRTC 保护把代理链路打断。
#
# 维护边界：
# - 需要强 UDP 隔离时由调用方显式传 WEBRTC_BLOCK_ALL_UDP=true；
# - 启用前必须确认当前 Mihomo 配置不依赖容器外发 UDP，或已经由 TUN/规则层正确接管。
export WEBRTC_BLOCK_ALL_UDP="${WEBRTC_BLOCK_ALL_UDP:-false}"
export CHROME_HEADLESS="${CHROME_HEADLESS:-false}"
export BROWSER_USER_AGENT="${BROWSER_USER_AGENT:-}"
export FINGERPRINT_RUNTIME_CONFIG_BASE64="${FINGERPRINT_RUNTIME_CONFIG_BASE64:-}"
export IMAGE_CONTRACT_PATH="${IMAGE_CONTRACT_PATH:-/opt/private-browser/image-contract.json}"
# 这些开关用于把 Chromium 启动参数从“全部硬编码”收口成“稳定基线 + 条件项”。
#
# 设计来源：
# - 当前镜像已经验证过 Xvfb/VNC/CDP/代理链路，但浏览器参数逐渐变重，后续继续堆 flag 会让排障失控；
# - 用户明确要求优化浏览器初始化，因此这里把高争议参数拆成可控环境变量，避免正式运行、调试联调和后续实验共用一套过重默认值；
# - 当前项目优先级是“稳定启动、CDP 可连、VNC 可见、代理出口一致”，不是在镜像基线里默认开启所有伪装或极限节流参数。
#
# 维护边界：
# - 这些开关只影响 Chromium 启动参数，不改变 profile 目录、代理配置落盘或 Mihomo 运行逻辑；
# - 如需继续调整，应优先通过环境变量做受控试验，不要重新把参数散回多个 if 分支里。
export CHROME_DISABLE_DEV_SHM_USAGE="${CHROME_DISABLE_DEV_SHM_USAGE:-true}"
export CHROME_DISABLE_BACKGROUND_NETWORKING="${CHROME_DISABLE_BACKGROUND_NETWORKING:-false}"
export CHROME_DISABLE_BACKGROUND_THROTTLING="${CHROME_DISABLE_BACKGROUND_THROTTLING:-false}"
export CHROME_REMOTE_ALLOW_ORIGINS="${CHROME_REMOTE_ALLOW_ORIGINS:-}"

# 这里打印镜像契约的来历：
# - 商业版环境包后续需要知道自己依赖哪个浏览器镜像、Chromium 版本和指纹注入版本；
# - 单靠 Docker tag 不够稳定，tag 可能被覆盖，排障时也很难知道容器实际运行的契约；
# - 因此容器启动时把构建阶段写入的 image-contract.json 打到日志，方便边缘服务或人工排查读取。
#
# 职责边界：
# - 这里只做只读打印，不修改 profile、不判断迁移兼容性；
# - 兼容性判断应由后续环境包导入/运行 API 根据 manifest 和镜像契约完成。
print_image_contract_once() {
  if [ -f "${IMAGE_CONTRACT_PATH}" ]; then
    echo "private-browser image contract:"
    cat "${IMAGE_CONTRACT_PATH}" || true
  fi
}

mkdir -p "${USER_DATA_DIR}"
mkdir -p "${USER_DATA_DIR}/Default"
cleanup_stale_chromium_profile_lock

# Seed a minimal Chromium profile so WebRTC privacy prefs apply on first launch.
cat > "${USER_DATA_DIR}/Default/Preferences" <<'EOF'
{
  "webrtc": {
    "ip_handling_policy": "disable_non_proxied_udp",
    "multiple_routes_enabled": false,
    "nonproxied_udp_enabled": false
  }
}
EOF

mkdir -p "${WEBRTC_BLOCKER_DIR}"
mkdir -p "${PROXY_STATUS_EXTENSION_DIR}"

cat > "${WEBRTC_BLOCKER_DIR}/manifest.json" <<'EOF'
{
  "manifest_version": 3,
  "name": "WebRTC Blocker",
  "version": "1.0.0",
  "description": "Disable WebRTC APIs at document start.",
  "content_scripts": [
    {
      "matches": ["<all_urls>"],
      "js": ["content.js"],
      "run_at": "document_start",
      "all_frames": true
    }
  ]
}
EOF

cat > "${WEBRTC_BLOCKER_DIR}/content.js" <<'EOF'
(() => {
  const rawFingerprintConfigBase64 = '__FINGERPRINT_RUNTIME_CONFIG_BASE64__';
  const injectedSource = `
    (() => {
      const fingerprintConfig = (() => {
        const fingerprintConfigBase64 = ${JSON.stringify(rawFingerprintConfigBase64)};
        if (!fingerprintConfigBase64) return null;
        try {
          return JSON.parse(atob(fingerprintConfigBase64));
        } catch (_error) {
          return null;
        }
      })();
      const rejectDisabled = () =>
        Promise.reject(new DOMException("WebRTC disabled", "NotAllowedError"));

      const defineValue = (target, property, value) => {
        if (!target) return;
        try {
          Object.defineProperty(target, property, {
            configurable: true,
            enumerable: false,
            writable: false,
            value,
          });
        } catch (_) {}
      };

      const defineGetter = (target, property, getter) => {
        if (!target) return;
        try {
          Object.defineProperty(target, property, {
            configurable: true,
            enumerable: false,
            get: getter,
          });
        } catch (_) {}
      };

      defineGetter(window, "RTCPeerConnection", () => undefined);
      defineGetter(window, "webkitRTCPeerConnection", () => undefined);
      defineGetter(window, "mozRTCPeerConnection", () => undefined);

      defineGetter(window, "MediaStream", () => undefined);
      defineGetter(window, "MediaStreamTrack", () => undefined);
      defineGetter(window, "RTCDataChannel", () => undefined);
      defineGetter(window, "RTCSessionDescription", () => undefined);
      defineGetter(window, "RTCIceCandidate", () => undefined);

      if (navigator.mediaDevices) {
        defineValue(navigator.mediaDevices, "getUserMedia", rejectDisabled);
        defineValue(navigator.mediaDevices, "enumerateDevices", async () => []);
      }

      defineValue(navigator, "getUserMedia", rejectDisabled);
      defineValue(navigator, "webkitGetUserMedia", rejectDisabled);
      defineValue(navigator, "mozGetUserMedia", rejectDisabled);

      if (fingerprintConfig) {
        const defineNavigatorString = (property, value) => {
          if (typeof value === "string" && value.trim()) {
            defineGetter(navigator, property, () => value);
          }
        };
        const defineNavigatorNumber = (property, value) => {
          if (Number.isFinite(value) && value > 0) {
            defineGetter(navigator, property, () => value);
          }
        };
        defineNavigatorString("userAgent", fingerprintConfig.userAgent);
        defineNavigatorString("platform", fingerprintConfig.platform);
        defineNavigatorString("language", fingerprintConfig.language);
        if (Array.isArray(fingerprintConfig.languages) && fingerprintConfig.languages.length) {
          defineGetter(navigator, "languages", () => fingerprintConfig.languages.slice());
        }
        defineNavigatorNumber("deviceMemory", fingerprintConfig.deviceMemory);
        defineNavigatorNumber("hardwareConcurrency", fingerprintConfig.hardwareConcurrency);
        if (Number.isFinite(fingerprintConfig.maxTouchPoints)) {
          defineGetter(navigator, "maxTouchPoints", () => fingerprintConfig.maxTouchPoints);
        }

        const applyScreenValue = (target, property, value) => {
          if (!target || !Number.isFinite(value) || value <= 0) {
            return;
          }
          try {
            Object.defineProperty(target, property, {
              configurable: true,
              enumerable: false,
              get: () => value,
            });
          } catch (_) {}
        };

        if (window.screen) {
          applyScreenValue(window.screen, "width", Number(fingerprintConfig.screen?.width));
          applyScreenValue(window.screen, "height", Number(fingerprintConfig.screen?.height));
          applyScreenValue(window.screen, "availWidth", Number(fingerprintConfig.availableScreen?.width));
          applyScreenValue(window.screen, "availHeight", Number(fingerprintConfig.availableScreen?.height));
          applyScreenValue(window.screen, "colorDepth", Number(fingerprintConfig.colorDepth));
          applyScreenValue(window.screen, "pixelDepth", Number(fingerprintConfig.colorDepth));
        }
      }
    })();
  `;

  const inject = () => {
    const script = document.createElement("script");
    script.textContent = injectedSource;
    (document.documentElement || document.head || document).appendChild(script);
    script.remove();
  };

  inject();
  document.addEventListener("readystatechange", inject, { once: true });
})();
EOF

fingerprint_runtime_config_base64_escaped="$(
  printf '%s' "${FINGERPRINT_RUNTIME_CONFIG_BASE64}" | sed 's/[\/&]/\\&/g'
)"
sed -i \
  "s/__FINGERPRINT_RUNTIME_CONFIG_BASE64__/${fingerprint_runtime_config_base64_escaped}/g" \
  "${WEBRTC_BLOCKER_DIR}/content.js"

write_proxy_status_extension() {
  local enabled="$1"
  local status="$2"
  local proxy_server="$3"
  local message="$4"
  local badge_text="OFF"
  local badge_color="#6b7280"

  if [ "${enabled}" = "true" ] && [ "${status}" = "available" ]; then
    badge_text="ON"
    badge_color="#16a34a"
  elif [ "${enabled}" = "true" ]; then
    badge_text="ERR"
    badge_color="#dc2626"
  fi

  # 这个扩展的来历：
  # - 用户明确指出不需要 Linux 桌面和底部工具栏，之前把 Clash Verge 托盘当成 proxy 入口是错误方向；
  # - 现在代理由容器内 Mihomo core 承担，浏览器里只需要一个轻量、可见、不会接管业务逻辑的状态入口；
  # - 因此这里动态生成 Manifest V3 扩展，用 action badge/popup 展示代理是否启用和实际端口。
  #
  # 职责边界：
  # - 扩展只显示状态，不修改 Chrome proxy 设置、不注入目标网页、不保存代理明文；
  # - 真正代理链路仍由 entrypoint 解析 configBase64 后启动 Mihomo，并通过 --proxy-server 交给 Chromium；
  # - 后续如果要做复杂代理切换，应放到边缘服务 API 和 Mihomo 配置层，不能让扩展变成控制中枢。
  cat > "${PROXY_STATUS_EXTENSION_DIR}/manifest.json" <<'EOF'
{
  "manifest_version": 3,
  "name": "Private Browser Proxy",
  "version": "1.0.0",
  "description": "Show current container proxy status.",
  "action": {
    "default_title": "Private Browser Proxy",
    "default_popup": "popup.html"
  },
  "background": {
    "service_worker": "background.js"
  }
}
EOF

  cat > "${PROXY_STATUS_EXTENSION_DIR}/background.js" <<EOF
chrome.action.setBadgeText({ text: ${badge_text@Q} });
chrome.action.setBadgeBackgroundColor({ color: ${badge_color@Q} });
EOF

  cat > "${PROXY_STATUS_EXTENSION_DIR}/popup.html" <<EOF
<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <style>
      body { min-width: 220px; margin: 0; padding: 12px; font: 13px/1.4 Arial, sans-serif; color: #111827; }
      .title { font-weight: 700; margin-bottom: 8px; }
      .row { display: flex; justify-content: space-between; gap: 12px; margin: 6px 0; }
      .value { font-weight: 600; word-break: break-all; text-align: right; }
      .ok { color: #16a34a; }
      .err { color: #dc2626; }
      .off { color: #6b7280; }
    </style>
  </head>
  <body>
    <div class="title">Private Browser Proxy</div>
    <div class="row"><span>Enabled</span><span class="value">${enabled}</span></div>
    <div class="row"><span>Status</span><span class="value ${status}">${status}</span></div>
    <div class="row"><span>Server</span><span class="value">${proxy_server}</span></div>
    <div class="row"><span>Message</span><span class="value">${message}</span></div>
  </body>
</html>
EOF
}

# Chromium may still bind the DevTools server to loopback only.
# Expose a stable external port from the container via a lightweight TCP proxy.
socat TCP-LISTEN:"${DEBUG_PORT}",bind=0.0.0.0,reuseaddr,fork TCP:127.0.0.1:"${INTERNAL_DEBUG_PORT}" >/tmp/socat.log 2>&1 &

start_display_stack

PROXY_STATUS="disabled"
PROXY_STATUS_MESSAGE="proxy disabled"
PROXY_SERVER=""

if [ "${ENABLE_PROXY}" = "true" ]; then
  if [ ! -x "${MIHOMO_BIN}" ]; then
    echo "mihomo binary not found: ${MIHOMO_BIN}" >&2
    exit 1
  fi

  if [ -z "${MIHOMO_CONFIG_BASE64}" ]; then
    fail_proxy_config_missing
    exit 1
  fi

  mkdir -p "${MIHOMO_HOME}"
  if [ -d /opt/private-browser/mihomo/resources ]; then
    cp -R /opt/private-browser/mihomo/resources/. "${MIHOMO_HOME}/" || true
  fi

  MIHOMO_CONFIG_PATH="${MIHOMO_HOME}/config.yaml"
  if ! printf '%s' "${MIHOMO_CONFIG_BASE64}" | base64 -d > "${MIHOMO_CONFIG_PATH}"; then
    fail_proxy_config_base64_invalid
    exit 1
  fi

  if ! PROXY_SERVER="$(extract_proxy_server_from_config "${MIHOMO_CONFIG_PATH}")"; then
    fail_proxy_port_missing
    exit 1
  fi
  export PROXY_SERVER

  proxy_port="$(extract_port_from_proxy_server "${PROXY_SERVER}")"
  if [ -z "${proxy_port}" ]; then
    fail_proxy_port_missing
    exit 1
  fi

  CLASH_TUN_ENABLED="$(extract_tun_enabled_from_config "${MIHOMO_CONFIG_PATH}")"
  if [ "${CLASH_TUN_ENABLED}" = "true" ] && [ ! -e /dev/net/tun ]; then
    fail_tun_requirements_missing
    exit 1
  fi

  "${MIHOMO_BIN}" -d "${MIHOMO_HOME}" -f "${MIHOMO_CONFIG_PATH}" >/tmp/mihomo.log 2>&1 &

  resolved_proxy_server="$(
    wait_for_proxy_port "${PROXY_SERVER}" 45
  )" || {
    echo "mihomo failed to expose a reachable proxy port" >&2
    tail -n 100 /tmp/mihomo.log >&2 || true
    exit 1
  }

  PROXY_SERVER="${resolved_proxy_server}"
  PROXY_STATUS="available"
  PROXY_STATUS_MESSAGE="ok"
  export PROXY_SERVER
fi

write_proxy_status_extension "${ENABLE_PROXY}" "${PROXY_STATUS}" "${PROXY_SERVER:-}" "${PROXY_STATUS_MESSAGE}"

if [ "${WEBRTC_BLOCK_ALL_UDP}" = "true" ]; then
  apply_udp_egress_block
fi

CHROME_ARGS=(
  # 这里禁用 GPU/硬件合成的来历：
  # - 当前项目跑在 Xvfb + x11vnc 的虚拟桌面里，实测 webVNC 会出现“状态已连接但画面整块发黑”；
  # - 现场排查发现 Chromium 窗口确实存在，但 x11vnc 日志持续提示 XDAMAGE/图像更新异常，
  #   这是 Chromium 在无真实 GPU 的虚拟显示里常见的黑屏链路；
  # - 因此这里强制回退到更稳定的软件渲染路径，优先保证远控可见性，避免后续又回到“浏览器在跑但 VNC 只能看到黑屏”的旧问题。
  #
  # 维护约束：
  # - 这里的目标是稳定可见，不追求 GPU 性能；
  # - 如果后续要重新启用 GPU，必须先在 Xvfb/VNC/webVNC 整链路上验证不会复现黑屏，再考虑回退这些参数。
  "--disable-gpu"
  "--disable-gpu-compositing"
  "--disable-gpu-rasterization"
  "--disable-accelerated-2d-canvas"
  "--force-effective-connection-type=4g"
  "--disable-features=UseSkiaRenderer,Translate,MediaRouter,OptimizationHints"
  "--disable-blink-features=AutomationControlled"
  "--remote-debugging-address=127.0.0.1"
  "--remote-debugging-port=${INTERNAL_DEBUG_PORT}"
  "--user-data-dir=${USER_DATA_DIR}"
  "--disk-cache-size=${CHROME_DISK_CACHE_SIZE_BYTES}"
  "--media-cache-size=${CHROME_MEDIA_CACHE_SIZE_BYTES}"
  "--window-size=${SCREEN_WIDTH},${SCREEN_HEIGHT}"
  "--lang=${BROWSER_LANG}"
  # 容器内以 chrome 非 root 用户运行 Chromium 时，很多 Linux 宿主机不会开放可用的 Chromium sandbox。
  # 这里的 --no-sandbox 只解决容器启动权限兼容问题，避免出现 “No usable sandbox” 导致 CDP/VNC 假健康；
  # 它不承担反风控、伪装或绕过校验含义，生产安全边界仍依赖容器最小权限、内网隔离和上游 Server 访问控制。
  "--no-sandbox"
  "--no-first-run"
  "--no-default-browser-check"
  "--disable-search-engine-choice-screen"
  "--password-store=basic"
  "--force-webrtc-ip-handling-policy=disable_non_proxied_udp"
  "--disable-webrtc-multiple-routes"
  "--enforce-webrtc-ip-permission-check"
  "--disable-extensions-except=${WEBRTC_BLOCKER_DIR},${PROXY_STATUS_EXTENSION_DIR}"
  "--load-extension=${WEBRTC_BLOCKER_DIR},${PROXY_STATUS_EXTENSION_DIR}"
)

if [ "${CHROME_DISABLE_DEV_SHM_USAGE}" = "true" ]; then
  CHROME_ARGS+=("--disable-dev-shm-usage")
fi

if [ "${CHROME_DISABLE_BACKGROUND_NETWORKING}" = "true" ]; then
  CHROME_ARGS+=("--disable-background-networking")
fi

if [ "${CHROME_DISABLE_BACKGROUND_THROTTLING}" = "true" ]; then
  CHROME_ARGS+=(
    "--disable-renderer-backgrounding"
    "--disable-background-timer-throttling"
  )
fi

if [ -n "${CHROME_REMOTE_ALLOW_ORIGINS}" ]; then
  CHROME_ARGS+=("--remote-allow-origins=${CHROME_REMOTE_ALLOW_ORIGINS}")
fi

if [ "${CHROME_HEADLESS}" = "true" ]; then
  CHROME_ARGS+=(
    "--headless=new"
    "--disable-gpu"
  )
else
  start_display_stack
  CHROME_ARGS+=("--start-maximized")
fi

if [ -n "${PROXY_SERVER:-}" ]; then
  CHROME_ARGS+=("--proxy-server=${PROXY_SERVER}")
fi

if [ -n "${BROWSER_USER_AGENT}" ]; then
  CHROME_ARGS+=("--user-agent=${BROWSER_USER_AGENT}")
fi

if [ -n "${TZ:-}" ]; then
  ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime || true
  echo "${TZ}" >/etc/timezone || true
fi

chown -R chrome:chrome "${USER_DATA_DIR}"

printf '#!/bin/bash\nexec %q' "${CHROME_BIN}" > /tmp/start-chrome.sh
for arg in "${CHROME_ARGS[@]}" "${START_URL}"; do
  printf ' %q' "$arg" >> /tmp/start-chrome.sh
done
printf '\n' >> /tmp/start-chrome.sh
chmod +x /tmp/start-chrome.sh

print_image_contract_once

su chrome /tmp/start-chrome.sh >/tmp/chrome.log 2>&1 &
chrome_pid="$!"

if ! wait_for_chromium_cdp_ready; then
  kill "${chrome_pid}" >/dev/null 2>&1 || true
  wait "${chrome_pid}" >/dev/null 2>&1 || true
  exit 1
fi

wait "${chrome_pid}"
