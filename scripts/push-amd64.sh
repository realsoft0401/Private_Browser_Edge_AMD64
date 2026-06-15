#!/usr/bin/env bash
set -euo pipefail

# 这个脚本用于正式推送 amd64 镜像。
# 与 build-amd64.sh 的区别是使用 --push，适合 CI 或已经登录阿里云镜像仓库的开发机。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE_REPO="${IMAGE_REPO:-crpi-6s60spbjvluac8j8.cn-shanghai.personal.cr.aliyuncs.com/ln0216/private_browser_edge}"
IMAGE_TAG="${IMAGE_TAG:-1.1-amd64}"
IMAGE_NAME="${IMAGE_NAME:-${IMAGE_REPO}:${IMAGE_TAG}}"
IMAGE_FAMILY="${IMAGE_FAMILY:-private_browser_edge}"
IMAGE_VERSION="${IMAGE_VERSION:-${IMAGE_TAG}}"
IMAGE_REVISION="${IMAGE_REVISION:-local}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-deb.debian.org}"
CLASH_VERGE_VERSION="${CLASH_VERGE_VERSION:-2.4.7}"

echo "Building and pushing amd64 image: ${IMAGE_NAME}"

docker buildx build \
  --platform linux/amd64 \
  --push \
  --build-arg "DEBIAN_MIRROR=${DEBIAN_MIRROR}" \
  --build-arg "CLASH_VERGE_VERSION=${CLASH_VERGE_VERSION}" \
  --build-arg "IMAGE_FAMILY=${IMAGE_FAMILY}" \
  --build-arg "IMAGE_VERSION=${IMAGE_VERSION}" \
  --build-arg "IMAGE_REVISION=${IMAGE_REVISION}" \
  -t "${IMAGE_NAME}" \
  "${ROOT_DIR}"
