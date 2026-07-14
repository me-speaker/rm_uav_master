#!/usr/bin/env bash
# =============================================================================
# build_install.sh — 跑 ega-uav:build 容器,在 host ~/rm_ws 上 build ROS 工作区
# =============================================================================
# 用途: dev 机 (arm64 / amd64) 一次性跑, 产物 install/build/log 写到 host 当前目录
#       然后用 deploy_to_drone.sh 把 install/ 推到 drone (drone 不需要 build image)
#
# 前置:
#   1. ega-uav:build image 已经 build 好:
#        bash scripts/build_native.sh --target build
#        # 或 CI 拉的 ghcr.io/${owner}/ega-uav-build:build-v1.0-stable
#   2. 当前目录是 ~/rm_ws (有 src/ 子目录)
#
# 用法:
#   bash scripts/build_install.sh                                # 默认 image
#   bash scripts/build_install.sh ega-uav:build-arm-v1.1         # 指定 tag
#   bash scripts/build_install.sh --no-patch                     # 不应用 mavros patch
#   bash scripts/build_install.sh --clean                        # 清 install/build/log 后重 build
#
# 输出 (写到 host 当前目录):
#   install/setup.bash          # 顶层 aggregator (entrypoint 检测的关键文件)
#   install/<pkg>/...           # per-package 产物
#   build/<pkg>/...             # cmake build tree
#   log/build_<timestamp>/...   # colcon log
#
# 设计依据 (踩过的坑, 这里都修了):
#   1. runtime image 装 mavros + mavros_msgs + libmavconn (apt 包), 不装 mavros-extras
#      → build image 里 src/mavros/{mavros,mavros_msgs,libmavconn}/ 需加 COLCON_IGNORE
#        让 apt 版本生效, src 只 build mavros_extras (带 vision_pose patch)
#   2. 必须 --symlink-install 才能生成顶层 install/setup.bash
#   3. 必须 cd /opt/uav_ws 跑 colcon (不要 pwd=/, colcon 写到 /install/ 而不是 host mount)
#   4. --build-base / --install-base 显式指定写到 host, 不要用 colcon 默认的 /build/, /install/
#   5. ROS apt 装 vendor meta-pkg (gtest_vendor 等) 自带 share/<pkg>/package.sh marker,
#      colcon enumerate 自动找到, 不需要手工建 fake markers
# =============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_IMAGE="${BUILD_IMAGE:-ega-uav:build-v1.0}"
APPLY_PATCH=1
CLEAN=0
BUILD_BASE="/opt/uav_ws/build"
INSTALL_BASE="/opt/uav_ws/install"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-patch) APPLY_PATCH=0; shift ;;
        --clean)    CLEAN=1; shift ;;
        --image)    BUILD_IMAGE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,22p' "$0"; exit 0 ;;
        *)          BUILD_IMAGE="$1"; shift ;;
    esac
done

cd "$REPO_ROOT"

# ---- 0. 前置检查 ----------------------------------------------------------
if [ ! -d src ]; then
    echo "[build_install] ❌ 当前目录没有 src/, 请在 ~/rm_ws 下跑 (脚本位置: $SCRIPT_DIR)" >&2
    exit 1
fi
if ! docker image inspect "$BUILD_IMAGE" >/dev/null 2>&1; then
    echo "[build_install] ❌ build image $BUILD_IMAGE 不存在, 先跑:" >&2
    echo "    bash scripts/build_native.sh --target build" >&2
    echo "    或 docker pull ghcr.io/\$GITHUB_REPOSITORY_OWNER/ega-uav-build:build-v1.0-stable" >&2
    exit 1
fi

# ---- 1. (可选) 清掉旧产物 ---------------------------------------------------
if [[ "$CLEAN" == "1" ]]; then
    echo "[build_install] --clean, 删 install/ build/ log/ ..."
    rm -rf install build log
fi

# ---- 2. 跑 build image ----------------------------------------------------
echo "[build_install] build image:  $BUILD_IMAGE"
echo "[build_install] workspace:    $REPO_ROOT"
echo "[build_install] build base:   $BUILD_BASE (写到 host mount)"
echo "[build_install] install base: $INSTALL_BASE"
echo "[build_install] apply mavros patch: $APPLY_PATCH"

# mount 整个 ~/rm_ws 到 /opt/uav_ws, 容器内跑 colcon build, 产物写回 host
docker run --rm \
    -v "$REPO_ROOT:/opt/uav_ws" \
    -w /opt/uav_ws \
    "$BUILD_IMAGE" \
    bash -c "
        set -eo pipefail
        # ROS env (build image 的 entrypoint 不一定 source, 显式 source 安全)
        source /opt/ros/humble/setup.bash

        # 1. 应用 mavros humble vision_pose patch (idempotent)
        if [[ '$APPLY_PATCH' == '1' ]] && [[ -f dockerfiles/mavros-patch.diff ]]; then
            cd src/mavros
            # 先 reverse 一次 (如果之前已经 apply 过, 反向会成功; 没 apply 过会失败被吞掉)
            git apply -R dockerfiles/mavros-patch.diff 2>/dev/null || true
            # 正向 apply (现在 src 应该是干净 upstream 状态)
            if git apply dockerfiles/mavros-patch.diff; then
                echo '[docker] ✓ mavros patch applied'
            else
                echo '[docker] ❌ mavros patch apply FAILED, 看上面输出' >&2
                exit 1
            fi
            cd ../..
        fi

        # 2. COLCON_IGNORE: 让 apt 装的 mavros/mavros_msgs/libmavconn 生效
        #    (runtime image 不装 mavros-extras, 由 src/mavros/mavros_extras/ 编译出)
        #    src/mavros/ 下其他子目录跟 apt 版本重复, 必须 ignore
        for sub in mavros mavros_msgs libmavconn; do
            f=src/mavros/\$sub/COLCON_IGNORE
            mkdir -p \"\$(dirname \$f)\" 2>/dev/null || true
            (umask 022; echo '# apt roshumble-\$sub (versioned) 提供, src 版不 build' > \$f)
        done
        echo '[docker] ✓ COLCON_IGNORE: src/mavros/{mavros,mavros_msgs,libmavconn}'

        # 3. colcon build: --symlink-install 强制生成顶层 install/setup.bash
        #    --build-base / --install-base 显式指定写到 host mount
        echo '[docker] colcon build --symlink-install (1-3 min on first run, seconds incremental) ...'
        colcon build --symlink-install \
            --build-base  '$BUILD_BASE' \
            --install-base '$INSTALL_BASE' \
            --cmake-args -DCMAKE_BUILD_TYPE=Release \
                         -DCMAKE_PREFIX_PATH='/usr/local;/opt/ros/humble;$INSTALL_BASE' \
            --event-handlers console_direct+
        echo '[docker] colcon build done'
    "

# ---- 3. 验证顶层 setup.bash -------------------------------------------------
if [ -f "$REPO_ROOT/install/setup.bash" ]; then
    echo ""
    echo "[build_install] ✅ build 完成"
    echo "[build_install] ✓ 顶层 install/setup.bash 存在 (drone 端 entrypoint 检测关键文件)"
    echo ""
    echo "产物 (写到 host 当前目录):"
    du -sh install build log 2>/dev/null
    echo ""
    echo "接下来:"
    echo "  bash scripts/deploy_to_drone.sh <user>@<drone-ip>  # 推 image + install 到 drone"
else
    echo "" >&2
    echo "[build_install] ❌ build 完成但 install/setup.bash 不存在!" >&2
    echo "  排查:" >&2
    echo "    - 看上面 [docker] colcon build 输出找错误" >&2
    echo "    - 看 log/build_*/logger_all.log" >&2
    echo "    - 不要用 --packages-select, 会破坏顶层 aggregator" >&2
    exit 1
fi
