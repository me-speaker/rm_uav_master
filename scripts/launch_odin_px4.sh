#!/usr/bin/env bash
# =============================================================================
# launch_odin_px4.sh — ODIN 真机 + PX4 全链路一键启动
# =============================================================================
# 启动顺序:
#   1. ODIN driver (host_sdk_sample) → /odin1/odometry
#   2. mavros_node              → /mavros/* (连 PX4)
#   3. slam_to_mavros_node      → /mavros/vision_pose/pose (force_ros_stamp=true)
#
# 数据流:
#   ODIN → /odin1/odometry → slam_to_mavros → /mavros/vision_pose/pose
#                              → mavros → MAVLink → PX4 EKF2
#                              → /mavros/local_position/pose
#
# 跑前确认:
#   1. PX4 接上 USB, 启动后心跳在
#   2. ODIN 接上 USB3.0 + 12V
#   3. 容器已起 (挂好 USB): bash scripts/start_uav_container.sh --lidar odin
#
# 用法:
#   bash scripts/launch_odin_px4.sh                          # 默认参数
#   bash scripts/launch_odin_px4.sh --fcu-url /dev/ttyACM0:921600
#   bash scripts/launch_odin_px4.sh --no-verify              # 跳过验证步骤
#
# systemd 自启见: docs/AUTOSTART.md
# =============================================================================

set -eo pipefail

FCU_URL="/dev/ttyACM0:921600"
CONTAINER="${CONTAINER:-rm_dep}"
SKIP_VERIFY="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fcu-url)        FCU_URL="$2"; shift 2 ;;
        --container)      CONTAINER="$2"; shift 2 ;;
        --no-verify)      SKIP_VERIFY="true"; shift ;;
        -h|--help)
            sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "[error] unknown: $1" >&2; exit 2 ;;
    esac
done

# ---- 前置检查 -----------------------------------------------------------
if ! docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[error] 容器 $CONTAINER 没在跑" >&2
    echo "        先: bash scripts/start_uav_container.sh --lidar odin" >&2
    exit 1
fi

if ! docker exec "$CONTAINER" test -f /opt/uav_ws/install/setup.bash; then
    echo "[error] 容器内还没 build" >&2; exit 1
fi

PX4_DEV=$(echo "$FCU_URL" | cut -d: -f1)
if ! docker exec "$CONTAINER" test -e "$PX4_DEV"; then
    echo "[error] 容器内看不到 $PX4_DEV" >&2
    echo "        重启容器时确保加了 --device=$PX4_DEV" >&2
    exit 1
fi

# ODIN USB 在容器里
# 用 grep ... | wc -l 而不是 grep -c,避免容器 entrypoint 的 stdout (例如 [uav_ws] ROS sourced 行)
# 把命令替换污染掉,导致变量不是单纯数字
ODIN_USB=$(docker exec "$CONTAINER" bash -c 'lsusb 2>/dev/null | grep "2207:0019" | wc -l' 2>/dev/null | tail -1 | tr -d '[:space:]')
if [[ "$ODIN_USB" != "1" ]]; then
    echo "[error] 容器内没看到 ODIN USB (vendor 2207:0019, 检测到 $ODIN_USB 个)" >&2
    echo "        重启容器时确保加了 --lidar odin (自动挂)" >&2
    exit 1
fi

echo "[launch_odin_px4] fcu=$FCU_URL  container=$CONTAINER"

# ---- 1. ODIN driver -----------------------------------------------------
echo "[1/4] 启动 ODIN driver (host_sdk_sample) ..."
docker exec "$CONTAINER" bash -c "pkill -f host_sdk_sample 2>/dev/null; sleep 1; true"
docker exec -d "$CONTAINER" bash -c "source /opt/uav_ws/install/setup.bash && exec ros2 launch odin_ros_driver odin1_ros2.launch.py > /tmp/odin.log 2>&1"

# 等 SDK init
echo "      等 30s 让 ODIN SDK 初始化..."
sleep 30

# ---- 2. mavros -----------------------------------------------------------
echo "[2/4] 启动 mavros (连 PX4, $FCU_URL) ..."
docker exec "$CONTAINER" bash -c "pkill -f mavros_node 2>/dev/null; sleep 1; true"
docker exec -d "$CONTAINER" bash -c "source /opt/uav_ws/install/setup.bash && exec ros2 launch /opt/uav_ws/scripts/px4.launch.py fcu_url:=$FCU_URL > /tmp/mavros.log 2>&1"

# 等连接 + heartbeat (polling connected=true, 最多 30s)
echo "      等 mavros 连上 PX4 (polling connected) ..."
for i in {1..30}; do
    if docker exec "$CONTAINER" bash -c "source /opt/uav_ws/install/setup.bash && timeout 1 ros2 topic echo /mavros/state --once --field connected 2>/dev/null | grep -q true"; then
        echo "      ✓ mavros connected (${i}s)"
        break
    fi
    sleep 1
done
if ! docker exec "$CONTAINER" bash -c "source /opt/uav_ws/install/setup.bash && timeout 1 ros2 topic echo /mavros/state --once --field connected 2>/dev/null | grep -q true"; then
    echo "[error] mavros 30s 内没连上 PX4, 看 /tmp/mavros.log"
    exit 1
fi

# ---- 3. slam_to_mavros (⭐ force_ros_stamp) ------------------------------
echo "[3/4] 启动 slam_to_mavros (force_ros_stamp=true) ..."
docker exec "$CONTAINER" bash -c "pkill -f slam_to_mavros_node 2>/dev/null; sleep 1; true"
docker exec -d "$CONTAINER" bash -c "source /opt/uav_ws/install/setup.bash && exec ros2 run slam_to_mavros slam_to_mavros_node --ros-args -p odom_topic:=/odin1/odometry -p force_ros_stamp:=true > /tmp/sm.log 2>&1"

sleep 5

# ---- 4. 验证 -------------------------------------------------------------
if [[ "$SKIP_VERIFY" == "true" ]]; then
    echo "[4/4] --no-verify 跳过验证"
    echo "[launch_odin_px4] 完成"
    exit 0
fi

echo "[4/4] 验证链路 ..."

# 检查 mavros 连接
CONNECTED=$(docker exec "$CONTAINER" bash -c "source /opt/uav_ws/install/setup.bash && ros2 topic echo /mavros/state --once --field connected 2>/dev/null | head -1")
if [[ "$CONNECTED" != *"true"* ]]; then
    echo "  [✗] mavros 没连上 PX4, 看 /tmp/mavros.log"
    exit 1
fi
echo "  [✓] mavros connected"

# 检查 ODIN 频率
ODIN_HZ=$(docker exec "$CONTAINER" bash -c "source /opt/uav_ws/install/setup.bash && timeout 4 ros2 topic hz /odin1/odometry 2>/dev/null | tail -1")
if [[ "$ODIN_HZ" != *"average"* ]]; then
    echo "  [✗] ODIN /odin1/odometry 无数据, 看 /tmp/odin.log"
    exit 1
fi
echo "  [✓] ODIN odom $ODIN_HZ"

# 检查 vision_pose 频率
VP_HZ=$(docker exec "$CONTAINER" bash -c "source /opt/uav_ws/install/setup.bash && timeout 4 ros2 topic hz /mavros/vision_pose/pose 2>/dev/null | tail -1")
if [[ "$VP_HZ" != *"average"* ]]; then
    echo "  [✗] vision_pose 无数据"
    exit 1
fi
echo "  [✓] vision_pose $VP_HZ"

# ⭐ 检查时间戳对齐 (Unix 时间, 不是几百秒)
STAMP_SEC=$(docker exec "$CONTAINER" bash -c "source /opt/uav_ws/install/setup.bash && ros2 topic echo /mavros/vision_pose/pose --once --field header.stamp.sec 2>/dev/null | head -1")
if [[ "$STAMP_SEC" =~ ^[0-9]+$ ]]; then
    if (( STAMP_SEC > 1000000000 )); then
        echo "  [✓] 时间戳对齐 (Unix sec=$STAMP_SEC)"
    else
        echo "  [✗] 时间戳异常 (sec=$STAMP_SEC, 期望 >1e9, force_ros_stamp 没生效)"
        exit 1
    fi
fi

echo ""
echo "============================================================"
echo "  ✅ 全部启动 + 验证通过"
echo "  监控话题:"
echo "    docker exec $CONTAINER bash -lc \"source /opt/uav_ws/install/setup.bash && ros2 topic echo /mavros/local_position/pose --field pose.position\""
echo "  停止:"
echo "    bash scripts/launch_odin_px4.sh --container $CONTAINER  # 不需要停"
echo "    docker exec $CONTAINER pkill -f slam_to_mavros_node"
echo "    docker exec $CONTAINER pkill -f mavros_node"
echo "    docker exec $CONTAINER pkill -f host_sdk_sample"
echo "============================================================"