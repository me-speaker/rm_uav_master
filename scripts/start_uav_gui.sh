#!/usr/bin/env bash
# =============================================================================
# start_uav_gui.sh — 容器内 GUI 转发栈
# =============================================================================
# 在容器内跑. 启 Xvfb (虚拟 display) + x11vnc + noVNC (websockify),
# 这样主机不用有 X server, 浏览器直接打开
#   http://<host-ip>:6080/vnc.html
# 就能看到容器里的 rviz2 / fast_lio 可视化界面.
#
# 默认端口:
#   VNC_PORT=5999    x11vnc (raw VNC, 可用任意 VNC 客户端连)
#   NOVNC_PORT=6080  noVNC (websockify, 浏览器访问)
#   VNC_DISPLAY=:99  Xvfb display
#
# 退出: Ctrl+C (前台的 x11vnc 终止时会自动 cleanup)
# =============================================================================

set -e

VNC_DISPLAY="${VNC_DISPLAY:-:99}"
VNC_PORT="${VNC_PORT:-5999}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
NOVNC_WEB=/opt/novnc
GEOMETRY="${GEOMETRY:-1920x1080x24}"

echo "[gui] Xvfb display=$VNC_DISPLAY  vnc_port=$VNC_PORT  novnc_port=$NOVNC_PORT"

# ---- 清理 stale ---------------------------------------------------------
pkill -9 -f "Xvfb ${VNC_DISPLAY}"     2>/dev/null || true
pkill -9 -f "x11vnc.*:${VNC_DISPLAY#:}" 2>/dev/null || true
pkill -9 -f "websockify.*${NOVNC_PORT}" 2>/dev/null || true
rm -f /tmp/.X${VNC_DISPLAY#:}-lock /tmp/.X11-unix/X${VNC_DISPLAY#:} 2>/dev/null || true

# ---- Xvfb 虚拟 display --------------------------------------------------
Xvfb ${VNC_DISPLAY} -screen 0 ${GEOMETRY} -nolisten tcp &
XVFB_PID=$!
sleep 1

# ---- x11vnc -------------------------------------------------------------
DISPLAY=${VNC_DISPLAY} x11vnc \
    -display ${VNC_DISPLAY} \
    -rfbport ${VNC_PORT} \
    -forever -shared \
    -nopw \
    -bg \
    -o /tmp/x11vnc.log
sleep 1

# ---- noVNC / websockify --------------------------------------------------
${NOVNC_WEB}/utils/novnc_proxy \
    --vnc localhost:${VNC_PORT} \
    --listen ${NOVNC_PORT} \
    --web ${NOVNC_WEB} \
    > /tmp/novnc.log 2>&1 &
NOVNC_PID=$!
sleep 1

echo "[gui] ready"
echo "  VNC     : localhost:${VNC_PORT}   (or <host-ip>:${VNC_PORT} via docker -p)"
echo "  noVNC   : http://localhost:${NOVNC_PORT}/vnc.html  (or http://<host-ip>:${NOVNC_PORT}/vnc.html)"
echo ""
echo "  在容器内另开终端跑:  ros2 launch /opt/uav_ws/uav_bringup.launch.py with_rviz:=true"
echo ""

cleanup() {
    echo ""
    echo "[gui] cleanup ..."
    kill $NOVNC_PID 2>/dev/null || true
    pkill -9 -f "x11vnc.*:${VNC_DISPLAY#:}" 2>/dev/null || true
    kill $XVFB_PID 2>/dev/null || true
    rm -f /tmp/.X${VNC_DISPLAY#:}-lock /tmp/.X11-unix/X${VNC_DISPLAY#:} 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# 阻塞等任意后台进程结束
wait -n $XVFB_PID $NOVNC_PID 2>/dev/null || true
cleanup