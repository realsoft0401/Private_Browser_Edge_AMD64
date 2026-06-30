#!/usr/bin/env bash
set -euo pipefail

# 这个脚本专门服务 amd64 商业镜像打包。
# 设计来源：
# - 用户当前使用 Apple Silicon 开发机，但商业节点优先走 x86_64/amd64；
# - 普通 docker build 在 M2 上会默认产出 arm64 镜像，容易和 Linux x86_64 指纹包发生不一致；
# - 因此这里强制使用 buildx + --platform linux/amd64，并把镜像版本、修订号写入 Dockerfile 的契约参数；
# - 本地 load 时显式关闭 provenance，避免 Docker Desktop 把结果留成不可直接 docker run 的构建元数据。
#
# 用法：
#   ./scripts/build-amd64.sh                                    # 默认本地构建 + load
#   ./scripts/build-amd64.sh --push                             # 构建并推送
#   ./scripts/build-amd64.sh --image myrepo/browser --tag v2.0  # 指定镜像和标签
#   ./scripts/build-amd64.sh --platform linux/amd64 --image repo --tag t --push
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── 默认值 ──────────────────────────────────────────────
PLATFORM="linux/amd64"
IMAGE_REPO="${IMAGE_REPO:-crpi-6s60spbjvluac8j8.cn-shanghai.personal.cr.aliyuncs.com/ln0216/private_browser_edge}"
IMAGE_TAG="${IMAGE_TAG:-1.1-amd64}"
DO_PUSH=false
IMAGE_FAMILY="${IMAGE_FAMILY:-private_browser_edge}"
IMAGE_VERSION="${IMAGE_VERSION:-${IMAGE_TAG}}"
IMAGE_REVISION="${IMAGE_REVISION:-local}"
DOCKERHUB_MIRROR="${DOCKERHUB_MIRROR:-docker.m.daocloud.io}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-mirrors.tuna.tsinghua.edu.cn}"
CLASH_VERGE_VERSION="${CLASH_VERGE_VERSION:-2.4.7}"

# ── 参数解析 ────────────────────────────────────────────
usage() {
  cat >&2 <<'EOF'
Usage: build-amd64.sh [OPTIONS]

Options:
  --platform <p>   目标平台，默认 linux/amd64
  --image <repo>   镜像仓库地址（不含 tag）
  --tag <t>        镜像标签
  --push           构建后推送（默认 --load 到本地 Docker）
  --revision <r>   镜像修订号，默认 local

Examples:
  ./scripts/build-amd64.sh
  ./scripts/build-amd64.sh --push
  ./scripts/build-amd64.sh --image myrepo/browser --tag v2.0 --push
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      PLATFORM="${2:?missing platform}"
      shift 2
      ;;
    --image)
      IMAGE_REPO="${2:?missing image repo}"
      shift 2
      ;;
    --tag)
      IMAGE_TAG="${2:?missing tag}"
      shift 2
      ;;
    --revision)
      IMAGE_REVISION="${2:?missing revision}"
      shift 2
      ;;
    --push)
      DO_PUSH=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

# ── 派生变量 ────────────────────────────────────────────
IMAGE_NAME="${IMAGE_REPO}:${IMAGE_TAG}"
# IMAGE_VERSION 跟随 tag（除非显式覆盖环境变量）
if [[ -z "${IMAGE_VERSION:-}" ]] || [[ "${IMAGE_VERSION}" == "${IMAGE_TAG}" ]]; then
  IMAGE_VERSION="${IMAGE_TAG}"
fi

# ── 构建 ────────────────────────────────────────────────
if [[ "${DO_PUSH}" == "true" ]]; then
  echo "Building and pushing amd64 image: ${IMAGE_NAME}"
  docker buildx build \
    --platform "${PLATFORM}" \
    --push \
    --build-arg "DOCKERHUB_MIRROR=${DOCKERHUB_MIRROR}" \
    --build-arg "DEBIAN_MIRROR=${DEBIAN_MIRROR}" \
    --build-arg "CLASH_VERGE_VERSION=${CLASH_VERGE_VERSION}" \
    --build-arg "IMAGE_FAMILY=${IMAGE_FAMILY}" \
    --build-arg "IMAGE_VERSION=${IMAGE_VERSION}" \
    --build-arg "IMAGE_REVISION=${IMAGE_REVISION}" \
    -t "${IMAGE_NAME}" \
    "${ROOT_DIR}"
else
  echo "Building amd64 image (local load): ${IMAGE_NAME}"
  docker buildx build \
    --platform "${PLATFORM}" \
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
fi
