# GitHub Actions 自动 Build Docker 镜像

## 触发条件

| 事件 | 行为 |
|---|---|
| `push` 到 master + 改 `Dockerfile.uav`/`src/`/`scripts/` | 自动 build + push 多架构镜像 |
| `git tag v1.0.0` 推送 | 自动 build + push,tag = `v1.0.0`, `v1.0`, `latest` |
| 手动 `workflow_dispatch` | 用输入的 tag prefix 临时 build (用于调试) |
| PR | 只 build 不 push (验证能 build 成功) |

## 镜像 tag 规则

| 来源 | 镜像 tag |
|---|---|
| push 到 master | `ghcr.io/<owner>/rm-uav-dep:arm-v1.0-stable` + `:sha-<7位>` |
| git tag v1.0.0 | `ghcr.io/<owner>/rm-uav-dep:v1.0.0` + `:v1.0` + `:latest` |
| 手动 dispatch (tag_prefix=arm-test) | `ghcr.io/<owner>/rm-uav-dep:arm-test-manual` |
| PR | 不 push,只在 build cache |

## 多架构支持

- `linux/amd64` (Intel/AMD dev 机)
- `linux/arm64` (Jetson Orin / Raspberry Pi 5 等机载电脑)

GitHub Actions runner 用 QEMU 模拟 arm64 build, 不用交叉编译。

## 机载电脑部署 (production)

### 1. 一次性: 配 GitHub Container Registry 访问

机载电脑需要拉 GHCR 镜像。两种方式:

**方式 A: 公开 repo** (推荐, 不需登录)
```bash
# 直接拉, GitHub Container Registry 对 public repo 免登录
docker pull ghcr.io/<owner>/rm-uav-dep:arm-v1.0-stable
```

**方式 B: 私有 repo** (需要登录)
```bash
# 1. GitHub → Settings → Developer settings → Personal access tokens → 创建一个
#    选 read:packages 权限
# 2. 机载电脑保存 token
echo "ghp_xxxxxxxxxxxx" | docker login ghcr.io -u <owner> --password-stdin
# 3. 拉镜像
docker pull ghcr.io/<owner>/rm-uav-dep:arm-v1.0-stable
```

### 2. 部署脚本

`scripts/deploy_to_drone.sh` (后续会写) 做的事:
- 拉最新镜像
- 停旧容器
- 起新容器 (挂 ODIN USB)
- 检查 launch file
- 输出 systemd status

### 3. systemd 自动更新 (可选)

如果想机载电脑**定期拉最新镜像** (比如每天 1 次),加一个 systemd timer:
```ini
# /etc/systemd/system/rm-uav-dep-update.timer
[Timer]
OnCalendar=*-*-* 01:00:00
[Install]
WantedBy=timers.target
```

## 调试

### 看 GitHub Actions 日志
1. 仓库 → Actions tab
2. 选失败的 run
3. 看 `build-and-push` step 的 log

### 本地模拟 CI build

```bash
# 装 buildx + qemu
docker buildx create --use --name ci-builder
docker run --privileged --rm tonistiigi/binfmt --install all

# 多架构 build + 加载到本地 (不 push)
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --file Dockerfile.uav \
  --load \
  --tag rm-uav-dep:local \
  .

# 或 build 单架构 (arm64) 然后 docker save
docker buildx build \
  --platform linux/arm64 \
  --file Dockerfile.uav \
  --output type=docker,dest=rm-uav-dep.tar \
  --tag rm-uav-dep:local \
  .
```

## 文件

- `.github/workflows/docker-build.yml` — workflow 定义
- `Dockerfile.uav` — 镜像构建 (被 workflow 用)
- 镜像 registry: `ghcr.io/<owner>/rm-uav-dep`