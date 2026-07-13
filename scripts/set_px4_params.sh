#!/usr/bin/env bash
# =============================================================================
# set_px4_params.sh — 不用 QGC, 通过 mavros param service 设 PX4 飞行参数
# =============================================================================
# 用法:
#   bash scripts/set_px4_params.sh             # 设 vision-only 必需参数
#   bash scripts/set_px4_params.sh --show      # 只看当前参数
#   bash scripts/set_px4_params.sh --reset     # 还原 (GPS 模式)
#
# 必设参数 (QGC 上手设也得设这些):
#   SYS_HAS_GPS    = 0    # 室内, 没 GPS
#   EKF2_AID_MASK  = 24   # bit 3 vision position, bit 4 vision yaw
#   EKF2_EV_CTRL   = 15   # enable vision_pose + vision_yaw
#   EKF2_HGT_REF   = 3    # Vision as height reference
#   MAV_USEHILGPS  = 0
#
# 设完 PX4 自动生效 (部分参数需要 reboot, 我们 reboot 一下保险)
# =============================================================================
set -eo pipefail

CONTAINER="${CONTAINER:-rm_dep}"
source_bash="source /opt/uav_ws/install/setup.bash"

# 颜色
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GRN}✅${NC} $*"; }
warn() { echo -e "  ${YEL}⚠️ ${NC} $*"; }
fail() { echo -e "  ${RED}❌${NC} $*"; }

# 参数表: name type value
# type: 1=INT8, 2=UINT8, 3=INT16, 4=UINT16, 5=INT32, 6=UINT32, 7=FLOAT, 8=DOUBLE
PARAMS=(
    "SYS_HAS_GPS|6|0"          # UINT32 = 0
    "EKF2_AID_MASK|6|24"       # UINT32 = 24 (bit3 vision pos + bit4 vision yaw)
    "EKF2_EV_CTRL|6|15"        # UINT32 = 15 (vision_pose + vision_yaw)
    "EKF2_HGT_REF|6|3"         # UINT32 = 3 (Vision)
    "MAV_USEHILGPS|2|0"        # UINT8 = 0
)

# PX4 EKF2 param persistence: 需要 COMMNS_DIAGNOSTICS=1? 不, 直接 set + reboot 即可

mode="set"
case "${1:-}" in
    --show|-s)  mode="show" ;;
    --reset|-r)
        # 还原成 GPS 模式
        PARAMS=(
            "SYS_HAS_GPS|6|1"
            "EKF2_AID_MASK|6|1"        # bit 0 = GPS
            "EKF2_HGT_REF|6|1"         # GPS
            "MAV_USEHILGPS|2|0"
        )
        ;;
esac

if ! docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    fail "容器 $CONTAINER 没在跑"
    exit 1
fi

# 检查 mavros 连通
if ! docker exec "$CONTAINER" bash -c "$source_bash && \
    ros2 topic echo /mavros/state --once 2>/dev/null | grep -q 'connected: true'"; then
    fail "mavros 没连 PX4 (state.connected != true)"
    echo "  先跑: bash scripts/launch_test_with_px4.sh --fcu-url /dev/ttyACM0:921600"
    exit 1
fi

if [[ "$mode" == "show" ]]; then
    echo "═══════════════════════════════════════════════════════════════"
    echo "  当前 PX4 关键参数"
    echo "═══════════════════════════════════════════════════════════════"
    for entry in "${PARAMS[@]}"; do
        IFS='|' read -r name type _ <<< "$entry"
        val=$(docker exec "$CONTAINER" bash -c "
            $source_bash && \
            ros2 service call /mavros/param/get mavros_msgs/srv/ParamGet \
                \"{param_id: '$name'}\" 2>/dev/null | \
            grep integer | head -1 | awk '{print \$2}'
        " 2>/dev/null)
        # UINT32/FLOAT 在 service 里都报成 integer 字段 (mavros 简化)
        printf "  %-20s = %s\n" "$name" "${val:-?}"
    done
    exit 0
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  设 PX4 参数 → vision-only 模式"
echo "═══════════════════════════════════════════════════════════════"

for entry in "${PARAMS[@]}"; do
    IFS='|' read -r name type value <<< "$entry"
    # mavros service 用 'integer' 字段 (兼容所有整数/FLOAT 类型)
    # value.real 留给 FLOAT/DOUBLE, 这里都设整数
    result=$(docker exec "$CONTAINER" bash -c "
        $source_bash && \
        ros2 service call /mavros/param/set mavros_msgs/srv/ParamSet \
            \"{param_id: '$name', value: {type: $type, integer: $value, real: 0.0}}\" \
            2>/dev/null | grep -E 'successful|reason' | head -2
    " 2>/dev/null)

    if echo "$result" | grep -q "successful: True"; then
        ok "$name = $value"
    else
        fail "$name: $result"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Reboot PX4 让参数生效"
echo "═══════════════════════════════════════════════════════════════"
docker exec "$CONTAINER" bash -c "$source_bash && \
    ros2 service call /mavros/cmd/command mavros_msgs/srv/CommandLong \
        \"{broadcast: false, command: 246, confirmation: 0, param1: 1.0, param2: 0.0, param3: 0.0, param4: 0.0, param5: 0.0, param6: 0.0, param7: 0.0}\" 2>/dev/null | grep -E success" \
    2>&1 | head -2

ok "Reboot 命令已发, 等 5s PX4 重启..."
sleep 5

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  验证参数生效"
echo "═══════════════════════════════════════════════════════════════"
$0 --show