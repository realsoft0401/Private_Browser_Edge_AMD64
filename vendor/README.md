# Vendor Packages

本目录只放 `linux/amd64` 浏览器运行镜像构建所需的离线包。

当前需要：

```text
Clash.Verge_2.4.7_amd64.deb
```

设计原因：

- amd64 商业镜像不能在构建时临时下载不确定的代理客户端包。
- 旧项目同时保留 `amd64` 和 `arm64` 包，这里故意只保留 `amd64`，避免 M2 本地构建时误走 arm64 链路。
- Dockerfile 会校验 deb 文件存在且能被 `dpkg-deb --info` 识别。

维护原则：

- 升级 Clash Verge 时，必须同步更新 Dockerfile/脚本里的 `CLASH_VERGE_VERSION` 默认值。
- 不要把 arm64 包放回这个目录；如果以后恢复 arm64，应建立独立打包流程。
