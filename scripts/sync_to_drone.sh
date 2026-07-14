#!/usr/bin/env bash
# =============================================================================
# sync_to_drone.sh — 增量同步代码到机载电脑 (uavboard 无网场景)
# =============================================================================
# 用法:
#   bash scripts/sync_to_drone.sh <user>@<host>
#   bash scripts/sync_to_drone.sh <user>@<drone-ip>
#
# 行为 (按改的内容选 flag):
#   -k     远端 kill 旧节点 (launch 自动重启)  ← 必加, 因为 Python 进程内存缓存旧 .pyc
#   -r     远端 colcon build                     ← 改 launch/setup.py/C++ 必加
#
# 例子:
#   # 改 slam_to_mavros_node.py (只 Python)
#   bash scripts/sync_to_drone.sh <user>@<drone-ip> -k
#
#   # 改 launch file (要 rebuild)
#   bash scripts/sync_to_drone.sh <user>@<drone-ip> -r -k
#
#   # 改 C++ (要 rebuild, 慢)
#   bash scripts/sync_to_drone.sh <user>@<drone-ip> -r -k
# =============================================================================

set -uo pipefail

DRONE_TARGET="${1:?用法: $0 <user>@<host>}"
REBUILD=""
KILL_OLD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--rebuild)  REBUILD="yes"; shift ;;
        -k|--kill)     KILL_OLD="yes"; shift ;;
        *) shift ;;
    esac
done

if [[ -z "$KILL_OLD" && -z "$REBUILD" ]]; then
    echo "[warn] 没加 -k 或 -r, 默认加 -k (kill 节点让 launch 重启生效)"
    KILL_OLD="yes"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo "[sync] $*"; }
die() { echo "[error] $*" >&2; exit 1; }

test -d "$REPO_ROOT" || die "rm_ws 目录不存在: $REPO_ROOT"

# 1. 增量同步
log "[1/3] rsync 增量同步代码到 $DRONE_TARGET ..."
rsync -avz --delete \
    --exclude='.git' \
    --exclude='.colcon_ws' \
    --exclude='dist' \
    --exclude='build' \
    --exclude='log' \
    --exclude='.vscode' \
    --exclude='.idea' \
    -e "ssh -o StrictHostKeyChecking=no" \
    "$REPO_ROOT/" "$DRONE_TARGET:~/rm_ws/"

# 2. (可选) 远端重 build
if [[ "$REBUILD" == "yes" ]]; then
    log "[2/3] 远端重 build (colcon) ..."
    ssh -o StrictHostKeyChecking=no "$DRONE_TARGET" '
        cd ~/rm_ws
        source /opt/uav_ws/install/setup.bash 2>/dev/null
        colcon build --symlink-install 2>&1 | tail -10
    '
else
    log "[2/3] 跳过 build (-r 加 -r 启用, 改 launch/setup.py/C++ 必加)"
fi

# 3. (可选) kill 旧节点
if [[ "$KILL_OLD" == "yes" ]]; then
    log "[3/3] 远端 kill 旧节点 (让 launch 重启) ..."
    ssh -o StrictHostKeyChecking=no "$DRONE_TARGET" '
        docker exec rm_dep bash -c "
            pkill -f slam_to_mavros_node 2>/dev/null
            pkill -f mavros_node 2>/dev/null
            pkill -f host_sdk_sample 2>/dev/null
            sleep 2
        " || true
    '
    log "    旧节点已 kill (如果你用 launch_odin_px4.sh 或 watchdog, 会自动重启)"
fi

log "✅ 同步完成"
echo ""
echo "  改 Python (slm/launch/...):"
echo "    bash scripts/sync_to_drone.sh $DRONE_TARGET -k"
echo ""
echo "  改 launch file / setup.py / C++:"
echo "    bash scripts/sync_to_drone.sh $DRONE_TARGET -r -k"
echo ""
echo "  改 Dockerfile (重 build 镜像):"
echo "    1. dev 机: bash scripts/build_native.sh --network host --tag ...:arm-v1.1"
echo "    2. bash scripts/deploy_to_drone.sh $DRONE_TARGET"