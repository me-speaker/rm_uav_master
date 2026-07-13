#!/usr/bin/env bash
# =============================================================================
# rm_dep-autostart.sh — 小电脑开机自启 (systemd 调)
# =============================================================================
# 功能:
#   1. 启动容器 (挂 ODIN USB, idle 模式, 不启节点)
#   2. 容器内启 watchdog: 检测 PX4 USB 出现后, 自动 launch_odin_px4.sh
#
# systemd 调: Type=oneshot, RemainAfterExit=yes
# PX4 飞控上电时间晚于小电脑时, watchdog 自动等 + 自动启动链路
#
# 安装:
#   sudo cp scripts/rm_dep-autostart.sh /usr/local/bin/
#   sudo chmod +x /usr/local/bin/rm_dep-autostart.sh
#   sudo cp systemd/rm_dep.service /etc/systemd/system/
#   sudo systemctl daemon-reload
#   sudo systemctl enable rm_dep.service
# =============================================================================

set -eo pipefail

CONTAINER="${CONTAINER:-rm_dep}"
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
WATCHDOG_INTERVAL=5   # 秒

log() { echo "[rm_dep-autostart] $*"; }

# ---- 1. 启容器 (idle 模式, 挂 USB) ---------------------------------------
log "启动容器 $CONTAINER (挂 ODIN USB, idle 模式) ..."

cd "$REPO_DIR"

# 启容器 (如果存在就 start, 不存在就 run)
if docker ps -a --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    log "  容器存在, docker start ..."
    docker start "$CONTAINER"
else
    log "  容器不存在, bash start_uav_container.sh --lidar odin ..."
    bash scripts/start_uav_container.sh --lidar odin
fi

# 等容器 entrypoint build 完 (首次启动可能 1-2 分钟)
log "  等容器内 build (首次可能 1-2 分钟) ..."
BUILD_WAIT=180   # 最长等 3 分钟
BUILD_START=$(date +%s)
while true; do
    if docker exec "$CONTAINER" test -f /opt/uav_ws/install/setup.bash 2>/dev/null; then
        log "  ✓ build 完成"
        break
    fi
    ELAPSED=$(($(date +%s) - BUILD_START))
    if (( ELAPSED > BUILD_WAIT )); then
        log "  ✗ build 超时 ($BUILD_WAIT 秒), 退出"
        exit 1
    fi
    sleep 5
done

# 验证 ODIN USB 在容器里
ODIN_USB=$(docker exec "$CONTAINER" lsusb 2>/dev/null | grep -c 2207:0019 || true)
if [[ "$ODIN_USB" != "1" ]]; then
    log "  ⚠️  容器内没看到 ODIN USB, 链路可能不完整 (PX4 EKF2 fusion 跑不了)"
fi

# ---- 2. 启 watchdog (后台) -----------------------------------------------
log "启动 watchdog (检测 PX4 USB 出现后自动 launch_odin_px4.sh) ..."

# 杀掉旧 watchdog (如果有)
docker exec "$CONTAINER" bash -lc "pkill -f rm_dep-watchdog 2>/dev/null; sleep 1; true"

# watchdog 拷进容器
docker cp "$REPO_DIR/scripts/rm_dep-watchdog.sh" "$CONTAINER:/opt/uav_ws/scripts/rm_dep-watchdog.sh"

# 启动 watchdog (后台, systemd RemainAfterExit=yes 后 watchdog 会继续跑)
docker exec -d "$CONTAINER" bash -lc "
    source /opt/uav_ws/install/setup.bash
    nohup bash /opt/uav_ws/scripts/rm_dep-watchdog.sh \
        > /tmp/rm_dep-watchdog.log 2>&1 &
    echo \$! > /tmp/rm_dep-watchdog.pid
"

log "✓ 自启完成, watchdog PID: $(docker exec $CONTAINER cat /tmp/rm_dep-watchdog.pid 2>/dev/null)"
log ""
log "后续 PX4 接上 USB 后会自动:"
log "  1. 检测到 /dev/ttyACM0"
log "  2. 调用 launch_odin_px4.sh 启 ODIN + mavros + slam_to_mavros"
log "  3. 验证链路"
log "看 watchdog log: docker exec $CONTAINER tail -f /tmp/rm_dep-watchdog.log"