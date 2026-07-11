#!/usr/bin/env bash
# =============================================================================
# test_smoke.sh — 容器 + 镜像 + 关键节点 一键 smoke test
# =============================================================================
# 跑全部检查, 任何一步失败 exit 1.
#
# 用法 (在 host 跑):
#   bash tests/test_smoke.sh                    # 用默认容器名 rm-uavsim
#   bash tests/test_smoke.sh --name my-drone    # 自定义容器名
#   bash tests/test_smoke.sh --skip-build       # 跳过 build 检查
# =============================================================================

set -eo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-rm-uavsim}"
IMAGE_NAME="${IMAGE_NAME:-uavsim:uav-v1.0}"
SKIP_BUILD=""
SKIP_RUNNING=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)         CONTAINER_NAME="$2"; shift 2 ;;
        --image)        IMAGE_NAME="$2"; shift 2 ;;
        --skip-build)   SKIP_BUILD=yes; shift ;;
        --skip-running) SKIP_RUNNING=yes; shift ;;
        -h|--help)
            sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown: $1" >&2; exit 2 ;;
    esac
done

pass=0; fail=0
ok()   { echo "  ✅ $*"; pass=$((pass+1)); }
bad()  { echo "  ❌ $*"; fail=$((fail+1)); }
hdr()  { echo ""; echo "═══ $* ═══"; }

# ---- 1. 镜像存在 ---------------------------------------------------------
hdr "1. 镜像检查 [$IMAGE_NAME]"
if [[ -z "$SKIP_BUILD" ]]; then
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        ok "镜像存在"
    else
        bad "镜像不存在: $IMAGE_NAME (跑: docker build -f Dockerfile.uav -t $IMAGE_NAME .)"
    fi
else
    echo "  ⏭️ 跳过"
fi

# ---- 2. 容器存在 ---------------------------------------------------------
hdr "2. 容器检查 [$CONTAINER_NAME]"
if docker ps -a --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    ok "容器存在"
    STATE=$(docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.State}}')
    if [[ "$STATE" == "running" ]]; then
        ok "容器在运行"
    else
        bad "容器不在运行 (state=$STATE)"
    fi
else
    bad "容器不存在 (跑: bash scripts/start_uav_container.sh --bringup)"
    echo "  后续检查全部跳过"
    echo ""; echo "═══ 总结 ═══"; echo "  PASS: $pass  FAIL: $fail"
    exit 1
fi

# ---- 3. mount 检查 ------------------------------------------------------
hdr "3. 源码 mount 检查"
if docker exec "$CONTAINER_NAME" test -d /opt/uav_ws/src/fast_lio \
                          && docker exec "$CONTAINER_NAME" test -d /opt/uav_ws/src/livox_ros_driver2 \
                          && docker exec "$CONTAINER_NAME" test -d /opt/uav_ws/src/slam_to_mavros; then
    ok "4 个源码包都 mount 到 /opt/uav_ws/src/"
else
    bad "/opt/uav_ws/src/ 缺包"
    docker exec "$CONTAINER_NAME" ls /opt/uav_ws/src/ 2>&1 | sed 's/^/    /'
fi

# ---- 4. build 产物 ------------------------------------------------------
hdr "4. build 产物检查"
docker exec "$CONTAINER_NAME" bash -c '
source /opt/uav_ws/install/setup.bash 2>/dev/null
test -f /opt/uav_ws/install/setup.bash && echo INSTALL_OK || echo NO_INSTALL
test -f /opt/uav_ws/install/fast_lio/lib/fast_lio/fastlio_mapping && echo FAST_LIO_OK || echo NO_FAST_LIO
test -f /opt/uav_ws/install/livox_ros_driver2/lib/livox_ros_driver2/livox_ros_driver2_node && echo LIVOX_OK || echo NO_LIVOX
test -f /opt/uav_ws/install/slam_to_mavros/lib/slam_to_mavros/slam_to_mavros_node && echo SLAM_BRIDGE_OK || echo NO_SLAM_BRIDGE
test -d /usr/local/lib/liblivox_lidar_sdk_shared.so && echo SDK_OK || echo NO_SDK
' 2>&1 | while read line; do
    case "$line" in
        INSTALL_OK)          ok "install/setup.bash" ;;
        NO_INSTALL)          bad "install/setup.bash 缺失 (entrypoint 自动 build 没跑?)" ;;
        FAST_LIO_OK)         ok "fastlio_mapping" ;;
        NO_FAST_LIO)         bad "fastlio_mapping 缺失" ;;
        LIVOX_OK)            ok "livox_ros_driver2_node" ;;
        NO_LIVOX)            bad "livox_ros_driver2_node 缺失" ;;
        SLAM_BRIDGE_OK)      ok "slam_to_mavros_node" ;;
        NO_SLAM_BRIDGE)      bad "slam_to_mavros_node 缺失" ;;
        SDK_OK)              ok "Livox-SDK2 /usr/local/lib" ;;
        NO_SDK)              bad "Livox-SDK2 缺失" ;;
    esac
done

# ---- 5. ROS 包注册 ------------------------------------------------------
hdr "5. ROS 2 包注册"
PKGS=$(docker exec "$CONTAINER_NAME" bash -c 'source /opt/uav_ws/install/setup.bash 2>/dev/null && ros2 pkg list 2>/dev/null' 2>&1)
for p in fast_lio livox_ros_driver2 slam_to_mavros mavros; do
    if echo "$PKGS" | grep -qx "$p"; then
        ok "ros2 pkg: $p"
    else
        bad "ros2 pkg: $p 缺失"
    fi
done

# ---- 6. 节点启动 dry-run -------------------------------------------------
hdr "6. 节点 dry-run (3s 启动检查)"
docker exec "$CONTAINER_NAME" bash -c '
source /opt/uav_ws/install/setup.bash
for n in slam_to_mavros_node; do
    timeout 3 ros2 run slam_to_mavros "$n" > /tmp/dryrun.log 2>&1 &
    PID=$!
    sleep 1.5
    if pgrep -f "$n" > /dev/null; then
        echo "OK: $n started"
    else
        echo "FAIL: $n did not start"
        cat /tmp/dryrun.log | head -3 | sed "s/^/  /"
    fi
    kill -9 $(pgrep -f "$n") 2>/dev/null
    wait 2>/dev/null
done
' 2>&1 | while read line; do
    case "$line" in
        OK:*)   ok "$(echo "$line" | cut -d: -f2-)" ;;
        FAIL:*) bad "$(echo "$line" | cut -d: -f2-)" ;;
    esac
done

# ---- 总结 -----------------------------------------------------------------
hdr "总结"
echo "  PASS: $pass"
echo "  FAIL: $fail"
if [[ $fail -gt 0 ]]; then
    exit 1
fi
echo "  ✅ 一切正常, 可以跑 --bringup 了"
exit 0