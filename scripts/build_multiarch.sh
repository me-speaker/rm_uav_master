#!/usr/bin/env bash
# =============================================================================
# build_multiarch.sh — 用 buildx 在 x86 dev 机上跨平台 build arm64 镜像
# =============================================================================
# 用法 (在 x86 dev 机上跑):
#   bash scripts/build_multiarch.sh                   # 默认 amd64 + arm64
#   bash scripts/build_multiarch.sh --arch amd64      # 只 build amd64
#   bash scripts/build_multiarch.sh --arch arm64      # 只 build arm64
#   bash scripts/build_multiarch.sh --base my-arm-img # 用你已经 pull 的本地 arm 镜像
#   bash scripts/build_multiarch.sh --mirror official # 国内用清华, 国外用 official
#   bash scripts/build_multiarch.sh --push REGISTRY   # build + push
#
# v3.0 Dockerfile 设计: ubuntu base + 全从 apt 装, 不依赖任何 single-arch
# base image. buildx 会按 host 架构/--platform 自动选 base 的 arch.
# =============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARCHS="linux/amd64,linux/arm64"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:22.04}"
ROS_MIRROR="${ROS_MIRROR:-tsinghua}"
PUSH=""
LOAD_LOCAL=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)        ARCHS="linux/$2"; shift 2 ;;
        --base)        BASE_IMAGE="$2"; shift 2 ;;
        --mirror)      ROS_MIRROR="$2"; shift 2 ;;
        --push)        PUSH="--push"; LOAD_LOCAL=0; shift ;;
        --no-load)     LOAD_LOCAL=0; shift ;;
        -h|--help)
            sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "[error] unknown: $1" >&2; exit 2 ;;
    esac
done

HOST=$(uname -m)
if [[ "$ARCHS" == *"linux/arm64"* ]]; then
    if [[ "$HOST" != *arm64* && "$HOST" != *aarch64* ]]; then
        echo "[build_multiarch] 检查 qemu-user-static ..."
        if ! docker run --rm --platform linux/arm64 alpine uname -m 2>&1 | grep -q aarch64; then
            echo "[build_multiarch] 装 qemu ..."
            docker run --privileged --rm tonistiigi/binfmt --install all 2>&1 | tail -3
        fi
    fi

    # 检查 base 架构能不能被 --platform linux/arm64 解析
    # 这里不依赖 docker.io, 只看本地 image 的架构
    BASE_ARCH=$(docker inspect "$BASE_IMAGE" --format '{{.Architecture}}' 2>/dev/null)
    case "$BASE_ARCH" in
        arm64|aarch64)
            echo "[build_multiarch] base 本地是 arm64 ✅"
            ;;
        amd64)
            echo "[error] base 是 amd64, 但要 build arm64 — 这没法 (除非用 qemu 跨 arch)" >&2
            echo "        你需要一个 arm64 的 base, 或 docker pull 一个" >&2
            exit 1
            ;;
        "")
            # base 不在本地, 让 docker build 自己拉 (可能失败因为 docker.io 不通)
            echo "[build_multiarch] base 不在本地, 让 docker build 去拉 (docker.io 可能不通)"
            ;;
        *)
            echo "[warn] base 架构未知: $BASE_ARCH, 继续 build 让 docker 报错" >&2
            ;;
    esac
fi

# buildx builder
BUILDER="uav-multiarch"
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
    echo "[build_multiarch] 创建 buildx builder: $BUILDER"
    docker buildx create --name "$BUILDER" --use --driver docker-container 2>&1 | tail -3
else
    docker buildx use "$BUILDER"
fi

ARCH_TAG=$(echo "$ARCHS" | tr ',' '\n' | head -1 | tr '/' '-')
echo "[build_multiarch] base=$BASE_IMAGE  ros_mirror=$ROS_MIRROR  arch=$ARCHS"

if [[ -n "$PUSH" ]]; then
    docker buildx build \
        --platform "$ARCHS" \
        -f "$REPO_ROOT/Dockerfile.uav" \
        --build-arg BASE_IMAGE="$BASE_IMAGE" \
        --build-arg ROS_APT_MIRROR="$ROS_MIRROR" \
        --tag "uavsim:${ARCH_TAG}-v3.0" \
        --push \
        "$REPO_ROOT"
    echo "[build_multiarch] ✅ pushed"
else
    docker buildx build \
        --platform "$ARCHS" \
        -f "$REPO_ROOT/Dockerfile.uav" \
        --build-arg BASE_IMAGE="$BASE_IMAGE" \
        --build-arg ROS_APT_MIRROR="$ROS_MIRROR" \
        --tag "uavsim:${ARCH_TAG}-v3.0" \
        --load \
        "$REPO_ROOT"
    echo "[build_multiarch] ✅ loaded (本地)"
    docker images "uavsim:${ARCH_TAG}-v3.0" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}"
fi