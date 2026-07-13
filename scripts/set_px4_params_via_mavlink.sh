#!/usr/bin/env bash
# =============================================================================
# set_px4_params_via_mavlink.sh — 停 mavros → pymavlink 设参数 → 重启 mavros
# =============================================================================
# pymavlink 跟 mavros 抢 /dev/ttyACM0 会失败 (MAVLink 半双工)
# 这个 wrapper 临时停 mavros + slam_to_mavros (host_sdk 保留),
# 让 pymavlink 独占端口设参数, 然后重启 mavros + slam_to_mavros
#
# 用法:
#   bash scripts/set_px4_params_via_mavlink.sh --show      # 只看参数
#   bash scripts/set_px4_params_via_mavlink.sh            # 设 vision-only 参数
# =============================================================================
set -e

CONTAINER="${CONTAINER:-rm_dep}"

# 确保 pymavlink 在
if ! docker exec "$CONTAINER" bash -c 'python3 -c "import pymavlink" 2>/dev/null'; then
    bash "$(dirname "$0")/ensure_pymavlink.sh" >/dev/null
fi

echo "═══ 临时停 mavros + slam_to_mavros (host_sdk 保留) ═══"
docker exec "$CONTAINER" bash -c '
    pkill -9 -f mavros_node 2>/dev/null || true
    pkill -9 -f slam_to_mavros_node 2>/dev/null || true
    sleep 2
'
echo "(mavros + slam 停了)"

# 临时把 fake pymavlink 跑在容器内
echo ""
echo "═══ 跑 pymavlink ═══"

# Run pymavlink inside container, 参数透传
docker exec -i "$CONTAINER" bash -c "
    python3 /opt/uav_ws/scripts/set_px4_mavlink.py $*
" 2>&1 | tee /tmp/px4_param_set.log

PX4_REBOOTED=$(grep -c "reboot" /tmp/px4_param_set.log 2>/dev/null || echo 0)

echo ""
echo "═══ 重启 mavros + slam_to_mavros ═══"
docker exec "$CONTAINER" bash -c '
    source /opt/uav_ws/install/setup.bash
    export FCU_URL=/dev/ttyACM0:921600
    ros2 launch /opt/uav_ws/scripts/uav_bringup.launch.py \
        lidar:=odin fcu_url:=${FCU_URL} \
        > /tmp/launch_uav_resume.log 2>&1 &
    disown
'

# 如果设了参数 (PX4 重启了), 等长一点让它重启完
if grep -q "Reboot" /tmp/px4_param_set.log 2>/dev/null; then
    echo ""
    echo "═══ PX4 重启中, 等 10s ═══"
    sleep 10
fi

echo "(Layer 4 已恢复)"