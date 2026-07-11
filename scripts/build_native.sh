#!/usr/bin/env bash
# =============================================================================
# build_native.sh — 在 host 上原生 build 当前架构的镜像 (推荐)
# =============================================================================
# 这是 build_arm64.sh 的通用化版本. 自动检测 host 架构并 build 同架构镜像.
#
# 用法 (任意架构 host):
#   bash scripts/build_native.sh                          # 自动用 host 架构的 base
#   bash scripts/build_native.sh --base ubuntu:22.04      # 指定 base (multi-arch 镜像)
#   bash scripts/build_native.sh --tag arm-v3.0          # 指定镜像 tag
#
# 历史别名: 之前叫 build_arm64.sh, 现在拆成了:
#   build_native.sh    (这个文件, 推荐, 任何架构)
#   build_multiarch.sh (跨架构 build, 需要 qemu)
#
# 默认 base 选择逻辑 (按 host 架构):
#   arm64 host → ubuntu:22.04-linuxarm64 (你本地已经 pull 的单架构 tag)
#   amd64 host → ubuntu:22.04_base (你本地 116MB 的旧 tag)
#   都可以 --base 覆盖
# =============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 检测 host 架构
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
    aarch64|arm64)  DEFAULT_BASE="ubuntu:22.04-linuxarm64"; DEFAULT_TAG="uavsim:arm-v3.0" ;;
    x86_64|amd64)  DEFAULT_BASE="ubuntu:22.04";             DEFAULT_TAG="uavsim:amd64-v3.0" ;;
    *) echo "[error] 不支持的 host 架构: $HOST_ARCH" >&2; exit 1 ;;
esac

IMAGE_NAME="${IMAGE_NAME:-$DEFAULT_TAG}"
BASE_IMAGE="${BASE_IMAGE:-$DEFAULT_BASE}"
ROS_MIRROR="${ROS_MIRROR:-tsinghua}"
USE_CACHE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)         IMAGE_NAME="$2"; shift 2 ;;
        --base)        BASE_IMAGE="$2"; shift 2 ;;
        --mirror)      ROS_MIRROR="$2"; shift 2 ;;
        --no-cache)    USE_CACHE="--no-cache"; shift ;;
        --network)     NETWORK_ARG="--network=$2"; shift 2 ;;
        -h|--help)
            sed -n '2,18p' "$0"
            echo "  --network host|none|<name>   build 容器网络 (Tegra kernel 没 iptable_raw 时用 host)"
            exit 0 ;;
        *) echo "[error] unknown: $1" >&2; exit 2 ;;
    esac
done

echo "[build_native] host=$HOST_ARCH  base=$BASE_IMAGE  tag=$IMAGE_NAME  ros_mirror=$ROS_MIRROR"

# 决定 --platform
if [[ "$BASE_IMAGE" == *linux*64 || "$BASE_IMAGE" == *arm64* || "$BASE_IMAGE" == *amd64* ]]; then
    PLATFORM_ARG=""
    echo "[build_native] base 是单架构 tag ($HOST_ARCH), 不加 --platform"
else
    # multi-arch tag
    case "$HOST_ARCH" in
        aarch64|arm64)  PLATFORM_ARG="--platform linux/arm64" ;;
        x86_64|amd64)  PLATFORM_ARG="--platform linux/amd64" ;;
    esac
    echo "[build_native] base 是 multi-arch tag, 加 $PLATFORM_ARG"
fi

NETWORK_ARG="${NETWORK_ARG:-}"
docker build \
    -f "$REPO_ROOT/Dockerfile.uav" \
    -t "$IMAGE_NAME" \
    $USE_CACHE \
    $PLATFORM_ARG \
    $NETWORK_ARG \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --build-arg ROS_APT_MIRROR="$ROS_MIRROR" \
    "$REPO_ROOT"

echo ""
echo "[build_native] ✅ $IMAGE_NAME build 完成 (架构: $HOST_ARCH)"
docker images "$IMAGE_NAME" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}"