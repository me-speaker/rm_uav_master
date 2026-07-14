#!/usr/bin/env bash
# =============================================================================
# deploy_to_drone.sh — 一键打包 dev → drone 部署物
# =============================================================================
# 跑这个脚本会生成:
#   - ega-uav_runtime-v1.0.tar.gz  (docker image)
#   - rm_ws.tar.gz                 (rm_ws/ 项目, 含 install/)
#
# 然后 ssh scp 到机载电脑
#
# 用法:
#   bash scripts/deploy_to_drone.sh <drone-user>@<drone-ip>
#
# 例如:
#   bash scripts/deploy_to_drone.sh jetson@192.168.1.10
# =============================================================================

set -eo pipefail

DRONE_TARGET="${1:?用法: $0 <user>@<host>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_TAG="${IMAGE_TAG:-ega-uav:runtime-v1.0}"
DIST_DIR="${REPO_ROOT}/dist"

log() { echo "[deploy] $*"; }
die() { echo "[error] $*" >&2; exit 1; }

# ---- 1. 前置检查 --------------------------------------------------------
log "前置检查..."
test -f "$REPO_ROOT/install/setup.bash" || die "install/setup.bash 不存在, 请先 build (colcon build --symlink-install)"
docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 || die "镜像 $IMAGE_TAG 不存在, 请先 build (bash scripts/build_native.sh)"

# ---- 2. 准备 dist 目录 ---------------------------------------------------
log "打包到 $DIST_DIR/ ..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# ---- 3. 打包镜像 ------------------------------------------------------
log "[1/2] 打包 docker 镜像 $IMAGE_TAG ..."
docker save "$IMAGE_TAG" | gzip > "$DIST_DIR/$(echo $IMAGE_TAG | tr ':/' '_').tar.gz"
ls -lh "$DIST_DIR"/*.tar.gz

# ---- 4. 打包 rm_ws/ (排除 git / build / log) -----------------------------
log "[2/2] 打包 rm_ws/ (含 install/) ..."
tar -czf "$DIST_DIR/rm_ws.tar.gz" \
    --exclude='.git' \
    --exclude='.colcon_ws' \
    --exclude='dist' \
    -C "$(dirname "$REPO_ROOT")" \
    "$(basename "$REPO_ROOT")"
ls -lh "$DIST_DIR/rm_ws.tar.gz"

# ---- 5. scp 到 drone ----------------------------------------------------
log "[3/3] scp 到 $DRONE_TARGET ..."
scp "$DIST_DIR"/*.tar.gz "$DRONE_TARGET:~/"

echo ""
echo "============================================================"
echo "✅ 部署文件就绪, 已 scp 到 $DRONE_TARGET"
echo ""
echo "在 $DRONE_TARGET 上:"
echo "  1. 加载镜像:"
echo "       docker load -i ~/ega-uav_runtime-v1.0.tar.gz"
echo "  2. 解压 rm_ws/:"
echo "       tar -xzf ~/rm_ws.tar.gz -C ~"
echo "  3. 一次性安装 systemd + logrotate:"
echo "       sudo cp ~/rm_ws/scripts/rm_dep-*.sh /usr/local/bin/"
echo "       sudo cp ~/rm_ws/scripts/rm_dep.service /etc/systemd/system/"
echo "       sudo cp ~/rm_ws/scripts/logrotate-uav.conf /etc/logrotate.d/uav"
echo "       sudo mkdir -p /var/log/uav"
echo "       sudo systemctl daemon-reload"
echo "       sudo systemctl enable --now rm_dep.service"
echo "============================================================"