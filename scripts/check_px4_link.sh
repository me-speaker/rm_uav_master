#!/usr/bin/env bash
# =============================================================================
# check_px4_link.sh — 无 GUI 情况下检查 PX4 链路状态
# =============================================================================
# 用法: bash scripts/check_px4_link.sh
#
# 输出的所有指标都来自 PX4 通过 MAVLink 主动发回的数据, 不用 QGC.
# =============================================================================
set -eo pipefail

CONTAINER="${CONTAINER:-rm_dep}"
source_bash="source /opt/uav_ws/install/setup.bash"

if ! docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[error] 容器 $CONTAINER 没在跑" >&2
    exit 1
fi

# 颜色
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GRN}✅${NC} $*"; }
warn() { echo -e "  ${YEL}⚠️ ${NC} $*"; }
fail() { echo -e "  ${RED}❌${NC} $*"; }

echo "═══════════════════════════════════════════════════════════════"
echo "  PX4 链路状态检查 (无 GUI)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# --- 1. MAVLink 链路 --------------------------------------------------------
echo "1. MAVLink 链路 (/mavros/state)"
STATE=$(docker exec "$CONTAINER" bash -c "$source_bash && ros2 topic echo /mavros/state --once 2>/dev/null")
if echo "$STATE" | grep -q "connected: true"; then
    ok "connected: true"
    MODE=$(echo "$STATE" | grep "mode:" | head -1 | awk '{print $2}')
    ok "PX4 mode: $MODE"
else
    fail "MAVLink 链路未通"
    echo "     排查: PX4 USB 接好? 串口权限? mavros 进程在跑?"
    exit 1
fi

# --- 2. PX4 硬件识别 (从 VER 消息) ----------------------------------------
echo ""
echo "2. PX4 板子身份 (从 sys plugin VER)"
VER=$(docker exec "$CONTAINER" bash -c "$source_bash && \
    ros2 topic echo /mavros/sys_status --once 2>/dev/null")
if echo "$VER" | grep -q "voltage"; then
    ok "PX4 sys_status 响应 (有 voltage/battery 字段)"
else
    warn "没看到 voltage 字段, PX4 没发 sys_status?"
fi

# --- 3. PX4 → ROS topic 频率 (验证 PX4 数据真在广播) ---------------------
echo ""
echo "3. PX4 → ROS topic 频率"
echo "─────────────────────────────────────"
hz_topic() {
    # 跑 4s 拿稳定 average rate, 提取数字部分
    local topic="$1"
    local out
    out=$(docker exec "$CONTAINER" bash -c "$source_bash && timeout 4 ros2 topic hz $topic 2>/dev/null" 2>/dev/null \
        | grep -E "^average rate:" | head -1)
    if [[ -n "$out" ]]; then
        echo "$out" | awk '{print $3}'
    else
        echo ""
    fi
}
for topic in /mavros/imu/data /mavros/sys_status /mavros/estimator_status /mavros/battery; do
    rate=$(hz_topic "$topic")
    if [[ -n "$rate" ]]; then
        ok "$topic: $rate Hz"
    else
        warn "$topic: 没数据"
    fi
done

# --- 4. ROS → PX4 vision_pose 频率 (我们发的) ----------------------------
echo ""
echo "4. ROS → PX4 (我们发的)"
echo "─────────────────────────────────────"
rate=$(hz_topic "/mavros/vision_pose/pose")
if [[ -n "$rate" ]]; then
    ok "/mavros/vision_pose/pose: $rate Hz"
else
    warn "/mavros/vision_pose/pose: 没数据"
fi

# --- 5. estimator_status 看 vision 是否被 PX4 接受 ------------------------
echo ""
echo "5. PX4 EKF2 estimator_status (⭐ 关键)"
echo "─────────────────────────────────────"
EST=$(docker exec "$CONTAINER" bash -c "$source_bash && \
    ros2 topic echo /mavros/estimator_status --once 2>/dev/null")
if echo "$EST" | grep -q "time_usec"; then
    ok "estimator_status 在发, PX4 EKF2 在跑"
    # control_mode_flags 比特位 (PX4 estimator_status.msg):
    #   bit 0: attitude          bit 4: yaw
    #   bit 1: velocity_xy       bit 5: velocity_z
    #   bit 2: position_horiz    bit 6: position_z
    # 期望: 大部分 bit 都是 true (说明 sensor 在 fused)
    echo "$EST" | grep -E "control_mode_flags|flags" | head -2 | sed 's/^/     /'
else
    fail "estimator_status 没数据"
fi

# --- 总结 -----------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  结论:"
echo "═══════════════════════════════════════════════════════════════"
if docker exec "$CONTAINER" bash -c "$source_bash && \
    ros2 topic echo /mavros/state --once 2>/dev/null" | grep -q "connected: true"; then
    echo -e "  ${GRN}✅ MAVLink 链路 OK, PX4 在响应${NC}"
    echo ""
    echo "  下一步: 想确认 PX4 EKF2 真的吃了 vision_pose, 看:"
    echo "    docker exec $CONTAINER bash -c 'source /opt/uav_ws/install/setup.bash && \
        ros2 topic echo /mavros/estimator_status'"
    echo "  如果 control_mode_flags 全是 true → EKF2 在融合 vision, 真链路通"
    echo "  如果只是 attitude/yaw true, position_* false → QGC 参数 EKF2_AID_MASK 没设"
else
    echo -e "  ${RED}❌ 链路异常, 看上面排查${NC}"
fi
echo ""