#!/usr/bin/env bash
# =============================================================================
# build_arm64.sh — 在 Jetson 等 arm64 小电脑上原生 build 镜像 (v3.0 from-scratch)
# =============================================================================
# 用法 (在 Jetson / Raspberry Pi 5 / NUC arm64 上跑):
#   bash scripts/build_arm64.sh                       # 默认 (用 ubuntu:22.04)
#   bash scripts/build_arm64.sh --tag arm-v3.0
#   bash scripts/build_arm64.sh --base my-ubuntu-arm  # 你已经 pull 的本地 arm 镜像
#   bash scripts/build_arm64.sh --no-cache
#   bash scripts/build_arm64.sh --mirror official     # 国内用清华, 国外用 official
#
# v3.0 Docker 设计: 从裸 Ubuntu 22.04 (multi-arch) 从 0 编译:
#   装 ROS 2 Humble (清华源镜像) → 装 MAVROS → 装 SLAM/Odin 依赖
#   → git clone Livox-SDK2 编译 → 拷脚本 → entrypoint 搞定
#
# 跟 x86 amd64 build 命令完全一样, Docker buildx 自动用 host 架构
# =============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-uavsim:arm-v3.0}"
# 优先用你本地已经 pull 的 arm 单架构 tag, 跟 multi-arch 兼容
# 备选: ubuntu:22.04 (DockerHub 官方 multi-arch)
BASE_IMAGE="${BASE_IMAGE:-ubuntu:22.04-linuxarm64}"
ROS_MIRROR="${ROS_MIRROR:-tsinghua}"
USE_CACHE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)         IMAGE_NAME="$2"; shift 2 ;;
        --base)        BASE_IMAGE="$2"; shift 2 ;;
        --mirror)      ROS_MIRROR="$2"; shift 2 ;;
        --no-cache)    USE_CACHE="--no-cache"; shift ;;
        -h|--help)
            sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "[error] unknown: $1" >&2; exit 2 ;;
    esac
done

# 1. 验证 host 架构
HOST_ARCH=$(uname -m)
echo "[build_arm64] host 架构: $HOST_ARCH"
if [[ "$HOST_ARCH" != "aarch64" && "$HOST_ARCH" != "arm64" ]]; then
    echo "[error] 这个脚本必须在 arm64 主机 (Jetson / Pi5 / NUC-arm) 上跑" >&2
    echo "        当前 host 是 $HOST_ARCH, 用 build_multiarch.sh 做跨平台 build" >&2
    exit 1
fi

# 2. 决定要不要加 --platform
# 单架构 tag (ubuntu:22.04-linuxarm64, 或本地 amd64 tag) 不需要 --platform
# multi-arch tag (需要 docker.io 通才能确认) 才需要
echo "[build_arm64] 用 base=$BASE_IMAGE, ROS_MIRROR=$ROS_MIRROR"
if [[ "$BASE_IMAGE" == *linuxarm64 || "$BASE_IMAGE" == *arm64* ]]; then
    PLATFORM_ARG=""
    echo "[build_arm64] base 是单架构 arm64 tag, 不加 --platform"
elif [[ "$BASE_IMAGE" == *linuxamd64 || "$BASE_IMAGE" == *amd64* ]]; then
    # 用户明确传了 amd64 base, 但 host 是 arm64 — build 必失败
    echo "[error] HOST 是 arm64 但 --base 是 amd64 镜像, 这没法 build" >&2
    exit 1
else
    # multi-arch tag, 让 docker build 自己决定或显式 --platform
    PLATFORM_ARG="--platform linux/arm64"
    echo "[build_arm64] 假设 base 是 multi-arch, 加 --platform linux/arm64"
fi

# 3. build
echo "[build_arm64] 构建 $IMAGE_NAME ..."
docker build \
    -f "$REPO_ROOT/Dockerfile.uav" \
    -t "$IMAGE_NAME" \
    $USE_CACHE \
    $PLATFORM_ARG \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --build-arg ROS_APT_MIRROR="$ROS_MIRROR" \
    "$REPO_ROOT"

echo ""
echo "[build_arm64] ✅ build 完成"
docker images "$IMAGE_NAME" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}"
echo ""
echo "下一步:"
echo "  1. 跑容器 (Jetson): bash scripts/start_uav_container.sh --image $IMAGE_NAME \\"
echo "                              --bringup --lidar mid360 --lidar-ip 192.168.1.150"
echo "  2. 复制到同款 Jetson: docker save $IMAGE_NAME | gzip > uavsim-arm-v3.0.tar.gz"