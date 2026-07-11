#!/usr/bin/env bash
# =============================================================================
# monitor_px4_native.sh — host 端 wrapper: 停 mavros → 跑 pymavlink 监控 → 恢复 mavros
# =============================================================================
# 因为 MAVLink 半双工单连接, mavros 占了 /dev/ttyACM0, pymavlink 拿不到数据.
# 这个脚本临时停 mavros + slam_to_mavros (host_sdk 保留, /odin1/odometry 还在),
# 在容器内跑 pymavlink monitor (直读 PX4 LOCAL_POSITION_NED / ESTIMATOR_STATUS),
# 完事自动重启 mavros + slam_to_mavros.
#
# 用法: bash scripts/monitor_px4_native.sh [秒数]   默认 30s
# =============================================================================
set -e

DURATION="${1:-30}"
CONTAINER="${CONTAINER:-rm-uavsim}"

if ! docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[error] 容器 $CONTAINER 没在跑" >&2
    exit 1
fi

# 确保 pymavlink 装了
if ! docker exec "$CONTAINER" bash -c 'python3 -c "import pymavlink" 2>/dev/null'; then
    bash "$(dirname "$0")/ensure_pymavlink.sh" >/dev/null
fi

echo "═══ 临时停 mavros + slam_to_mavros ═══"
docker exec "$CONTAINER" bash -c '
    pkill -9 -f mavros_node 2>/dev/null || true
    pkill -9 -f slam_to_mavros_node 2>/dev/null || true
    sleep 2
' 2>&1 | tail -3
echo "(mavros 停了, host_sdk 保留)"
echo ""

echo "═══ 启动 pymavlink 监控 (跑 ${DURATION}s) ═══"
docker exec "$CONTAINER" bash -c "
    source /opt/uav_ws/install/setup.bash
    timeout $((DURATION + 5)) python3 /opt/uav_ws/scripts/monitor_px4_mavlink.py
" 2>&1 || true
echo ""

echo "═══ 重启 mavros + slam_to_mavros ═══"
docker exec "$CONTAINER" bash -c '
    source /opt/uav_ws/install/setup.bash
    export FCU_URL=/dev/ttyACM0:921600
    rm -rf /dev/shm/fastrtps_* 2>/dev/null
    ros2 launch /opt/uav_ws/scripts/uav_bringup.launch.py \
        lidar:=odin \
        fcu_url:=${FCU_URL} \
        > /tmp/launch_uav_resume.log 2>&1 &
    disown
'
echo "Layer 4 已恢复 (等 ~10s)"