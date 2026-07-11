#!/usr/bin/env bash
# =============================================================================
# stop_launch.sh — 停掉 launch_slam / launch_uav / launch_uav_gui 启的节点
# =============================================================================
# 用法:
#   bash scripts/stop_launch.sh                  # 停所有 (slam + uav + uav-gui)
#   bash scripts/stop_launch.sh slam             # 只停 SLAM
#   bash scripts/stop_launch.sh uav              # 只停 uav 链路
#   bash scripts/stop_launch.sh uav-gui          # 只停 uav-gui (含 GUI)
#   bash scripts/stop_launch.sh --all            # 同不传参
# =============================================================================

set -eo pipefail

TARGET="${1:-all}"

CONTAINER="${CONTAINER:-rm-uavsim}"

if ! docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[error] 容器 $CONTAINER 没在跑"; exit 1
fi

docker exec "$CONTAINER" bash -lc "
    case \"$TARGET\" in
        slam)
            pkill -f 'livox_ros_driver2_node' 2>/dev/null
            pkill -f 'fastlio_mapping'        2>/dev/null
            pkill -f 'slam_to_mavros_node'    2>/dev/null
            pkill -f 'rviz2'                  2>/dev/null
            ;;
        odin)
            pkill -f 'host_sdk_sample'        2>/dev/null
            pkill -f 'pcd2depth_ros2_node'    2>/dev/null
            pkill -f 'cloud_reprojection_ros2_node' 2>/dev/null
            pkill -f 'image_overlay_node'     2>/dev/null
            pkill -f 'slam_to_mavros_node'    2>/dev/null
            pkill -f 'rviz2'                  2>/dev/null
            ;;
        uav)
            pkill -f 'mavros_node'            2>/dev/null
            pkill -f 'livox_ros_driver2_node' 2>/dev/null
            pkill -f 'fastlio_mapping'        2>/dev/null
            pkill -f 'host_sdk_sample'        2>/dev/null
            pkill -f 'pcd2depth_ros2_node'    2>/dev/null
            pkill -f 'cloud_reprojection_ros2_node' 2>/dev/null
            pkill -f 'image_overlay_node'     2>/dev/null
            pkill -f 'slam_to_mavros_node'    2>/dev/null
            ;;
        uav-gui)
            pkill -f 'rviz2'                  2>/dev/null
            pkill -f 'novnc_proxy'            2>/dev/null
            pkill -f 'websockify'             2>/dev/null
            pkill -f 'x11vnc'                 2>/dev/null
            pkill -f 'Xvfb'                   2>/dev/null
            pkill -f 'mavros_node'            2>/dev/null
            pkill -f 'livox_ros_driver2_node' 2>/dev/null
            pkill -f 'fastlio_mapping'        2>/dev/null
            pkill -f 'host_sdk_sample'        2>/dev/null
            pkill -f 'slam_to_mavros_node'    2>/dev/null
            ;;
        px4-test|px4_only)
            pkill -f 'mavros_node'            2>/dev/null
            pkill -f 'fake_odom_publisher'    2>/dev/null
            pkill -f 'slam_to_mavros_node'    2>/dev/null
            ;;
        all|--all)
            pkill -f 'mavros_node'            2>/dev/null
            pkill -f 'livox_ros_driver2_node' 2>/dev/null
            pkill -f 'fastlio_mapping'        2>/dev/null
            pkill -f 'host_sdk_sample'        2>/dev/null
            pkill -f 'pcd2depth_ros2_node'    2>/dev/null
            pkill -f 'cloud_reprojection_ros2_node' 2>/dev/null
            pkill -f 'image_overlay_node'     2>/dev/null
            pkill -f 'slam_to_mavros_node'    2>/dev/null
            pkill -f 'rviz2'                  2>/dev/null
            pkill -f 'novnc_proxy'            2>/dev/null
            pkill -f 'x11vnc'                 2>/dev/null
            pkill -f 'Xvfb'                   2>/dev/null
            ;;
        *) echo 'usage: stop_launch.sh [slam|uav|uav-gui|all]'; exit 2 ;;
    esac
    sleep 1
    # 残留清理
    pkill -9 -f 'mavros_node'            2>/dev/null
    pkill -9 -f 'livox_ros_driver2_node' 2>/dev/null
    pkill -9 -f 'fastlio_mapping'        2>/dev/null
    pkill -9 -f 'slam_to_mavros_node'    2>/dev/null
    pkill -9 -f 'rviz2'                  2>/dev/null
    pkill -9 -f 'novnc_proxy'            2>/dev/null
    pkill -9 -f 'x11vnc'                 2>/dev/null
    pkill -9 -f 'Xvfb'                   2>/dev/null
    echo done
" 2>&1

echo "[stop_launch] $TARGET 节点已停"
echo ""
echo "  确认: bash scripts/start_uav_container.sh exec bash -c 'pgrep -af \"livox|fast_lio|mavros|host_sdk|rviz2\" || echo clean'"