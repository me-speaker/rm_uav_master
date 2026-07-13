#!/usr/bin/env bash
# =============================================================================
# rm_dep-stop.sh — systemd 调用的停止脚本
# =============================================================================
set -eo pipefail

CONTAINER="${CONTAINER:-rm_dep}"

echo "[rm_dep-stop] 停止容器 $CONTAINER ..."

# 杀掉 watchdog
docker exec "$CONTAINER" bash -lc "pkill -f rm_dep-watchdog 2>/dev/null; true" 2>/dev/null || true

# 杀掉节点
docker exec "$CONTAINER" bash -lc "
    pkill -f slam_to_mavros_node 2>/dev/null || true
    pkill -f mavros_node 2>/dev/null || true
    pkill -f host_sdk_sample 2>/dev/null || true
" 2>/dev/null || true

sleep 2

# 停容器
docker stop "$CONTAINER" 2>/dev/null || true

echo "[rm_dep-stop] 完成"