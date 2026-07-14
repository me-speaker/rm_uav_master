#!/usr/bin/env bash
# =============================================================================
# rm_dep-watchdog.sh — 容器内 watchdog (systemd 自启用)
# =============================================================================
# 循环检测 PX4 USB 是否出现, 出现后自动 launch 整个链路.
# 已经跑则跳过; 任何节点死了重启.
#
# Logging:
#   /var/log/uav/watchdog-YYYYMMDD.log    watchdog 自己的 log
#   /var/log/uav/launch-YYYYMMDD-HHMMSS.log  ros2 launch 输出 (含 ODIN/mavros/slam)
#
# 容器内不需要 logrotate, host 端 systemd timer 调用 logrotate 滚动.
#
# PID 文件: /tmp/rm_dep-watchdog.pid (供 stop 用)
# =============================================================================

set -uo pipefail

INTERVAL="${WATCHDOG_INTERVAL:-2}"
FCU_DEV="${FCU_DEV:-/dev/ttyACM0}"
CONTAINER="${1:-rm_dep}"  # autostart 传容器名过来
LAUNCH_FILE="slam_to_mavros/odin_px4_full.launch.py"

LOG_DIR="${LOG_DIR:-/var/log/uav}"
WD_LOG="$LOG_DIR/watchdog-$(date +%Y%m%d).log"
LAUNCH_LOG="$LOG_DIR/launch-$(date +%Y%m%d-%H%M%S).log"
PID_FILE="/tmp/rm_dep-watchdog.pid"

mkdir -p "$LOG_DIR"

# 把 watchdog stdout/stderr 也重定向到 log (nohup + setsid 后会丢失当前 stdout)
exec >>"$WD_LOG" 2>&1

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# 写 PID (先删旧的, 避免 Permission denied)
rm -f "$PID_FILE" 2>/dev/null
echo $$ > "$PID_FILE"
log "watchdog 启动 PID=$$ interval=${INTERVAL}s fcu_dev=$FCU_DEV"

launched="false"
launch_pid=""

while true; do
    # 1. 检查 PX4 USB 是否在
    if [[ ! -e "$FCU_DEV" ]]; then
        if [[ "$launched" == "true" ]]; then
            log "⚠️  $FCU_DEV 消失, 重置状态 (PX4 断电 / 重启)"
            launched="false"
            # 不杀 launch, 让它自己 reconnect PX4 (mavros respawn 会重连)
        else
            log "⏳ 等 $FCU_DEV 出现 ..."
        fi
        sleep "$INTERVAL"
        continue
    fi

    # 2. 已经在跑 → 健康检查
    if [[ "$launched" == "true" ]]; then
        if [[ -n "$launch_pid" ]] && ! kill -0 "$launch_pid" 2>/dev/null; then
            log "⚠️  ros2 launch 进程 (PID $launch_pid) 死了, 重启"
            launched="false"
            launch_pid=""
        elif ! pgrep -f host_sdk_sample >/dev/null 2>&1; then
            log "⚠️  ODIN host_sdk_sample 死了"
        elif ! pgrep -f mavros_node >/dev/null 2>&1; then
            log "⚠️  mavros_node 死了"
        elif ! pgrep -f slam_to_mavros_node >/dev/null 2>&1; then
            log "⚠️  slam_to_mavros_node 死了"
        else
            sleep "$INTERVAL"
            continue
        fi
        # 节点死了, 整个 launch 重启
        launched="false"
        if [[ -n "$launch_pid" ]]; then
            kill -TERM "-$launch_pid" 2>/dev/null || true
            sleep 2
        fi
    fi

    # 3. 启 ros2 launch (在容器内跑, 用 docker exec)
    log "🚀 $FCU_DEV 出现, 启 ros2 launch slam_to_mavros/odin_px4_full.launch.py ..."
    # watchdog 可能跑在 host 或容器内, 用 docker exec 兼容两种
    # 用 source 命令组合避免 bash -c 嵌套引号
    nohup setsid docker exec "$CONTAINER" \
        bash -c 'source /opt/uav_ws/install/setup.bash && exec ros2 launch slam_to_mavros odin_px4_full.launch.py' \
        >"$LAUNCH_LOG" 2>&1 &
    launch_pid=$!

    log "    launch PID: $launch_pid, log: $LAUNCH_LOG"
    # 等 15s 让 ODIN SDK init + mavros 连接
    sleep 15
    launched="true"
done