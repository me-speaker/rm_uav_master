#!/usr/bin/env bash
# =============================================================================
# ensure_pymavlink.sh — 确保容器里装了 pymavlink (set_px4_mavlink.py 依赖)
# =============================================================================
# 用途:
#   每次重启容器如果 pymavlink 没装, 跑一下这个.
#   mavros 的 PX4 param service 在 humble 版本 broken, 我们走原始 MAVLink 设参.
#
# 用法:
#   bash scripts/ensure_pymavlink.sh
# =============================================================================
set -e

CONTAINER="${CONTAINER:-rm_dep}"

if ! docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[error] 容器 $CONTAINER 没在跑, 先: bash scripts/start_uav_container.sh" >&2
    exit 1
fi

# 检查 pip3 是否装了 --break-system-packages 选项 (新 pip 才有)
pip_has_flag() {
    docker exec "$CONTAINER" pip3 install --help 2>&1 | grep -q -- "--break-system-packages"
}

# 检查 pymavlink
if docker exec "$CONTAINER" python3 -c "import pymavlink" 2>/dev/null; then
    echo "[ok] pymavlink 已装, version: $(docker exec $CONTAINER python3 -c 'import pymavlink; print(pymavlink.__version__)')"
    exit 0
fi

echo "[info] pymavlink 没装, 开始装 ..."

# 1. 装 pip
if ! docker exec "$CONTAINER" command -v pip3 >/dev/null 2>&1; then
    echo "[info] apt install python3-pip ..."
    docker exec "$CONTAINER" bash -c '
        apt-get update -qq && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends python3-pip
    ' 2>&1 | tail -3
fi

# 2. 装 pymavlink + pyserial
echo "[info] pip install pymavlink pyserial ..."
if pip_has_flag; then
    docker exec "$CONTAINER" pip3 install --break-system-packages pymavlink pyserial 2>&1 | tail -3
else
    # 老 pip 没有 --break-system-packages, 用 --user
    docker exec "$CONTAINER" pip3 install pymavlink pyserial 2>&1 | tail -3
fi

# 3. 验证
echo ""
echo "[verify]"
docker exec "$CONTAINER" python3 -c "import pymavlink, serial; print(f'pymavlink {pymavlink.__version__}, pyserial OK')"
echo ""
echo "[ok] 装好了, 可以用 set_px4_mavlink.py 了"
echo "     bash scripts/set_px4_mavlink.sh --show      # 看参数"
echo "     bash scripts/set_px4_mavlink.sh             # 设 vision-only 参数"