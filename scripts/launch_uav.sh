#!/usr/bin/env bash
# =============================================================================
# launch_uav.sh — 全链路模式 (SLAM + slam_to_mavros + MAVROS + PX4)
# =============================================================================
# 跑: livox_ros_driver2 + fast_lio + slam_to_mavros + mavros (px4.launch)
# 用: 真机部署, 让 PX4 EKF2 用 SLAM 视觉位姿当主定位
#
# 用法:
#   bash scripts/launch_uav.sh                                                     # 默认参数
#   bash scripts/launch_uav.sh --lidar-ip 192.168.1.150 --fcu-url /dev/ttyUSB0:921600
#   bash scripts/launch_uav.sh --lidar-ip 192.168.1.150 --fcu-url udp://:14540@127.0.0.1:14557
#   CONTAINER=my-drone bash scripts/launch_uav.sh --lidar-ip 192.168.1.150
# =============================================================================

set -eo pipefail

LIDAR_IP="192.168.1.1xx"
FCU_URL="/dev/ttyUSB0:921600"
PX4_USB=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --lidar-ip)     LIDAR_IP="$2"; shift 2 ;;
        --fcu-url)      FCU_URL="$2"; shift 2 ;;
        --device)       PX4_USB="$2"; shift 2 ;;
        -h|--help)      sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "[error] unknown: $1" >&2; exit 2 ;;
    esac
done

CONTAINER="${CONTAINER:-rm-uavsim}"

# 前置检查
if ! docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[error] 容器 $CONTAINER 没在跑, 先: bash scripts/start_uav_container.sh" >&2
    exit 1
fi
if ! docker exec "$CONTAINER" test -f /opt/uav_ws/install/setup.bash; then
    echo "[error] 容器内还没 build, 等 entrypoint 跑完 (看 logs)" >&2
    exit 1
fi

# 如果容器没 mount PX4 USB, 给个提示
if [[ -n "$PX4_USB" ]] && ! docker exec "$CONTAINER" test -e "$PX4_USB"; then
    echo "[warn] 容器内看不到 $PX4_USB, 确认启动时加了 --device=$PX4_USB" >&2
fi

echo "[launch_uav] LIDAR_IP=$LIDAR_IP  FCU_URL=$FCU_URL  container=$CONTAINER"

# 一键 launch 整套 (uav_bringup.launch.py 内部按序拉: livox → fast_lio → slam_to_mavros → mavros)
docker exec -d "$CONTAINER" bash -lc "
    source /opt/uav_ws/install/setup.bash
    export LIVOX_LIDAR_IP=$LIDAR_IP
    export FCU_URL=$FCU_URL
    ros2 launch /opt/uav_ws/uav_bringup.launch.py \
        fcu_url:=\${FCU_URL} \
        > /tmp/launch_uav.log 2>&1 &
    echo \$! > /tmp/launch_uav.pid
"

sleep 3

echo ""
echo "[launch_uav] 启动顺序 (uav_bringup.launch.py 自动处理延时):"
echo "  T+0s : livox_ros_driver2  (Mid-360 UDP)"
echo "  T+1s : fast_lio           (SLAM)"
echo "  T+2s : slam_to_mavros     (桥)"
echo "  T+3s : mavros px4.launch  (MAVLink ↔ PX4)"
echo ""
echo "═══ 实时日志 ═══"
echo "  bash scripts/start_uav_container.sh exec bash -c 'tail -f /tmp/launch_uav.log'"
echo ""
echo "═══ 看连接状态 (PX4 是否连上) ═══"
echo "  bash scripts/start_uav_container.sh exec bash -c 'source /opt/uav_ws/install/setup.bash && ros2 topic echo /mavros/state --once'"
echo "  → 应该看到 connected: true"
echo ""
echo "═══ 看 SLAM 输出频率 ═══"
echo "  bash scripts/start_uav_container.sh exec bash -c 'source /opt/uav_ws/install/setup.bash && ros2 topic hz /Odometry /mavros/vision_pose/pose'"
echo ""
echo "═══ 停 ═══"
echo "  bash scripts/stop_launch.sh uav"
echo ""
echo "═══ 期望最终 topic (约 8 个) ═══"
echo "  /livox/lidar                 /livox/imu"
echo "  /Odometry                    /cloud_registered"
echo "  /mavros/vision_pose/pose     /mavros/vision_speed/speed_twist"
echo "  /mavros/state                /mavros/imu/data"