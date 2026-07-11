#!/usr/bin/env bash
# uav_entrypoint.sh — 容器内快捷入口 (放 /usr/local/bin/)
# 默认 CMD 是 bash; 用户可手动跑 uav_bringup / uav_gui
set -e
source /opt/ros/${ROS_DISTRO:-humble}/setup.bash
source ${UAV_WS:-/opt/uav_ws}/install/setup.bash
echo "[uav_entrypoint] ROS_DISTRO=$ROS_DISTRO  UAV_WS=${UAV_WS:-/opt/uav_ws}"
echo "[uav_entrypoint] 常用命令:"
echo "    ros2 launch /opt/uav_ws/uav_bringup.launch.py"
echo "    ros2 launch /opt/uav_ws/uav_bringup.launch.py with_rviz:=true"
echo "    start_uav_gui.sh   # 浏览器 noVNC"
exec "$@"