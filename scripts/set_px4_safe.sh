#!/usr/bin/env bash
# =============================================================================
# set_px4_safe.sh — 安全写 PX4 参数 (停 mavros → pymavlink 设 → 重启 mavros)
# =============================================================================
# pymavlink 跟 mavros 抢 /dev/ttyACM0 必然失败. 这个 wrapper:
#   1. 停 mavros (跟 slam_to_mavros)
#   2. 调 set_px4_mavlink.py 设 PX4 参数 (不抢串口)
#   3. 重启 mavros + slam_to_mavros
#
# 注意: set_px4_mavlink.py 里的 reboot 命令会 kill mavros USB deadlock,
#       所以这个 wrapper 在 reboot 后会 wait+verify mavros 起来
#
# 用法:
#   bash scripts/set_px4_safe.sh --show    # 只看参数 (不重启 mavros)
#   bash scripts/set_px4_safe.sh          # 设参数 + reboot mavros-safe
# =============================================================================
set -e

CONTAINER="${CONTAINER:-rm_dep}"

if ! docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[error] 容器 $CONTAINER 没在跑" >&2
    exit 1
fi

# 确保 pymavlink 在容器里
if ! docker exec "$CONTAINER" bash -c 'python3 -c "import pymavlink" 2>/dev/null'; then
    bash "$(dirname "$0")/ensure_pymavlink.sh" >/dev/null
fi

# --show 也需要先停 mavros (pymavlink 要独占 /dev/ttyACM0)
echo "═══ 停 mavros + slam_to_mavros ═══"
docker exec "$CONTAINER" bash -c '
    pkill -9 -f mavros_node 2>/dev/null || true
    pkill -9 -f slam_to_mavros_node 2>/dev/null || true
    sleep 3
'
echo "(mavros + slam 停了, host_sdk 保留)"

# 设 / 读 参数
echo ""
echo "═══ pymavlink 操作 ═══"
docker exec -i "$CONTAINER" python3 /opt/uav_ws/scripts/set_px4_mavlink.py "$@" 2>&1 | tail -20

# 等 PX4 重启完
echo ""
echo "═══ 等 PX4 重启 + 重启 mavros ═══"
sleep 10

# 检查 PX4 USB 是否回来
if ! docker exec "$CONTAINER" bash -c 'lsusb 2>/dev/null | grep -q 3163'; then
    echo "[warn] PX4 USB 还没回来, 再等 5s"
    sleep 5
fi

# 重启 mavros + slam_to_mavros
echo ""
echo "═══ 重启 Layer 4 ═══"
docker exec -d "$CONTAINER" bash -c '
    source /opt/uav_ws/install/setup.bash
    export FCU_URL=/dev/ttyACM0:921600
    ros2 launch /opt/uav_ws/scripts/uav_bringup.launch.py \
        lidar:=odin fcu_url:=${FCU_URL} \
        > /tmp/launch_uav.log 2>&1 &
    disown
'

# 等 mavros 起来
for i in 1 2 3 4 5; do
    sleep 3
    if docker exec "$CONTAINER" bash -c 'source /opt/uav_ws/install/setup.bash && timeout 2 ros2 topic echo /mavros/state --once 2>/dev/null | grep -q "connected: true"'; then
        echo ""
        echo "✅ mavros 起来了, connected"
        break
    fi
    echo "等 mavros ($i/5)..."
done

echo ""
echo "═══ 验证参数 ═══"
docker exec "$CONTAINER" python3 /opt/uav_ws/scripts/set_px4_mavlink.py --show