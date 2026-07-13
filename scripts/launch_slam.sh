#!/usr/bin/env bash
# =============================================================================
# launch_slam.sh — 纯 SLAM 模式 (无 MAVROS, 无 PX4)
# =============================================================================
# 跑: livox_ros_driver2 (Mid-360) + fast_lio
# 不跑: slam_to_mavros, mavros (跟 PX4 完全解耦)
# 用途: 测 SLAM 本身, 调 fast_lio 参数, 验证点云输入
#
# 用法:
#   bash scripts/launch_slam.sh                                  # 默认 lidar IP 192.168.1.1xx
#   bash scripts/launch_slam.sh 192.168.1.150                    # 指定 lidar IP
#   CONTAINER=my-drone bash scripts/launch_slam.sh 192.168.1.150 # 自定义容器
#   bash scripts/launch_slam.sh 192.168.1.150 --rviz             # 同时开 rviz (容器需 WITH_GUI=yes)
# =============================================================================

set -eo pipefail

LIDAR_IP="${1:-192.168.1.1xx}"
shift || true

WITH_RVIZ="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rviz|--with-rviz)   WITH_RVIZ="true"; shift ;;
        --no-rviz)            WITH_RVIZ="false"; shift ;;
        -h|--help)            sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "[error] unknown: $1" >&2; exit 2 ;;
    esac
done

CONTAINER="${CONTAINER:-rm_dep}"

# 前置检查
if ! docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[error] 容器 $CONTAINER 没在跑, 先: bash scripts/start_uav_container.sh" >&2
    exit 1
fi
if ! docker exec "$CONTAINER" test -f /opt/uav_ws/install/setup.bash; then
    echo "[error] 容器内还没 build, 等 entrypoint 跑完 (看 logs)" >&2
    exit 1
fi

echo "[launch_slam] LIDAR_IP=$LIDAR_IP  rviz=$WITH_RVIZ  container=$CONTAINER"

# 用 detached exec 起, 后台跑 4 个 SLAM 节点:
#   1. livox_ros_driver2  (Mid-360 UDP → /livox/lidar, /livox/imu)
#   2. fast_lio           (SLAM → /Odometry, /cloud_registered)
#   3. slam_to_mavros     (/Odometry → /mavros/vision_pose/pose)  ← 即使没 PX4 也跑
#   4. (可选) rviz2        (可视化)
# 注意: 这里特意不拉 mavros, 跟 PX4 完全解耦
docker exec -d "$CONTAINER" bash -lc "
    source /opt/uav_ws/install/setup.bash
    export LIVOX_LIDAR_IP=$LIDAR_IP
    # 1. livox
    ros2 launch livox_ros_driver2 msg_MID360_launch.py \
        xfer_format:=0 multi_topic:=0 data_src:=0 \
        publish_freq:=10.0 output_data_type:=0 \
        frame_id:=livox_frame \
        > /tmp/launch_slam_livox.log 2>&1 &
    sleep 2
    # 2. fast_lio
    ros2 launch fast_lio mapping.launch.py \
        config_file:=mid360.yaml rviz:=false use_sim_time:=false \
        > /tmp/launch_slam_fastlio.log 2>&1 &
    sleep 1
    # 3. slam_to_mavros 桥
    ros2 launch slam_to_mavros slam_to_mavros.launch.py \
        > /tmp/launch_slam_bridge.log 2>&1 &
    $( [[ "$WITH_RVIZ" == "true" ]] && echo "
    sleep 2
    DISPLAY=:99 ros2 launch fast_lio mapping.launch.py rviz:=true use_sim_time:=false \
        > /tmp/launch_slam_rviz.log 2>&1 &
    " )
    echo 'launched'
" 2>&1

sleep 4

echo ""
echo "[launch_slam] 已启动 3 个节点 (livox + fast_lio + slam_to_mavros), rviz=$WITH_RVIZ"
echo ""
echo "═══ 实时日志 ═══"
echo "  bash scripts/start_uav_container.sh exec bash -c 'tail -f /tmp/launch_slam_*.log'"
echo ""
echo "═══ 看 topic ═══"
echo "  bash scripts/start_uav_container.sh exec bash -c 'source /opt/uav_ws/install/setup.bash && ros2 topic list'"
echo ""
echo "═══ 停 ═══"
echo "  bash scripts/stop_launch.sh slam"
echo ""
echo "═══ 期望输出 topic ═══"
echo "  /livox/lidar               PointCloud2     (Mid-360 点云)"
echo "  /livox/imu                 Imu             (Mid-360 内置 IMU)"
echo "  /Odometry                  nav_msgs/Odometry   (FAST-LIO 输出)"
echo "  /cloud_registered          PointCloud2     (FAST-LIO 注册后的点云)"
echo "  /mavros/vision_pose/pose   PoseStamped     (slam_to_mavros 输出, 没 PX4 也无害)"