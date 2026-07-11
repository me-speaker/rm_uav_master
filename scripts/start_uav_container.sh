#!/usr/bin/env bash
# =============================================================================
# start_uav_container.sh — rm_ws 机载 SLAM+MAVROS 容器启动器 (v1.1, ODIN 兼容)
# =============================================================================
#
# 工作流:
#   1. 自动 -v <rm_ws>/src:/opt/uav_ws/src     (源码挂载, 即时迭代)
#   2. 自动 -v <rm_ws>/config:/opt/uav_ws/config  (外参/参数 可选)
#   3. PX4 USB device passthrough (/dev/ttyUSB*)
#   4. ODIN USB passthrough (vendor 2207:0019) — --lidar odin 时
#   5. --network host  (Mid360 UDP, ODIN 不需要)
#   6. 首次启动容器内自动 colcon build (entrypoint 检测)
#
# 用法:
#   bash scripts/start_uav_container.sh                       # 启交互 shell (= start, 无 --bringup)
#   bash scripts/start_uav_container.sh start --bringup       # 显式 start + 自动跑 uav_bringup
#   bash scripts/start_uav_container.sh --bringup             # ↑ 同上, 隐含 start
#   bash scripts/start_uav_container.sh --bringup-gui         # + 启 noVNC
#   bash scripts/start_uav_container.sh --build               # 先 build 镜像再启
#   bash scripts/start_uav_container.sh --lidar mid360 --lidar-ip 192.168.1.150
#   bash scripts/start_uav_container.sh --lidar odin
#   bash scripts/start_uav_container.sh --fcu-url /dev/ttyACM0:57600
#   bash scripts/start_uav_container.sh --device /dev/ttyACM0
#   bash scripts/start_uav_container.sh stop | status | logs | exec | build
#
# 子命令 / 选项:
#   start (default) | stop | status | logs [-f] | exec <cmd...> | build
#   --build                   build 镜像 (docker build -f Dockerfile.uav)
#   --bringup                容器内自动跑 uav_bringup.launch.py
#   --bringup-gui            同上 + 自动起 noVNC
#   --lidar <mid360|odin>    雷达类型 (默认 mid360)
#   --lidar-ip <IP>          Mid-360 IP
#   --fcu-url <URL>          PX4 MAVLink URL (默认 /dev/ttyUSB0:921600)
#   --device </dev/...>      显式 mount PX4 USB device
#   --odin-usb <bus/dev>     ODIN USB (e.g. 001/002)
#   --novnc-port <port>      noVNC http 端口 (默认 6080)
#   --vnc-port <port>        x11vnc 端口 (默认 5999)
#   --src <dir>              源码目录 (默认 ${REPO_ROOT}/src)
#   --scripts <dir>          scripts 目录 (默认 ${REPO_ROOT}/scripts, 改 launch 不用 rebuild)
#   --workspace-dir <dir>    colcon 产物目录 install/build/log (默认 ${REPO_ROOT}/.colcon_ws)
#   --config <dir>           config 目录 (默认 ${REPO_ROOT}/config, 可选)
#   --image <name:tag>       镜像 (默认按 host 架构: uavsim:arm-v3.0 / uavsim:amd64-v3.0)
#   --name <name>            容器名 (默认 rm-uavsim)
#   --no-tty                 CI 模式
#   --rm                     容器退出即删
# =============================================================================

set -eo pipefail

# ---- 0. 路径 + 默认参数 ----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKERFILE="${REPO_ROOT}/Dockerfile.uav"
if [[ -z "${IMAGE_NAME:-}" ]]; then
    if [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]]; then
        IMAGE_NAME="uavsim:arm-v3.0"
    else
        IMAGE_NAME="uavsim:amd64-v3.0"
    fi
fi
CONTAINER_NAME="${CONTAINER_NAME:-rm-uavsim}"
SRC_DIR="${SRC_DIR:-${REPO_ROOT}/src}"
# colcon workspace artifacts (install/build/log) 持久化到 host, 避免每次重启重新 build
# 默认放 ${REPO_ROOT}/.colcon_ws, 不污染源码目录, .gitignore 覆盖
WORKSPACE_DIR="${WORKSPACE_DIR:-${REPO_ROOT}/.colcon_ws}"
# scripts/ 也挂进容器, 改 launch / entrypoint 不用 rebuild 镜像
SCRIPTS_DIR="${SCRIPTS_DIR:-${REPO_ROOT}/scripts}"
CONFIG_DIR="${CONFIG_DIR:-${REPO_ROOT}/config}"
LIDAR="${LIDAR:-mid360}"
LIVOX_LIDAR_IP="${LIVOX_LIDAR_IP:-192.168.1.1xx}"
FCU_URL="${FCU_URL:-/dev/ttyUSB0:921600}"
PX4_USB="${PX4_USB:-}"
ODIN_USB="${ODIN_USB:-}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_PORT="${VNC_PORT:-5999}"
BUILD_FLAG=""
BRINGUP_FLAG=""
BRINGUP_GUI_FLAG=""
TTY_FLAG="-it"
RM_FLAG=""
MOUNT_CONFIG="yes"

# ---- 1. 子命令 -------------------------------------------------------------
# 智能识别: 第一个参数如果是已知子命令 (start/stop/status/logs/exec/build)
# 则当作子命令; 否则隐含为 "start"
KNOWN_SUBCMDS="start stop status logs exec build"
FIRST_ARG="${1:-}"
if [[ -z "$FIRST_ARG" ]] || [[ " $KNOWN_SUBCMDS " == *" $FIRST_ARG "* ]]; then
    SUBCMD="${FIRST_ARG:-start}"
    shift || true
else
    SUBCMD="start"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build)        BUILD_FLAG="yes"; shift ;;
        --bringup)      BRINGUP_FLAG="yes"; shift ;;
        --bringup-gui)  BRINGUP_GUI_FLAG="yes"; BRINGUP_FLAG="yes"; shift ;;
        --lidar)        LIDAR="$2"; shift 2 ;;
        --lidar-ip)     LIVOX_LIDAR_IP="$2"; shift 2 ;;
        --fcu-url)      FCU_URL="$2"; shift 2 ;;
        --device)       PX4_USB="$2"; shift 2 ;;
        --odin-usb)     ODIN_USB="$2"; shift 2 ;;
        --novnc-port)   NOVNC_PORT="$2"; shift 2 ;;
        --vnc-port)     VNC_PORT="$2"; shift 2 ;;
        --src)          SRC_DIR="$2"; shift 2 ;;
        --scripts)       SCRIPTS_DIR="$2"; shift 2 ;;
        --workspace-dir)  WORKSPACE_DIR="$2"; shift 2 ;;
        --config)       CONFIG_DIR="$2"; shift 2 ;;
        --no-config)    MOUNT_CONFIG=""; shift ;;
        --image)        IMAGE_NAME="$2"; shift 2 ;;
        --name)         CONTAINER_NAME="$2"; shift 2 ;;
        --no-tty)       TTY_FLAG="-i"; shift ;;
        --rm)           RM_FLAG="--rm"; shift ;;
        -h|--help)
            sed -n '2,40p' "$0"; exit 0 ;;
        *)
            echo "[error] unknown option: $1" >&2
            exit 1 ;;
    esac
done

# ---- 2. helpers -------------------------------------------------------------
die() { echo "[error] $*" >&2; exit 1; }
info() { echo "[info] $*"; }

detect_px4_usb() {
    if [[ -n "$PX4_USB" ]]; then echo "$PX4_USB"; return; fi
    for d in /dev/ttyACM0 /dev/ttyACM1 /dev/ttyUSB0 /dev/ttyUSB1; do
        if [[ -e "$d" ]]; then echo "$d"; return; fi
    done
    echo ""
}

image_exists() {
    docker image inspect "$IMAGE_NAME" >/dev/null 2>&1
}

container_running() {
    docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' 2>/dev/null \
        | grep -qx "$CONTAINER_NAME"
}

container_exists() {
    docker ps -a --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' 2>/dev/null \
        | grep -qx "$CONTAINER_NAME"
}

# ---- 3. build ---------------------------------------------------------------
do_build() {
    if [[ ! -f "$DOCKERFILE" ]]; then
        die "Dockerfile.uav not found: $DOCKERFILE (应在 ${REPO_ROOT} 根)"
    fi

    # 自动按 host 架构选 base, 避免 docker.io 不通时拉 multi-arch manifest 超时
    # 允许 --base 显式覆盖, 也允许 BASE_IMAGE 环境变量
    if [[ -n "${BASE_IMAGE:-}" ]]; then
        BUILD_BASE="$BASE_IMAGE"
    elif [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]]; then
        # arm64 host: 用本地已 pull 的单架构 tag (免走 docker.io)
        BUILD_BASE="ubuntu:22.04-linuxarm64"
    else
        BUILD_BASE="ubuntu:22.04"
    fi
    info "build ${IMAGE_NAME} from ${DOCKERFILE} (base=${BUILD_BASE}, context: ${REPO_ROOT})"
    docker build \
        -f "$DOCKERFILE" \
        -t "$IMAGE_NAME" \
        --build-arg "BUILDKIT_INLINE_CACHE=1" \
        --build-arg "BASE_IMAGE=${BUILD_BASE}" \
        "$REPO_ROOT"
}

# ---- 4. docker run ----------------------------------------------------------
do_start() {
    if ! image_exists; then
        info "image ${IMAGE_NAME} not found, auto-build ..."
        do_build
    fi

    if container_running; then
        info "container ${CONTAINER_NAME} already running"
        info "  docker exec -it ${CONTAINER_NAME} bash"
        info "  bash scripts/start_uav_container.sh logs -f"
        exit 0
    fi

    if container_exists; then
        info "container ${CONTAINER_NAME} exists, removing ..."
        docker rm -f "$CONTAINER_NAME" >/dev/null
    fi

    # ---- 源码挂载 (核心: 迭代友好的关键) ---------------------------------
    if [[ ! -d "$SRC_DIR" ]]; then
        die "src 目录不存在: $SRC_DIR"
    fi
    info "mount src:  $SRC_DIR  ->  /opt/uav_ws/src"
    local mount_args=( -v "${SRC_DIR}:/opt/uav_ws/src" )

    # ---- scripts/ 挂载 (改 launch / entrypoint 不用 rebuild) ---------------
    # uav_bringup.launch.py / px4.launch.py / uav_entrypoint.sh 等都在 host 上,
    # 改了立即生效, 不用 docker build. Dockerfile 里 COPY 这些文件只是为了兜底
    # (host 没挂的时候 container 也能跑). mount 会优先于 COPY.
    if [[ -d "$SCRIPTS_DIR" ]]; then
        info "mount scripts: $SCRIPTS_DIR  ->  /opt/uav_ws/scripts"
        mount_args+=( -v "${SCRIPTS_DIR}:/opt/uav_ws/scripts" )
        # entrypoint.sh 单独再挂到 /usr/local/bin/ (容器启动走 ENTRYPOINT 这路径)
        if [[ -f "$SCRIPTS_DIR/uav_entrypoint.sh" ]]; then
            mount_args+=( -v "${SCRIPTS_DIR}/uav_entrypoint.sh:/usr/local/bin/uav_entrypoint.sh" )
        fi
    fi

    # ---- colcon artifacts (install/build/log) 持久化到 host ----------------
    # 首次启动: host 目录是空 → entrypoint 跑 colcon build → 产物落 host
    # 之后启动: install/setup.bash 存在 → entrypoint 跳过 build → 秒启
    # 强制 clean rebuild: rm -rf .colcon_ws/{install,build,log}/. 然后重启
    mkdir -p "$WORKSPACE_DIR/install" "$WORKSPACE_DIR/build" "$WORKSPACE_DIR/log"
    info "mount ws:   $WORKSPACE_DIR/{install,build,log}  ->  /opt/uav_ws/{install,build,log}"
    mount_args+=( -v "${WORKSPACE_DIR}/install:/opt/uav_ws/install" )
    mount_args+=( -v "${WORKSPACE_DIR}/build:/opt/uav_ws/build" )
    mount_args+=( -v "${WORKSPACE_DIR}/log:/opt/uav_ws/log" )
    mount_args+=( -v "/etc/udev/rules.d/99-odin-usb.rules:/etc/udev/rules.d/99-odin-usb.rules")

    # config 目录 (外参 yaml 等) — 可选, 不存在就跳过
    if [[ -n "$MOUNT_CONFIG" && -d "$CONFIG_DIR" ]]; then
        info "mount cfg:  $CONFIG_DIR  ->  /opt/uav_ws/config"
        mount_args+=( -v "${CONFIG_DIR}:/opt/uav_ws/config:ro" )
    fi

    # ---- device passthrough ----------------------------------------------
    local device_args=()
    local px4_dev
    px4_dev="$(detect_px4_usb)"
    if [[ -n "$px4_dev" ]]; then
        info "mount PX4 USB: $px4_dev"
        device_args+=(--device="$px4_dev")
    else
        info "no PX4 USB detected (/dev/ttyACM*, /dev/ttyUSB*), 跳过"
        info "  飞控在其它串口: --device </dev/xxx>"
    fi

    # ODIN USB: 优先用 --odin-usb <bus>/<dev> 显式指定, 否则按 vendor 2207:0019 找
    if [[ "$LIDAR" == "odin" ]]; then
        local odin_usb_path="/dev/bus/usb"
        if [[ -n "$ODIN_USB" ]]; then
            odin_usb_path="/dev/bus/usb/${ODIN_USB}"
        else
            # 自动检测: lsusb 找 vendor 2207 product 0019
            local odin_auto
            # mawk 不支持 match() 的数组捕获, 用 sed 提取 Bus/Device
            odin_auto=$(lsusb 2>/dev/null | grep "2207:0019" | head -1 \
                | sed -n 's/.*Bus \([0-9]\+\) Device \([0-9]\+\).*/\1\/\2/p')
            if [[ -n "$odin_auto" ]]; then
                odin_usb_path="/dev/bus/usb/${odin_auto}"
            fi
        fi
        if [[ -e "$odin_usb_path" ]]; then
            info "mount ODIN USB: $odin_usb_path"
            # 整个 USB bus 都给容器 (ODIN 是 USB 3.0 设备, 需整 bus)
            local bus_num="${odin_usb_path#/dev/bus/usb/}"; bus_num="${bus_num%%/*}"
            device_args+=(--device="/dev/bus/usb/${bus_num}" -v /dev/bus/usb:/dev/bus/usb)
        else
            info "[warn] --lidar odin 但找不到 ODIN USB (期望 vendor 2207:0019)"
            info "       lsusb 看一眼, 或 --odin-usb <bus>/<dev> 显式指定"
        fi
    fi

    # ---- port forwards (noVNC) -------------------------------------------
    local port_args=()
    if [[ -n "$BRINGUP_GUI_FLAG" ]]; then
        port_args+=(-p "${NOVNC_PORT}:6080")
        port_args+=(-p "${VNC_PORT}:5999")
    fi

    # ---- 决定启动后做什么 -----------------------------------------------
    local docker_cmd
    if [[ -n "$BRINGUP_GUI_FLAG" ]]; then
        docker_cmd="bash -lc 'set -e; \
            nohup start_uav_gui.sh > /tmp/uav_gui.log 2>&1 & \
            sleep 2; \
            ros2 launch /opt/uav_ws/scripts/uav_bringup.launch.py \
                lidar:=${LIDAR} fcu_url:=${FCU_URL}; \
            wait'"
    elif [[ -n "$BRINGUP_FLAG" ]]; then
        docker_cmd="ros2 launch /opt/uav_ws/scripts/uav_bringup.launch.py \
            lidar:=${LIDAR} fcu_url:=${FCU_URL}"
    else
        docker_cmd="bash"
    fi

    info "docker run image=${IMAGE_NAME} name=${CONTAINER_NAME}"
    info "  cmd: ${docker_cmd}"
    docker run $RM_FLAG \
        --name "$CONTAINER_NAME" \
        --hostname "$CONTAINER_NAME" \
        --restart unless-stopped \
        --network host \
        $TTY_FLAG \
        -d \
        "${device_args[@]}" \
        "${port_args[@]}" \
        "${mount_args[@]}" \
        -v /tmp/uav_logs:/tmp/uav_logs \
        -e LIVOX_LIDAR_IP="$LIVOX_LIDAR_IP" \
        -e FCU_URL="$FCU_URL" \
        -e ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}" \
        -e NOVNC_PORT="$NOVNC_PORT" \
        -e VNC_PORT="$VNC_PORT" \
        "$IMAGE_NAME" \
        bash -c "$docker_cmd"

    info "container ${CONTAINER_NAME} started"
    info ""
    info "iter 流程 (改代码 → 生效):"
    info "  1. 主机改 rm_ws/src/*/*.py → 容器内重启节点即生效 (--symlink-install)"
    info "  2. 改 fast_lio/*.cpp → bash scripts/start_uav_container.sh exec bash"
    info "     然后在容器内: cd /opt/uav_ws && colcon build --packages-select fast_lio"
    info ""
    info "useful commands:"
    info "  bash scripts/start_uav_container.sh logs -f"
    info "  bash scripts/start_uav_container.sh exec bash"
    info "  bash scripts/start_uav_container.sh status"
    info "  bash scripts/start_uav_container.sh stop"
    if [[ -n "$BRINGUP_GUI_FLAG" ]]; then
        info ""
        info "GUI:"
        info "  noVNC:   http://<host-ip>:${NOVNC_PORT}/vnc.html"
        info "  raw VNC: <host-ip>:${VNC_PORT}"
    fi
}

# ---- 5. subcommand dispatcher ----------------------------------------------
case "$SUBCMD" in
    start)
        [[ -n "$BUILD_FLAG" ]] && do_build
        do_start
        ;;
    stop)
        if container_running; then
            info "stopping ${CONTAINER_NAME} ..."
            docker stop "$CONTAINER_NAME"
            docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
            info "stopped"
        else
            info "${CONTAINER_NAME} not running"
        fi
        ;;
    status)
        if container_exists; then
            docker ps -a --filter "name=^${CONTAINER_NAME}$" \
                --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}"
            echo ""
            echo "=== last 15 log lines ==="
            docker logs --tail 15 "$CONTAINER_NAME" 2>&1 || true
            echo ""
            echo "=== mount check (是否挂载了源码) ==="
            docker exec "$CONTAINER_NAME" bash -lc \
                'ls -la /opt/uav_ws/src/ 2>&1 | head -10' 2>&1 || true
            echo ""
            echo "=== ROS topic check ==="
            docker exec "$CONTAINER_NAME" bash -lc \
                "source /opt/ros/\$ROS_DISTRO/setup.bash && \
                 [ -f /opt/uav_ws/install/setup.bash ] && source /opt/uav_ws/install/setup.bash && \
                 ros2 topic list 2>/dev/null | grep -E 'mavros|vision_pose|Odometry|livox|fast_lio' | head -20" \
                2>&1 || true
        else
            info "${CONTAINER_NAME} not created yet"
        fi
        ;;
    logs)
        if ! container_exists; then die "container not created"; fi
        shift || true
        docker logs "$@" "$CONTAINER_NAME"
        ;;
    exec)
        if ! container_running; then die "container not running"; fi
        docker exec $TTY_FLAG "$CONTAINER_NAME" "$@"
        ;;
    build) do_build ;;
    *)
        echo "[error] unknown subcommand: $SUBCMD" >&2
        echo "  try: start | stop | status | logs | exec | build" >&2
        exit 1
        ;;
esac
