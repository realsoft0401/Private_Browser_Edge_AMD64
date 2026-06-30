# Private Browser Edge AMD64 打包流程

这个目录只负责 `linux/amd64` 浏览器运行镜像，不负责 Go 边缘服务，也不负责旧 Node `control-api`。

## 为什么单独拆这个目录

旧 `Private_Browser_Control/docker/Dockerfile` 已经验证了 Chromium、Xvfb、VNC、Clash Verge、TUN、WebRTC 限制和 profile 持久化链路，但它仍然是多架构混合打包思路。商业化后，指纹包需要和镜像运行环境绑定，所以这里先把 `amd64` 流程独立出来，避免 Apple Silicon 本地构建时误产出 `arm64` 镜像。

## 当前镜像职责

- 提供 Debian bookworm + Chromium 桌面运行环境。
- 提供 Xvfb + fluxbox + x11vnc，用于浏览器可视化控制。
- 不启动 Linux 桌面底部工具栏，也不执行默认壁纸设置命令，避免 fbsetbg/xmessage 弹窗污染 VNC 画面。
- 提供 Mihomo 代理注入能力，代理配置通过 `MIHOMO_CONFIG_BASE64` 传入；当前也临时接受 `CLASH_VERGE_CONFIG_BASE64` 作为旧环境变量别名。
- 动态生成 `Private Browser Proxy` Chrome 扩展，只在浏览器工具栏显示代理状态，不接管代理逻辑。
- 提供 WebRTC UDP 限制和运行时指纹字段注入。
- 在 `/opt/private-browser/image-contract.json` 写入镜像契约，用于后续判断环境包迁移兼容性。

## 浏览器初始化基线

当前 `entrypoint.sh` 已把 Chromium 启动参数收口为“稳定基线 + 条件项”。

### 运行原子性

浏览器实例的运行能力必须按一个整体判断，不能把 VNC、CDP、Mihomo/Clash 代理配置拆成几个可独立降级的半成品状态。

当前启动原子性规则：

- `ENABLE_PROXY=true` 时，`MIHOMO_CONFIG_BASE64` 必须存在、可解码、可解析出 `mixed-port` / `port` / `socks-port`，并且 Mihomo 本地代理端口必须可连接，否则容器启动失败。
- `tun.enable=true` 时，容器必须具备 `/dev/net/tun` 和运行侧 `NET_ADMIN` 条件；条件缺失时容器启动失败，不会静默改写代理配置。
- `ENABLE_VNC=true` 时，Xvfb、fluxbox、x11vnc 和 `VNC_PORT` 必须就绪，否则容器启动失败。
- CDP 必须同时满足内部 `127.0.0.1:${INTERNAL_DEBUG_PORT}` 探测通过，以及外部 `socat` 暴露的 `${DEBUG_PORT}` 可连接，否则容器启动失败。
- Chromium 只有在代理状态扩展、WebRTC 扩展、VNC/CDP 入口和必要网络约束准备完成后才进入健康探测。

这条规则的目的不是追求“容器尽量跑起来”，而是避免上层 Client/Server 看到一个 `running` 容器后误以为浏览器、VNC、CDP 和代理链路都可用。

### 默认稳定基线

默认长期保留的参数目标是：

- CDP 可稳定连接
- Xvfb/VNC 画面可见
- fluxbox 桌面无默认工具栏、无壁纸设置弹窗
- 多实例 profile 行为一致
- WebRTC 不走非代理 UDP
- 缓存体积可控

因此当前默认基线会保留：

- `--remote-debugging-address=127.0.0.1`
- `--remote-debugging-port=${INTERNAL_DEBUG_PORT}`
- `--user-data-dir=${USER_DATA_DIR}`
- `--window-size=${SCREEN_WIDTH},${SCREEN_HEIGHT}`
- `--lang=${BROWSER_LANG}`
- `--no-sandbox`：仅用于容器内 Chromium sandbox 权限兼容，避免 CDP/VNC 假健康，不作为风控规避策略。
- `--no-first-run`
- `--no-default-browser-check`
- `--disable-search-engine-choice-screen`
- `--password-store=basic`
- WebRTC 三项约束参数

### 默认不再硬开的大参数

下面这些参数不再作为“无条件永久默认值”：

- `--remote-allow-origins=*`
- `--disable-background-networking`
- `--disable-renderer-backgrounding`
- `--disable-background-timer-throttling`

设计原因是：

- 这些参数更适合按场景打开，而不是把正式运行、调试联调、兼容性排障都绑死在一套过重配置里；
- 当前项目更优先保证浏览器启动稳定、CDP 可达、画面可见和代理链路一致，而不是把所有潜在优化一次性压进基线。
- `--disable-features` 和 `--disable-blink-features` 是两类不同开关；`AutomationControlled` 技术上必须走 `--disable-blink-features`，但它的主要作用是隐藏自动化控制特征，因此已纳入正式默认基线（通过环境变量默认值控制）。

### `AutomationControlled` 决策记录

`--disable-blink-features=AutomationControlled` 技术上可以影响 Blink 自动化控制标记，例如 `navigator.webdriver` 相关行为；它不能通过 `--disable-features=...` 替代。

本项目确认把它加入正式 Edge 镜像默认启动参数（通过 `CHROME_DISABLE_BLINK_AUTOMATION_CONTROLLED` 默认 `true`）。原因是在 CDP/VNC 远程浏览器场景下，`navigator.webdriver` 会导致 Google 等站点触发 reCAPTCHA 风控，即便所有用户操作均为拟人化流程也会被拦截。

如有需要关闭此参数，设置 `CHROME_DISABLE_BLINK_AUTOMATION_CONTROLLED=false` 即可恢复默认行为。

### 条件环境变量

当前支持通过环境变量控制部分启动参数：

- `CHROME_DISABLE_DEV_SHM_USAGE=true|false`
- `CHROME_DISABLE_BACKGROUND_NETWORKING=true|false`
- `CHROME_DISABLE_BACKGROUND_THROTTLING=true|false`
- `CHROME_REMOTE_ALLOW_ORIGINS=<value>`
- `CHROME_DISABLE_BLINK_AUTOMATION_CONTROLLED=true|false`
- `CHROME_CDP_HEALTH_RETRIES=<number>`
- `WEBRTC_BLOCK_ALL_UDP=true|false`

维护原则：

- 先通过环境变量验证参数效果，再决定是否调整正式默认值；
- 不要为了临时测试把参数重新散落回多个脚本分支；
- 如需扩大 CDP 暴露范围，优先通过受控端口映射或反向代理处理，不要直接长期依赖 `remote-allow-origins=*`。
- `WEBRTC_BLOCK_ALL_UDP` 是系统层强隔离选项，默认关闭；启用前必须确认不会误伤 Mihomo/Clash 的 DNS、UDP 转发或代理协议。
- `CHROME_DISABLE_BLINK_AUTOMATION_CONTROLLED` 默认开启（`true`），用于避免 `navigator.webdriver` 触发风控；可显式设为 `false` 恢复关闭状态。
### 运行时指纹注入链

当前镜像把“当前页补注入”和“刷新后新文档继续生效”拆成两段，避免仓库里存在脚本但正式镜像没跑起来。

- `scripts/fp_inject.py`
  - 在 Chromium 冷启动完成、CDP 健康检查通过后执行一次；
  - 先给当前 page target 注册 `Page.addScriptToEvaluateOnNewDocument`，再对当前文档补打一轮；
  - 如果配置了 `START_URL`，会在首次导航后再安装一次，保证首屏和首跳转文档使用同一份注入逻辑。
- `scripts/fp_daemon.py`
  - 作为后台守护进程持续运行；
  - 每 2 秒扫描一次现有 page target；
  - 对新出现的 page target 安装 `Page.addScriptToEvaluateOnNewDocument`，并补打一轮当前文档注入。

这样做的原因是：

- 旧链路只做 `Runtime.evaluate`，页面刷新后同一个 target 的新文档会丢失归一化脚本；
- 之前仓库里虽然已经有 daemon 脚本，但 entrypoint 没有真正启动它，导致文档、脚本和镜像行为不一致；
- 现在把启动阶段和守护阶段都接回正式启动链，排障时可以明确看到 `/tmp/fp_inject.log` 和 `/tmp/fp_daemon.log`。

### 启动后 CDP 健康探测

Chromium 启动后，`entrypoint.sh` 会同步执行 CDP 健康探测，避免出现“容器已经 Up，但 CDP 不可用”的假健康。

探测顺序：

```text
1. GET /json/version
2. PUT /json/new?about:blank，必要时回退 GET
3. 连接 target 的 DevTools WebSocket
4. Runtime.evaluate("1+1")
5. 通过 `${DEBUG_PORT}` 外部 CDP 代理端口请求 `/json/version`
6. 关闭测试 target
```

只有这些步骤全部通过，容器才继续等待 Chromium 主进程；如果超过 `CHROME_CDP_HEALTH_RETRIES` 仍失败，容器会输出 `/tmp/chrome.log` 尾部日志并退出。

实现细节：

- HTTP 探测使用 `curl`
- WebSocket 探测使用 `python3-websocket`
- 不引入 `wscat` 或 Node 工具链
- 健康探测只验证 CDP 基础能力，不访问任何第三方业务站点

## 旧版能力对齐检查

| 能力 | 当前实现 | 是否需要额外文件 |
| --- | --- | --- |
| VNC | `x11vnc` + `ENABLE_VNC=true` + `VNC_PORT` | 不需要 |
| CDP | `chromium --remote-debugging-port=${INTERNAL_DEBUG_PORT}` + `socat` 转发到 `${DEBUG_PORT}` | 不需要 |
| noVNC | 由 `Private_Browser_Client` 的 `/web-vnc.html` 和 WebSocket 代理提供 | 不属于浏览器镜像 |
| Mihomo 代理核心 | 从 `vendor/Clash.Verge_2.4.7_amd64.deb` 抽取 `/usr/bin/verge-mihomo` | 需要 vendor deb |
| 浏览器 Proxy 状态入口 | `entrypoint.sh` 动态生成 `/tmp/private-browser-proxy-status-extension` | 不需要提前 COPY |
| WebRTC 保护插件 | `entrypoint.sh` 动态生成 `/tmp/webrtc-blocker-extension` | 不需要提前 COPY |
| 剪贴板 | `autocutsel` + `xclip` | 不需要 |
| UDP 防漏 | `iptables` / `ip6tables` | 不需要 |
| 进程托管 | `tini` | 不需要 |

## 构建

在本目录或项目根目录执行都可以：

```bash
cd Private_Browser_Edge_AMD64
./scripts/build-amd64.sh
```

默认镜像名：

```text
crpi-6s60spbjvluac8j8.cn-shanghai.personal.cr.aliyuncs.com/ln0216/private_browser_edge:1.1-amd64
```

如果临时需要覆盖 tag：

```bash
IMAGE_TAG=1.1 ./scripts/build-amd64.sh
```

## 推送

```bash
cd Private_Browser_Edge_AMD64
./scripts/push-amd64.sh
```

推送前需要先登录镜像仓库。

## 查看镜像契约

```bash
cd Private_Browser_Edge_AMD64
./scripts/inspect-contract.sh
```

契约里会包含：

- `arch=amd64`
- Debian/Chromium/Chromedriver/Mihomo 版本
- 指纹引擎版本
- 启动参数版本
- 预期 `navigator.platform=Linux x86_64`

## 指纹检测站点参考

浏览器运行镜像联调、代理排障、WebRTC 防漏核验和指纹一致性自测时，可参考独立文档：

- [fingerprint-testing-sites.md](/Users/lining/Documents/Browser_virtualization/Private_Browser_Edge_AMD64/fingerprint-testing-sites.md)

## 时区一致性方案

`edge_amd64` 当前正在补一份独立的时区一致性收口方案，专门解释为什么会出现
“页面 timezone 看起来正确，但系统层 timezone 仍然不一致”的分裂，以及后续应该
如何把环境包 timezone、容器系统时区和浏览器 JS 暴露统一到同一条链路上。

- [timezone-alignment-plan.md](/Users/lining/Documents/Browser_virtualization/Private_Browser_Edge_AMD64/timezone-alignment-plan.md)

## 维护原则

- 不要把这里改回 amd64/arm64 混合构建。
- 不要再使用不带架构含义的 `latest` 作为商业环境包镜像。
- 不要只依赖 tag 判断兼容性；后续环境包应记录 image contract。
- 如果以后恢复 arm64，应该新增独立目录或明确 multi-arch 契约，再让服务端决定下发哪个镜像。
- 不要恢复 `tint2`、桌面托盘或 Clash Verge GUI 作为 proxy 入口；当前方案是 Mihomo core + 浏览器状态扩展。
- 不要在容器内静默改写 `proxy/clash.yaml`。如果配置里 `tun.enable=true`，运行容器时必须提供 `NET_ADMIN` 和 `/dev/net/tun`；条件不满足时应明确失败，避免出现代理链路看似启动但实际规则/DNS 保护被削弱。


cd /Users/lining/Documents/Browser_virtualization/Private_Browser_Edge_AMD64
./scripts/build-amd64.sh \
  --platform linux/amd64 \
  --image crpi-6s60spbjvluac8j8.cn-shanghai.personal.cr.aliyuncs.com/ln0216/private_browser_edge \
  --tag 1.1-amd64 \
  --push







cd /Users/lining/Documents/Browser_virtualization/Private_Browser_Edge_AMD64

docker buildx build \
  --platform linux/amd64 \
  --no-cache \
  --push \
  --build-arg DOCKERHUB_MIRROR=docker.m.daocloud.io \
  --build-arg DEBIAN_MIRROR=mirrors.tuna.tsinghua.edu.cn \
  --build-arg CLASH_VERGE_VERSION=2.4.7 \
  --build-arg IMAGE_FAMILY=private_browser_edge \
  --build-arg IMAGE_VERSION=1.1-amd64 \
  --build-arg IMAGE_REVISION=local \
  -t crpi-6s60spbjvluac8j8.cn-shanghai.personal.cr.aliyuncs.com/ln0216/private_browser_edge:1.1-amd64 \
  .
