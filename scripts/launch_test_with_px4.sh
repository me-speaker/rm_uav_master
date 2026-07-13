#!/usr/bin/env bash
# =============================================================================
# launch_test_with_px4.sh — PX4-only 全链路测试 (无 LiDAR 硬件)
# =============================================================================
# 用 fake_odom_publisher 替代真实 SLAM, 验证:
#   fake /Odometry -> slam_to_mavros -> /mavros/vision_pose/pose
#                                       -> mavros -> PX4 EKF2 (真硬件)
#
# 跑前确认:
#   1. PX4 接上 USB, 启动后心跳在
#   2. 容器已起: bash scripts/start_uav_container.sh  (默认 idle)
#
# 用法:
#   bash scripts/launch_test_with_px4.sh                       # 默认参数
#   bash scripts/launch_test_with_px4.sh --fcu-url /dev/ttyACM0:921600
#   bash scripts/launch_test_with_px4.sh --motion-mode circle  # 圆周运动
#   bash scripts/launch_test_with_px4.sh --motion-mode hover   # 原地悬浮
#
# 期望 QGroundControl 看:
#   - drone 在地图上"原地抖动/小幅度运动" (fused position)
#   - ESTIMATOR STATUS: vision pose fused ✅
#   - SYS_STATUS: 正常
# =============================================================================

set -eo pipefail

MOTION_MODE="hover"
FCU_URL="/dev/ttyUSB0:921600"
FAKE_RATE="50.0"
NOISE_POS="0.005"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --motion-mode)   MOTION_MODE="$2"; shift 2 ;;
        --fcu-url)       FCU_URL="$2"; shift 2 ;;
        --rate)          FAKE_RATE="$2"; shift 2 ;;
        --noise)         NOISE_POS="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "[error] unknown: $1" >&2; exit 2 ;;
    esac
done

CONTAINER="${CONTAINER:-rm_dep}"

if ! docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[error] 容器 $CONTAINER 没在跑, 先: bash scripts/start_uav_container.sh" >&2
    exit 1
fi
if ! docker exec "$CONTAINER" test -f /opt/uav_ws/install/setup.bash; then
    echo "[error] 容器内还没 build" >&2; exit 1
fi

# 检查 PX4 USB
PX4_DEV=$(echo "$FCU_URL" | cut -d: -f1)
if ! docker exec "$CONTAINER" test -e "$PX4_DEV"; then
    echo "[warn] 容器内看不到 $PX4_DEV (确认启动时加了 --device=$PX4_DEV)" >&2
fi

echo "[launch_test_with_px4] motion=$MOTION_MODE  fcu=$FCU_URL  rate=${FAKE_RATE}Hz  container=$CONTAINER"
echo ""

# 一键启动: uav_bringup.launch.py lidar:=fake (内部会拉 fake_odom + slam_to_mavros + mavros)
docker exec -d "$CONTAINER" bash -lc "
    source /opt/uav_ws/install/setup.bash
    export FCU_URL=$FCU_URL
    ros2 launch /opt/uav_ws/scripts/uav_bringup.launch.py \
        lidar:=fake \
        fcu_url:=\${FCU_URL} \
        fake_motion_mode:=$MOTION_MODE \
        fake_rate_hz:=$FAKE_RATE \
        fake_noise_pos_m:=$NOISE_POS \
        > /tmp/launch_px4_test.log 2>&1 &
    echo \$! > /tmp/launch_px4_test.pid
"

sleep 5

echo "[launch_test_with_px4] 启动顺序:"
echo "  T+0s : fake_odom_publisher   (产 /Odometry @ ${FAKE_RATE}Hz, mode=$MOTION_MODE)"
echo "  T+0s : slam_to_mavros        (桥 -> /mavros/vision_pose/pose)"
echo "  T+3s : mavros px4.launch     (连 PX4)"
echo ""
echo "═══ 实时日志 ═══"
echo "  bash scripts/start_uav_container.sh exec bash -c 'tail -f /tmp/launch_px4_test.log'"
echo ""
echo "═══ 验证 PX4 是否收到 vision pose ═══"
echo "  1. mavros state (期望 connected=true):"
echo "     bash scripts/start_uav_container.sh exec bash -c 'source /opt/uav_ws/install/setup.bash && ros2 topic echo /mavros/state --once'"
echo ""
echo "  2. /mavros/vision_pose/pose 频率 (期望 ~${FAKE_RATE}Hz):"
echo "     bash scripts/start_uav_container.sh exec bash -c 'source /opt/uav_ws/install/setup.bash && timeout 3 ros2 topic hz /mavros/vision_pose/pose'"
echo ""
echo "  3. PX4 端的 vision 融合状态 (期望 'fused'):"
echo "     bash scripts/start_uav_container.sh exec bash -c 'source /opt/uav_ws/install/setup.bash && ros2 service call /mavros/cmd/command std_srvs/srv/Trigger 2>/dev/null'"
echo ""
echo "  4. QGroundControl 看 drone 位置 (期望在地图上小幅运动)"
echo ""
echo "═══ 停 ═══"
echo "  bash scripts/stop_launch.sh px4-test"