#!/usr/bin/env bash
set -euo pipefail

# 这个脚本用于验证镜像内的契约文件。
# 后续环境包导入/迁移时，应以这个契约作为兼容性判断依据之一，而不是只看镜像 tag 字符串。
IMAGE_REPO="${IMAGE_REPO:-crpi-6s60spbjvluac8j8.cn-shanghai.personal.cr.aliyuncs.com/ln0216/private_browser_edge}"
IMAGE_TAG="${IMAGE_TAG:-1.1-amd64}"
IMAGE_NAME="${IMAGE_NAME:-${IMAGE_REPO}:${IMAGE_TAG}}"

docker run --rm --entrypoint /bin/sh "${IMAGE_NAME}" -lc \
  'cat /opt/private-browser/image-contract.json && printf "\n"; chromium --version; chromedriver --version'
