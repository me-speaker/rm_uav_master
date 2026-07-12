#!/usr/bin/env bash
# =============================================================================
# monitor_layer4.sh — Layer 4 实时监控 ODIN 输出 vs PX4 EKF2 输出
# =============================================================================
# 跑法: bash scripts/monitor_layer4.sh
#
# 跑这个脚本前, 假设你已经:
#   1. PX4 已用 vision-only 参数 (set_px4_mavlink.sh)
#   2. 全链路 launch 已经在跑 (uav_bringup.launch.py lidar:=odin)
#
# 显示:
#   - /odin1/odometry 位置 (ODIN SLAM 输出, "真值参考")
#   - /mavros/local_position/pose 位置 (PX4 EKF2 融合输出, 应该跟着 ODIN 走)
#   - /mavros/vision_pose/pose 频率 (确认 EKF2 真在收到)
#
# 看输出是否同步: 当你挪 ODIN, 两边的 y/x 应该**同向**变化 (数值可能差 30-50%)
# =============================================================================
set -eo pipefail

CONTAINER="${CONTAINER:-rm-uavsim}"
source_bash="source /opt/uav_ws/install/setup.bash"

if ! docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[error] 容器 $CONTAINER 没在跑" >&2
    exit 1
fi

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 取一次 topic 内容的 helper (不用 --field, 因为不同 msg 类型字段路径不一样)
# Odometry 是 pose.pose.position, PoseStamped 是 pose.position, PoseWithCovariance 是 pose.pose.position
# 直接 echo 全部, 然后 awk 抓 x:/y:/z: (取第一次出现 = position)
get_pose() {
    local topic="$1"
    docker exec "$CONTAINER" bash -c "$source_bash && \
        timeout 3 ros2 topic echo $topic --once 2>/dev/null"
}

# 提取 x, y, z 数值
extract_pos() {
    local label="$1"
    local raw="$2"
    local x y z
    x=$(echo "$raw" | awk '/x:/{x=$2} END{print x+0}')
    y=$(echo "$raw" | awk '/y:/{y=$2} END{print y+0}')
    z=$(echo "$raw" | awk '/z:/{z=$2} END{print z+0}')
    printf "  %-30s x=%8.3f  y=%8.3f  z=%8.3f\n" "$label" "${x:-0}" "${y:-0}" "${z:-0}"
}

# 取频率 (timeout 必须 4s+, ros2 topic hz 至少 1 帧才能出 average rate)
get_hz() {
    local topic="$1"
    docker exec "$CONTAINER" bash -c "$source_bash && \
        timeout 5 ros2 topic hz $topic 2>/dev/null | grep average | head -1 | awk '{print \$3}'"
}

# 一次拿多个频率 (节省 docker exec 开销, 5s timeout 一次)
get_hz_batch() {
    docker exec "$CONTAINER" bash -c "$source_bash && {
        timeout 5 ros2 topic hz /odin1/odometry 2>/dev/null | grep average | head -1 | awk '{print \"odin=\"\$3}'
        timeout 5 ros2 topic hz /mavros/vision_pose/pose 2>/dev/null | grep average | head -1 | awk '{print \"vision=\"\$3}'
    }"
}

# 一次拿多个 topic 的最新 pose (echo --once 5s timeout 拿到一条)
get_pose_batch() {
    docker exec "$CONTAINER" bash -c "$source_bash && {
        echo '===ODIN==='
        timeout 4 ros2 topic echo /odin1/odometry --once 2>/dev/null
        echo '===PX4==='
        timeout 4 ros2 topic echo /mavros/local_position/pose --once 2>/dev/null
    }"
}

echo "═══════════════════════════════════════════════════════════════"
echo -e "  ${CYAN}Layer 4 实时监控${NC}  (按 Ctrl+C 退出)"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo -e "  ${GRN}ODIN${NC}    →  /odin1/odometry           (SLAM 输出, 参考真值)"
echo -e "  ${GRN}PX4${NC}     →  /mavros/local_position/pose (EKF2 融合 vision 后)"
echo ""
echo "  移动 ODIN: 两边的 x/y 应该同向变化 (PX4 滞后 + IMU 加权,数值会打折)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

PREV_ODIN_X=""
PREV_ODIN_Y=""
PREV_PX4_X=""
PREV_PX4_Y=""

# 跑 N 轮
for i in $(seq 1 60); do
    # 频率 (5s timeout 一次)
    hz_out=$(get_hz_batch)
    odin_hz=$(echo "$hz_out" | grep -oE "odin=[0-9.]+" | cut -d= -f2)
    vision_hz=$(echo "$hz_out" | grep -oE "vision=[0-9.]+" | cut -d= -f2)

    echo "═══════════════════════════════════════════════════════════════"
    echo -e "  ${CYAN}[T+${i}s] 频率:${NC}"
    echo "  /odin1/odometry:            ${odin_hz:-N/A} Hz"
    echo "  /mavros/vision_pose/pose:   ${vision_hz:-N/A} Hz"
    echo ""

    # 位置 (一次拿两个)
    pose_out=$(get_pose_batch)
    odin_raw=$(echo "$pose_out" | sed -n '/===ODIN===/,/===PX4===/p' | sed '/===PX4===/d')
    px4_raw=$(echo  "$pose_out" | sed -n '/===PX4===/,$p' | sed '/===PX4===/d')

    extract_pos "/odin1/odometry"          "$odin_raw"
    extract_pos "/mavros/local_position/pose" "$px4_raw"

    # delta (跟前一轮比, 应该是同号)
    if [[ -n "$odin_raw" && -n "$PREV_ODIN_X" ]]; then
        cur_x=$(echo "$odin_raw" | awk '/x:/{x=$2} END{print x+0}')
        cur_y=$(echo "$odin_raw" | awk '/y:/{y=$2} END{print y+0}')
        dx_odin=$(echo "$cur_x $PREV_ODIN_X" | awk '{print $1-$2}')
        dy_odin=$(echo "$cur_y $PREV_ODIN_Y" | awk '{print $1-$2}')

        cur_px4_x=$(echo "$px4_raw" | awk '/x:/{x=$2} END{print x+0}')
        cur_px4_y=$(echo "$px4_raw" | awk '/y:/{y=$2} END{print y+0}')
        dx_px4=$(echo "$cur_px4_x $PREV_PX4_X" | awk '{print $1-$2}')
        dy_px4=$(echo "$cur_px4_y $PREV_PX4_Y" | awk '{print $1-$2}')

        echo ""
        echo -e "  ${YEL}Δ since last sample:${NC}"
        printf "    ODIN:  Δx=%+7.3f  Δy=%+7.3f\n" "$dx_odin" "$dy_odin"
        printf "    PX4:   Δx=%+7.3f  Δy=%+7.3f\n" "$dx_px4" "$dy_px4"

        # 方向对比
        sx_odin=$(echo "$dx_odin" | awk '{print ($1>=0)?1:-1}')
        sx_px4=$(echo  "$dx_px4"  | awk '{print ($1>=0)?1:-1}')
        sy_odin=$(echo "$dy_odin" | awk '{print ($1>=0)?1:-1}')
        sy_px4=$(echo  "$dy_px4"  | awk '{print ($1>=0)?1:-1}')

        if [[ "$sx_odin" == "$sx_px4" && "$sy_odin" == "$sy_px4" ]]; then
            echo -e "    ${GRN}✅ 方向一致 (EKF2 在跟 ODIN)${NC}"
        elif [[ "$sx_odin" == "$sx_px4" || "$sy_odin" == "$sy_px4" ]]; then
            echo -e "    ${YEL}⚠️  部分一致${NC}"
        else
            echo -e "    ${RED}❌ 方向相反, EKF2 没在用 vision${NC}"
        fi

        PREV_ODIN_X="$cur_x"; PREV_ODIN_Y="$cur_y"
        PREV_PX4_X="$cur_px4_x"; PREV_PX4_Y="$cur_px4_y"
    else
        # 第一次
        PREV_ODIN_X=$(echo "$odin_raw" | awk '/x:/{x=$2} END{print x+0}')
        PREV_ODIN_Y=$(echo "$odin_raw" | awk '/y:/{y=$2} END{print y+0}')
        PREV_PX4_X=$(echo "$px4_raw"  | awk '/x:/{x=$2} END{print x+0}')
        PREV_PX4_Y=$(echo "$px4_raw"  | awk '/y:/{y=$2} END{print y+0}')
    fi

    sleep 1
done