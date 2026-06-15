# 这个 Dockerfile 的设计来源：
# - 旧 Private_Browser_Control/docker/Dockerfile 已经验证了 Chromium + Xvfb + VNC + Clash Verge 的运行链路；
# - 但旧打包流程同时兼容 amd64/arm64，且默认使用 latest tag，不适合作为商业环境下可追踪的指纹镜像；
# - 因此本文件单独服务 amd64 交付流程，构建时会拒绝非 amd64 架构，并在镜像内写入 image-contract.json。
#
# 职责边界：
# - 只构建“浏览器运行容器镜像”，不包含 Go 边缘服务，也不包含旧 Node control-api；
# - 只固化运行时依赖、启动入口、镜像契约，不负责 profile/env 包生成和数据库记录；
# - 后续如果恢复 arm64，应新增独立目录或明确 multi-arch 合同，不能把这里改回混合架构；
# - 正式 docker build 链路不能只改 apt 源，基础镜像入口也必须可通过 DOCKERHUB_MIRROR 收敛。
ARG DOCKERHUB_MIRROR=docker.m.daocloud.io
FROM ${DOCKERHUB_MIRROR}/library/debian:bookworm-slim

ARG TARGETARCH
ARG DEBIAN_MIRROR=deb.debian.org
ARG CLASH_VERGE_VERSION=2.4.7
ARG IMAGE_FAMILY=private_browser_edge
ARG IMAGE_VERSION=1.1-amd64
ARG IMAGE_REVISION=local
ARG FINGERPRINT_ENGINE_VERSION=webrtc-blocker-1.0.0
ARG LAUNCH_ARGS_VERSION=stable-fp-daemonized-v2

LABEL org.opencontainers.image.title="Private Browser Edge AMD64"
LABEL org.opencontainers.image.description="AMD64 browser runtime image for Private_Browser_Client browser environments"
LABEL org.opencontainers.image.version="${IMAGE_VERSION}"
LABEL org.opencontainers.image.revision="${IMAGE_REVISION}"
LABEL bv.image.family="${IMAGE_FAMILY}"
LABEL bv.image.arch="amd64"
LABEL bv.fingerprint.engine.version="${FINGERPRINT_ENGINE_VERSION}"
LABEL bv.launch.args.version="${LAUNCH_ARGS_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV IMAGE_CONTRACT_PATH=/opt/private-browser/image-contract.json

COPY vendor/ /tmp/clash-verge-vendor/

# 这里保留旧镜像已验证的桌面栈依赖，并增加 amd64 架构硬校验。
#
# 运行能力和安装包对应关系：
# - VNC：由 `x11vnc` 提供，entrypoint 根据 ENABLE_VNC=true 在 DISPLAY 上启动；
# - CDP：不是独立安装包，由 `chromium` 的 --remote-debugging-port 提供，再由 `socat` 从容器内端口转发到 0.0.0.0；
# - ChromeDriver：由 `chromium-driver` 提供，主要用于版本记录和后续排障，不替代 CDP；
# - 代理核心：只从 Clash Verge deb 中抽取 `verge-mihomo` 与规则资源，不启动 Electron 图形界面；
# - 浏览器代理状态入口：由 entrypoint 动态生成 Chrome extension，用于在浏览器工具栏显示代理状态；
# - WebRTC 保护插件：由 entrypoint 动态生成临时 Chrome extension，不需要在 Dockerfile 额外 COPY 插件文件。
# - CDP 健康探测：由 `curl` + `python3-websocket` 完成 /json/version、target、Runtime.evaluate 三层检查，
#   不引入 npm/wscat，避免为了一个探测动作把 Node 工具链塞进浏览器运行镜像。
#
# 维护原则：
# - 不能为了方便在 Apple Silicon 上本地 build 就放开架构限制；M2 应通过 buildx --platform linux/amd64 构建；
# - Chromium 版本暂由 Debian bookworm 仓库决定，但实际版本必须写入镜像契约，便于后续判断环境包是否可迁移；
# - Clash Verge deb 仅作为 Mihomo core 的离线载体，不能再把 Electron GUI 和桌面托盘当作运行方案；
# - 运行时不应出现 Linux 桌面底栏，VNC 画面以浏览器窗口为主。
RUN set -eux; \
  if [ -n "${TARGETARCH}" ] && [ "${TARGETARCH}" != "amd64" ]; then \
    echo "This Dockerfile only supports linux/amd64, got TARGETARCH=${TARGETARCH}" >&2; \
    exit 1; \
  fi; \
  sed -i "s|http://deb.debian.org/debian|http://${DEBIAN_MIRROR}/debian|g" /etc/apt/sources.list.d/debian.sources; \
  sed -i "s|http://deb.debian.org/debian-security|http://${DEBIAN_MIRROR}/debian-security|g" /etc/apt/sources.list.d/debian.sources; \
  printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' > /etc/apt/apt.conf.d/99-private-browser-retries; \
  apt-get update; \
  apt-get install -y --fix-missing --no-install-recommends \
    chromium \
    chromium-driver \
    xvfb \
    fluxbox \
    x11vnc \
    autocutsel \
    xclip \
    iptables \
    socat \
    python3 \
    python3-websocket \
    ca-certificates \
    curl \
    gzip \
    fonts-noto-cjk \
    fonts-dejavu-core \
    fonts-liberation \
    fonts-freefont-ttf \
    fonts-noto-color-emoji \
    keyboard-configuration \
    tzdata \
    tini; \
  arch="$(dpkg --print-architecture)"; \
  if [ "${arch}" != "amd64" ]; then \
    echo "This image must be built as amd64, got dpkg architecture=${arch}" >&2; \
    exit 1; \
  fi; \
  local_deb_path="/tmp/clash-verge-vendor/Clash.Verge_${CLASH_VERGE_VERSION}_amd64.deb"; \
  if [ ! -f "${local_deb_path}" ]; then \
    echo "Missing vendored amd64 Clash Verge package: ${local_deb_path}" >&2; \
    exit 1; \
  fi; \
  dpkg-deb --info "${local_deb_path}" >/dev/null; \
  mkdir -p /tmp/clash-verge-extract /opt/private-browser/mihomo; \
  dpkg-deb -x "${local_deb_path}" /tmp/clash-verge-extract; \
  cp /tmp/clash-verge-extract/usr/bin/verge-mihomo /opt/private-browser/mihomo/verge-mihomo; \
  cp /tmp/clash-verge-extract/usr/bin/verge-mihomo-alpha /opt/private-browser/mihomo/verge-mihomo-alpha; \
  cp -R "/tmp/clash-verge-extract/usr/lib/Clash Verge/resources" /opt/private-browser/mihomo/resources; \
  chmod +x /opt/private-browser/mihomo/verge-mihomo /opt/private-browser/mihomo/verge-mihomo-alpha; \
  mkdir -p /opt/private-browser; \
  chromium_version="$(chromium --version | sed 's/^Chromium //')"; \
  chromium_driver_version="$(chromedriver --version | awk '{print $2}')"; \
  os_version="$(. /etc/os-release && printf '%s' "${PRETTY_NAME}")"; \
  mihomo_version="$(/opt/private-browser/mihomo/verge-mihomo -v 2>/dev/null | head -n 1 || true)"; \
  if [ -z "${mihomo_version}" ]; then mihomo_version="verge-mihomo-from-clash-verge-${CLASH_VERGE_VERSION}"; fi; \
  { \
    printf '{\n'; \
    printf '  "family": "%s",\n' "${IMAGE_FAMILY}"; \
    printf '  "version": "%s",\n' "${IMAGE_VERSION}"; \
    printf '  "revision": "%s",\n' "${IMAGE_REVISION}"; \
    printf '  "arch": "amd64",\n'; \
    printf '  "os": "debian",\n'; \
    printf '  "osVersion": "%s",\n' "${os_version}"; \
    printf '  "chromiumVersion": "%s",\n' "${chromium_version}"; \
    printf '  "chromiumDriverVersion": "%s",\n' "${chromium_driver_version}"; \
    printf '  "proxyCore": "verge-mihomo",\n'; \
    printf '  "proxyCoreVersion": "%s",\n' "${mihomo_version}"; \
    printf '  "fontPackVersion": "fonts-noto-cjk+dejavu+liberation+freefont+emoji:bookworm",\n'; \
    printf '  "fingerprintEngineVersion": "%s",\n' "${FINGERPRINT_ENGINE_VERSION}"; \
    printf '  "launchArgsVersion": "%s",\n' "${LAUNCH_ARGS_VERSION}"; \
    printf '  "webglMode": "swiftshader-software-rendering",\n'; \
    printf '  "profileCompatibility": {\n'; \
    printf '    "navigatorPlatform": "Linux x86_64",\n'; \
    printf '    "expectedUserAgentArch": "Linux x86_64"\n'; \
    printf '  }\n'; \
    printf '}\n'; \
  } > /opt/private-browser/image-contract.json; \
  rm -rf /tmp/clash-verge-vendor /tmp/clash-verge-extract; \
  rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY entrypoint.sh /entrypoint.sh
COPY scripts/fp_inject.py /app/scripts/fp_inject.py
COPY scripts/fp_daemon.py /app/scripts/fp_daemon.py
RUN chmod +x /entrypoint.sh && useradd --create-home --shell /bin/bash chrome

# 9222 是容器内 CDP 对外端口，5900 是容器内默认 VNC 端口；宿主机端口由边缘服务按 envSequence 映射。
EXPOSE 9222 5900

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
