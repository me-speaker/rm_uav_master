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

set -uo pipefail  # 不要 -e, 出错不退出 (要一直跑 tail -F)

CONTAINER="${CONTAINER:-rm_dep}"
# 脚本可能在 /usr/local/bin/ 但项目实际在 ~/rm_ws, 不要用 dirname 推断
# 直接找 watchdog 路径 (机载电脑固定路径)
WATCHDOG_HOST="/home/<drone-user>/rm_ws/scripts/rm_dep-watchdog.sh"
LAUNCH_HOST="/home/<drone-user>/rm_ws/scripts/launch_odin_px4.sh"
REPO_DIR="/home/<drone-user>/rm_ws"  # for docker cp 路径
WATCHDOG_INTERVAL=5   # 秒

log() { echo "[rm_dep-autostart] $*"; }

# ---- 1. 启容器 (idle 模式, 挂 USB) ---------------------------------------
log "启动容器 $CONTAINER (挂 ODIN USB, idle 模式) ..."

cd "$REPO_DIR"

# 启容器 (如果存在就 start, 不存在就 run)
if docker ps -a --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    log "  容器存在, docker start (retry loop, 等 PX4 USB) ..."
    # PX4 飞控可能上电晚于小电脑, /dev/ttyACM0 还没出现, docker start 会失败
    # 等 5s 重试, 最多 60s (PX4 还没上电就等 watchdog 检测)
    for i in {1..12}; do
        if docker start "$CONTAINER" 2>/dev/null; then
            log "  ✓ 容器 start 成功 (第 $i 次)"
            break
        fi
        if [[ $i -eq 12 ]]; then
            log "  ⚠️  60s 内 PX4 USB 还没出现, 容器 start 失败, 继续 (watchdog 会接管)"
        fi
        sleep 5
    done
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

# ---- 2. 启 watchdog (host 跑, 检测 /dev/ttyACM0 + 调容器内 launch) -------
log "启动 watchdog (host 跑, 检测 /dev/ttyACM0 + 调 launch_odin_px4.sh) ..."

# 杀掉旧 watchdog (host + 容器)
pkill -f rm_dep-watchdog 2>/dev/null || true
docker exec "$CONTAINER" bash -lc "pkill -f rm_dep-watchdog 2>/dev/null; sleep 1; true" 2>/dev/null || true

# watchdog 拷进容器 (供 watchdog exec launch_odin_px4.sh)
docker cp "$WATCHDOG_HOST" "$CONTAINER:/opt/uav_ws/scripts/rm_dep-watchdog.sh"
docker cp "$LAUNCH_HOST" "$CONTAINER:/opt/uav_ws/scripts/launch_odin_px4.sh"

# health_led.py 也拷到 host /usr/local/bin/ (watchdog 在 host 跑, 调它 trigger 启动信号灯)
HEALTH_LED_HOST="/home/<drone-user>/rm_ws/scripts/health_led.py"
sudo cp "$HEALTH_LED_HOST" /usr/local/bin/health_led.py
sudo chmod +x /usr/local/bin/health_led.py

# 启动 watchdog 在 host (detached, 完全脱离 systemd service 进程组)
# 写日志到 /var/log/uav/watchdog-YYYYMMDD.log (systemd 启的脚本无权写 /var/log/uav 的话, 自动 fallback)
WD_LOG_DIR="${LOG_DIR:-/var/log/uav}"
mkdir -p "$WD_LOG_DIR" 2>/dev/null || WD_LOG_DIR="/tmp"
WD_LOG_FILE="$WD_LOG_DIR/watchdog-$(date +%Y%m%d).log"
nohup setsid bash "$WATCHDOG_HOST" \
    "$CONTAINER" >"$WD_LOG_FILE" 2>&1 < /dev/null &
WD_PID=$!
disown
echo "$WD_PID" > /var/run/rm_dep-watchdog.pid 2>/dev/null || true

log "✓ 自启完成, watchdog host PID: $WD_PID, log: $WD_LOG_FILE"
log ""
log "后续 PX4 接上 USB 后会自动:"
log "  1. 检测到 /dev/ttyACM0"
log "  2. 在容器内调 launch_odin_px4.sh 启 ODIN + mavros + slam_to_mavros"
log "  3. 验证链路"
log "看 watchdog log: tail -f $WD_LOG_FILE"

# systemd 需要 service 进程一直跑着 (Type=simple) 才能保持 active
# watchdog 已经 setsid detach, 不会因为 autostart 退出而死
# autostart 用 sleep infinity 永远阻塞, 直到 systemd kill (systemctl stop)
exec sleep infinity