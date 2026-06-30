# edge_amd64 时区一致性优化方案

## 背景

当前 `Private_Browser_Edge_AMD64` 在时区相关联调里已经暴露出一个典型问题：

```text
Zone:   America/New_York
Local:  Mon Jun 15 2026 21:31:01 GMT-0400 (EDT)
System: Mon Jun 15 2026 20:31:27 GMT-0500 (Central Daylight Time)
```

这说明同一个浏览器实例里，至少有两套时区事实没有被统一：

- 浏览器页面脚本看到的时区事实。
- Chromium / Linux 系统层暴露出来的时区事实。

在当前项目里，这不是单纯的显示问题，而是运行环境原子性问题。根据项目既定约束，`timezone`、代理出口、语言、屏幕和环境包运行事实必须一致；不能出现“页面看起来像纽约，但系统层还停在芝加哥”这种半同步状态。

## 这个问题为什么必须先写文档再改代码

这次不应该直接把某一行脚本改掉就继续试，因为当前时区链路横跨了 3 层：

1. 环境包里的 `profile.environment.timezone`
2. 容器 Linux 系统时区，例如 `TZ`、`/etc/localtime`、`/etc/timezone`
3. 浏览器 JS / 指纹注入层对 timezone 的暴露

如果不先把职责边界和收口规则写清楚，后面很容易重新回到以下旧问题：

- 只改 `TZ`，结果系统层和 JS 层继续分裂。
- 只改 JS 注入，结果页面通过了，但系统层事实仍然不一致。
- run 阶段探测回写了 timezone，但容器启动时没有把这个值作为统一入口重新生效。
- README、镜像契约、排障口径和真正代码实现再次脱节。

## 当前实现现状

结合仓库现状，`edge_amd64` 已经具备下面这些能力：

- `Private_Browser_Client` 在 run 阶段会把 `profile.environment.timezone` 作为 `TZ` 传进浏览器容器。
- `Private_Browser_Edge_AMD64/entrypoint.sh` 会在 Chromium 启动前尝试把 `TZ` 写入 `/etc/localtime` 和 `/etc/timezone`。
- run 阶段的 timezone 最终值仍然以容器内 provider 探测为准，并可能在探测后触发一次受控重建。

这说明问题不是“完全没有 timezone 链路”，而是“链路已有，但没有形成单一事实源和一致性自检”。

## 初步根因判断

当前最需要防的不是单一 bug，而是下面几类结构性问题：

### 1. 容器系统时区和浏览器脚本时区没有统一入口

现在 `TZ` 是一条入口，`/etc/localtime` / `/etc/timezone` 是另一条入口，指纹注入脚本又是第三条入口。只要这三条入口不是从同一个值、同一个阶段统一落地，就可能出现截图里的分裂。

### 2. 时区应用时机不够可验证

即使 entrypoint 里已经写了 `/etc/localtime`，如果没有明确的启动前校验和启动日志，排障时我们无法快速判断：

- `TZ` 是否真的传入了容器
- IANA 时区是否有效
- `/etc/localtime` 是否真的切到了目标时区
- Chromium 启动时继承到的是哪套时区事实

### 3. JS 层 timezone 暴露没有纳入正式契约

当前指纹注入链已经统一了 `userAgent`、`language`、`screen` 等字段，但 timezone 还没有被明确写进“浏览器运行态归一化契约”。这会导致：

- 环境包明明要求纽约时区，但新文档、刷新页、首个 about:blank 页面不一定稳定继承；
- 系统层和 JS 层出现差异时，没有一条明确规则说明谁负责收口。

## 这次优化的目标

本次优化不是“让某个测试站页面更好看”，而是把 `edge_amd64` 的时区能力收口成一个稳定契约。

目标应明确为：

- 环境包 timezone 是唯一业务来源。
- 容器系统时区和 Chromium 运行时区必须从同一个值初始化。
- JS / 指纹注入层暴露的 timezone 必须与容器系统层保持一致。
- run 阶段 timezone probe 回写后，如果 timezone 变化，必须通过受控重建让新值重新进入上述同一条链路。
- 失败时要明确失败原因和修复建议，不能静默继续。

## 不该做的事情

这次优化有几个边界不能破：

- 不能把 timezone 逻辑重新做成多个入口各自猜测的黑盒行为。
- 不能只为了过某个站点测试就引入和环境包事实不一致的临时 JS override。
- 不能在 timezone 无效、缺失或系统层切换失败时静默启动 Chromium。
- 不能绕过 Client 的 `profile.environment.timezone`，在镜像里自己拍脑袋决定默认业务时区。
- 不能把这次修复做成“页面层看起来对了，但 run/README/排障口径没有更新”的半成品。

## 建议的实现顺序

后续正式编码时，建议按下面顺序推进。

### 第一步：明确单一时区入口

把浏览器容器运行时的目标时区收口为一个明确变量，例如：

- 业务来源仍是 `profile.environment.timezone`
- Client run 负责把它稳定传入容器
- entrypoint 只认这一条正式入口，并把它同步到系统层和浏览器层

这里的核心原则不是变量名本身，而是“只保留一个正式入口，其他地方只消费，不再各自推导”。

### 第二步：把系统层时区设置前置并加失败收口

在 Chromium、Xvfb、Mihomo 和指纹注入链真正开始前，先完成：

- IANA timezone 合法性校验
- `/usr/share/zoneinfo/<timezone>` 存在性校验
- `/etc/localtime` / `/etc/timezone` 更新
- 启动日志里输出本次最终采用的 timezone

如果这一层失败，应直接让容器启动失败，并给出明确修复建议。

### 第三步：把 JS timezone 暴露纳入正式运行契约

指纹注入脚本当前已经覆盖首屏、刷新后新文档和新 page target；timezone 也应使用同一条注入链路统一处理，而不是在不同位置各写一份逻辑。

这里要注意：

- JS 层不是独立真相源，只是系统层统一后的浏览器暴露面；
- 如果系统层和 JS 层不一致，应优先修正链路，而不是无条件依赖 JS 伪装掩盖问题。

### 第四步：补最小自检和验收输出

后续实现完成后，至少应能通过日志或诊断接口看到：

- 期望 timezone 是什么
- 容器系统层最终采用了什么
- 浏览器运行层最终暴露了什么
- 如果三者不一致，卡在哪一层

## 建议的文档和代码落点

后续正式落地时，建议同步修改下面几处：

- `Private_Browser_Client/Service/BrowserEnv/run.go`
  - 明确容器时区入口变量从哪里来。
- `Private_Browser_Edge_AMD64/entrypoint.sh`
  - 统一系统层时区设置和启动前校验。
- `Private_Browser_Edge_AMD64/scripts/fp_inject.py`
  - 首次注入链路的 timezone 暴露一致性。
- `Private_Browser_Edge_AMD64/scripts/fp_daemon.py`
  - 新 page target 的持续一致性。
- `Private_Browser_Edge_AMD64/README.md`
  - 补充时区一致性原则和排障口径。

## 验收标准

后续代码改完后，至少要满足下面这些验收点：

### 成功路径

- 环境包配置 `America/New_York` 时：
  - 容器系统层显示纽约时区
  - 浏览器页面 `Date` / `Intl` 等时区相关结果一致
  - run 完成后不再出现 `Zone=New_York` 但 `System=Central` 这类分裂

### 失败路径

- timezone 为空时，Client 在进入容器前就拒绝
- timezone 非法时，容器启动前明确失败
- 时区文件不存在或写入失败时，容器明确失败
- timezone probe 回写后触发重建时，如果新时区未成功生效，run 不能伪装成功

### 维护路径

- README 能解释时区从哪来、怎么生效、失败怎么看
- 后续开发者不看对话，只看仓库文档，也能理解为什么 timezone 不能只改一层

## 本文档的作用边界

这份文档当前只回答一件事：`edge_amd64` 的 timezone 为什么会分裂，以及后续应该按什么原则修。

它不替代后续逐文件实现说明，也不替代 run / timezone probe 的 API 文档。真正进入编码阶段时，仍然要按这里的约束同步更新 README、实现注释和必要测试。
