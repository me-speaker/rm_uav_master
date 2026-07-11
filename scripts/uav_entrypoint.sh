#!/usr/bin/env bash
# uav_entrypoint.sh — 容器内快捷入口 (放 /usr/local/bin/)
# 默认 CMD 是 bash; 用户可手动跑 uav_bringup / uav_gui
set -e
source /opt/ros/${ROS_DISTRO:-humble}/setup.bash
source ${UAV_WS:-/opt/uav_ws}/install/setup.bash

# 装 pymavlink + pyserial (如果还没装) — set_px4_mavlink.py 用
# mavros 的 PX4 param service 在 humble 版本 broken, 我们走原始 MAVLink 设参
if ! python3 -c "import pymavlink" 2>/dev/null; then
    echo "[uav_entrypoint] 安装 pymavlink + pyserial (约 30s) ..."
    if ! command -v pip3 >/dev/null; then
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends python3-pip >/dev/null
    fi
    # 老 pip 没有 --break-system-packages, 自动判断
    if pip3 install --help 2>&1 | grep -q -- "--break-system-packages"; then
        pip3 install --break-system-packages --quiet pymavlink pyserial
    else
        pip3 install --quiet pymavlink pyserial
    fi
    echo "[uav_entrypoint] pymavlink OK"
fi

echo "[uav_entrypoint] ROS_DISTRO=$ROS_DISTRO  UAV_WS=${UAV_WS:-/opt/uav_ws}"
echo "[uav_entrypoint] 常用命令:"
echo "    ros2 launch /opt/uav_ws/scripts/uav_bringup.launch.py"
echo "    ros2 launch /opt/uav_ws/scripts/uav_bringup.launch.py with_rviz:=true"
echo "    start_uav_gui.sh   # 浏览器 noVNC"
echo "    python3 /opt/uav_ws/scripts/set_px4_mavlink.py   # 设 PX4 vision-only 参数"
exec "$@"