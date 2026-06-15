# Private_Browser_Edge_AMD64 开发代理规范

## 浏览器初始化与 Google 生态兼容边界

本目录只负责 `linux/amd64` 浏览器运行镜像。后续优化 Google 搜索、Workspace、YouTube 等 Google 生态访问体验时，目标必须收口为：

- 浏览器实例稳定启动。
- CDP 可连接、可诊断、可复现。
- Xvfb/VNC 有头画面可见。
- 代理、时区、语言、窗口尺寸和 profile 运行事实一致。
- 页面兼容性异常能够被识别、记录和失败收口。

这类优化是“运行环境兼容性”和“业务访问稳定性”优化，不是绕过验证码、人机校验、异常流量保护或反自动化检测。

## 允许落地的优化

- 默认优先使用有头模式，纯 `headless` 只能作为显式调试或受控批处理模式。
- Chromium 必须使用持久化 `--user-data-dir`，并由 Client 为每个环境包分配独立 profile 目录。
- 容器内 Chromium 继续以非 root 用户运行。
- CDP 默认只监听 `127.0.0.1`，由容器端口映射、Client 或受控代理对外暴露。
- 浏览器启动后必须能通过 `/json/version`、target 创建或列表读取、`Runtime.evaluate` 等方式做健康探测。
- WebRTC 相关参数可以用于防止非代理 UDP 泄露，不能用于伪造访问身份。
- `timezone`、`lang`、`userAgent`、`screen`、`proxy` 等运行参数应来自环境包或 Server 下发的明确配置。
- 访问受限、验证码、人机校验、异常流量页应被识别为任务失败事实，写入阶段、错误和修复建议。
- 操作频率、并发数量和任务节奏可以作为业务保护与资源保护策略，防止系统自我压垮或制造异常请求洪峰。
- 所有启动参数变更必须先小范围灰度，验证 CDP、VNC、代理、timezone probe、run/stop 生命周期后再扩大。

## VNC / CDP / Mihomo 原子性规则

VNC、CDP、Mihomo/Clash 代理配置是浏览器运行容器的原子能力组合，不能拆成“浏览器能启动就算成功，其他能力后面再说”的半健康状态。

正式规则：

- `ENABLE_PROXY=true` 时，Mihomo 配置必须存在、可解码、可解析端口，且本地代理端口必须可连接。
- `tun.enable=true` 时，必须具备 `/dev/net/tun` 和 `NET_ADMIN` 运行条件；缺失时必须失败，不能自动改写配置或降级。
- `ENABLE_VNC=true` 时，Xvfb、fluxbox、x11vnc 和 `VNC_PORT` 必须全部就绪。
- fluxbox 只作为浏览器窗口管理器使用，必须禁用默认工具栏和 fbsetbg/xmessage 壁纸弹窗；不要为了壁纸能力安装 Eterm/feh 等无关包。
- CDP 必须同时验证内部 `INTERNAL_DEBUG_PORT` 和外部 `DEBUG_PORT`；内部 Runtime.evaluate 通过但外部 socat 暴露失败，也必须视为启动失败。
- 代理状态扩展和 WebRTC 扩展属于启动契约的一部分，不能因为扩展生成失败而静默跳过。

维护时不要把这些检查改成后台 warning。它们是环境包 run 能否可信的前置条件。

## 禁止落地的优化

- 不实现绕过验证码、人机校验、异常流量检测或反机器人保护的逻辑。
- 不在正式基线里默认加入 `--disable-blink-features=AutomationControlled` 这类以隐藏自动化特征为主要目的的参数。
- 不伪造或篡改 `navigator.webdriver`、`window.chrome`、插件列表、硬件参数、触控点、内存、CPU 核心数等浏览器 API 返回值来规避站点检测。
- 不把“模拟真人轨迹”“随机化操作节奏”“预热访问路径”作为规避平台风控的工程策略。
- 不把“民用网络出口”写成绕过第三方访问限制的技术承诺。
- 不自动处理或点击 reCAPTCHA、验证码、账号安全挑战、异常流量确认页。
- 不为了让流程继续而静默忽略访问受限页面；识别到受限页面必须停止任务并返回明确错误。

### `AutomationControlled` 参数决策记录

`--disable-features` 和 `--disable-blink-features` 是 Chromium 的两类不同开关：

- `--disable-features=UseSkiaRenderer,Translate,MediaRouter,OptimizationHints` 只用于关闭指定 Chromium 功能，当前主要服务 Xvfb/VNC 渲染稳定性和减少非必要后台能力。
- `--disable-blink-features=AutomationControlled` 技术上才会影响 Blink 自动化控制标记，例如 `navigator.webdriver` 相关行为。

- `--disable-blink-features=AutomationControlled` 加入正式 Edge 镜像默认启动参数。而是它的主要作用是隐藏自动化控制特征，容易把系统边界从“稳定、可诊断、可复现的授权 CDP/VNC 运行环境”推向“规避站点检测”。

后续如果客户在自有系统、授权测试环境或内部靶场里确实需要验证该参数，只能作为独立测试配置或测试镜像单独评审、单独命名、单独记录风险，不能混入生产默认镜像，也不能作为访问第三方业务平台的默认优化。

## Chromium 启动参数原则

启动参数分为“稳定基线”和“条件项”。

稳定基线应优先保留：

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
- WebRTC 非代理 UDP 约束参数
- 缓存容量上限参数

条件项必须通过环境变量显式打开，例如：

- `CHROME_DISABLE_DEV_SHM_USAGE`
- `CHROME_DISABLE_BACKGROUND_NETWORKING`
- `CHROME_DISABLE_BACKGROUND_THROTTLING`
- `CHROME_REMOTE_ALLOW_ORIGINS`
- `CHROME_HEADLESS`
- `WEBRTC_BLOCK_ALL_UDP`

维护时不要把条件项重新写成永久默认值。需要实验时，先通过环境变量验证，再决定是否升级为正式基线。

`WEBRTC_BLOCK_ALL_UDP` 属于系统层强隔离开关，默认应保持关闭。启用前必须确认不会破坏 Mihomo/Clash 的 DNS、UDP 转发、TUN 或具体代理协议；不能为了 WebRTC 保护牺牲代理链路原子性。

## 访问受限页面的收口规则

当浏览器进入 Google reCAPTCHA、`unusual traffic`、账号安全验证、访问受限、权限不足等页面时，RPA/CDP 任务必须：

- 停止继续执行核心业务动作。
- 标记当前任务失败。
- 记录失败阶段，例如 `navigate`、`search`、`submit`、`upload`、`wait_result`。
- 记录可脱敏的页面标题、URL 摘要和识别原因。
- 返回管理员可执行建议，例如更换授权测试环境、使用官方 API、人工接管或降低业务频率。

不要把访问受限页面当成普通页面继续点击，也不要在 Edge 镜像里加入自动绕过逻辑。

## 启动后健康探测要求

后续继续优化 `entrypoint.sh` 时，应优先补齐启动后健康探测，而不是继续堆 Chromium flag。

最小健康探测应覆盖：

```text
1. GET /json/version
2. GET /json/list 或创建 about:blank target
3. DevTools WebSocket 连接
4. Runtime.enable
5. Runtime.evaluate("1+1")
6. 通过外部 CDP 代理端口请求 /json/version
```

只有这些步骤通过，才能认为当前浏览器实例满足 CDP 自动化基础条件。

当前 AMD64 镜像的实现约定：

- HTTP 探测使用 `curl`。
- WebSocket 探测使用 `python3-websocket`。
- 不引入 `jq`、`wscat` 或 Node 工具链，避免为了健康检查扩大运行镜像依赖面。
- 健康探测失败必须让容器启动失败，不能只在后台打印错误后继续运行。

## 文档与镜像契约

- 每次调整 Chromium 默认启动参数，都要同步更新 `LAUNCH_ARGS_VERSION`。
- 每次调整启动参数基线，都要同步更新 `README.md` 的浏览器初始化说明。
- 不要只改 `entrypoint.sh`，否则镜像契约、部署文档和排障口径会脱节。
- 如果新增健康探测脚本，应在 README 里写清探测阶段、失败语义和修复建议。
