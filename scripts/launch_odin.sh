#!/usr/bin/env bash
# =============================================================================
# launch_odin.sh — 纯 ODIN 模式 (无 MAVROS, 无 PX4, 无 fast_lio)
# =============================================================================
# 跑: odin_ros_driver (host_sdk_sample)
#     → /odin1/cloud_raw, /odin1/cloud_slam, /odin1/imu, /odin1/odometry
#     (ODIN 自带 SLAM, 直接出 /odin1/odometry, 不需要 fast_lio)
# 不跑: slam_to_mavros, mavros
# 用途: 测 ODIN 本身, 看自带 SLAM 效果, 调 control_command.yaml
#
# 用法:
#   bash scripts/launch_odin.sh                            # 用默认 config
#   bash scripts/launch_odin.sh --rviz                     # 同时开 rviz (容器需 GUI)
#   CONTAINER=my-drone bash scripts/launch_odin.sh
#
# 期望输出 topic:
#   /odin1/cloud_raw       PointCloud2     (DTOF 原始点云)
#   /odin1/cloud_slam      PointCloud2     (ODIN SLAM 后点云)
#   /odin1/imu             Imu             (ODIN 内置 IMU)
#   /odin1/odometry        Odometry        (⭐ ODIN 自带 SLAM 输出)
#   /odin1/image           Image           (RGB 图像)
#   /odin1/cloud_render    PointCloud2     (彩色点云)
# =============================================================================

set -eo pipefail

WITH_RVIZ="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rviz|--with-rviz)   WITH_RVIZ="true"; shift ;;
        --no-rviz)            WITH_RVIZ="false"; shift ;;
        -h|--help)            sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "[error] unknown: $1" >&2; exit 2 ;;
    esac
done

CONTAINER="${CONTAINER:-rm-uavsim}"

# 前置检查
if ! docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[error] 容器 $CONTAINER 没在跑, 先: bash scripts/start_uav_container.sh --lidar odin" >&2
    exit 1
fi
if ! docker exec "$CONTAINER" test -f /opt/uav_ws/install/setup.bash; then
    echo "[error] 容器内还没 build, 等 entrypoint 跑完 (看 logs)" >&2
    exit 1
fi

# 看 ODIN USB 是否在容器里
ODIN_USB_CHECK=$(docker exec "$CONTAINER" bash -c 'lsusb 2>/dev/null | grep -i "2207:0019\|rockchip" || echo NO_ODIN_USB')
echo "[launch_odin] ODIN USB 检测: $ODIN_USB_CHECK"
if [[ "$ODIN_USB_CHECK" == *"NO_ODIN_USB" ]]; then
    echo "[warn] 容器内没看到 ODIN USB 设备 (vendor 2207:0019)"
    echo "       重启容器时确保加了 --lidar odin (自动检测) 或 --odin-usb <bus>/<dev>"
    echo "       节点仍会启动, 但会因找不到设备立即退出"
fi

echo "[launch_odin] rviz=$WITH_RVIZ  container=$CONTAINER"

# 启 ODIN + slam_to_mavros 桥 (ODIN 自带 SLAM → /mavros/vision_pose/pose, 没 PX4 也无害)
docker exec -d "$CONTAINER" bash -lc "
    source /opt/uav_ws/install/setup.bash
    # 1. ODIN 主驱动
    ros2 launch odin_ros_driver odin1_ros2.launch.py \
        > /tmp/launch_odin.log 2>&1 &
    echo \$! > /tmp/launch_odin.pid
    sleep 2
    # 2. slam_to_mavros 桥 (订阅 /odin1/odometry)
    ros2 launch slam_to_mavros slam_to_mavros.launch.py \
        odom_topic:=/odin1/odometry \
        > /tmp/launch_odin_bridge.log 2>&1 &
    sleep 1
    $( [[ "$WITH_RVIZ" == "true" ]] && echo "
    sleep 2
    DISPLAY=:99 ros2 run rviz2 rviz2 -d /opt/uav_ws/install/odin_ros_driver/share/odin_ros_driver/config/odin_ros2.rviz \
        > /tmp/launch_odin_rviz.log 2>&1 &
    " )
    echo 'launched'
" 2>&1

sleep 4

echo ""
echo "[launch_odin] 节点已启: host_sdk_sample + (3 个辅助节点) + slam_to_mavros"
echo ""
echo "═══ 实时日志 ═══"
echo "  ODIN:    bash scripts/start_uav_container.sh exec bash -c 'tail -f /tmp/launch_odin.log'"
echo "  桥:      bash scripts/start_uav_container.sh exec bash -c 'tail -f /tmp/launch_odin_bridge.log'"
echo ""
echo "═══ 看 topic ═══"
echo "  bash scripts/start_uav_container.sh exec bash -c 'source /opt/uav_ws/install/setup.bash && ros2 topic list'"
echo ""
echo "═══ 看 ODIN 自带 SLAM 频率 ═══"
echo "  bash scripts/start_uav_container.sh exec bash -c 'source /opt/uav_ws/install/setup.bash && ros2 topic hz /odin1/odometry /odin1/cloud_slam'"
echo ""
echo "═══ 停 ═══"
echo "  bash scripts/stop_launch.sh odin"
echo ""
echo "═══ 期望 topic ═══"
echo "  /odin1/cloud_raw        PointCloud2"
echo "  /odin1/cloud_slam       PointCloud2"
echo "  /odin1/imu              Imu"
echo "  /odin1/odometry         Odometry      ⭐ 自带 SLAM 输出"
echo "  /odin1/image            Image"
echo "  /mavros/vision_pose/pose PoseStamped  (slam_to_mavros 转发, 没 PX4 也无害)"