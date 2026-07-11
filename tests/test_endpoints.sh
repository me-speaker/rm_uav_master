#!/usr/bin/env bash
# =============================================================================
# test_endpoints.sh — 端到端: 喂 /Odometry, 验证 /mavros/vision_pose/pose 输出
# =============================================================================
# 用法:
#   bash tests/test_endpoints.sh                # 默认容器 rm-uavsim
#   CONTAINER=foo bash tests/test_endpoints.sh  # 自定义
#
# 退出码: 0=全部通过, 1=有失败
# =============================================================================

set -eo pipefail

CONTAINER="${CONTAINER:-rm-uavsim}"
PASS=0; FAIL=0
ok()  { echo "  ✅ $*"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $*"; FAIL=$((FAIL+1)); }

echo "═══ slam_to_mavros e2e test [$CONTAINER] ═══"

# 0. preflight
if ! docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "❌ 容器 $CONTAINER 没在跑"; exit 1
fi

# 1. 启动 slam_to_mavros_node (后台)
echo ""
echo "--- 1. 启 slam_to_mavros_node ---"
docker exec -d "$CONTAINER" bash -c '
source /opt/uav_ws/install/setup.bash
nohup ros2 run slam_to_mavros slam_to_mavros_node > /tmp/stm_e2e.log 2>&1 &
echo $! > /tmp/stm_e2e.pid
'
sleep 3
if docker exec "$CONTAINER" pgrep -f slam_to_mavros_node >/dev/null; then
    ok "节点起来了 (PID $(docker exec $CONTAINER pgrep -f slam_to_mavros_node))"
else
    bad "节点没起来"
    docker exec "$CONTAINER" cat /tmp/stm_e2e.log 2>&1 | sed 's/^/    /'
    exit 1
fi

# 2. 发测试 /Odometry
echo ""
echo "--- 2. 发 /Odometry @ 10Hz x 3s ---"
docker exec "$CONTAINER" bash -c '
source /opt/uav_ws/install/setup.bash
ODOM_YAML="{header: {stamp: {sec: 0, nanosec: 0}, frame_id: \"odom\"}, child_frame_id: \"base_link\", pose: {pose: {position: {x: 1.5, y: -0.5, z: 0.3}, orientation: {x: 0.0, y: 0.0, z: 0.0, w: 1.0}}}, twist: {twist: {linear: {x: 0.1, y: 0.2, z: 0.05}}}}"
timeout 3 ros2 topic pub -r 10 /Odometry nav_msgs/msg/Odometry "$ODOM_YAML" > /dev/null 2>&1
' && ok "pub 完成" || bad "pub 失败"

# 3. 验证 /mavros/vision_pose/pose 有数据
echo ""
echo "--- 3. /mavros/vision_pose/pose header.frame_id ---"
sleep 1
FRAME_ID=$(docker exec "$CONTAINER" bash -c '
source /opt/uav_ws/install/setup.bash
timeout 2 ros2 topic echo /mavros/vision_pose/pose --field header.frame_id 2>&1 | head -1
' 2>&1 | tr -d '\r' | grep -v "context is not valid" | head -1)
if [[ "$FRAME_ID" == "map" ]]; then
    ok "frame_id = map (PX4 EKF2 期望)"
else
    bad "frame_id 异常: '$FRAME_ID'"
fi

# 4. 验证 /mavros/vision_speed/speed_twist 有数据
echo ""
echo "--- 4. /mavros/vision_speed/speed_twist ---"
SPEED_LINE=$(docker exec "$CONTAINER" bash -c '
source /opt/uav_ws/install/setup.bash
timeout 2 ros2 topic echo /mavros/vision_speed/speed_twist 2>&1 | grep -E "linear.x|linear.y|linear.z" | head -3
' 2>&1 | tr -d '\r')
if echo "$SPEED_LINE" | grep -q "0.1\|0.2\|0.05"; then
    ok "速度字段正确 (linear.x=0.1, y=0.2, z=0.05)"
else
    bad "速度字段异常: $SPEED_LINE"
fi

# 5. 验证 TF odom -> base_link
echo ""
echo "--- 5. TF odom -> base_link ---"
TF_LINE=$(docker exec "$CONTAINER" bash -c '
source /opt/uav_ws/install/setup.bash
timeout 3 ros2 run tf2_ros tf2_echo odom base_link --once 2>&1 | head -10
' 2>&1 | tr -d '\r')
if echo "$TF_LINE" | grep -q "Translation"; then
    ok "TF odom → base_link 有数据"
    echo "$TF_LINE" | grep -E "Translation|Rotation" | head -2 | sed 's/^/      /'
else
    bad "TF odom → base_link 无数据"
fi

# 6. cleanup
echo ""
echo "--- 6. cleanup ---"
docker exec "$CONTAINER" bash -c 'kill -9 $(pgrep -f slam_to_mavros_node) 2>/dev/null; echo done' >/dev/null
ok "节点已停"

# ---- 总结 -----------------------------------------------------------------
echo ""
echo "═══ 总结 ═══"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0