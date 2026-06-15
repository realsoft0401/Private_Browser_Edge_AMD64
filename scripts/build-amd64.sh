#!/usr/bin/env bash
set -euo pipefail

# 这个脚本专门服务 amd64 商业镜像打包。
# 设计来源：
# - 用户当前使用 Apple Silicon 开发机，但商业节点优先走 x86_64/amd64；
# - 普通 docker build 在 M2 上会默认产出 arm64 镜像，容易和 Linux x86_64 指纹包发生不一致；
# - 因此这里强制使用 buildx + --platform linux/amd64，并把镜像版本、修订号写入 Dockerfile 的契约参数；
# - 本地 load 时显式关闭 provenance，避免 Docker Desktop 把结果留成不可直接 docker run 的构建元数据。
#
# 职责边界：
# - 只负责本地构建并加载到当前 Docker；
# - 不负责 push、不负责更新 Go 边缘服务配置、不负责生成 profile/env 包。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE_REPO="${IMAGE_REPO:-crpi-6s60spbjvluac8j8.cn-shanghai.personal.cr.aliyuncs.com/ln0216/private_browser_edge}"
IMAGE_TAG="${IMAGE_TAG:-1.1-amd64}"
IMAGE_NAME="${IMAGE_NAME:-${IMAGE_REPO}:${IMAGE_TAG}}"
IMAGE_FAMILY="${IMAGE_FAMILY:-private_browser_edge}"
IMAGE_VERSION="${IMAGE_VERSION:-${IMAGE_TAG}}"
IMAGE_REVISION="${IMAGE_REVISION:-local}"
# 正式构建链路里，FROM 基础镜像入口也必须走可覆盖的国内镜像前缀。
DOCKERHUB_MIRROR="${DOCKERHUB_MIRROR:-docker.m.daocloud.io}"
# 默认使用本轮验证通过的清华 Debian 源；如节点网络不同，可通过 DEBIAN_MIRROR 覆盖。
DEBIAN_MIRROR="${DEBIAN_MIRROR:-mirrors.tuna.tsinghua.edu.cn}"
CLASH_VERGE_VERSION="${CLASH_VERGE_VERSION:-2.4.7}"

echo "Building amd64 image: ${IMAGE_NAME}"

docker buildx build \
  --platform linux/amd64 \
  --load \
  --provenance=false \
  --build-arg "DOCKERHUB_MIRROR=${DOCKERHUB_MIRROR}" \
  --build-arg "DEBIAN_MIRROR=${DEBIAN_MIRROR}" \
  --build-arg "CLASH_VERGE_VERSION=${CLASH_VERGE_VERSION}" \
  --build-arg "IMAGE_FAMILY=${IMAGE_FAMILY}" \
  --build-arg "IMAGE_VERSION=${IMAGE_VERSION}" \
  --build-arg "IMAGE_REVISION=${IMAGE_REVISION}" \
  -t "${IMAGE_NAME}" \
  "${ROOT_DIR}"
