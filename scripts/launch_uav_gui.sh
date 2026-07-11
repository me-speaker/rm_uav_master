#!/usr/bin/env bash
# =============================================================================
# launch_uav_gui.sh — 全链路 + GUI 转发 (浏览器 noVNC 看 rviz)
# =============================================================================
# 跑: 全链路 (同 launch_uav.sh) + 容器内 Xvfb + x11vnc + noVNC
# 用: 开发调试, 远程看 rviz, 不需要 X server
#
# 流程:
#   1. 在容器后台启 Xvfb :99 + x11vnc :5999 + noVNC http :6080
#   2. 启全链路 launch (livox + fast_lio + slam_to_mavros + mavros)
#   3. 启 rviz2 (在 DISPLAY=:99 上)
#   4. 浏览器开: http://<host-ip>:6080/vnc.html
#
# 用法:
#   bash scripts/launch_uav_gui.sh --lidar-ip 192.168.1.150
#   bash scripts/launch_uav_gui.sh --lidar-ip 192.168.1.150 --novnc-port 8080
#
# 注意: 容器启动时必须 -p 6080:6080 (noVNC http) 和 -p 5999:5999 (raw VNC)
#       start_uav_container.sh --bringup-gui 已自动加这些端口
# =============================================================================

set -eo pipefail

LIDAR_IP="192.168.1.1xx"
FCU_URL="/dev/ttyUSB0:921600"
NOVNC_PORT="6080"
VNC_PORT="5999"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --lidar-ip)     LIDAR_IP="$2"; shift 2 ;;
        --fcu-url)      FCU_URL="$2"; shift 2 ;;
        --novnc-port)   NOVNC_PORT="$2"; shift 2 ;;
        --vnc-port)     VNC_PORT="$2"; shift 2 ;;
        -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "[error] unknown: $1" >&2; exit 2 ;;
    esac
done

CONTAINER="${CONTAINER:-rm-uavsim}"

# 前置检查
if ! docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[error] 容器 $CONTAINER 没在跑, 先: bash scripts/start_uav_container.sh --bringup-gui" >&2
    exit 1
fi
if ! docker exec "$CONTAINER" test -f /opt/uav_ws/install/setup.bash; then
    echo "[error] 容器内还没 build" >&2; exit 1
fi

echo "[launch_uav_gui] LIDAR_IP=$LIDAR_IP  FCU_URL=$FCU_URL  noVNC=:${NOVNC_PORT}"
echo ""

# 1. 启 Xvfb + x11vnc + noVNC (容器内)
echo "[1/3] 启 Xvfb + x11vnc + noVNC ..."
docker exec -d "$CONTAINER" bash -lc "
    source /opt/uav_ws/install/setup.bash
    export NOVNC_PORT=$NOVNC_PORT VNC_PORT=$VNC_PORT VNC_DISPLAY=:99
    nohup start_uav_gui.sh > /tmp/launch_gui.log 2>&1 &
    echo \$! > /tmp/launch_gui.pid
"
sleep 4
if docker exec "$CONTAINER" pgrep -f "Xvfb :99" >/dev/null; then
    echo "  ✅ Xvfb :99 在跑"
else
    echo "  ❌ Xvfb 没起来, 看 /tmp/launch_gui.log"
    docker exec "$CONTAINER" cat /tmp/launch_gui.log 2>&1 | sed 's/^/    /'
    exit 1
fi

# 2. 启全链路 (livox → fast_lio → slam_to_mavros → mavros)
echo "[2/3] 启全链路 launch ..."
docker exec -d "$CONTAINER" bash -lc "
    source /opt/uav_ws/install/setup.bash
    export LIVOX_LIDAR_IP=$LIDAR_IP FCU_URL=$FCU_URL
    ros2 launch /opt/uav_ws/uav_bringup.launch.py fcu_url:=\${FCU_URL} \
        > /tmp/launch_uav_gui_chain.log 2>&1 &
    echo \$! > /tmp/launch_uav_chain.pid
"
sleep 4

# 3. 启 rviz2 (在 DISPLAY=:99 上)
echo "[3/3] 启 rviz2 ..."
docker exec -d "$CONTAINER" bash -lc "
    source /opt/uav_ws/install/setup.bash
    DISPLAY=:99 nohup ros2 launch fast_lio mapping.launch.py rviz:=true use_sim_time:=false \
        > /tmp/launch_uav_rviz.log 2>&1 &
    echo \$! > /tmp/launch_uav_rviz.pid
"
sleep 3

# 获取 host IP (给用户访问 noVNC 用)
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<host-ip>")

echo ""
echo "═══════════════════════════════════════════════════════"
echo "✅ 全部启起来了, 浏览器打开 noVNC 看 rviz:"
echo "   http://${HOST_IP}:${NOVNC_PORT}/vnc.html"
echo ""
echo "   或用 VNC 客户端直连:  ${HOST_IP}:${VNC_PORT}"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "═══ 实时日志 ═══"
echo "  GUI:    bash scripts/start_uav_container.sh exec bash -c 'tail -f /tmp/launch_gui.log'"
echo "  链路:   bash scripts/start_uav_container.sh exec bash -c 'tail -f /tmp/launch_uav_gui_chain.log'"
echo "  rviz:   bash scripts/start_uav_container.sh exec bash -c 'tail -f /tmp/launch_uav_rviz.log'"
echo ""
echo "═══ 停 ═══"
echo "  bash scripts/stop_launch.sh uav-gui"