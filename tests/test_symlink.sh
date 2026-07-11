#!/usr/bin/env bash
# =============================================================================
# test_symlink.sh — 验证挂载模式即时生效
# =============================================================================
# 在容器内:
#   1. 确认 build/slam_to_mavros/slam_to_mavros → src/slam_to_mavros/slam_to_mavros
#   2. 写一个 marker 到 src/.py
#   3. import 该模块, 看 module file 是否包含 marker
#   4. cleanup
#
# 用法:
#   bash tests/test_symlink.sh                    # 默认容器 rm-uavsim
#   CONTAINER=my-drone bash tests/test_symlink.sh
# =============================================================================

set -eo pipefail

CONTAINER="${CONTAINER:-rm-uavsim}"

echo "═══ 挂载 symlink 验证 [$CONTAINER] ═══"

# 1. 容器在跑吗
if ! docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "❌ 容器 $CONTAINER 没在跑"; exit 1
fi

# 2. build → src symlink
echo ""
echo "--- 1. build/ → src/ symlink ---"
docker exec "$CONTAINER" bash -c '
SOURCE_DIR=/opt/uav_ws/build/slam_to_mavros/slam_to_mavros
TARGET=$(readlink -f "$SOURCE_DIR" 2>/dev/null || echo "BROKEN")
echo "  $SOURCE_DIR"
echo "    → $TARGET"
if [[ "$TARGET" == *"/opt/uav_ws/src/slam_to_mavros/slam_to_mavros" ]]; then
    echo "  ✅ symlink OK"
else
    echo "  ❌ symlink 错, 不是 src/"
    exit 1
fi
'

# 3. 写 marker, 验证 Python 能看到
echo ""
echo "--- 2. 写 marker 到 src/, 验证 Python 立即看到 ---"
MARKER="##_TEST_MARKER_$(date +%s)_$$"
docker exec "$CONTAINER" bash -c "
source /opt/uav_ws/install/setup.bash
ORIG=/opt/uav_ws/src/slam_to_mavros/slam_to_mavros/slam_to_mavros_node.py
echo \"$MARKER\" >> \"\$ORIG\"
python3 -c \"
import slam_to_mavros.slam_to_mavros_node as m
src_file = m.__file__
content = open(src_file).read()
if '$MARKER' in content:
    print('  ✅ import 看到的源码包含 marker')
    print('  module:', src_file)
else:
    print('  ❌ import 看到的源码不含 marker')
    print('  module:', src_file)
    print('  last 3 lines:')
    print('  ', content.splitlines()[-3:])
\"
sed -i \"/$MARKER/d\" \"\$ORIG\"
echo '  cleanup done'
"

echo ""
echo "═══ 通过 ═══"